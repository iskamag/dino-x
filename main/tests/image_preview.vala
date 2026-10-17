using Dino.Ui;

namespace Dino.Ui.Test {

private string fixture_dir;
private bool have_display;

private ImagePreview preview(string name, int max_width = 600, int max_height = 300) throws Error {
    var stream = File.new_for_path(Path.build_filename(fixture_dir, name)).read();
    try {
        return ImagePreview.decode(stream, max_width, max_height);
    } finally {
        try { stream.close(); } catch (Error e) { }
    }
}

private void test_formats() {
    try {
        foreach (string extension in new string[] { "gif", "webp", "png" }) {
            var still = preview("static." + extension);
            assert_null(still.animation_format);
            assert_cmpint(still.pixbuf.width, CompareOperator.EQ, 4);
            assert_cmpint(still.pixbuf.height, CompareOperator.EQ, 4);
        }
        foreach (string extension in new string[] { "gif", "webp" }) {
            var animation = preview("animated." + extension);
            assert_cmpstr(animation.animation_format, CompareOperator.EQ, extension.up());
            // The second frame is blue: the preview must remain red.
            unowned uint8[] pixels = animation.pixbuf.get_pixels();
            assert_cmpint(pixels[0], CompareOperator.EQ, 255);
            assert_cmpint(pixels[2], CompareOperator.EQ, 0);
        }
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void test_scaling() {
    try {
        foreach (string name in new string[] { "static.png", "animated.gif", "animated.webp" }) {
            var image = preview(name, 2, 2);
            assert_cmpint(image.pixbuf.width, CompareOperator.EQ, 2);
            assert_cmpint(image.pixbuf.height, CompareOperator.EQ, 2);
        }
        var image = preview("interlaced.gif");
        assert_cmpint(image.pixbuf.width, CompareOperator.EQ, 32);
        assert_cmpint(image.pixbuf.get_pixels()[0], CompareOperator.EQ, 255);
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void test_orientation_scaling() {
    try {
        var image = preview("orientation-6.jpg", 60, 30);
        assert_true(image.pixbuf.width <= 60);
        assert_true(image.pixbuf.height <= 30);
        assert_true(image.pixbuf.height > image.pixbuf.width);
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void test_webp_alpha() {
    try {
        var image = preview("animated-alpha.webp");
        assert_cmpstr(image.animation_format, CompareOperator.EQ, "WEBP");
        assert_true(image.pixbuf.has_alpha);
        assert_cmpint(image.pixbuf.get_pixels()[3], CompareOperator.EQ, 128);
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void test_webp_offset() {
    try {
        var image = preview("animated-offset.webp");
        assert_cmpint(image.pixbuf.width, CompareOperator.EQ, 8);
        assert_cmpint(image.pixbuf.height, CompareOperator.EQ, 8);
        unowned uint8[] pixels = image.pixbuf.get_pixels();
        assert_cmpint(pixels[3], CompareOperator.EQ, 0);
        int offset = image.pixbuf.rowstride * 2 + 2 * image.pixbuf.n_channels;
        assert_cmpint(pixels[offset], CompareOperator.EQ, 255);
        assert_cmpint(pixels[offset + 3], CompareOperator.EQ, 255);
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void test_later_frames_not_decoded() {
    try {
        foreach (string extension in new string[] { "gif", "webp" }) {
            var image = preview("broken-second-frame." + extension);
            assert_cmpstr(image.animation_format, CompareOperator.EQ, extension.up());
            assert_cmpint(image.pixbuf.get_pixels()[0], CompareOperator.EQ, 255);
        }
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void test_truncated_image() {
    try {
        var image = ImagePreview.decode(new MemoryInputStream.from_data("GIF89a".data), 600, 300);
        GLib.Test.fail();
    } catch (Error e) { assert_true(e is IOError.INVALID_DATA); }
}

private void test_cancelled_load() {
    var loop = new MainLoop();
    var cancellable = new Cancellable();
    cancellable.cancel();
    ImagePreview.load.begin(File.new_for_path(Path.build_filename(fixture_dir, "animated.gif")), 600, 300, cancellable, (obj, result) => {
        try {
            var image = ImagePreview.load.end(result);
            GLib.Test.fail();
        } catch (Error e) { assert_true(e is IOError.CANCELLED); }
        loop.quit();
    });
    loop.run();
}

private void assert_marker(FileImageWidget widget, string? expected) {
    var overlay = widget.get_first_child() as Gtk.Overlay;
    bool found = false;
    for (Gtk.Widget? child = overlay.get_first_child(); child != null; child = child.get_next_sibling()) {
        var label = child as Gtk.Label;
        if (label != null && label.visible && (label.label == "GIF" || label.label == "WEBP")) {
            assert_cmpstr(label.label, CompareOperator.EQ, expected);
            found = true;
        }
    }
    assert_true(found == (expected != null));
}

private void test_texture_release() {
    if (!have_display) { GLib.Test.skip("No display available"); return; }
    var loop = new MainLoop();
    var widget = new FileImageWidget();
    widget.load_from_file.begin(File.new_for_path(Path.build_filename(fixture_dir, "animated.gif")), "animated.gif", (obj, result) => {
        try {
            widget.load_from_file.end(result);
            assert_marker(widget, "GIF");
            var overlay = widget.get_first_child() as Gtk.Overlay;
            var stack = overlay.child as Gtk.Stack;
            var picture = stack.visible_child as FixedRatioPicture;
            var texture_ref = WeakRef(picture.paintable);
            assert_nonnull(picture.paintable);
            // Retain the disposed row to ensure it releases its pixels immediately.
            widget.dispose();
            assert_null(texture_ref.get());
            widget.dispose();
            assert_null(stack.visible_child);
        } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
        loop.quit();
    });
    loop.run();
}

private void test_dispose_during_load() {
    if (!have_display) { GLib.Test.skip("No display available"); return; }
    var loop = new MainLoop();
    var widget = new FileImageWidget();
    var overlay = widget.get_first_child() as Gtk.Overlay;
    var stack = overlay.child as Gtk.Stack;
    widget.load_from_file.begin(File.new_for_path(Path.build_filename(fixture_dir, "animated.webp")), "animated.webp", (obj, result) => {
        try {
            widget.load_from_file.end(result);
        } catch (Error e) { assert_true(e is IOError.CANCELLED); }
        assert_null(stack.visible_child);
        loop.quit();
    });
    widget.dispose();
    loop.run();
}

private void test_preview_replacement() {
    if (!have_display) { GLib.Test.skip("No display available"); return; }
    var loop = new MainLoop();
    var widget = new FileImageWidget();
    widget.load_from_file.begin(File.new_for_path(Path.build_filename(fixture_dir, "animated.gif")), "animated.gif", (obj, result) => {
        try {
            widget.load_from_file.end(result);
            assert_marker(widget, "GIF");
            var overlay = widget.get_first_child() as Gtk.Overlay;
            var stack = overlay.child as Gtk.Stack;
            var picture = stack.visible_child as FixedRatioPicture;
            var texture_ref = WeakRef(picture.paintable);
            widget.load_from_file.begin(File.new_for_path(Path.build_filename(fixture_dir, "static.png")), "static.png", (obj, result) => {
                try {
                    widget.load_from_file.end(result);
                    assert_marker(widget, null);
                    assert_null(texture_ref.get());
                    assert_null(stack.get_first_child().get_next_sibling());
                    widget.dispose();
                } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
                loop.quit();
            });
        } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); loop.quit(); }
    });
    loop.run();
}

private void collect_images(Gtk.Widget widget, Gee.ArrayList<FileImageWidget> images) {
    if (widget is FileImageWidget) { images.add((FileImageWidget) widget); return; }
    for (Gtk.Widget? child = widget.get_first_child(); child != null; child = child.get_next_sibling()) collect_images(child, images);
}

private void test_grouped_images() {
    if (!have_display) { GLib.Test.skip("No display available"); return; }
    try {
        var bytes = File.new_for_path(Path.build_filename(fixture_dir, "static.png")).load_bytes();
        var transfers = new Gee.ArrayList<Dino.Entities.FileTransfer>();
        for (int i = 0; i < 3; i++) {
            var transfer = new Dino.Entities.FileTransfer() { file_name="image.png", width=8000, height=8000 };
            transfer.thumbnails.add(new Xmpp.Xep.JingleContentThumbnails.Thumbnail() { data=bytes });
            transfers.add(transfer);
        }
        var group = new ImageGroupWidget(transfers);
        var images = new Gee.ArrayList<FileImageWidget>();
        collect_images(group, images);
        assert_cmpint(images.size, CompareOperator.EQ, 3);
        var loop = new MainLoop();
        bool ready = false;
        uint timeout_id = 0;
        uint check_id = 0;
        timeout_id = Timeout.add_seconds(5, () => { timeout_id = 0; loop.quit(); return Source.REMOVE; });
        check_id = Timeout.add(10, () => {
            foreach (var image in images) {
                var overlay = image.get_first_child() as Gtk.Overlay;
                var stack = overlay.child as Gtk.Stack;
                if (stack.visible_child == null) return Source.CONTINUE;
            }
            ready = true;
            check_id = 0;
            loop.quit();
            return Source.REMOVE;
        });
        loop.run();
        if (timeout_id != 0) Source.remove(timeout_id);
        if (check_id != 0) Source.remove(check_id);
        assert_true(ready);
        foreach (var image in images) {
            var overlay = image.get_first_child() as Gtk.Overlay;
            var stack = overlay.child as Gtk.Stack;
            var picture = stack.visible_child as FixedRatioPicture;
            assert_cmpint(picture.paintable.get_intrinsic_width(), CompareOperator.LE, 600);
            assert_cmpint(picture.paintable.get_intrinsic_height(), CompareOperator.LE, 300);
        }
        var first_overlay = images[0].get_first_child() as Gtk.Overlay;
        var first_stack = first_overlay.child as Gtk.Stack;
        var first_picture = first_stack.visible_child as FixedRatioPicture;
        var texture_ref = WeakRef(first_picture.paintable);
        group.dispose();
        assert_null(texture_ref.get());
        assert_null(first_stack.visible_child);
        foreach (var image in images) assert_null(image.get_first_child());
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private class ImageRow : Dino.Plugins.MetaConversationItem {
    public signal void loaded();
    public weak FileImageWidget image;

    public override Object? get_widget(Dino.Plugins.ConversationItemWidgetInterface outer, Dino.Plugins.WidgetType type) {
        var widget = new FileImageWidget();
        image = widget;
        widget.load_from_file.begin(File.new_for_path(Path.build_filename(fixture_dir, "animated.webp")), "animated.webp", (obj, result) => {
            try {
                widget.load_from_file.end(result);
            } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
            loaded();
        });
        return widget;
    }

    public override Gee.List<Dino.Plugins.MessageAction>? get_item_actions(Dino.Plugins.WidgetType type) { return null; }
}

private void test_conversation_switch() {
    if (!have_display) { GLib.Test.skip("No display available"); return; }
    try {
        var app = new Dino.Ui.Application();
        var view = new Dino.Ui.ConversationSummary.ConversationView().init(app.stream_interactor);
        var account = new Dino.Entities.Account(Xmpp.Jid.from_string("preview@example.com"), "");
        var first = new Dino.Entities.Conversation(Xmpp.Jid.from_string("first@example.com"), account, Dino.Entities.Conversation.Type.GROUPCHAT);
        var second = new Dino.Entities.Conversation(Xmpp.Jid.from_string("second@example.com"), account, Dino.Entities.Conversation.Type.GROUPCHAT);
        view.initialize_for_conversation(first);
        while (MainContext.default().pending()) MainContext.default().iteration(false);
        var loop = new MainLoop();
        var item = new ImageRow();
        item.loaded.connect(loop.quit);
        view.do_insert_item(item);
        loop.run();
        var image = item.image;
        assert_marker(image, "WEBP");
        var overlay = image.get_first_child() as Gtk.Overlay;
        var stack = overlay.child as Gtk.Stack;
        var picture = stack.visible_child as FixedRatioPicture;
        var texture_ref = WeakRef(picture.paintable);
        // Keep the old row alive, as pending callbacks and highlighted items can.
        view.initialize_for_conversation(second);
        assert_null(texture_ref.get());
        assert_null(stack.visible_child);
        while (MainContext.default().pending()) MainContext.default().iteration(false);
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

int main(string[] args) {
    GLib.Test.init(ref args);
    fixture_dir = args[1];
    try {
        var test_dir = DirUtils.make_tmp("dino-preview-tests-XXXXXX");
        Environment.set_variable("XDG_DATA_HOME", test_dir, true);
        Environment.set_variable("XDG_CACHE_HOME", test_dir, true);
        Environment.set_variable("XDG_CONFIG_HOME", test_dir, true);
    } catch (Error e) { stderr.printf("%s\n", e.message); return 1; }
    have_display = Gtk.init_check();
    if (have_display) Adw.init();
    GLib.Test.add_func("/preview/formats", test_formats);
    GLib.Test.add_func("/preview/scaling", test_scaling);
    GLib.Test.add_func("/preview/orientation-scaling", test_orientation_scaling);
    GLib.Test.add_func("/preview/webp-alpha", test_webp_alpha);
    GLib.Test.add_func("/preview/webp-offset", test_webp_offset);
    GLib.Test.add_func("/preview/first-frame-only", test_later_frames_not_decoded);
    GLib.Test.add_func("/preview/truncated", test_truncated_image);
    GLib.Test.add_func("/preview/cancelled", test_cancelled_load);
    GLib.Test.add_func("/preview/texture-release", test_texture_release);
    GLib.Test.add_func("/preview/dispose-during-load", test_dispose_during_load);
    GLib.Test.add_func("/preview/replacement", test_preview_replacement);
    GLib.Test.add_func("/preview/conversation-switch", test_conversation_switch);
    GLib.Test.add_func("/preview/grouped-images", test_grouped_images);
    add_regression_tests();
    add_message_state_regression_tests();
    add_call_state_regression_tests();
    return GLib.Test.run();
}

}
