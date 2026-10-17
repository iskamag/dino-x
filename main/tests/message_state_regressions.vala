using Dino.Entities;

namespace Dino.Ui.Test {

private Conversation state_conversation(ServiceTestApplication app, Account account, string jid,
        Conversation.Type type = Conversation.Type.CHAT) throws Error {
    var conversation = new Conversation(Xmpp.Jid.from_string(jid), account, type);
    conversation.persist(app.db);
    return conversation;
}

private Message state_message(ServiceTestApplication app, Conversation conversation, string body,
        string? reference_id = null, Xmpp.Jid? sender = null) {
    var message = new Message(body) {
        account=conversation.account, counterpart=sender ?? conversation.counterpart,
        ourpart=conversation.account.bare_jid, direction=Message.DIRECTION_RECEIVED,
        type_=Dino.Util.get_message_type_for_conversation(conversation),
        stanza_id=reference_id ?? Xmpp.random_uuid(), server_id=reference_id ?? Xmpp.random_uuid(),
        time=new DateTime.now_utc(), local_time=new DateTime.now_utc()
    };
    app.stream_interactor.get_module(MessageStorage.IDENTITY).add_message(message, conversation);
    app.stream_interactor.get_module(ContentItemStore.IDENTITY).insert_message(message, conversation);
    return message;
}

private void test_cold_server_id_lookup() {
    try {
        var app = get_service_app();
        var account = create_account(app);
        var room = state_conversation(app, account, "room@example.com", Conversation.Type.GROUPCHAT);
        var chat = state_conversation(app, account, "peer@example.com");
        var pm = state_conversation(app, account, "room@example.com/Alice", Conversation.Type.GROUPCHAT_PM);
        var room_message = state_message(app, room, "room message", null, Xmpp.Jid.from_string("room@example.com/Alice"));
        var chat_message = state_message(app, chat, "chat message", null, Xmpp.Jid.from_string("peer@example.com/device"));
        var pm_message = state_message(app, pm, "private message");
        var cold = new StreamInteractor(app.db);
        MessageStorage.start(cold, app.db);
        var storage = cold.get_module(MessageStorage.IDENTITY);
        assert_cmpint(storage.get_message_by_server_id(room_message.server_id, room).id, CompareOperator.EQ, room_message.id);
        assert_cmpint(storage.get_message_by_server_id(chat_message.server_id, chat).id, CompareOperator.EQ, chat_message.id);
        assert_cmpint(storage.get_message_by_server_id(pm_message.server_id, pm).id, CompareOperator.EQ, pm_message.id);
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void test_private_room_history() {
    try {
        var app = get_service_app();
        var account = create_account(app);
        var alice = state_conversation(app, account, "room@example.com/Alice", Conversation.Type.GROUPCHAT_PM);
        var bob = state_conversation(app, account, "room@example.com/Bob", Conversation.Type.GROUPCHAT_PM);
        var alice_message = state_message(app, alice, "Alice's private message");
        state_message(app, bob, "Bob's private message");
        var cold = new StreamInteractor(app.db);
        MessageStorage.start(cold, app.db);
        var storage = cold.get_module(MessageStorage.IDENTITY);
        var messages = storage.get_messages(alice);
        assert_cmpint(messages.size, CompareOperator.EQ, 1);
        assert_cmpint(messages[0].id, CompareOperator.EQ, alice_message.id);
        assert_cmpint(storage.get_last_message(alice).id, CompareOperator.EQ, alice_message.id);
        assert_true(storage.get_message_by_stanza_id(alice_message.stanza_id, alice).counterpart.equals(alice.counterpart));
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void test_messages_after_backfilled() {
    try {
        var app = get_service_app();
        var account = create_account(app);
        var conversation = state_conversation(app, account, "peer@example.com");
        var storage = app.stream_interactor.get_module(MessageStorage.IDENTITY);
        var now = new DateTime.now_utc();

        // Newer message inserted first, older message backfilled later with a higher id.
        var newer = new Message("newer") {
            account=account, counterpart=conversation.counterpart, ourpart=account.bare_jid,
            direction=Message.DIRECTION_RECEIVED, type_=Message.Type.CHAT,
            stanza_id=Xmpp.random_uuid(), time=now, local_time=now
        };
        storage.add_message(newer, conversation);
        var older = new Message("older") {
            account=account, counterpart=conversation.counterpart, ourpart=account.bare_jid,
            direction=Message.DIRECTION_RECEIVED, type_=Message.Type.CHAT,
            stanza_id=Xmpp.random_uuid(), time=now.add_minutes(-1), local_time=now.add_minutes(-1)
        };
        storage.add_message(older, conversation);
        assert_true(older.id > newer.id);

        var after = storage.get_messages_after_message(conversation, older.time, older.id, 10);
        assert_cmpint(after.size, CompareOperator.EQ, 1);
        assert_cmpstr(after[0].message.body, CompareOperator.EQ, "newer");
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void test_dedupe_scopes_message_type() {
    var loop = new MainLoop();
    test_dedupe_scopes_message_type_async.begin((obj, result) => {
        try {
            test_dedupe_scopes_message_type_async.end(result);
        } catch (Error e) {
            GLib.Test.fail();
            GLib.Test.message(e.message);
        }
        loop.quit();
    });
    loop.run();
}

private async void test_dedupe_scopes_message_type_async() throws Error {
    var app = get_service_app();
    var account = create_account(app);
    app.stream_interactor.module_manager.initialize(account);
    app.stream_interactor.account_added(account);
    var conversations = app.stream_interactor.get_module(ConversationManager.IDENTITY);
    var room = conversations.create_conversation(Xmpp.Jid.from_string("room@example.com"), account, Conversation.Type.GROUPCHAT);
    var pm = conversations.create_conversation(Xmpp.Jid.from_string("room@example.com/Alice"), account, Conversation.Type.GROUPCHAT_PM);
    var alice = Xmpp.Jid.from_string("room@example.com/Alice");
    var now = new DateTime.now_utc();

    // Same sender, body and (missing) stanza id, but a groupchat message and a PM.
    var room_message = new Entities.Message("hi") {
        account=account, counterpart=alice, ourpart=account.bare_jid, direction=Entities.Message.DIRECTION_RECEIVED,
        type_=Entities.Message.Type.GROUPCHAT, time=now, local_time=now
    };
    var pm_message = new Entities.Message("hi") {
        account=account, counterpart=alice, ourpart=account.bare_jid, direction=Entities.Message.DIRECTION_RECEIVED,
        type_=Entities.Message.Type.GROUPCHAT_PM, time=now, local_time=now
    };
    var stanza = new Xmpp.MessageStanza() { from=alice, to=account.bare_jid };
    stanza.body = "hi";

    var processor = app.stream_interactor.get_module(MessageProcessor.IDENTITY);
    assert_false(yield processor.received_pipeline.run(room_message, stanza, room));
    assert_false(yield processor.received_pipeline.run(pm_message, stanza, pm));

    assert_cmpint((int) app.db.message.select().with(app.db.message.account_id, "=", account.id).count(), CompareOperator.EQ, 2);
    assert_cmpint(app.stream_interactor.get_module(MessageStorage.IDENTITY).get_messages(pm).size, CompareOperator.EQ, 1);
    assert_cmpint(app.stream_interactor.get_module(MessageStorage.IDENTITY).get_messages(room).size, CompareOperator.EQ, 1);
}

private void check_correction_transmission(bool reload) {
    try {
        var app = get_service_app();
        var account = create_account(app);
        var conversation = state_conversation(app, account, "peer@example.com");
        var processor = app.stream_interactor.get_module(MessageProcessor.IDENTITY);
        var correction_module = app.stream_interactor.get_module(MessageCorrection.IDENTITY);
        var original = processor.create_out_message("original", conversation);
        app.stream_interactor.get_module(ContentItemStore.IDENTITY).insert_message(original, conversation);
        var correction = processor.create_out_message("corrected", conversation);
        correction_module.set_correction(conversation, correction, original);
        if (reload) {
            // A fresh application's modules have no transient correction map.
            var restarted = new ServiceTestApplication();
            correction = restarted.stream_interactor.get_module(MessageStorage.IDENTITY).get_message_by_id(correction.id, conversation);
            processor = restarted.stream_interactor.get_module(MessageProcessor.IDENTITY);
            assert_cmpstr(correction.edit_to, CompareOperator.EQ, original.stanza_id);
        }
        for (int attempt = 0; attempt < 2; attempt++) {
            var stanza = new Xmpp.MessageStanza(correction.stanza_id);
            processor.build_message_stanza(correction, stanza, conversation);
            assert_cmpstr(Xmpp.Xep.LastMessageCorrection.get_replace_id(stanza), CompareOperator.EQ, original.stanza_id);
        }
        var ordinary = new Xmpp.MessageStanza(original.stanza_id);
        processor.build_message_stanza(original, ordinary, conversation);
        assert_null(Xmpp.Xep.LastMessageCorrection.get_replace_id(ordinary));
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

// Isolate the reply listener from transport, notification, and history-sync listeners.
private MessageListenerHolder reply_pipeline(ServiceTestApplication app) {
    var processor = app.stream_interactor.get_module(MessageProcessor.IDENTITY);
    processor.received_pipeline = new MessageListenerHolder();
    Replies.start(app.stream_interactor, app.db);
    return processor.received_pipeline;
}

private void run_reply_listener(MessageListenerHolder pipeline, Message message, Xmpp.MessageStanza stanza, Conversation conversation) {
    var loop = new MainLoop();
    bool finished = false;
    pipeline.run.begin(message, stanza, conversation, (obj, result) => {
        assert_false(pipeline.run.end(result));
        finished = true;
        loop.quit();
    });
    if (!finished) loop.run();
}

private void check_late_reply(bool reload, bool same_second) {
    try {
        var app = new ServiceTestApplication();
        var account = create_account(app);
        var conversation = state_conversation(app, account, "peer@example.com");
        var pipeline = reply_pipeline(app);
        string original_id = Xmpp.random_uuid();
        var reply = state_message(app, conversation, "reply");
        var reply_stanza = new Xmpp.MessageStanza(reply.stanza_id);
        Xmpp.Xep.Replies.set_reply_to(reply_stanza, new Xmpp.Xep.Replies.ReplyTo(conversation.counterpart, original_id));
        run_reply_listener(pipeline, reply, reply_stanza, conversation);
        assert_cmpint(reply.quoted_item_id, CompareOperator.EQ, 0);
        var pending = app.db.reply.select().with(app.db.reply.message_id, "=", reply.id).row().inner;
        string pending_id = pending[app.db.reply.quoted_message_stanza_id];
        assert_cmpstr(pending_id, CompareOperator.EQ, original_id);
        if (reload) {
            app = new ServiceTestApplication();
            pipeline = reply_pipeline(app);
            reply = app.stream_interactor.get_module(MessageStorage.IDENTITY).get_message_by_id(reply.id, conversation);
        }
        var original = state_message(app, conversation, "original", original_id);
        original.time = same_second ? reply.time : reply.time.add_seconds(-5);
        var original_stanza = new Xmpp.MessageStanza(original.stanza_id);
        run_reply_listener(pipeline, original, original_stanza, conversation);
        var item = app.stream_interactor.get_module(ContentItemStore.IDENTITY).get_content_item_for_message(conversation, original);
        assert_cmpint(reply.quoted_item_id, CompareOperator.EQ, item.id);
        // Repeated arrival/reconciliation must not create duplicate metadata.
        run_reply_listener(pipeline, original, original_stanza, conversation);
        var resolved = app.db.reply.select().with(app.db.reply.message_id, "=", reply.id).row().inner;
        int quoted_id = resolved[app.db.reply.quoted_content_item_id];
        string? unresolved_id = resolved[app.db.reply.quoted_message_stanza_id];
        assert_cmpint(quoted_id, CompareOperator.EQ, item.id);
        assert_null(unresolved_id);
        assert_cmpint((int)app.db.reply.select().with(app.db.reply.message_id, "=", reply.id).count(), CompareOperator.EQ, 1);
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private class ReplyWidgetContainer : Object, Plugins.ConversationItemWidgetInterface {
    public Gtk.Widget? quote;
    public int quote_updates = 0;
    public void set_widget(Object? object, Plugins.WidgetType type, int priority) {
        if (priority != 1) return;
        quote = object as Gtk.Widget;
        quote_updates++;
    }
}

private void test_late_reply_widget() {
    if (!have_display) { GLib.Test.skip("No display available"); return; }
    try {
        var app = get_service_app();
        var account = create_account(app);
        var conversation = state_conversation(app, account, "peer@example.com");
        var original = state_message(app, conversation, "original");
        var reply = state_message(app, conversation, "> original\nreply");
        var locations = new Gee.ArrayList<Xmpp.Xep.FallbackIndication.FallbackLocation>();
        locations.add(new Xmpp.Xep.FallbackIndication.FallbackLocation.partial_body(0, 11));
        var fallbacks = new Gee.ArrayList<Xmpp.Xep.FallbackIndication.Fallback>();
        fallbacks.add(new Xmpp.Xep.FallbackIndication.Fallback(Xmpp.Xep.Replies.NS_URI, locations));
        reply.set_fallbacks(fallbacks);
        var store = app.stream_interactor.get_module(ContentItemStore.IDENTITY);
        var item = store.get_content_item_for_message(conversation, reply);
        var row = new ConversationSummary.MessageMetaItem(item, app.stream_interactor);
        var container = new ReplyWidgetContainer();
        row.get_widget(container, Plugins.WidgetType.GTK4);
        assert_null(container.quote);
        reply.set_quoted_item(store.get_content_item_for_message(conversation, original).id);
        assert_nonnull(container.quote);
        assert_cmpstr(row.label.get_text(), CompareOperator.EQ, "reply");
        int updates = container.quote_updates;
        var quote_ref = WeakRef(container.quote);
        reply.set_quoted_item(reply.quoted_item_id);
        assert_cmpint(container.quote_updates, CompareOperator.EQ, updates);
        assert_true(quote_ref.get() == container.quote);
        row.dispose();
        row.dispose();
        reply.set_quoted_item(0);
        assert_cmpint(container.quote_updates, CompareOperator.EQ, updates);
        container.quote = null;
    } catch (Error e) { GLib.Test.fail(); GLib.Test.message(e.message); }
}

private void add_message_state_regression_tests() {
    GLib.Test.add_func("/messages/dedupe-type-scope", test_dedupe_scopes_message_type);
    GLib.Test.add_func("/messages/after-backfilled", test_messages_after_backfilled);
    GLib.Test.add_func("/messages/cold-server-id", test_cold_server_id_lookup);
    GLib.Test.add_func("/messages/private-room-history", test_private_room_history);
    GLib.Test.add_func("/messages/correction-retry", () => check_correction_transmission(false));
    GLib.Test.add_func("/messages/correction-restart", () => check_correction_transmission(true));
    GLib.Test.add_func("/messages/late-reply", () => check_late_reply(false, false));
    GLib.Test.add_func("/messages/late-reply-same-second", () => check_late_reply(false, true));
    GLib.Test.add_func("/messages/late-reply-restart", () => check_late_reply(true, false));
    GLib.Test.add_func("/messages/late-reply-widget", test_late_reply_widget);
}

}
