using Dino.Entities;

namespace Dino.Plugins.OpenPgp {

public class PgpFileDecryptor : FileDecryptor, Object {

    private class DecryptRequest : Object {
        public string input_path;
        public string output_path;
    }

    public Encryption get_encryption() {
        return Encryption.PGP;
    }

    public FileReceiveData prepare_get_meta_info(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) {
        return receive_data;
    }

    public FileMeta prepare_download_file(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data, FileMeta file_meta) {
        return file_meta;
    }

    public bool can_decrypt_file(Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) {
        return file_transfer.file_name.has_suffix("pgp") ||
                (file_transfer.content_type != null && file_transfer.content_type.get_mime_type() == "application/pgp-encrypted");
    }

    public async InputStream decrypt_file(InputStream encrypted_stream, Conversation conversation, FileTransfer file_transfer, FileReceiveData receive_data) throws FileReceiveError {
        File? encrypted_file = null;
        File? clear_file = null;

        try {
            GLib.FileIOStream encrypted_stream_handle;
            encrypted_file = File.new_tmp("dino-pgp-encrypted-XXXXXX", out encrypted_stream_handle);
            encrypted_stream_handle.close(null);

            var output = encrypted_file.replace(null, false, FileCreateFlags.REPLACE_DESTINATION, null);
            var buffer = new uint8[64 * 1024];
            ssize_t read;
            try {
                while ((read = yield encrypted_stream.read_async(buffer, GLib.Priority.LOW)) > 0) {
                    yield output.write_async(buffer[:read], GLib.Priority.LOW);
                }
            } catch (Error e) {
                try {
                    yield output.close_async(GLib.Priority.LOW);
                } catch (Error close_error) { }
                throw e;
            }
            yield output.close_async(GLib.Priority.LOW);

            GLib.FileIOStream clear_stream_handle;
            clear_file = File.new_tmp("dino-pgp-clear-XXXXXX", out clear_stream_handle);
            clear_stream_handle.close(null);

            var request = new DecryptRequest() {
                input_path = encrypted_file.get_path(),
                output_path = clear_file.get_path()
            };
            var task = new GLib.Task(request, null, (source, result) => decrypt_file.callback());
            task.run_in_thread((task, source, data, cancellable) => {
                try {
                    var decrypt_request = (DecryptRequest) source;
                    string? filename = GPGHelper.decrypt_file_to_file(decrypt_request.input_path, decrypt_request.output_path);
                    var value = GLib.Value(typeof(string));
                    value.set_string(filename ?? "");
                    task.return_value(value);
                } catch (Error e) {
                    task.return_error((owned) e);
                }
            });
            yield;

            GLib.Value result;
            task.propagate_value(out result);
            string? decrypted_filename = result.get_string();

            file_transfer.encryption = Encryption.PGP;
            if (decrypted_filename != null && decrypted_filename != "") {
                debug("Decrypting file %s from %s", decrypted_filename, file_transfer.file_name);
                file_transfer.file_name = decrypted_filename;
            } else if (file_transfer.file_name.has_suffix(".pgp")) {
                debug("Decrypting file %s from %s", file_transfer.file_name.substring(0, file_transfer.file_name.length - 4), file_transfer.file_name);
                file_transfer.file_name = file_transfer.file_name.substring(0, file_transfer.file_name.length - 4);
            }

            var decrypted = clear_file.read(null);
            clear_file.delete(null);
            encrypted_file.delete(null);
            return decrypted;
        } catch (Error e) {
            if (encrypted_file != null) {
                try {
                    encrypted_file.delete(null);
                } catch (Error delete_error) { }
            }
            if (clear_file != null) {
                try {
                    clear_file.delete(null);
                } catch (Error delete_error) { }
            }
            throw new FileReceiveError.DECRYPTION_FAILED("PGP file decryption error: %s".printf(e.message));
        }
    }
}

}
