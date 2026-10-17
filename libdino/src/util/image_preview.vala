using Gdk;

namespace Dino {

// Only compressed data for the first frame reaches the image decoder.
public class ImagePreview : Object {
    public Pixbuf pixbuf;
    public string? animation_format;

    private ImagePreview(Pixbuf pixbuf, string? animation_format = null) {
        this.pixbuf = pixbuf;
        this.animation_format = animation_format;
    }

    public static async ImagePreview load(File file, int max_width, int max_height, Cancellable? cancellable = null) throws Error {
        var request = new PreviewRequest(file, max_width, max_height);
        var task = new Task(request, cancellable, (source, result) => load.callback());
        task.run_in_thread((task, source, data, cancellable) => {
            try {
                var worker_request = (PreviewRequest) source;
                var stream = worker_request.file.read(cancellable);
                ImagePreview? preview = null;
                try {
                    preview = decode(stream, worker_request.max_width, worker_request.max_height, cancellable);
                } finally {
                    try {
                        stream.close();
                    } catch (Error e) { }
                }
                var result = Value(typeof(ImagePreview));
                result.set_object(preview);
                task.return_value(result);
            } catch (Error e) {
                task.return_error((owned) e);
            }
        });
        yield;
        Value result;
        task.propagate_value(out result);
        return (ImagePreview) result.get_object();
    }

    public static ImagePreview decode(InputStream input, int max_width, int max_height, Cancellable? cancellable = null) throws Error {
        if (max_width <= 0 || max_height <= 0) throw new IOError.INVALID_ARGUMENT("Invalid preview dimensions");
        var stream = new BufferedInputStream.sized(input, 4096);
        while (stream.peek_buffer().length < 12) {
            if (stream.fill(12 - stream.peek_buffer().length, cancellable) == 0) break;
        }
        unowned uint8[] prefix = stream.peek_buffer();
        if (matches(prefix, 0, "GIF87a") || matches(prefix, 0, "GIF89a")) {
            return decode_gif(stream, max_width, max_height, cancellable);
        }
        if (matches(prefix, 0, "RIFF") && matches(prefix, 8, "WEBP")) {
            return decode_webp(stream, max_width, max_height, cancellable);
        }
        var pixbuf = decode_still(stream, max_width, max_height, cancellable);
        return new ImagePreview(pixbuf.apply_embedded_orientation() ?? pixbuf);
    }

    private static Pixbuf decode_still(InputStream input, int max_width, int max_height, Cancellable? cancellable = null) throws Error {
        BufferedInputStream stream;
        if (input is BufferedInputStream) {
            stream = (BufferedInputStream) input;
        } else {
            stream = new BufferedInputStream.sized(input, 4096);
        }
        while (stream.peek_buffer().length < 4096 && stream.fill(4096 - stream.peek_buffer().length, cancellable) > 0) {
        }
        int orientation = read_orientation(stream.peek_buffer());
        var loader = new PixbufLoader();
        loader.size_prepared.connect((loader, width, height) => {
            // EXIF orientations 5-8 rotate by 90 degrees, so the bounding box
            // used for scaling has swapped dimensions.
            bool swapped = orientation >= 5 && orientation <= 8;
            int prepared_width = swapped ? height : width;
            int prepared_height = swapped ? width : height;
            double scale = double.min(1, double.min((double) max_width / prepared_width, (double) max_height / prepared_height));
            loader.set_size(int.max(1, (int) (width * scale)), int.max(1, (int) (height * scale)));
        });
        bool closed = false;
        try {
            var buffer = new uint8[4096];
            ssize_t count;
            while ((count = stream.read(buffer, cancellable)) > 0) loader.write(buffer[:count]);
            closed = true;
            loader.close();
            var pixbuf = loader.get_pixbuf();
            if (pixbuf == null) throw new IOError.INVALID_DATA("Image has no pixels");
            return pixbuf;
        } finally {
            if (!closed) {
                try {
                    loader.close();
                } catch (Error e) { }
            }
        }
    }

    private static int read_orientation(uint8[] data) {
        if (data.length < 4 || data[0] != 0xFF || data[1] != 0xD8) return 1;
        int pos = 2;
        while (pos + 4 <= data.length) {
            if (data[pos] != 0xFF) return 1;
            uint8 marker = data[pos + 1];
            if (marker == 0xD8 || marker == 0xD9) {
                pos += 2;
                continue;
            }
            if (marker == 0xDA) break;
            int length = (data[pos + 2] << 8) | data[pos + 3];
            if (length < 2 || pos + 2 + length > data.length) break;
            if (marker == 0xE1 && length >= 8 && matches(data, pos + 4, "Exif\0\0")) {
                return read_tiff_orientation(data, pos + 10, pos + 2 + length);
            }
            pos += 2 + length;
        }
        return 1;
    }

    private static uint read_u16(uint8[] data, int offset, int limit, bool little_endian) {
        if (offset + 2 > limit) return 0;
        if (little_endian) return data[offset] | (data[offset + 1] << 8);
        return (data[offset] << 8) | data[offset + 1];
    }

