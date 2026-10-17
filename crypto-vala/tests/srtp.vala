using Crypto.Srtp;

private uint8[] make_key() {
    var key = new uint8[16];
    for (int i = 0; i < key.length; i++) key[i] = (uint8) (i + 1);
    return key;
}

private uint8[] make_salt() {
    var salt = new uint8[14];
    for (int i = 0; i < salt.length; i++) salt[i] = (uint8) (0x40 + i);
    return salt;
}

private uint8[] make_rtp_packet() {
    var packet = new uint8[40];
    packet[0] = 0x80;
    packet[1] = 0x60;
    packet[2] = 0x12;
    packet[3] = 0x34;
    for (int i = 4; i < packet.length; i++) packet[i] = (uint8) i;
    return packet;
}

private void test_rtp_in_place_matches_allocating_encrypt() {
    uint8[] key = make_key();
    uint8[] salt = make_salt();
    uint8[] packet = make_rtp_packet();

    var allocating = new Session();
    allocating.set_encryption_key(AES_CM_128_HMAC_SHA1_80, key, salt);
    uint8[] expected = allocating.encrypt_rtp(packet);

    var in_place = new Session();
    in_place.set_encryption_key(AES_CM_128_HMAC_SHA1_80, key, salt);
    uint8[] buffer = new uint8[packet.length + max_trailer_bytes()];
    Memory.copy(buffer, packet, packet.length);
    int length = in_place.encrypt_rtp_in_place(buffer, packet.length);

    assert_cmpint(length, CompareOperator.EQ, expected.length);
    assert_true(Memory.cmp(buffer, expected, length) == 0);
}

private void test_rtcp_in_place_matches_allocating_encrypt() {
    uint8[] key = make_key();
    uint8[] salt = make_salt();
    var packet = new uint8[28];
    packet[0] = 0x80;
    packet[1] = 0xC8;
    for (int i = 2; i < packet.length; i++) packet[i] = (uint8) (i * 3);

    var allocating = new Session();
    allocating.set_encryption_key(AES_CM_128_HMAC_SHA1_80, key, salt);
    uint8[] expected = allocating.encrypt_rtcp(packet);

    var in_place = new Session();
    in_place.set_encryption_key(AES_CM_128_HMAC_SHA1_80, key, salt);
    uint8[] buffer = new uint8[packet.length + max_trailer_bytes() + 4];
    Memory.copy(buffer, packet, packet.length);
    int length = in_place.encrypt_rtcp_in_place(buffer, packet.length);

    assert_cmpint(length, CompareOperator.EQ, expected.length);
    assert_true(Memory.cmp(buffer, expected, length) == 0);
}

int main(string[] args) {
    GLib.Test.init(ref args);
    GLib.Test.add_func("/crypto/srtp-rtp-in-place", test_rtp_in_place_matches_allocating_encrypt);
    GLib.Test.add_func("/crypto/srtp-rtcp-in-place", test_rtcp_in_place_matches_allocating_encrypt);
    return GLib.Test.run();
}
