using Dino.Plugins.OpenPgp;

private void test_contact_signature_lookup() {
    try {
        var db = new Database(":memory:");
        var jid = Xmpp.Jid.from_string("peer@example.com");
        db.set_contact_signature(jid, "signature", "signed status");

        var row = db.get_contact_key_row(jid);
        assert_true(row.is_present());
        assert_null(row.get(db.contact_key_table.key));
        assert_cmpstr(row.get(db.contact_key_table.sig), CompareOperator.EQ, "signature");
        assert_cmpstr(row.get(db.contact_key_table.signed_data), CompareOperator.EQ, "signed status");

        db.set_contact_key(jid, "fingerprint");
        assert_cmpstr(db.get_contact_key(jid), CompareOperator.EQ, "fingerprint");
        db.set_contact_signature(jid, "new signature", "new status");
        row = db.get_contact_key_row(jid);
        assert_null(row.get(db.contact_key_table.key));
        assert_cmpstr(row.get(db.contact_key_table.sig), CompareOperator.EQ, "new signature");
        assert_cmpstr(row.get(db.contact_key_table.signed_data), CompareOperator.EQ, "new status");
    } catch (Error e) {
        GLib.Test.fail();
        GLib.Test.message(e.message);
    }
}

int main(string[] args) {
    GLib.Test.init(ref args);
    GLib.Test.add_func("/openpgp/contact-signature-lookup", test_contact_signature_lookup);
    return GLib.Test.run();
}