    private static uint read_u32(uint8[] data, int offset, int limit, bool little_endian) {
        if (offset + 4 > limit) return 0;
        if (little_endian) {
            return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24);
        }
        return (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
    }

    private static int read_tiff_orientation(uint8[] data, int offset, int limit) {
        if (offset + 8 > limit) return 1;
        bool little_endian;
        if (data[offset] == 'I' && data[offset + 1] == 'I') {
            little_endian = true;
        } else if (data[offset] == 'M' && data[offset + 1] == 'M') {
            little_endian = false;
        } else {
            return 1;
        }
        if (read_u16(data, offset + 2, limit, little_endian) != 42) return 1;
        int ifd = offset + (int) read_u32(data, offset + 4, limit, little_endian);
        if (ifd + 2 > limit) return 1;
        int entries = (int) read_u16(data, ifd, limit, little_endian);
        for (int i = 0; i < entries; i++) {
            int entry = ifd + 2 + i * 12;
            if (entry + 12 > limit) break;
            if (read_u16(data, entry, limit, little_endian) == 0x0112) {
                int value = (int) read_u16(data, entry + 8, limit, little_endian);
                return value >= 1 && value <= 8 ? value : 1;
            }
        }
        return 1;
    }

    private static bool matches(uint8[] data, int offset, string text) {
        if (data.length < offset + text.length) return false;
        for (int i = 0; i < text.length; i++) {
            if (data[offset + i] != text[i]) return false;
        }
        return true;
    }

    private static uint8[] read_exact(InputStream stream, int count, Cancellable? cancellable) throws Error {
        var bytes = new uint8[count];
        size_t read;
        stream.read_all(bytes, out read, cancellable);
        if (read != count) throw new IOError.INVALID_DATA("Truncated image");
        return bytes;
    }

    private static void skip_exact(InputStream stream, uint64 count, Cancellable? cancellable) throws Error {
        while (count > 0) {
            ssize_t skipped = stream.skip((size_t) uint64.min(count, 4096), cancellable);
            if (skipped == 0) throw new IOError.INVALID_DATA("Truncated image");
            count -= skipped;
        }
    }

    private static void gif_blocks(InputStream stream, ByteArray? first_frame, Cancellable? cancellable) throws Error {
        while (true) {
            var size = read_exact(stream, 1, cancellable);
            if (first_frame != null) first_frame.append(size);
            if (size[0] == 0) return;
            if (first_frame != null) first_frame.append(read_exact(stream, size[0], cancellable));
            else skip_exact(stream, size[0], cancellable);
        }
    }

    private static ImagePreview decode_gif(InputStream stream, int max_width, int max_height, Cancellable? cancellable) throws Error {
        var first_frame = new ByteArray();
        var header = read_exact(stream, 13, cancellable);
        first_frame.append(header);
        if ((header[10] & 0x80) != 0) {
            first_frame.append(read_exact(stream, 3 * (1 << ((header[10] & 7) + 1)), cancellable));
        }
        bool has_frame = false;
        bool animated = false;
        while (true) {
            uint8 block = read_exact(stream, 1, cancellable)[0];
            if (block == 0x3b) break;
            if (block == 0x21) {
                var label = read_exact(stream, 1, cancellable);
                // Only the first frame's graphic control affects its rendering.
                bool copy = !has_frame && label[0] == 0xf9;
                if (copy) {
                    first_frame.append(new uint8[] { block, label[0] });
                }
                gif_blocks(stream, copy ? first_frame : null, cancellable);
            } else if (block == 0x2c) {
                if (has_frame) {
                    animated = true;
                    break;
                }
                first_frame.append(new uint8[] { block });
                var descriptor = read_exact(stream, 9, cancellable);
                first_frame.append(descriptor);
                if ((descriptor[8] & 0x80) != 0) {
                    first_frame.append(read_exact(stream, 3 * (1 << ((descriptor[8] & 7) + 1)), cancellable));
                }
                first_frame.append(read_exact(stream, 1, cancellable)); // LZW code size
                gif_blocks(stream, first_frame, cancellable);
                has_frame = true;
            } else {
                throw new IOError.INVALID_DATA("Invalid GIF block");
            }
        }
        if (!has_frame) throw new IOError.INVALID_DATA("GIF has no image frame");
        first_frame.append(new uint8[] { 0x3b });
        var encoded = ByteArray.free_to_bytes((owned) first_frame);
        var frame_stream = new MemoryInputStream.from_bytes(encoded);
        return new ImagePreview(decode_still(frame_stream, max_width, max_height, cancellable), animated ? "GIF" : null);
    }

    private static uint32 little_endian(uint8[] bytes, int offset, int count) {
        uint32 value = 0;
        for (int i = 0; i < count; i++) value |= (uint32) bytes[offset + i] << (8 * i);
        return value;
    }

