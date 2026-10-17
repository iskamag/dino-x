namespace Xmpp.Test {

class ModuleHardeningTest : Gee.TestCase {
    public ModuleHardeningTest() {
        base("ModuleHardening");
        add_test("stream_management_ack_without_h", test_sm_ack_without_h);
        add_test("stream_management_resumed_without_h", test_sm_resumed_without_h);
        add_test("occupant_id_status_without_code", test_occupant_id_status_without_code);
        add_test("raw_udp_invalid_candidates", test_raw_udp_invalid_candidates);
        add_test("raw_udp_valid_candidate", test_raw_udp_valid_candidate);
        add_test("presence_empty_priority", test_presence_empty_priority);
        add_async_test("iq_write_failure_propagates", (cb) => { test_iq_write_failure.begin(cb); });
        add_async_test("iq_request_cancellation", (cb) => { test_iq_cancellation.begin(cb); });
    }

    private class HardeningStream : IoXmppStream {
        public HardeningStream() {
            base(test_domain());
            reset_stream(new SimpleIOStream(new MemoryInputStream(), new MemoryOutputStream.resizable()));
            add_module(new Bind.Module(null));
        }

        private static Jid test_domain() {
            try { return Jid.from_string("example.org"); }
            catch (InvalidJidError e) { assert_not_reached(); }
        }

        public override async void connect() throws IOError {}
    }

    private void test_sm_ack_without_h() {
        var stream = new HardeningStream();
        var module = new Xep.StreamManagement.Module();
        stream.add_module(module);
        module.attach(stream);
        stream.add_flag(new Xep.StreamManagement.Flag());
        module.on_enabled(stream, new StanzaNode.build("enabled", Xep.StreamManagement.NS_URI).put_attribute("id", "session"));

        stream.received_nonza(stream, new StanzaNode.build("a", Xep.StreamManagement.NS_URI));
        fail_if_not_eq_int(module.h_outbound, 0);
    }

    private void test_sm_resumed_without_h() {
        var module = new Xep.StreamManagement.Module();
        var original = new HardeningStream();
        original.add_module(module);
        module.attach(original);
        original.add_flag(new Xep.StreamManagement.Flag());
        module.on_enabled(original, new StanzaNode.build("enabled", Xep.StreamManagement.NS_URI).put_attribute("id", "session"));

        module.detach(original);
        var stream = new HardeningStream();
        stream.add_module(module);
        module.attach(stream);
        stream.add_flag(new Xep.StreamManagement.Flag());

        module.on_resumed(stream, new StanzaNode.build("resumed", Xep.StreamManagement.NS_URI));
        fail_if_not_eq_int(module.h_outbound, 0);
    }

    private void test_occupant_id_status_without_code() {
        var stream = new HardeningStream();
        var presence = new Presence.Stanza();
        presence.stanza = new StanzaNode.build("presence")
            .put_node(new StanzaNode.build("occupant-id", Xep.OccupantIds.NS_URI).put_attribute("id", "abc"))
            .put_node(new StanzaNode.build("x", Xep.Muc.NS_URI_USER)
                .put_node(new StanzaNode.build("status", Xep.Muc.NS_URI_USER)));

        var module = new Xep.OccupantIds.Module();
        module.parse_occupant_id_from_presence(stream, presence);
    }

    private void test_raw_udp_invalid_candidates() {
        var transport = new StanzaNode.build("transport", Xep.JingleRawUdp.NS_URI)
            .put_node(new StanzaNode.build("candidate", Xep.JingleRawUdp.NS_URI));
        var parameters = new Xep.JingleRawUdp.TransportParameters(1, transport);
        fail_if_not_eq_int(parameters.remote_candidates.size, 0);
    }

    private void test_raw_udp_valid_candidate() {
        var transport = new StanzaNode.build("transport", Xep.JingleRawUdp.NS_URI)
            .put_node(new StanzaNode.build("candidate", Xep.JingleRawUdp.NS_URI)
                .put_attribute("component", "1")
                .put_attribute("generation", "0")
                .put_attribute("id", "cand-1")
                .put_attribute("ip", "192.0.2.1")
                .put_attribute("port", "50000"));
        var parameters = new Xep.JingleRawUdp.TransportParameters(1, transport);
        fail_if_not_eq_int(parameters.remote_candidates.size, 1);
        fail_if_not_eq_str(parameters.remote_candidates[0].id, "cand-1");
        fail_if_not_eq_int(parameters.remote_candidates[0].component, 1);
        fail_if_not_eq_uint(parameters.remote_candidates[0].port, 50000);

        parameters.own_candidates.add(parameters.remote_candidates[0]);
        var xml = parameters.to_transport_stanza_node("transport-info");
        fail_if_not_eq_str(xml.get_subnode("candidate", Xep.JingleRawUdp.NS_URI).get_attribute("component"), "1");
    }

    private class FailingWriteStream : HardeningStream {
        public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
            throw new IOError.FAILED("write failed");
        }
    }

    private async void test_iq_write_failure(Gee.TestFinishedCallback cb) {
        var stream = new FailingWriteStream();
        var module = new Iq.Module();
        stream.add_module(module);
        module.attach(stream);
        var iq = new Iq.Stanza.get(new StanzaNode.build("ping", "urn:xmpp:ping").add_self_xmlns());
        bool failed = false;
        try {
            yield module.send_iq_async(stream, iq);
        } catch (IOError e) {
            failed = true;
        }
        fail_if_not(failed, "IQ write error was not propagated");
        cb();
    }

    private async void test_iq_cancellation(Gee.TestFinishedCallback cb) {
        var stream = new HardeningStream();
        var module = new Iq.Module();
        stream.add_module(module);
        module.attach(stream);
        var iq = new Iq.Stanza.get(new StanzaNode.build("ping", "urn:xmpp:ping").add_self_xmlns());
        var cancellable = new Cancellable();
        Timeout.add(10, () => { cancellable.cancel(); return false; });
        bool cancelled = false;
        try {
            yield module.send_iq_async(stream, iq, Priority.DEFAULT, cancellable);
        } catch (IOError.CANCELLED e) {
            cancelled = true;
        }
        fail_if_not(cancelled, "cancelled IQ request did not return");
        cb();
    }

    private void test_presence_empty_priority() {
        var presence = new Presence.Stanza();
        presence.stanza.put_node(new StanzaNode.build(Presence.Stanza.NODE_PRIORITY));
        fail_if_not_eq_int(presence.priority, 0);
    }
}

}
