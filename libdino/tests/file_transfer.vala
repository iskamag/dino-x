using Dino;
using Dino.Entities;

private class FileTestApplication : GLib.Application, Dino.Application {
    public Dino.Database db { get; set; }
    public Entities.Settings settings { get; set; }
    public StreamInteractor stream_interactor { get; set; }
    public Plugins.Registry plugin_registry { get; set; default = new Plugins.Registry(); }
    public SearchPathGenerator? search_path_generator { get; set; }

    public FileTestApplication() throws Error {
        Object(application_id: "im.dino.FileTransferTests", flags: ApplicationFlags.NON_UNIQUE);
        init();
    }

    public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
}

private FileTestApplication app;

private FileTransfer create_transfer(string url, int64 size) throws Error {
    var account = new Account(Xmpp.Jid.from_string(Xmpp.random_uuid() + "@example.com"), "");
    account.persist(app.db);
    app.stream_interactor.module_manager.initialize(account);
    // Set up the local service caches without connecting an account to a server.
    app.stream_interactor.account_added(account);
    var peer = Xmpp.Jid.from_string("peer@example.com");
    app.stream_interactor.get_module(ConversationManager.IDENTITY).create_conversation(peer, account, Conversation.Type.CHAT);
    var transfer = new FileTransfer() {
        account=account, counterpart=peer, ourpart=account.bare_jid, file_name="file.txt", size=size,
        provider=FileManager.SFS_PROVIDER_ID
    };
    transfer.sfs_sources.add(new Xmpp.Xep.StatelessFileSharing.HttpSource() { url=url });
    return transfer;
}

private Soup.Server create_server() throws Error {
    var server = new Soup.Server("server-header", "Dino tests");
    server.listen_local(0, Soup.ServerListenOptions.IPV4_ONLY);
    return server;
}

private async void check_http_status() throws Error {
    var server = create_server();
    server.add_handler(null, (server, message, path, query) => {
        message.set_status(path == "/ok" ? 200 : 404, null);
        message.set_response("text/plain", Soup.MemoryUse.COPY, "response".data);
    });
    var http = app.stream_interactor.get_module(FileManager2.IDENTITY).http_ft;
    foreach (string path in new string[] { "missing", "ok" }) {
        var url = server.get_uris().data.to_string() + path;
        var transfer = create_transfer(url, -1);
        var receive_data = new HttpFileReceiveData() { url=url };
        bool metadata_failed = false;
        try {
            var metadata = yield http.request_meta_data(transfer, receive_data, new FileMeta());
            assert_cmpint((int) metadata.size, CompareOperator.EQ, 8);
        } catch (FileReceiveError.GET_METADATA_FAILED e) {
            metadata_failed = true;
        }
        assert_true(metadata_failed == (path == "missing"));
        bool download_failed = false;
        try {
            var input = yield http.download(transfer, receive_data);
            yield input.close_async();
        } catch (IOError.FAILED e) {
            download_failed = true;
        }
        assert_true(download_failed == (path == "missing"));
    }
    server.disconnect();
}

private async void check_download_status() throws Error {
    var server = create_server();
    server.add_handler(null, (server, message, path, query) => {
        message.set_status(403, null);
        message.set_response("text/plain", Soup.MemoryUse.COPY, "denied".data);
    });
    var transfer = create_transfer(server.get_uris().data.to_string() + "file.txt", 6);
    GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*Error downloading file:*status code 403*");
    yield app.stream_interactor.get_module(FileManager.IDENTITY).download_file(transfer);
    GLib.Test.assert_expected_messages();
    assert_cmpint(transfer.state, CompareOperator.EQ, FileTransfer.State.NOT_STARTED);
    assert_null(transfer.path);
    server.disconnect();
}