    private static void put_little_endian(uint8[] bytes, int offset, uint32 value, int count) {
        for (int i = 0; i < count; i++) bytes[offset + i] = (uint8) (value >> (8 * i));
    }

    private static ImagePreview decode_webp(InputStream stream, int max_width, int max_height, Cancellable? cancellable) throws Error {
        var header = read_exact(stream, 12, cancellable);
        uint64 remaining = little_endian(header, 4, 4);
        if (remaining < 4) throw new IOError.INVALID_DATA("Invalid WebP size");
        remaining -= 4;
        var encoded = new ByteArray();
        encoded.append(header);
        uint8[]? extended = null;
        uint32 background = 0;
        while (remaining >= 8) {
            var chunk = read_exact(stream, 8, cancellable);
            uint32 size = little_endian(chunk, 4, 4);
            uint64 padded = (uint64) size + (size & 1);
            remaining -= 8;
            if (padded > remaining || padded > int.MAX) throw new IOError.INVALID_DATA("Invalid WebP chunk size");
            if (matches(chunk, 0, "ANMF")) {
                if (extended == null || size < 16) throw new IOError.INVALID_DATA("Invalid WebP animation frame");
                var frame = read_exact(stream, 16, cancellable);
                int x = (int) little_endian(frame, 0, 3) * 2;
                int y = (int) little_endian(frame, 3, 3) * 2;
                int width = (int) little_endian(frame, 6, 3) + 1;
                int height = (int) little_endian(frame, 9, 3) + 1;
                int canvas_width = (int) little_endian(extended, 4, 3) + 1;
                int canvas_height = (int) little_endian(extended, 7, 3) + 1;
                if (x + width > canvas_width || y + height > canvas_height) throw new IOError.INVALID_DATA("WebP frame exceeds canvas");
                // Make a still WebP from this frame's compressed subchunks.
                encoded.append(read_exact(stream, (int) size - 16, cancellable));
                put_little_endian(encoded.data, 4, encoded.len - 8, 4);
                // VP8X is required to be the first chunk in extended WebP.
                encoded.data[20] &= 0x30; // Only ICC profile and alpha apply to the still frame.
                put_little_endian(encoded.data, 24, (uint32) width - 1, 3);
                put_little_endian(encoded.data, 27, (uint32) height - 1, 3);
                var bytes = ByteArray.free_to_bytes((owned) encoded);
                var frame_stream = new MemoryInputStream.from_bytes(bytes);
                double scale = double.min(1, double.min((double) max_width / canvas_width, (double) max_height / canvas_height));
                int target_width = int.max(1, (int) (canvas_width * scale));
                int target_height = int.max(1, (int) (canvas_height * scale));
                var pixbuf = new Pixbuf.from_stream_at_scale(frame_stream,
                    int.max(1, (int) Math.ceil(width * scale)), int.max(1, (int) Math.ceil(height * scale)), false, cancellable);
                var canvas = new Pixbuf(Colorspace.RGB, true, 8, target_width, target_height);
                canvas.fill(background);
                int dest_x = (int) (x * scale), dest_y = (int) (y * scale);
                int dest_width = int.min(pixbuf.width, target_width - dest_x);
                int dest_height = int.min(pixbuf.height, target_height - dest_y);
                if ((frame[15] & 2) != 0) pixbuf.copy_area(0, 0, dest_width, dest_height, canvas, dest_x, dest_y);
                else pixbuf.composite(canvas, dest_x, dest_y, dest_width, dest_height, dest_x, dest_y, 1, 1, InterpType.NEAREST, 255);
                return new ImagePreview(canvas, "WEBP");
            }
            if (matches(chunk, 0, "ANIM")) {
                if (size != 6) throw new IOError.INVALID_DATA("Invalid WebP animation header");
                var animation = read_exact(stream, 6, cancellable);
                background = ((uint32) animation[2] << 24) | ((uint32) animation[1] << 16) | ((uint32) animation[0] << 8) | animation[3];
            } else {
                encoded.append(chunk);
                var payload = read_exact(stream, (int) padded, cancellable);
                if (matches(chunk, 0, "VP8X")) {
                    if (size != 10 || extended != null || encoded.len != 20) throw new IOError.INVALID_DATA("Invalid WebP extended header");
                    extended = payload.copy();
                }
                encoded.append(payload);
            }
            remaining -= padded;
        }
        if (remaining != 0) throw new IOError.INVALID_DATA("Truncated WebP chunk header");
        put_little_endian(encoded.data, 4, encoded.len - 8, 4);
        var bytes = ByteArray.free_to_bytes((owned) encoded);
        return new ImagePreview(decode_still(new MemoryInputStream.from_bytes(bytes), max_width, max_height, cancellable).apply_embedded_orientation());
    }
}

private class PreviewRequest : Object {
    public File file;
    public int max_width;
    public int max_height;

    public PreviewRequest(File file, int max_width, int max_height) {
        this.file = file;
        this.max_width = max_width;
        this.max_height = max_height;
    }
}

}
