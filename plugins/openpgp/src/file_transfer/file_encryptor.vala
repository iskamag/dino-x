using Dino.Entities;

namespace Dino.Plugins.OpenPgp {

public class PgpFileEncryptor : Dino.FileEncryptor, Object {

    private class EncryptRequest : Object {
        public string input_path;
        public string output_path;
        public GPG.Key[] keys;
        public string file_name;
    }

    StreamInteractor stream_interactor;

    public PgpFileEncryptor(StreamInteractor stream_interactor) {
        this.stream_interactor = stream_interactor;
    }

    public bool can_encrypt_file(Conversation conversation, FileTransfer file_transfer) {
        return conversation.encryption == Encryption.PGP;
    }

    public async FileMeta encrypt_file(Conversation conversation, FileTransfer file_transfer) throws FileSendError {
        FileMeta file_meta = new FileMeta();
        File? encrypted_file = null;

        try {
            GPG.Key[] keys = stream_interactor.get_module(Manager.IDENTITY).get_key_fprs(conversation);

            GLib.FileIOStream iostream;
            encrypted_file = File.new_tmp("dino-pgp-XXXXXX", out iostream);
            iostream.close(null);

            var request = new EncryptRequest() {
                input_path = file_transfer.get_file().get_path(),
                output_path = encrypted_file.get_path(),
                keys = keys,
                file_name = file_transfer.file_name
            };
            var task = new GLib.Task(request, null, (source, result) => encrypt_file.callback());
            task.run_in_thread((task, source, data, cancellable) => {
                try {
                    var encrypt_request = (EncryptRequest) source;
                    int64 size = GPGHelper.encrypt_file_to_file(encrypt_request.input_path, encrypt_request.output_path,
                            encrypt_request.keys, GPG.EncryptFlags.ALWAYS_TRUST, encrypt_request.file_name);
                    var value = GLib.Value(typeof(int64));
                    value.set_int64(size);
                    task.return_value(value);
                } catch (Error e) {
                    task.return_error((owned) e);
                }
            });
            yield;

            GLib.Value result;
            task.propagate_value(out result);
            file_meta.size = result.get_int64();

            if (file_transfer.input_stream != null) {
                try {
                    yield file_transfer.input_stream.close_async(GLib.Priority.LOW, null);
                } catch (Error e) { }
            }
            file_transfer.input_stream = encrypted_file.read(null);
            file_transfer.encryption = Encryption.PGP;
            file_transfer.server_file_name = Xmpp.random_uuid() + ".pgp";
            encrypted_file.delete(null);
            encrypted_file = null;
        } catch (Error e) {
            if (encrypted_file != null) {
                try {
                    encrypted_file.delete(null);
                } catch (Error delete_error) { }
            }
            throw new FileSendError.ENCRYPTION_FAILED("PGP file encryption error: %s".printf(e.message));
        }
        debug("Encrypting file %s as %s", file_transfer.file_name, file_transfer.server_file_name);

        return file_meta;
    }

    public FileSendData? preprocess_send_file(Conversation conversation, FileTransfer file_transfer, FileSendData file_send_data, FileMeta file_meta) {
        HttpFileSendData? send_data = file_send_data as HttpFileSendData;
        if (send_data == null) return null;

        send_data.encrypt_message = false;

        return file_send_data;
    }
}

}
