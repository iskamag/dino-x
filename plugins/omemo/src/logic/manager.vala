using Dino.Entities;
using Omemo;
using Qlite;
using Xmpp;
using Gee;

namespace Dino.Plugins.Omemo {

public enum KeyFetchResult {
    OK,
    UNSUPPORTED,
    FAILED
}

public enum MessageSendDecision {
    SEND,
    WAIT,
    WONT_SEND
}

public class SendPolicy : Object {
    // Pure decision function so the send-state transitions can be unit tested
    // without a stream, a database or libomemo.
    public static MessageSendDecision decide(Xep.Omemo.EncryptState enc) {
        if (enc.other_failure > 0 || (enc.other_lost == enc.other_devices && enc.other_devices > 0)) {
            return MessageSendDecision.WONT_SEND;
        }
        if (!enc.own_list || enc.own_devices == 0 || enc.own_unknown > 0 || enc.other_unknown > 0 || enc.other_waiting_lists > 0) {
            return MessageSendDecision.WAIT;
        }
        // Known address but no usable recipient device: sending here would emit
        // an OMEMO stanza without a single <key> element.
        if (enc.other_devices == 0) {
            return MessageSendDecision.WONT_SEND;
        }
        if (!enc.encrypted) {
            return MessageSendDecision.WONT_SEND;
        }
        return MessageSendDecision.SEND;
    }
}

public class RetryPolicy : Object {
    public const int MAX_ATTEMPTS = 5;
    public const uint MAX_DELAY_SECONDS = 60;

    public static uint delay_seconds(int attempt) {
        if (attempt <= 0) return 2;
        return uint.min(MAX_DELAY_SECONDS, 1u << uint.min(attempt + 1, 6));
    }
}

public class Manager : StreamInteractionModule, Object {
    public static ModuleIdentity<Manager> IDENTITY = new ModuleIdentity<Manager>("omemo_manager");
    public string id { get { return IDENTITY.id; } }

    private StreamInteractor stream_interactor;
    private Database db;
    private TrustManager trust_manager;
    private HashMap<Account, OmemoEncryptor> encryptors;
    private Map<Entities.Message, MessageState> message_states = new HashMap<Entities.Message, MessageState>(Entities.Message.hash_func, Entities.Message.equals_func);

    // One retry timer per address/device. Timers are only scheduled while
    // messages are actually waiting, so idle accounts do no work.
    private HashMap<string, uint> devicelist_retry_timeouts = new HashMap<string, uint>();
    private HashMap<string, int> devicelist_retry_attempts = new HashMap<string, int>();
    private HashMap<string, uint> bundle_retry_timeouts = new HashMap<string, uint>();
    private HashMap<string, int> bundle_retry_attempts = new HashMap<string, int>();

    private class MessageState {
        public Entities.Message msg { get; private set; }
        public Xep.Omemo.EncryptState last_try { get; private set; }
        public int waiting_other_sessions { get; set; }
        public int waiting_own_sessions { get; set; }
        public bool waiting_own_devicelist { get; set; }
        public int waiting_other_devicelists { get; set; }
        public bool force_next_attempt { get; set; }
        public bool will_send_now { get; private set; }
        public bool active_send_attempt { get; set; }
        // Devices whose encryption failed with UNKNOWN, per recipient. Their
        // sessions are reset before refetching bundles.
        public HashMap<string, ArrayList<int32>> waiting_other_sessions_by_jid { get; private set; default = new HashMap<string, ArrayList<int32>>(); }
        public HashMap<string, ArrayList<int32>> waiting_own_sessions_by_jid { get; private set; default = new HashMap<string, ArrayList<int32>>(); }

        public MessageState(Entities.Message msg, Xep.Omemo.EncryptState last_try) {
            update_from_encrypt_status(msg, last_try);
        }

