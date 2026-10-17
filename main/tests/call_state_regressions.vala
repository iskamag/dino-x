using Dino.Entities;

namespace Dino.Ui.Test {

private void check_call_invite_termination(bool rejected_on_other_device) {
    try {
        var app = get_service_app();
        var account = create_account(app);
        var interactor = app.stream_interactor;
        interactor.module_manager.initialize(account);
        interactor.account_added(account);
        // No media plugin is needed for a ringing invite. Initialize its abstract
        // protocol class so PeerState can look up the optional module normally.
        var rtp_class = typeof(Xmpp.Xep.JingleRtp.Module).class_ref();
        assert_nonnull(rtp_class);
        var calls = interactor.get_module(Calls.IDENTITY);
        var invites = interactor.module_manager.get_module(account, Xmpp.Xep.CallInvites.Module.IDENTITY);
        var peer = Xmpp.Jid.from_string("peer@example.com/device");
        var local = account.bare_jid.with_resource("desktop");
        var other_device = account.bare_jid.with_resource("phone");
        string call_id = Xmpp.random_uuid();
        Call? received_call = null;
        int terminations = 0;
        ulong incoming_handler = calls.call_incoming.connect((call) => received_call = call);
        ulong terminated_handler = calls.call_terminated.connect((call) => {
            if (call == received_call) terminations++;
        });
        var methods = new Gee.ArrayList<Xmpp.StanzaNode>();
        methods.add(new Xmpp.StanzaNode.build("jingle", Xmpp.Xep.CallInvites.NS_URI).put_attribute("sid", call_id));
        var stanza = new Xmpp.MessageStanza() { from=peer, to=local, type_=Xmpp.MessageStanza.TYPE_CHAT };
        invites.call_proposed(peer, local, call_id, false, methods, stanza);
        calls.disconnect(incoming_handler);
        assert_nonnull(received_call);
        assert_true(calls.call_states.has_key(received_call));
        assert_true(calls.jmi_request_peer.has_key(received_call));

        for (int i = 0; i < 2; i++) {
            if (rejected_on_other_device) {
                invites.call_rejected(other_device, peer, call_id, Xmpp.MessageStanza.TYPE_CHAT);
            } else {
                invites.call_retracted(peer, local, call_id, Xmpp.MessageStanza.TYPE_CHAT);
            }
            assert_false(calls.call_states.has_key(received_call));
            assert_false(calls.jmi_request_peer.has_key(received_call));
            assert_cmpint(terminations, CompareOperator.EQ, 1);
        }
        assert_true(received_call.state == (rejected_on_other_device ? Call.State.DECLINED : Call.State.MISSED));
        calls.disconnect(terminated_handler);
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void check_call_cleanup_without_stream(bool accept) {
    try {
        var app = get_service_app();
        var account = create_account(app);
        var interactor = app.stream_interactor;
        interactor.module_manager.initialize(account);
        interactor.account_added(account);
        var rtp_class = typeof(Xmpp.Xep.JingleRtp.Module).class_ref();
        assert_nonnull(rtp_class);
        var calls = interactor.get_module(Calls.IDENTITY);
        var invites = interactor.module_manager.get_module(account, Xmpp.Xep.CallInvites.Module.IDENTITY);
        var peer = Xmpp.Jid.from_string("peer@example.com/device");
        var local = account.bare_jid.with_resource("desktop");
        string call_id = Xmpp.random_uuid();
        Call? received_call = null;
        int terminations = 0;
        ulong incoming_handler = calls.call_incoming.connect((call) => received_call = call);
        ulong terminated_handler = calls.call_terminated.connect((call) => {
            if (call == received_call) terminations++;
        });
        var methods = new Gee.ArrayList<Xmpp.StanzaNode>();
        methods.add(new Xmpp.StanzaNode.build("jingle", Xmpp.Xep.CallInvites.NS_URI).put_attribute("sid", call_id));
        var stanza = new Xmpp.MessageStanza() { from=peer, to=local, type_=Xmpp.MessageStanza.TYPE_CHAT };
        invites.call_proposed(peer, local, call_id, false, methods, stanza);
        calls.disconnect(incoming_handler);
        assert_nonnull(received_call);
        assert_true(calls.call_states.has_key(received_call));

        // No stream is connected, so neither accepting nor rejecting can send anything.
        if (accept) {
            calls.call_states[received_call].accept();
        } else {
            calls.call_states[received_call].reject();
        }
        assert_false(calls.call_states.has_key(received_call));
        assert_cmpint(terminations, CompareOperator.EQ, 1);
        assert_true(received_call.state == (accept ? Call.State.FAILED : Call.State.DECLINED));
        calls.disconnect(terminated_handler);
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void add_call_state_regression_tests() {
    GLib.Test.add_func("/calls/invite-rejected-on-other-device", () => check_call_invite_termination(true));
    GLib.Test.add_func("/calls/invite-retracted", () => check_call_invite_termination(false));
    GLib.Test.add_func("/calls/reject-without-stream", () => check_call_cleanup_without_stream(false));
    GLib.Test.add_func("/calls/accept-without-stream", () => check_call_cleanup_without_stream(true));
}

}
