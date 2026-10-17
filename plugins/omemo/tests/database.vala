using Gee;

namespace Omemo.Test {

using Dino.Plugins.Omemo;
using Xmpp;

class DatabaseTest : Gee.TestCase {
    private const string BUNDLE_NS = "eu.siacs.conversations.axolotl";

    public DatabaseTest() {
        base("Database");
        add_test("pending_identity_key", test_pending_identity_key);
    }

    private static Bundle bundle_with_key(ECPublicKey key) {
        StanzaNode node = new StanzaNode.build("bundle", BUNDLE_NS).add_self_xmlns()
            .put_node(new StanzaNode.build("identityKey", BUNDLE_NS)
                .put_node(new StanzaNode.text(Base64.encode(key.serialize()))));
        return new Bundle(node);
    }

    private void test_pending_identity_key() {
        string dir = DirUtils.make_tmp("dino-omemo-db-test-XXXXXX");
        var db = new Database(Path.build_filename(dir, "omemo.db"));
        int identity_id = (int) db.identity.insert()
            .value(db.identity.account_id, 1)
            .value(db.identity.device_id, 1)
            .value(db.identity.identity_key_private_base64, "AAAA")
            .value(db.identity.identity_key_public_base64, "AAAA")
            .perform();
        fail_if(identity_id <= 0, "could not create local identity");

        fail_if_not(Plugin.ensure_context(), "could not initialize the OMEMO context");
        Context context = Plugin.get_context();
        string address = "peer@example.org";
        // The refusal path intentionally logs at CRITICAL; keep the test alive
        // so it can verify the database state.
        GLib.LogLevelFlags old_fatal_mask = GLib.Log.set_always_fatal(GLib.LogLevelFlags.LEVEL_ERROR);
        try {
            string old_key = Base64.encode(context.generate_key_pair().public.serialize());
            string new_key = Base64.encode(context.generate_key_pair().public.serialize());
            string third_key = Base64.encode(context.generate_key_pair().public.serialize());
            Bundle old_bundle = bundle_with_key(context.decode_public_key(Base64.decode(old_key)));
            Bundle new_bundle = bundle_with_key(context.decode_public_key(Base64.decode(new_key)));
            Bundle third_bundle = bundle_with_key(context.decode_public_key(Base64.decode(third_key)));

            fail_if(db.identity_meta.insert_device_bundle(identity_id, address, 5, old_bundle, TrustLevel.TRUSTED) < 0, "initial bundle rejected");
            fail_if(db.identity_meta.insert_device_bundle(identity_id, address, 5, new_bundle, TrustLevel.TRUSTED) >= 0,
                "changed identity key was accepted silently");

            Qlite.Row? device_opt = db.identity_meta.get_device(identity_id, address, 5);
            fail_if(device_opt == null, "device row missing");
            if (device_opt == null) return;
            Qlite.Row device = (!)device_opt;
            fail_if_not_eq_str(device[db.identity_meta.identity_key_public_base64], old_key, "old key must be kept");
            fail_if_not_eq_str(device[db.identity_meta.pending_identity_key_public_base64], new_key, "new key must be parked");
            fail_if_not_eq_int((int) db.identity_meta.get_pending_identity_keys(identity_id, address).count(), 1);
            fail_if_not_eq_int((int) db.identity_meta.get_new_devices(identity_id, address).count(), 0,
                "a pending key change must not show up as a new device");

            bool pending_trusted = false;
            foreach (Qlite.Row row in db.identity_meta.get_trusted_devices(identity_id, address)) {
                if (row[db.identity_meta.device_id] == 5) pending_trusted = true;
            }
            fail_if(pending_trusted, "a device with a pending key change must not receive messages");

            fail_if_not(db.identity_meta.accept_pending_identity_key(identity_id, address, 5), "accepting the key failed");
            device_opt = db.identity_meta.get_device(identity_id, address, 5);
            fail_if(device_opt == null, "device row missing after accept");
            if (device_opt == null) return;
            device = (!)device_opt;
            fail_if_not_eq_str(device[db.identity_meta.identity_key_public_base64], new_key, "accepted key not stored");
            fail_if_not_eq_str(device[db.identity_meta.pending_identity_key_public_base64], null, "pending key not cleared");
            fail_if_not_eq_int(device[db.identity_meta.trust_level], TrustLevel.TRUSTED);

            fail_if(db.identity_meta.insert_device_bundle(identity_id, address, 5, new_bundle, TrustLevel.TRUSTED) < 0,
                "accepted bundle rejected on refetch");

            fail_if(db.identity_meta.insert_device_bundle(identity_id, address, 5, third_bundle, TrustLevel.TRUSTED) >= 0,
                "a second change was accepted silently");
            db.identity_meta.clear_pending_identity_key(identity_id, address, 5);
            device_opt = db.identity_meta.get_device(identity_id, address, 5);
            fail_if(device_opt == null, "device row missing after clear");
            if (device_opt != null) {
                fail_if(((!)device_opt)[db.identity_meta.pending_identity_key_public_base64] != null, "pending key not cleared");
            }
        } catch (Error e) {
            GLib.Test.fail();
            GLib.Test.message(e.message);
        } finally {
            GLib.Log.set_always_fatal(old_fatal_mask);
        }
    }
}

}