        public void update_from_encrypt_status(Entities.Message msg, Xep.Omemo.EncryptState new_try) {
            this.msg = msg;
            this.last_try = new_try;
            this.waiting_other_sessions = new_try.other_unknown;
            this.waiting_own_sessions = new_try.own_unknown;
            this.waiting_own_devicelist = !new_try.own_list;
            this.waiting_other_devicelists = new_try.other_waiting_lists;
            this.waiting_other_sessions_by_jid = new_try.other_unknown_devices;
            this.waiting_own_sessions_by_jid = new_try.own_unknown_devices;
            this.active_send_attempt = false;
            will_send_now = false;
            switch (SendPolicy.decide(new_try)) {
                case MessageSendDecision.WONT_SEND:
                    msg.marked = Entities.Message.Marked.WONTSEND;
                    break;
                case MessageSendDecision.WAIT:
                    msg.marked = Entities.Message.Marked.UNSENT;
                    break;
                case MessageSendDecision.SEND:
                    will_send_now = true;
                    break;
            }
        }

        public bool should_retry_now() {
            return !waiting_own_devicelist && waiting_other_devicelists <= 0 && waiting_other_sessions <= 0 && waiting_own_sessions <= 0 && !active_send_attempt;
        }

        public string to_string() {
            return @"MessageState (msg=$(msg.stanza_id), send=$will_send_now, $last_try)";
        }
    }

    private Manager(StreamInteractor stream_interactor, Database db, TrustManager trust_manager, HashMap<Account, OmemoEncryptor> encryptors) {
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.trust_manager = trust_manager;
        this.encryptors = encryptors;

        stream_interactor.account_added.connect(on_account_added);
        stream_interactor.stream_negotiated.connect(on_stream_negotiated);
        stream_interactor.get_module(MessageProcessor.IDENTITY).pre_message_send.connect(on_pre_message_send);
        stream_interactor.get_module(RosterManager.IDENTITY).mutual_subscription.connect(on_mutual_subscription);
    }

    public void clear_device_list(Account account) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;

        stream.get_module(StreamModule.IDENTITY).clear_device_list(stream);
    }

    private Gee.List<Jid> get_occupants(Jid jid, Account account){
        Gee.List<Jid> occupants = new ArrayList<Jid>(Jid.equals_bare_func);
        if(!stream_interactor.get_module(MucManager.IDENTITY).is_groupchat(jid, account)){
            occupants.add(jid);
        }
        Gee.List<Jid>? occupant_jids = stream_interactor.get_module(MucManager.IDENTITY).get_offline_members(jid, account);
        if(occupant_jids == null) {
            return occupants;
        }
        foreach (Jid occupant in occupant_jids) {
            if(!occupant.equals(account.bare_jid)){
                occupants.add(occupant.bare_jid);
            }
        }
        return occupants;
    }

    private bool message_targets_jid(Entities.Message msg, Account account, Jid jid) {
        if (!msg.account.equals(account)) return false;
        if (account.bare_jid.equals(jid)) return true;
        if (msg.counterpart == null) return false;
        if (msg.counterpart.equals_bare(jid)) return true;
        return get_occupants(((!)msg.counterpart).bare_jid, account).contains(jid);
    }

    private void request_missing_keys(XmppStream stream, Account account, Entities.Message msg, MessageState state) {
        StreamModule? module_ = stream.get_module(StreamModule.IDENTITY);
        if (module_ == null) return;
        StreamModule module = (!)module_;

        if (state.waiting_own_devicelist) {
            module.request_user_devicelist.begin(stream, account.bare_jid);
        }
        if (state.waiting_own_sessions > 0) {
            module.fetch_bundles(stream, account.bare_jid, trust_manager.get_trusted_devices(account, account.bare_jid));
            reset_failed_sessions(module, stream, account.bare_jid, state.waiting_own_sessions_by_jid);
        }
        if (msg.counterpart == null) return;

        Gee.List<Jid> occupants = get_occupants(((!)msg.counterpart).bare_jid, account);
        if (state.waiting_other_devicelists > 0) {
            foreach (Jid jid in occupants) {
                module.request_user_devicelist.begin(stream, jid);
            }
        }
        if (state.waiting_other_sessions > 0) {
            foreach (Jid jid in occupants) {
                module.fetch_bundles(stream, jid, trust_manager.get_trusted_devices(account, jid));
                reset_failed_sessions(module, stream, jid, state.waiting_other_sessions_by_jid);
            }
        }
    }

