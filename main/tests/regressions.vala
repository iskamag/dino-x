using Dino.Entities;

namespace Dino.Ui.Test {

// Exercise the real core services and application actions without opening a window.
private class ServiceTestApplication : GLib.Application, Dino.Application {
    public Database db { get; set; }
    public Entities.Settings settings { get; set; }
    public StreamInteractor stream_interactor { get; set; }
    public Plugins.Registry plugin_registry { get; set; default = new Plugins.Registry(); }
    public SearchPathGenerator? search_path_generator { get; set; }

    public ServiceTestApplication() throws Error {
        Object(application_id: "im.dino.Dino.RegressionTests", flags: ApplicationFlags.NON_UNIQUE);
        init();
    }

    public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
}

private ServiceTestApplication? service_app;

private ServiceTestApplication get_service_app() throws Error {
    if (service_app == null) service_app = new ServiceTestApplication();
    GLib.Application.set_default(service_app);
    return service_app;
}

private Account create_account(ServiceTestApplication app) throws Error {
    var account = new Account(Xmpp.Jid.from_string(Xmpp.random_uuid() + "@example.com"), "");
    account.persist(app.db);
    return account;
}

private void check_retraction(bool outgoing, bool groupchat) {
    try {
        var app = get_service_app();
        var account = create_account(app);
        var peer = Xmpp.Jid.from_string(groupchat ? "room@example.com/peer" : "peer@example.com/device");
        var conversation = new Conversation(groupchat ? peer.bare_jid : peer, account,
            groupchat ? Conversation.Type.GROUPCHAT : Conversation.Type.CHAT);
        conversation.persist(app.db);
        string reference_id = Xmpp.random_uuid();
        var original = new Entities.Message("Original message") {
            account=account, counterpart=peer, ourpart=account.bare_jid, direction=outgoing,
            type_=groupchat ? Entities.Message.Type.GROUPCHAT : Entities.Message.Type.CHAT,
            stanza_id=reference_id, server_id=reference_id,
            time=new DateTime.now_utc(), local_time=new DateTime.now_utc()
        };
        app.stream_interactor.get_module(MessageStorage.IDENTITY).add_message(original, conversation);
        app.stream_interactor.get_module(ContentItemStore.IDENTITY).insert_message(original, conversation);
        var deletion = app.stream_interactor.get_module(MessageDeletion.IDENTITY);
        int deleted = 0;
        ulong handler = deletion.item_deleted.connect(() => deleted++);
        var stanza = new Xmpp.MessageStanza() { from=peer, to=account.bare_jid };
        Xmpp.Xep.MessageRetraction.set_retract_id(stanza, reference_id);
        var request = new Entities.Message(null) { counterpart=peer, ourpart=account.bare_jid, direction=false };
        var loop = new MainLoop();
        deletion.run.begin(request, stanza, conversation, (obj, result) => {
            deletion.run.end(result);
            loop.quit();
        });
        loop.run();
        deletion.disconnect(handler);
        bool allowed = !outgoing && !groupchat;
        assert_cmpint(deleted, CompareOperator.EQ, allowed ? 1 : 0);
        assert_cmpstr(original.body, CompareOperator.EQ, allowed ? "" : "Original message");
        // The decision must also hold in persistent history, not just in the cached object.
        var row = app.db.message.select().with(app.db.message.id, "=", original.id).row().inner;
        string stored_body = row[app.db.message.body];
        assert_cmpstr(stored_body, CompareOperator.EQ, original.body);
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private Gtk.Stack image_stack(FileImageWidget image) {
    var overlay = image.get_first_child() as Gtk.Overlay;
    assert_nonnull(overlay);
    return overlay.child as Gtk.Stack;
}

private FileTransmissionProgress image_progress(FileImageWidget image) {
    var overlay = image.get_first_child();
    for (Gtk.Widget? child = overlay.get_first_child(); child != null; child = child.get_next_sibling()) {
        if (child is FileTransmissionProgress) return (FileTransmissionProgress) child;
    }
    assert_not_reached();
}

private FileTransfer image_transfer() {
    return new FileTransfer() {
        file_name="image.png", content_type=new Xmpp.FileContentType.from_mime_type("image/png"),
        width=4, height=4, size=1024
    };
}

private void check_cancel_transfer(bool outgoing) {
    if (!have_display) { GLib.Test.skip("No display available"); return; }
    try {
        var app = get_service_app();
        app.register();
        var transfer = image_transfer();
        transfer.account = create_account(app);
        transfer.counterpart = Xmpp.Jid.from_string("peer@example.com");
        transfer.ourpart = transfer.account.bare_jid;
        transfer.time = transfer.local_time = new DateTime.now_utc();
        transfer.direction = outgoing;
        transfer.state = FileTransfer.State.IN_PROGRESS;
        app.stream_interactor.get_module(FileTransferStorage.IDENTITY).add_file(transfer);
        var widget = new FileImageWidget.from_file_transfer(transfer);
        var progress = image_progress(widget);
        assert_true(progress.state == (outgoing ? FileTransmissionProgress.State.UPLOADING : FileTransmissionProgress.State.DOWNLOADING));
        var button = progress.get_child() as Gtk.Button;
        button.clicked();
        assert_true(transfer.cancellable.is_cancelled());
        widget.dispose();
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void test_large_image_groups() {
    if (!have_display) { GLib.Test.skip("No display available"); return; }
    try {
        var bytes = File.new_for_path(Path.build_filename(fixture_dir, "static.png")).load_bytes();
        for (int count = 2; count <= 9; count++) {
            var transfers = new Gee.ArrayList<FileTransfer>();
            for (int i = 0; i < count; i++) {
                var transfer = image_transfer();
                transfer.size = 1024 + i;
                transfer.thumbnails.add(new Xmpp.Xep.JingleContentThumbnails.Thumbnail() { data=bytes });
                transfers.add(transfer);
            }
            var group = new ImageGroupWidget(transfers);
            var images = new Gee.ArrayList<FileImageWidget>();
            collect_images(group, images);
            assert_cmpint(images.size, CompareOperator.EQ, count);
            for (int i = 0; i < count; i++) {
                assert_cmpint((int) image_progress(images[i]).file_size, CompareOperator.EQ, 1024 + i);
                wait_for_stack_child(image_stack(images[i]), typeof(FixedRatioPicture));
            }
            group.dispose();
            foreach (var image in images) assert_null(image.get_first_child());
        }
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void wait_for_stack_child(Gtk.Stack stack, Type child_type) {
    if (stack.visible_child != null && stack.visible_child.get_type().is_a(child_type)) return;
    var loop = new MainLoop();
    ulong handler = stack.notify["visible-child"].connect(() => {
        if (stack.visible_child != null && stack.visible_child.get_type().is_a(child_type)) loop.quit();
    });
    bool timed_out = false;
    uint timeout = Timeout.add_seconds(5, () => { timed_out = true; loop.quit(); return Source.REMOVE; });
    loop.run();
    stack.disconnect(handler);
    if (!timed_out) Source.remove(timeout);
    assert_false(timed_out);
    assert_true(stack.visible_child.get_type().is_a(child_type));
}

private void check_broken_image(bool grouped) {
    if (!have_display) { GLib.Test.skip("No display available"); return; }
    try {
        var transfer = image_transfer();
        transfer.path = Xmpp.random_uuid() + ".png";
        transfer.state = FileTransfer.State.COMPLETE;
        DirUtils.create_with_parents(FileManager.get_storage_dir(), 0700);
        FileUtils.set_contents(transfer.get_file().get_path(), "not an image");
        Gtk.Widget widget;
        if (grouped) {
            var transfers = new Gee.ArrayList<FileTransfer>();
            transfers.add(transfer);
            transfers.add(transfer);
            widget = new ImageGroupWidget(transfers);
        } else {
            widget = new FileWidget(transfer);
        }
        var images = new Gee.ArrayList<FileImageWidget>();
        collect_images(widget, images);
        assert_cmpint(images.size, CompareOperator.EQ, grouped ? 2 : 1);
        foreach (var image in images) {
            var stack = image_stack(image);
            wait_for_stack_child(stack, typeof(FileDefaultWidget));
            var fallback = stack.visible_child as FileDefaultWidget;
            assert_cmpstr(fallback.name_label.label, CompareOperator.EQ, transfer.file_name);
            assert_nonnull(fallback.file_menu.popover);
            assert_false(image_progress(image).visible);
        }
        widget.dispose();
        foreach (var image in images) assert_null(image.get_first_child());
        transfer.get_file().delete();
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void test_broken_thumbnail_recovery() {
    if (!have_display) { GLib.Test.skip("No display available"); return; }
    try {
        var transfer = image_transfer();
        transfer.thumbnails.add(new Xmpp.Xep.JingleContentThumbnails.Thumbnail() { data=new Bytes("broken".data) });
        var widget = new FileImageWidget.from_file_transfer(transfer);
        var stack = image_stack(widget);
        wait_for_stack_child(stack, typeof(FileDefaultWidget));
        var fallback_ref = WeakRef(stack.visible_child);
        transfer.path = Xmpp.random_uuid() + ".png";
        DirUtils.create_with_parents(FileManager.get_storage_dir(), 0700);
        File.new_for_path(Path.build_filename(fixture_dir, "static.png")).copy(transfer.get_file(), FileCopyFlags.NONE);
        transfer.state = FileTransfer.State.COMPLETE;
        wait_for_stack_child(stack, typeof(FixedRatioPicture));
        var picture = stack.visible_child as FixedRatioPicture;
        assert_nonnull(picture);
        assert_nonnull(picture.paintable);
        assert_null(fallback_ref.get());
        widget.dispose();
        transfer.get_file().delete();
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void add_regression_tests() {
    GLib.Test.add_func("/messages/retraction-denied", () => check_retraction(true, false));
    GLib.Test.add_func("/messages/retraction-allowed", () => check_retraction(false, false));
    GLib.Test.add_func("/messages/retraction-muc-denied", () => check_retraction(false, true));
    GLib.Test.add_func("/files/cancel-download", () => check_cancel_transfer(false));
    GLib.Test.add_func("/files/cancel-upload", () => check_cancel_transfer(true));
    GLib.Test.add_func("/files/large-image-groups", test_large_image_groups);
    GLib.Test.add_func("/files/broken-image", () => check_broken_image(false));
    GLib.Test.add_func("/files/broken-grouped-image", () => check_broken_image(true));
    GLib.Test.add_func("/files/broken-thumbnail-recovery", test_broken_thumbnail_recovery);
}

}
