namespace Xmpp.Test {

class ModuleHardeningTest : Gee.TestCase {
    public ModuleHardeningTest() {
        base("ModuleHardening");
        add_test("stream_management_ack_without_h", test_sm_ack_without_h);
        add_test("stream_management_resumed_without_h", test_sm_resumed_without_h);
        add_test("occupant_id_status_without_code", test_occupant_id_status_without_code);
        add_test("muc_occupant_leave_keeps_affiliation", test_muc_occupant_leave_keeps_affiliation);
        add_test("raw_udp_invalid_candidates", test_raw_udp_invalid_candidates);
        add_test("raw_udp_valid_candidate", test_raw_udp_valid_candidate);
        add_test("presence_empty_priority", test_presence_empty_priority);
        add_test("ice_candidate_missing_attrs", test_ice_candidate_missing_attrs);
        add_test("namespace_scoping", test_namespace_scoping);
        add_async_test("iq_write_failure_propagates", (cb) => { test_iq_write_failure.begin(cb); });
        add_async_test("iq_request_cancellation", (cb) => { test_iq_cancellation.begin(cb); });
        add_async_test("entity_time_failure_cleans_up", (cb) => { test_entity_time_failure.begin(cb); });
        add_async_test("pubsub_write_failure_releases_listener", (cb) => { test_pubsub_write_failure.begin(cb); });
        add_async_test("pubsub_timeout_releases_listener", (cb) => { test_pubsub_timeout.begin(cb); });
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

    private void test_muc_occupant_leave_keeps_affiliation() {
        var stream = new HardeningStream();
        stream.add_module(new Presence.Module());
        stream.add_module(new MessageModule());
        stream.add_module(new Xep.ServiceDiscovery.Module());
        stream.add_module(new Xep.Muc.Module());
        stream.add_flag(new Xep.ServiceDiscovery.Flag());
        var bind_flag = new Bind.Flag();
        bind_flag.my_jid = Jid.from_string("me@example.org/me");
        stream.add_flag(bind_flag);

        var presence_module = stream.get_module(Presence.Module.IDENTITY);
        presence_module.attach(stream);
        var muc_module = stream.get_module(Xep.Muc.Module.IDENTITY);
        muc_module.attach(stream);
        var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);

        var room = Jid.from_string("room@muc.example");
        var alice = Jid.from_string("room@muc.example/alice");
        var alice_real = Jid.from_string("alice@example.org");
        flag.set_muc_nick(room.with_resource("me"));

        stream.received_presence_stanza(stream, new StanzaNode.build("presence", "jabber:client")
            .put_attribute("from", alice.to_string())
            .put_node(new StanzaNode.build("x", Xep.Muc.NS_URI_USER)
                .put_node(new StanzaNode.build("item", Xep.Muc.NS_URI_USER)
                    .put_attribute("affiliation", "admin")
                    .put_attribute("jid", alice_real.to_string())
                    .put_attribute("role", "moderator"))));

        fail_if(flag.get_affiliation(room, alice) != Xep.Muc.Affiliation.ADMIN);
        fail_if(flag.get_affiliation(room, alice_real) != Xep.Muc.Affiliation.ADMIN);
        fail_if(flag.get_real_jid(alice) == null);
        fail_if(flag.get_occupant_role(alice) != Xep.Muc.Role.MODERATOR);

        stream.received_presence_stanza(stream, new StanzaNode.build("presence", "jabber:client")
            .put_attribute("from", alice.to_string())
            .put_attribute("type", "unavailable")
            .put_node(new StanzaNode.build("x", Xep.Muc.NS_URI_USER)));

        // The occupant-specific entry goes away, the persistent real-JID
        // affiliation stays.
        fail_if(flag.get_real_jid(alice) != null);
        fail_if(flag.get_occupant_role(alice) != Xep.Muc.Role.NONE);
        fail_if(flag.get_affiliation(room, alice) != Xep.Muc.Affiliation.NONE);
        fail_if(flag.get_affiliation(room, alice_real) != Xep.Muc.Affiliation.ADMIN);
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

    private async void test_entity_time_failure(Gee.TestFinishedCallback cb) {
        var stream = new FailingWriteStream();
        var iq_module = new Iq.Module();
        stream.add_module(iq_module);
        iq_module.attach(stream);
        var time_module = new Xep.EntityTime.Module();
        time_module.enabled = true;
        var jid = Jid.from_string("peer@example.com");

        DateTime? first = yield time_module.query_time(stream, jid);
        fail_if_not(first == null);
        // A failed request must not leave a pending future behind.
        DateTime? second = yield time_module.query_time(stream, jid);
        fail_if_not(second == null);
        cb();
    }

    private void test_namespace_scoping() {
        var root = new NamespaceState.for_stanza();
        fail_if_not_eq_str(root.current_ns_uri, "jabber:client");
        var child = root.push();
        child.add_assoc("urn:test", "t");
        child.set_current("urn:current");
        fail_if_not_eq_str(child.find_uri("t"), "urn:test");
        fail_if_not_eq_str(child.find_uri("stream"), "http://etherx.jabber.org/streams");
        fail_if_not_eq_str(child.current_ns_uri, "urn:current");
        fail_if_not_eq_str(root.current_ns_uri, "jabber:client");

        bool missing = false;
        try { root.find_uri("t"); } catch (IOError e) { missing = true; }
        fail_if_not(missing);

        var inner = child.push();
        inner.set_current("urn:inner");
        fail_if_not_eq_str(inner.current_ns_uri, "urn:inner");
        fail_if_not_eq_str(child.current_ns_uri, "urn:current");
        fail_if_not_eq_str(child.pop().current_ns_uri, "jabber:client");
    }

    private void test_ice_candidate_missing_attrs() {
        bool threw = false;
        try {
            Xep.JingleIceUdp.Candidate.parse(new StanzaNode.build("candidate", Xep.JingleIceUdp.NS_URI));
        } catch (Xep.Jingle.IqError e) {
            threw = true;
        }
        fail_if_not(threw);
    }

    private void test_presence_empty_priority() {
        var presence = new Presence.Stanza();
        presence.stanza.put_node(new StanzaNode.build(Presence.Stanza.NODE_PRIORITY));
        fail_if_not_eq_int(presence.priority, 0);
    }

    private class SilentWriteStream : HardeningStream {
        public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
            // Pretend the write succeeded but never deliver an IQ result.
        }
    }