    private void reset_failed_sessions(StreamModule module, XmppStream stream, Jid jid, HashMap<string, ArrayList<int32>> failed_by_jid) {
        ArrayList<int32>? devices = failed_by_jid[jid.bare_jid.to_string()];
        if (devices == null) return;
        foreach (int32 device_id in devices) {
            module.reset_session_and_fetch_bundle(stream, jid, device_id);
        }
    }

    private void on_pre_message_send(Entities.Message message, Xmpp.MessageStanza message_stanza, Conversation conversation) {
        if (message.encryption != Encryption.OMEMO) return;
        if (message.type_ == Message.Type.GROUPCHAT_PM) {
            message.marked = Message.Marked.WONTSEND;
            return;
        }

        XmppStream? stream = stream_interactor.get_stream(conversation.account);
        if (stream == null) {
            message.marked = Entities.Message.Marked.UNSENT;
            return;
        }
        StreamModule? module_ = ((!)stream).get_module(StreamModule.IDENTITY);
        if (module_ == null) {
            message.marked = Entities.Message.Marked.UNSENT;
            return;
        }

        OmemoEncryptor? encryptor = encryptors[conversation.account];
        if (encryptor == null) {
            warning("OMEMO encryptor for %s is not initialized", conversation.account.bare_jid.to_string());
            message.marked = Entities.Message.Marked.UNSENT;
            return;
        }

        //Get a list of everyone for whom the message should be encrypted
        Gee.List<Jid> recipients;
        if (message_stanza.type_ == MessageStanza.TYPE_GROUPCHAT) {
            recipients = get_occupants((!)message.to.bare_jid, conversation.account);
            if (recipients.size == 0) {
                message.marked = Entities.Message.Marked.WONTSEND;
                return;
            }
        } else {
            recipients = new ArrayList<Jid>(Jid.equals_bare_func);
            recipients.add(message_stanza.to);
        }

        //Attempt to encrypt the message
        Xep.Omemo.EncryptState enc_state = encryptor.encrypt(message_stanza, conversation.account.bare_jid, recipients, stream);
        MessageState state;
        lock (message_states) {
            if (message_states.has_key(message)) {
                state = message_states.get(message);
                state.update_from_encrypt_status(message, enc_state);
                if (state.will_send_now) {
                    debug("sending message delayed: %s", state.to_string());
                }
            } else {
                state = new MessageState(message, enc_state);
                message_states[message] = state;
            }
            if (state.will_send_now) {
                message_states.unset(message);
            }
        }

        if (state.will_send_now) return;

        if (message.marked == Entities.Message.Marked.WONTSEND) {
            // Nothing left to fetch: either the contact has no usable device,
            // a key change must be accepted, or all devices are unreachable.
            debug("not sending message %s", state.to_string());
            lock (message_states) {
                message_states.unset(message);
            }
            return;
        }

        debug("delaying message %s", state.to_string());
        request_missing_keys((!)stream, conversation.account, message, state);
    }

    private void on_mutual_subscription(Account account, Jid jid) {
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;

        cancel_devicelist_retry(account, jid);
        StreamModule? module = stream_interactor.module_manager.get_module(account, StreamModule.IDENTITY);
        if (module != null) {
            module.request_user_devicelist.begin((!)stream, jid);
        }
    }

    private void on_stream_negotiated(Account account, XmppStream stream) {
        StreamModule? module = stream_interactor.module_manager.get_module(account, StreamModule.IDENTITY);
        if (module == null) return;

        reset_retries(account);
        module.request_user_devicelist.begin(stream, account.bare_jid);

        // Resume messages that were waiting for keys when the stream went away.
        var pending = new ArrayList<Entities.Message>();
        lock (message_states) {
            foreach (var msg in message_states.keys) {
                if (msg.account.equals(account)) pending.add(msg);
            }
        }
        foreach (var msg in pending) {
            MessageState? state = message_states[msg];
            if (state == null) continue;
            request_missing_keys(stream, account, msg, (!)state);
        }
    }