private async void check_cancel_retry(bool during_metadata) throws Error {
    var server = create_server();
    var transfer = create_transfer(server.get_uris().data.to_string() + "file.txt", during_metadata ? -1 : 8);
    var manager = app.stream_interactor.get_module(FileManager.IDENTITY);
    int requests = 0;
    bool duplicate_finished = false;
    server.add_handler(null, (server, message, path, query) => {
        requests++;
        if (requests == 1) {
            assert_cmpint(transfer.state, CompareOperator.EQ, FileTransfer.State.IN_PROGRESS);
            transfer.cancellable.cancel();
            // A duplicate activation must neither start another request nor reset
            // the cancellable while the first task is still pending.
            manager.download_file.begin(transfer, (obj, result) => {
                manager.download_file.end(result);
                duplicate_finished = true;
            });
            assert_true(transfer.cancellable.is_cancelled());
        }
        message.set_status(200, null);
        message.set_response("text/plain", Soup.MemoryUse.COPY, "response".data);
    });
    if (during_metadata) {
        GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*Error downloading file: HEAD request failed*");
    }
    yield manager.download_file(transfer);
    if (during_metadata) GLib.Test.assert_expected_messages();
    assert_cmpint(requests, CompareOperator.EQ, 1);
    assert_true(duplicate_finished);
    assert_cmpint(transfer.state, CompareOperator.EQ, FileTransfer.State.NOT_STARTED);
    assert_true(transfer.cancellable.is_cancelled());

    yield manager.download_file(transfer);
    assert_false(transfer.cancellable.is_cancelled());
    assert_cmpint(transfer.state, CompareOperator.EQ, FileTransfer.State.COMPLETE);
    assert_cmpint(requests, CompareOperator.EQ, during_metadata ? 3 : 2);
    string contents;
    FileUtils.get_contents(transfer.get_file().get_path(), out contents);
    assert_cmpstr(contents, CompareOperator.EQ, "response");
    transfer.get_file().delete();
    server.disconnect();
}

private async void check_truncated_download() throws Error {
    var server = create_server();
    server.add_handler(null, (server, message, path, query) => {
        message.set_status(200, null);
        message.set_response("text/plain", Soup.MemoryUse.COPY, "abc".data);
    });
    var transfer = create_transfer(server.get_uris().data.to_string() + "file.txt", 100000);
    GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*Download truncated*");
    yield app.stream_interactor.get_module(FileManager.IDENTITY).download_file(transfer);
    GLib.Test.assert_expected_messages();
    assert_cmpint(transfer.state, CompareOperator.EQ, FileTransfer.State.NOT_STARTED);
    assert_null(transfer.path);

    // The partial file must not be left behind.
    var enumerator = File.new_for_path(FileManager.get_storage_dir()).enumerate_children("*", FileQueryInfoFlags.NONE);
    FileInfo? info;
    while ((info = enumerator.next_file(null)) != null) {
        if (info.get_name().has_suffix("file.txt")) GLib.Test.fail();
    }
    server.disconnect();
}

private void check_query_sql_args() {
    var row = app.db.query_sql("SELECT ? AS value", new string[] { "hello" }).get_next();
    assert_nonnull(row);
    assert_cmpstr(row.get_text("value"), CompareOperator.EQ, "hello");
}

private void check_file_transfer_info_index() {
    var row = app.db.query_sql("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'file_transfer_info_idx'").get_next();
    assert_nonnull(row);
}

private void run_check(int check) {
    var loop = new MainLoop();
    run_check_async.begin(check, (obj, result) => {
        try { run_check_async.end(result); }
        catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
        loop.quit();
    });
    loop.run();
}

private async void run_check_async(int check) throws Error {
    switch (check) {
        case 0: yield check_http_status(); break;
        case 1: yield check_download_status(); break;
        case 2: yield check_cancel_retry(false); break;
        case 3: yield check_cancel_retry(true); break;
        case 4: yield check_truncated_download(); break;
    }
}

int main(string[] args) {
    GLib.Test.init(ref args);
    try {
        var directory = DirUtils.make_tmp("dino-file-transfer-tests-XXXXXX");
        Environment.set_variable("XDG_DATA_HOME", directory, true);
        Environment.set_variable("XDG_CONFIG_HOME", directory, true);
        Environment.set_variable("XDG_CACHE_HOME", directory, true);
        app = new FileTestApplication();
        GLib.Application.set_default(app);
    } catch (Error e) { stderr.printf("%s\n", e.message); return 1; }
    GLib.Test.add_func("/file-transfers/http-status", () => run_check(0));
    GLib.Test.add_func("/file-transfers/download-status", () => run_check(1));
    GLib.Test.add_func("/file-transfers/cancel-retry", () => run_check(2));
    GLib.Test.add_func("/file-transfers/cancel-metadata-retry", () => run_check(3));
    GLib.Test.add_func("/file-transfers/truncated-download", () => run_check(4));
    GLib.Test.add_func("/file-transfers/query-sql-args", check_query_sql_args);
    GLib.Test.add_func("/file-transfers/info-index", check_file_transfer_info_index);
    return GLib.Test.run();
}
