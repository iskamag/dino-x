using Dino.Entities;
using Dino.Plugins.OpenPgp;

private static string test_dir;

private static bool run_gpg(string[] argv) {
    int status = -1;
    string standard_output;
    string standard_error;
    try {
        Process.spawn_sync(test_dir, argv, null, SpawnFlags.SEARCH_PATH, null, out standard_output, out standard_error, out status);
    } catch (Error e) {
        GLib.Test.message(e.message);
        return false;
    }
    if (status != 0) GLib.Test.message(standard_error);
    return status == 0;
}

private static int count_temp_files() {
    int count = 0;
    var directory = File.new_for_path(Environment.get_tmp_dir());
    try {
        var enumerator = directory.enumerate_children("standard::name", FileQueryInfoFlags.NONE);
        FileInfo? info;
        while ((info = enumerator.next_file(null)) != null) {
            if (info.get_name().has_prefix("dino-pgp-")) count++;
        }
    } catch (Error e) { }
    return count;
}

private void test_file_roundtrip() {
    try {
        string home = Path.build_filename(test_dir, "gnupg");
        DirUtils.create_with_parents(home, 0700);
        Environment.set_variable("GNUPGHOME", home, true);

        if (!run_gpg(new string[] { "gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
                "--quick-generate-key", "Dino Test <test@example.com>", "default", "default", "never" })) {
            GLib.Test.fail();
            return;
        }

        var plain = new uint8[1024 * 1024 + 7];
        for (int i = 0; i < plain.length; i++) plain[i] = (uint8) (i * 31);
        string plain_path = Path.build_filename(test_dir, "plain.bin");
        var plain_output = File.new_for_path(plain_path).replace(null, false, FileCreateFlags.REPLACE_DESTINATION, null);
        plain_output.write_all(plain, null);
        plain_output.close(null);

        var keys = GPGHelper.get_keylist("test@example.com");
        assert_cmpint(keys.size, CompareOperator.GT, 0);
        string encrypted_path = Path.build_filename(test_dir, "encrypted.pgp");
        int64 encrypted_size = GPGHelper.encrypt_file_to_file(plain_path, encrypted_path, keys.to_array(),
                GPG.EncryptFlags.ALWAYS_TRUST, "plain.bin");
        assert_cmpint((int) encrypted_size, CompareOperator.GT, 0);

        int temp_files_before = count_temp_files();
        var encrypted_stream = File.new_for_path(encrypted_path).read(null);
        var decryptor = new PgpFileDecryptor();
        var transfer = new FileTransfer() {
            file_name = "plain.bin.pgp",
            content_type = new Xmpp.FileContentType.from_mime_type("application/pgp-encrypted")
        };

        var account = new Account(Xmpp.Jid.from_string("test@example.com"), "");
        var conversation = new Conversation(Xmpp.Jid.from_string("peer@example.com"), account, Conversation.Type.CHAT);

        var loop = new MainLoop();
        InputStream? clear_stream = null;
        Error? decryption_error = null;
        decryptor.decrypt_file.begin(encrypted_stream, conversation, transfer, new Dino.FileReceiveData(), (obj, result) => {
            try {
                clear_stream = decryptor.decrypt_file.end(result);
            } catch (Error e) {
                decryption_error = e;
            }
            loop.quit();
        });
        loop.run();

        assert_true(decryption_error == null);
        assert_nonnull(clear_stream);
        assert_cmpstr(transfer.file_name, CompareOperator.EQ, "plain.bin");
        assert_cmpint(transfer.encryption, CompareOperator.EQ, Encryption.PGP);

        var clear_bytes = new ByteArray();
        var buffer = new uint8[64 * 1024];
        while (true) {
            ssize_t read = ((!)clear_stream).read(buffer, null);
            if (read <= 0) break;
            clear_bytes.append(buffer[:read]);
        }
        assert_cmpint((int) clear_bytes.len, CompareOperator.EQ, plain.length);
        assert_true(Memory.cmp(clear_bytes.data, plain, plain.length) == 0);
        assert_cmpint(count_temp_files(), CompareOperator.EQ, temp_files_before);
    } catch (Error e) {
        GLib.Test.fail();
        GLib.Test.message(e.message);
    }
}

int main(string[] args) {
    GLib.Test.init(ref args);
    try {
        test_dir = DirUtils.make_tmp("dino-openpgp-file-tests-XXXXXX");
    } catch (Error e) {
        stderr.printf("%s\n", e.message);
        return 1;
    }
    GLib.Test.add_func("/openpgp/file-roundtrip", test_file_roundtrip);
    return GLib.Test.run();
}