    private void on_account_added(Account account) {
        StreamModule module = stream_interactor.module_manager.get_module(account, StreamModule.IDENTITY);
        if (module != null) {
            module.device_list_loaded.connect((jid, devices) => on_device_list_loaded(account, jid, devices));
            module.device_list_fetch_failed.connect((jid) => on_device_list_fetch_failed(account, jid));
            module.bundle_fetched.connect((jid, device_id, bundle) => on_bundle_fetched(account, jid, device_id, bundle));
            module.bundle_fetch_failed.connect((jid, device_id) => on_bundle_fetch_failed(account, jid, device_id));
        }
        initialize_store.begin(account);
    }

    private void on_device_list_loaded(Account account, Jid jid, ArrayList<int32> device_list) {
        debug("received device list for %s from %s", account.bare_jid.to_string(), jid.to_string());

        cancel_devicelist_retry(account, jid);

        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return;
        StreamModule? module = ((!)stream).get_module(StreamModule.IDENTITY);
        if (module == null) return;

        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;

        //Update meta database
        db.identity_meta.insert_device_list(identity_id, jid.bare_jid.to_string(), device_list);

        //Fetch the bundle for each new device
        int inc = 0;
        foreach (Row row in db.identity_meta.get_unknown_devices(identity_id, jid.bare_jid.to_string())) {
            try {
                module.fetch_bundle(stream, Jid.from_string(row[db.identity_meta.address_name]), row[db.identity_meta.device_id], false);
                inc++;
            } catch (InvalidJidError e) {
                warning("Ignoring device with invalid Jid: %s", e.message);
            }
        }
        if (inc > 0) {
            debug("new bundles %i/%i for %s", inc, device_list.size, jid.to_string());
        }

        //Create an entry for the jid in the account table if one does not exist already
        if (db.trust.select().with(db.trust.identity_id, "=", identity_id).with(db.trust.address_name, "=", jid.bare_jid.to_string()).count() == 0) {
            db.trust.insert().value(db.trust.identity_id, identity_id).value(db.trust.address_name, jid.bare_jid.to_string()).value(db.trust.blind_trust, true).perform();
        }

        //Get all messages that needed the devicelist and determine if we can now send them
        HashSet<Entities.Message> send_now = new HashSet<Entities.Message>();
        lock (message_states) {
            foreach (Entities.Message msg in message_states.keys) {
                if (!message_targets_jid(msg, account, jid)) continue;
                MessageState state = message_states[msg];
                if (account.bare_jid.equals(jid)) {
                    state.waiting_own_devicelist = false;
                } else if (state.waiting_other_devicelists > 0) {
                    state.waiting_other_devicelists--;
                }
                if (state.should_retry_now()) {
                    send_now.add(msg);
                    state.active_send_attempt = true;
                }
            }
        }
        foreach (Entities.Message msg in send_now) {
            if (msg.counterpart == null) continue;
            Entities.Conversation? conv = stream_interactor.get_module(ConversationManager.IDENTITY).get_conversation(((!)msg.counterpart), account);
            if (conv == null) continue;
            stream_interactor.get_module(MessageProcessor.IDENTITY).send_xmpp_message(msg, (!)conv, true);
        }
    }

    private static string retry_key(Account account, Jid jid, int32 device_id = -1) {
        return account.id.to_string() + "/" + jid.bare_jid.to_string() + (device_id >= 0 ? "/" + device_id.to_string() : "");
    }

    private void cancel_devicelist_retry(Account account, Jid jid) {
        string key = retry_key(account, jid);
        uint timeout_id = 0;
        if (devicelist_retry_timeouts.has_key(key)) timeout_id = devicelist_retry_timeouts[key];
        if (timeout_id != 0) Source.remove(timeout_id);
        devicelist_retry_timeouts.unset(key);
        devicelist_retry_attempts.unset(key);
    }

