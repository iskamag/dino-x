namespace Xmpp.Test {

class StreamManagementTest : Gee.TestCase {
    public StreamManagementTest() {
        base("StreamManagement");
        add_test("resume_preserves_wire_order", test_resume_order);
        add_test("queued_messages_preserve_order", test_queue_order);
        add_test("resume_partial_ack_preserves_wire_order", test_partial_ack_order);
        add_test("resume_survives_connection_cancellation", test_connection_cancellation);
        add_test("explicit_cancellation_is_respected", test_explicit_cancellation);
        add_test("resume_drains_queue_after_connection_cancellation", test_cancelled_connection_queue);
        add_test("resume_failure_waits_for_bind", test_resume_failure_waits_for_bind);
        add_test("non_resumable_connection_drains_queue", test_non_resumable_connection_drains_queue);
    }

    private class CaptureLog : XmppLog {
        public Gee.List<string> message_ids = new Gee.ArrayList<string>();

        public override bool should_log_node(StanzaNode node) {
            if (node.name == "message") message_ids.add(node.get_attribute("id"));
            return false;
        }
    }

    private class MemoryStream : IoXmppStream {
        public CaptureLog capture = new CaptureLog();

        public MemoryStream() {
            base(test_domain());
            reset_stream(new SimpleIOStream(new MemoryInputStream(), new MemoryOutputStream.resizable()));
            log = capture;
            add_module(new Bind.Module(null));
        }

        private static Jid test_domain() {
            try { return Jid.from_string("example.org"); }
            catch (InvalidJidError e) { assert_not_reached(); }
        }

        public override async void connect() throws IOError {}
    }

    private MemoryStream enable(Xep.StreamManagement.Module module) {
        var stream = new MemoryStream();
        stream.add_module(module);
        module.attach(stream);
        stream.add_flag(new Xep.StreamManagement.Flag());
        module.on_enabled(stream, new StanzaNode.build("enabled", Xep.StreamManagement.NS_URI).put_attribute("id", "session"));
        return stream;
    }

    private MemoryStream resume(Xep.StreamManagement.Module module, MemoryStream old_stream, int h = 0) {
        module.detach(old_stream);
        var stream = new MemoryStream();
        stream.add_module(module);
        module.attach(stream);
        stream.add_flag(new Xep.StreamManagement.Flag());
        module.on_resumed(stream, new StanzaNode.build("resumed", Xep.StreamManagement.NS_URI).put_attribute("h", h.to_string()));
        return stream;
    }

    private void send(MemoryStream stream, int number, int priority = Priority.DEFAULT, Cancellable? cancellable = null) {
        var stanza = new StanzaNode.build("message", JABBER_URI).put_attribute("id", "m%d".printf(number));
        stream.write_async.begin(stanza, priority, cancellable, (obj, result) => {
            try { stream.write_async.end(result); }
            catch (IOError.CANCELLED e) {}
            catch (Error e) {
                // Sessions abandoned by the resume-failure tests leave their
                // in-flight stanzas failed asynchronously.
                if (!e.message.contains("not acked and") && !e.message.contains("stream management is unavailable")) fail_if_reached(e.message);
            }
        });
    }

    private void ack(MemoryStream stream, int h) {
        stream.received_nonza(stream, new StanzaNode.build("a", Xep.StreamManagement.NS_URI).put_attribute("h", h.to_string()));
    }

    private void test_resume_order() {
        var module = new Xep.StreamManagement.Module();
        var original = enable(module);
        for (int i = 1; i <= 10; i++) send(original, i, i % 2 == 0 ? Priority.LOW : Priority.DEFAULT);
        send(original, 11, Priority.HIGH);

        var resumed = resume(module, original);
        fail_if_not_eq_int(resumed.capture.message_ids.size, 10);
        for (int i = 0; i < resumed.capture.message_ids.size; i++) {
            fail_if_not_eq_str(resumed.capture.message_ids[i], "m%d".printf(i + 1));
        }
        ack(resumed, 10);
        fail_if_not_eq_int(resumed.capture.message_ids.size, 11);
        fail_if_not_eq_str(resumed.capture.message_ids[10], "m11");
        ack(resumed, 11);
    }

    private void test_partial_ack_order() {
        var module = new Xep.StreamManagement.Module();
        var original = enable(module);
        for (int i = 1; i <= 10; i++) send(original, i, i % 2 == 0 ? Priority.LOW : Priority.DEFAULT);
        send(original, 11, Priority.HIGH);

        var resumed = resume(module, original, 4);
        fail_if_not_eq_int(resumed.capture.message_ids.size, 7);
        for (int i = 0; i < resumed.capture.message_ids.size; i++) {
            fail_if_not_eq_str(resumed.capture.message_ids[i], "m%d".printf(i + 5));
        }
        ack(resumed, 11);
    }

    private void test_queue_order() {
        var module = new Xep.StreamManagement.Module();
        var stream = enable(module);
        for (int i = 1; i <= 20; i++) send(stream, i);
        ack(stream, 10);
        fail_if_not_eq_int(stream.capture.message_ids.size, 20);
        for (int i = 0; i < stream.capture.message_ids.size; i++) {
            fail_if_not_eq_str(stream.capture.message_ids[i], "m%d".printf(i + 1));
        }
        ack(stream, 20);
    }

    private void test_connection_cancellation() {
        var module = new Xep.StreamManagement.Module();
        var original = enable(module);
        send(original, 1);
        original.cancel();
        var resumed = resume(module, original);
        fail_if_not_eq_int(resumed.capture.message_ids.size, 1);
        if (resumed.capture.message_ids.size > 0) fail_if_not_eq_str(resumed.capture.message_ids[0], "m1");
        ack(resumed, 1);
    }

    private void test_cancelled_connection_queue() {
        var module = new Xep.StreamManagement.Module();
        var original = enable(module);
        for (int i = 1; i <= 20; i++) send(original, i);
        original.cancel();

        var resumed = resume(module, original);
        fail_if_not_eq_int(resumed.capture.message_ids.size, 10);
        ack(resumed, 10);
        fail_if_not_eq_int(resumed.capture.message_ids.size, 20);
        for (int i = 0; i < resumed.capture.message_ids.size; i++) {
            fail_if_not_eq_str(resumed.capture.message_ids[i], "m%d".printf(i + 1));
        }
        ack(resumed, 20);
    }

    private void test_resume_failure_waits_for_bind() {
        var module = new Xep.StreamManagement.Module();
        var original = enable(module);
        for (int i = 1; i <= 11; i++) send(original, i);

        module.detach(original);
        var stream = new MemoryStream();
        stream.add_module(module);
        module.attach(stream);
        stream.add_flag(new Xep.StreamManagement.Flag());

        module.on_resume_failed(stream, new StanzaNode.build("failed", Xep.StreamManagement.NS_URI));
        fail_if_not_eq_int(stream.capture.message_ids.size, 0);

        module.on_enabled(stream, new StanzaNode.build("enabled", Xep.StreamManagement.NS_URI).put_attribute("id", "new-session"));
        fail_if_not_eq_int(stream.capture.message_ids.size, 1);
        if (stream.capture.message_ids.size > 0) fail_if_not_eq_str(stream.capture.message_ids[0], "m11");
    }

    private void test_non_resumable_connection_drains_queue() {
        var module = new Xep.StreamManagement.Module();
        var original = enable(module);
        for (int i = 1; i <= 20; i++) send(original, i);

        module.detach(original);
        var stream = new MemoryStream();
        stream.add_module(module);
        module.attach(stream);

        // Bind on a stream without the SM feature: stanzas left in flight by the
        // old session must fail instead of waiting forever, and the rest of the
        // queue must be written without waiting for acknowledgements.
        stream.get_module(Bind.Module.IDENTITY).bound_to_resource(stream, stream.remote_name);

        fail_if_not_eq_int(stream.capture.message_ids.size, 10);
        for (int i = 0; i < stream.capture.message_ids.size; i++) {
            fail_if_not_eq_str(stream.capture.message_ids[i], "m%d".printf(i + 11));
        }
    }

    private void test_explicit_cancellation() {
        var module = new Xep.StreamManagement.Module();
        var original = enable(module);
        var operation = new Cancellable();
        send(original, 1, Priority.DEFAULT, operation);
        operation.cancel();
        var resumed = resume(module, original);
        fail_if_not_eq_int(resumed.capture.message_ids.size, 0);
    }
}
}