    private class RequestOutcome : Object {
        public bool called = false;
        public bool success = true;
    }

    private static Jid hardening_jid(string jid) {
        try {
            return Jid.from_string(jid);
        } catch (InvalidJidError e) {
            assert_not_reached();
        }
    }

    private async void test_pubsub_write_failure(Gee.TestFinishedCallback cb) {
        var stream = new FailingWriteStream();
        var iq_module = new Iq.Module();
        stream.add_module(iq_module);
        iq_module.attach(stream);
        var pubsub = new Xep.Pubsub.Module();
        stream.add_module(pubsub);

        var outcome = new RequestOutcome();
        pubsub.request(stream, hardening_jid("peer@example.org"), "node", (stream, jid, id, node, success) => {
            outcome.called = true;
            outcome.success = success;
        });

        var loop = new MainLoop();
        Timeout.add(200, () => { loop.quit(); return false; });
        loop.run();

        fail_if_not(outcome.called, "pubsub listener was not released on write failure");
        fail_if(outcome.success, "pubsub write failure reported as success");
        cb();
    }

    private async void test_pubsub_timeout(Gee.TestFinishedCallback cb) {
        var stream = new SilentWriteStream();
        var iq_module = new Iq.Module();
        stream.add_module(iq_module);
        iq_module.attach(stream);
        var pubsub = new Xep.Pubsub.Module();
        stream.add_module(pubsub);
        pubsub.request_timeout_seconds = 1;

        var outcome = new RequestOutcome();
        var loop = new MainLoop();
        pubsub.request(stream, hardening_jid("peer@example.org"), "node", (stream, jid, id, node, success) => {
            outcome.called = true;
            outcome.success = success;
            loop.quit();
        });
        Timeout.add_seconds(3, () => { loop.quit(); return false; });
        loop.run();

        fail_if_not(outcome.called, "pubsub listener was not released on timeout");
        fail_if(outcome.success, "pubsub timeout reported as success");
        cb();
    }

}


}