    private void cancel_bundle_retry(Account account, Jid jid, int32 device_id) {
        string key = retry_key(account, jid, device_id);
        uint timeout_id = 0;
        if (bundle_retry_timeouts.has_key(key)) timeout_id = bundle_retry_timeouts[key];
        if (timeout_id != 0) Source.remove(timeout_id);
        bundle_retry_timeouts.unset(key);
        bundle_retry_attempts.unset(key);
    }

    private void reset_retries(Account account) {
        string prefix = account.id.to_string() + "/";
        var devicelist_keys = new ArrayList<string>();
        foreach (var key in devicelist_retry_timeouts.keys) {
            if (key.has_prefix(prefix)) devicelist_keys.add(key);
        }
        foreach (var key in devicelist_keys) {
            Source.remove(devicelist_retry_timeouts[key]);
            devicelist_retry_timeouts.unset(key);
            devicelist_retry_attempts.unset(key);
        }
        var devicelist_attempt_keys = new ArrayList<string>();
        foreach (var key in devicelist_retry_attempts.keys) {
            if (key.has_prefix(prefix)) devicelist_attempt_keys.add(key);
        }
        foreach (var key in devicelist_attempt_keys) devicelist_retry_attempts.unset(key);

        var bundle_keys = new ArrayList<string>();
        foreach (var key in bundle_retry_timeouts.keys) {
            if (key.has_prefix(prefix)) bundle_keys.add(key);
        }
        foreach (var key in bundle_keys) {
            Source.remove(bundle_retry_timeouts[key]);
            bundle_retry_timeouts.unset(key);
            bundle_retry_attempts.unset(key);
        }
        var bundle_attempt_keys = new ArrayList<string>();
        foreach (var key in bundle_retry_attempts.keys) {
            if (key.has_prefix(prefix)) bundle_attempt_keys.add(key);
        }
        foreach (var key in bundle_attempt_keys) bundle_retry_attempts.unset(key);
    }

    private void on_device_list_fetch_failed(Account account, Jid jid) {
        bool waiting = false;
        lock (message_states) {
            foreach (Entities.Message msg in message_states.keys) {
                if (!message_targets_jid(msg, account, jid)) continue;
                MessageState state = message_states[msg];
                if (state.waiting_other_devicelists > 0 || state.waiting_own_devicelist) {
                    waiting = true;
                    break;
                }
            }
        }
        if (!waiting) return;

        string key = retry_key(account, jid);
        if (devicelist_retry_timeouts.has_key(key)) return;

        int attempt = 1;
        if (devicelist_retry_attempts.has_key(key)) attempt = devicelist_retry_attempts[key] + 1;
        devicelist_retry_attempts[key] = attempt;
        if (attempt > RetryPolicy.MAX_ATTEMPTS) {
            warning("Giving up fetching the OMEMO device list of %s after %d attempts", jid.to_string(), RetryPolicy.MAX_ATTEMPTS);
            mark_waiting_messages_wont_send(account, jid, true);
            devicelist_retry_attempts.unset(key);
            return;
        }

        uint delay = RetryPolicy.delay_seconds(attempt);
        devicelist_retry_timeouts[key] = Timeout.add_seconds(delay, () => {
            devicelist_retry_timeouts.unset(key);
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) return false;
            StreamModule? module = stream.get_module(StreamModule.IDENTITY);
            if (module != null) module.request_user_devicelist.begin(stream, jid);
            return false;
        });
    }

    private void on_bundle_fetch_failed(Account account, Jid jid, int32 device_id) {
        string key = retry_key(account, jid, device_id);
        int attempt = 1;
        if (bundle_retry_attempts.has_key(key)) attempt = bundle_retry_attempts[key] + 1;
        bundle_retry_attempts[key] = attempt;

        if (attempt > RetryPolicy.MAX_ATTEMPTS) {
            warning("Giving up fetching the OMEMO bundle for %s/%d after %d attempts", jid.to_string(), device_id, RetryPolicy.MAX_ATTEMPTS);
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream != null) {
                StreamModule? module = stream.get_module(StreamModule.IDENTITY);
                if (module != null) module.ignore_device(jid, device_id);
            }
            bundle_retry_attempts.unset(key);
            continue_message_sending(account, jid, device_id);
            return;
        }

        if (bundle_retry_timeouts.has_key(key)) return;
        uint delay = RetryPolicy.delay_seconds(attempt);
        bundle_retry_timeouts[key] = Timeout.add_seconds(delay, () => {
            bundle_retry_timeouts.unset(key);
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream == null) return false;
            StreamModule? module = stream.get_module(StreamModule.IDENTITY);
            if (module != null) module.fetch_bundle(stream, jid, device_id, false);
            return false;
        });
    }

    private void mark_waiting_messages_wont_send(Account account, Jid jid, bool only_devicelist) {
        lock (message_states) {
            foreach (Entities.Message msg in message_states.keys) {
                if (!message_targets_jid(msg, account, jid)) continue;
                MessageState state = message_states[msg];
                if (only_devicelist && state.waiting_other_devicelists <= 0 && !state.waiting_own_devicelist) continue;
                msg.marked = Entities.Message.Marked.WONTSEND;
            }
        }
    }

    private void on_bundle_fetched(Account account, Jid jid, int32 device_id, Bundle bundle) {
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return;
        if (bundle.identity_key == null) {
            warning("Ignoring OMEMO bundle for %s/%d without a usable identity key", jid.bare_jid.to_string(), device_id);
            return;
        }

        bool blind_trust = db.trust.get_blind_trust(identity_id, jid.bare_jid.to_string(), true);

        //If we don't blindly trust new devices and we haven't seen this key before then don't trust it
        bool untrust = !(blind_trust || db.identity_meta.with_address(identity_id, jid.bare_jid.to_string())
                .with(db.identity_meta.device_id, "=", device_id)
                .with(db.identity_meta.identity_key_public_base64, "=", Base64.encode(bundle.identity_key.serialize()))
                .single().row().is_present());

        //Get trust information from the database if the device id is known
        Row device = db.identity_meta.get_device(identity_id, jid.bare_jid.to_string(), device_id);
        TrustLevel trusted = TrustLevel.UNKNOWN;
        if (device != null) {
            trusted = (TrustLevel) device[db.identity_meta.trust_level];
        }

        if(untrust) {
            trusted = TrustLevel.UNKNOWN;
        } else if (blind_trust && trusted == TrustLevel.UNKNOWN) {
            trusted = TrustLevel.TRUSTED;
        }

        //Update the database with the appropriate trust information
        if (db.identity_meta.insert_device_bundle(identity_id, jid.bare_jid.to_string(), device_id, bundle, trusted) < 0) {
            critical("Refusing to start a session for %s/%d: identity key changed", jid.bare_jid.to_string(), device_id);
            // The pending key is stored by insert_device_bundle(). Keep the old
            // key, do not release the message waiters and surface the message as
            // failed until the user accepts the new key explicitly.
            cancel_bundle_retry(account, jid, device_id);
            trust_manager.bad_message_state_updated(account, jid, device_id);
            mark_waiting_messages_wont_send(account, jid, false);
            return;
        }
        cancel_bundle_retry(account, jid, device_id);

        if (should_start_session(account, jid)) {
            XmppStream? stream = stream_interactor.get_stream(account);
            if (stream != null) {
                StreamModule? module = ((!)stream).get_module(StreamModule.IDENTITY);
                if (module != null) {
                    module.start_session(stream, jid, device_id, bundle);
                }
            }
        }
        continue_message_sending(account, jid, device_id);
    }

    private bool should_start_session(Account account, Jid jid) {
        lock (message_states) {
            foreach (Entities.Message msg in message_states.keys) {
                if (message_targets_jid(msg, account, jid)) return true;
            }
        }
        return false;
    }

    private bool consume_failed_device(HashMap<string, ArrayList<int32>> failed_by_jid, Jid jid, int32 device_id) {
        if (device_id < 0) return false;
        string key = jid.bare_jid.to_string();
        ArrayList<int32>? devices = failed_by_jid[key];
        if (devices == null) return false;
        if (!devices.remove(device_id)) return false;
        if (devices.size == 0) failed_by_jid.unset(key);
        return true;
    }

    private void continue_message_sending(Account account, Jid jid, int32 device_id) {
        //Get all messages waiting and determine if they can now be sent
        HashSet<Entities.Message> send_now = new HashSet<Entities.Message>();
        lock (message_states) {
            foreach (Entities.Message msg in message_states.keys) {
                if (!message_targets_jid(msg, account, jid)) continue;
                MessageState state = message_states[msg];

                if (account.bare_jid.equals(jid)) {
                    if (consume_failed_device(state.waiting_own_sessions_by_jid, jid, device_id) && state.waiting_own_sessions > 0) {
                        state.waiting_own_sessions--;
                    }
                } else if (consume_failed_device(state.waiting_other_sessions_by_jid, jid, device_id) && state.waiting_other_sessions > 0) {
                    state.waiting_other_sessions--;
                }
                if (state.should_retry_now()) {
                    send_now.add(msg);
                    state.active_send_attempt = true;
                }
            }
        }
        foreach (Entities.Message msg in send_now) {
            if (msg.counterpart == null) continue;
            Entities.Conversation? conv = stream_interactor.get_module(ConversationManager.IDENTITY).get_conversation(((!)msg.counterpart), account);
            if (conv == null) continue;
            stream_interactor.get_module(MessageProcessor.IDENTITY).send_xmpp_message(msg, (!)conv, true);
        }
    }

    public bool accept_pending_identity_key(Account account, Jid jid, int32 device_id) {
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return false;
        string address = jid.bare_jid.to_string();
        if (!db.identity_meta.accept_pending_identity_key(identity_id, address, device_id)) return false;

        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            StreamModule? module = stream.get_module(StreamModule.IDENTITY);
            if (module != null) {
                Row? device = db.identity_meta.get_device(identity_id, address, device_id);
                if (device != null && device[db.identity_meta.identity_key_public_base64] != null) {
                    // libomemo's in-memory identity key store still holds the
                    // refused key; replace it or the newly fetched bundle will
                    // be rejected as untrusted when building the session.
                    try {
                        module.store.identity_key_store.save_identity(new Address(address, device_id),
                            Base64.decode(device[db.identity_meta.identity_key_public_base64]));
                    } catch (Error e) {
                        debug("Could not store accepted OMEMO identity key for %s/%d: %s", address, device_id, e.message);
                    }
                }
                try {
                    Address session_address = new Address(address, device_id);
                    if (module.store.session_store.contains_session(session_address)) {
                        module.store.session_store.delete_session(session_address);
                    }
                } catch (Error e) {
                    debug("Could not delete old OMEMO session with %s/%d: %s", address, device_id, e.message);
                }
                module.unignore_device(jid, device_id);
                module.fetch_bundle(stream, jid.bare_jid, device_id, false);
            }
        }

        // Back to "pending", not "failed"; the refetched bundle releases the waiters.
        lock (message_states) {
            foreach (Entities.Message msg in message_states.keys) {
                if (!message_targets_jid(msg, account, jid)) continue;
                MessageState state = message_states[msg];
                state.msg.marked = Entities.Message.Marked.UNSENT;
            }
        }
        trust_manager.bad_message_state_updated(account, jid, device_id);
        return true;
    }

    public bool reject_pending_identity_key(Account account, Jid jid, int32 device_id) {
        int identity_id = db.identity.get_id(account.id);
        if (identity_id < 0) return false;
        string address = jid.bare_jid.to_string();
        db.identity_meta.clear_pending_identity_key(identity_id, address, device_id);
        db.identity_meta.update()
            .with(db.identity_meta.identity_id, "=", identity_id)
            .with(db.identity_meta.address_name, "=", address)
            .with(db.identity_meta.device_id, "=", device_id)
            .set(db.identity_meta.trust_level, TrustLevel.UNTRUSTED)
            .perform();
        mark_waiting_messages_wont_send(account, jid, false);
        trust_manager.bad_message_state_updated(account, jid, device_id);
        return true;
    }

    private async void initialize_store(Account account) {
        // If the account is not yet persisted, wait for that and then continue - without identity.account_id the entry isn't worth much.
        if (account.id == -1) {
            account.notify["id"].connect(() => initialize_store.callback());
            yield;
        }
        StreamModule? module = stream_interactor.module_manager.get_module(account, StreamModule.IDENTITY);
        if (module == null) return;
        Store store = module.store;
        Qlite.Row? row = db.identity.row_with(db.identity.account_id, account.id).inner;
        int identity_id = -1;

        if (row == null) {
            // OMEMO not yet initialized, starting with empty base
            try {
                store.identity_key_store.local_registration_id = Random.int_range(1, int32.MAX);

                ECKeyPair key_pair = Plugin.get_context().generate_key_pair();
                store.identity_key_store.identity_key_private = new Bytes(key_pair.private.serialize());
                store.identity_key_store.identity_key_public = new Bytes(key_pair.public.serialize());

                identity_id = (int) db.identity.upsert()
                        .value(db.identity.account_id, account.id, true)
                        .value(db.identity.device_id, (int) store.local_registration_id)
                        .value(db.identity.identity_key_private_base64, Base64.encode(store.identity_key_store.identity_key_private.get_data()))
                        .value(db.identity.identity_key_public_base64, Base64.encode(store.identity_key_store.identity_key_public.get_data()))
                        .perform();
            } catch (Error e) {
                // Ignore error
            }
        } else {
            store.identity_key_store.local_registration_id = ((!)row)[db.identity.device_id];
            store.identity_key_store.identity_key_private = new Bytes(Base64.decode(((!)row)[db.identity.identity_key_private_base64]));
            store.identity_key_store.identity_key_public = new Bytes(Base64.decode(((!)row)[db.identity.identity_key_public_base64]));
            identity_id = ((!)row)[db.identity.id];
        }

        if (identity_id >= 0) {
            store.signed_pre_key_store = new BackedSignedPreKeyStore(db, identity_id);
            store.pre_key_store = new BackedPreKeyStore(db, identity_id);
            store.session_store = new BackedSessionStore(db, identity_id);
        } else {
            warning("store for %s is not persisted!", account.bare_jid.to_string());
        }

        // Generated new device ID, ensure this gets added to the devicelist
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream != null) {
            module.request_user_devicelist.begin((!)stream, account.bare_jid);
        }
    }

    public async KeyFetchResult ensure_get_keys_for_conversation(Conversation conversation) {
        if (stream_interactor.get_module(MucManager.IDENTITY).is_private_room(conversation.account, conversation.counterpart)) {
            foreach (Jid offline_member in stream_interactor.get_module(MucManager.IDENTITY).get_offline_members(conversation.counterpart, conversation.account)) {
                KeyFetchResult result = yield ensure_get_keys_for_jid(conversation.account, offline_member);
                if (result != KeyFetchResult.OK) {
                    return result;
                }
            }
            return KeyFetchResult.OK;
        }

        return yield ensure_get_keys_for_jid(conversation.account, conversation.counterpart.bare_jid);
    }

    public async KeyFetchResult ensure_get_keys_for_jid(Account account, Jid jid) {
        if (trust_manager.is_known_address(account, jid)) return KeyFetchResult.OK;
        XmppStream? stream = stream_interactor.get_stream(account);
        if (stream == null) return KeyFetchResult.FAILED;
        StreamModule? module = stream_interactor.module_manager.get_module(account, StreamModule.IDENTITY);
        if (module == null) return KeyFetchResult.FAILED;
        DeviceListResult device_list = yield module.request_user_devicelist(stream, jid);
        if (!device_list.success) return KeyFetchResult.FAILED;
        return device_list.devices.size > 0 ? KeyFetchResult.OK : KeyFetchResult.UNSUPPORTED;
    }

    public static void start(StreamInteractor stream_interactor, Database db, TrustManager trust_manager, HashMap<Account, OmemoEncryptor> encryptors) {
        Manager m = new Manager(stream_interactor, db, trust_manager, encryptors);
        stream_interactor.add_module(m);
    }
}

}
