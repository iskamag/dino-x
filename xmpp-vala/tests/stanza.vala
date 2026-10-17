namespace Xmpp.Test {

class StanzaTest : Gee.TestCase {
    public StanzaTest() {
        base("Stanza");

        add_async_test("node_one", (cb) => { test_node_one.begin(cb); });
        add_async_test("typical_stream", (cb) => { test_typical_stream.begin(cb); });
        add_async_test("ack_stream", (cb) => { test_ack_stream.begin(cb); });
        add_test("get_attribute_(u)int", test_get_attribute_int);
        add_test("test_encoded_val", test_encoded_val);
        add_async_test("unknown_prefix_is_opaque", (cb) => { test_unknown_prefix.begin(cb); });
        add_async_test("values_spanning_buffer_refills", (cb) => { test_buffer_refills.begin(cb); });
    }

    private async void test_node_one(Gee.TestFinishedCallback cb) {
        var node1 = new StanzaNode.build("test", "ns1_uri")
                .add_self_xmlns()
                .put_attribute("ns2", "ns2_uri", XMLNS_URI)
                .put_attribute("bla", "blub")
                .put_node(new StanzaNode.build("testaa", "ns2_uri")
                    .put_attribute("ns3", "ns3_uri", XMLNS_URI))
                .put_node(new StanzaNode.build("testbb", "ns3_uri")
                    .add_self_xmlns());

        var xml1 = node1.to_xml();
        var node2 = yield new StanzaReader.for_string(xml1).read_node();
        fail_if_not(node1.equals(node2));
        fail_if_not_eq_str(node1.to_string(), node2.to_string());
        cb();
    }

    private async void test_typical_stream(Gee.TestFinishedCallback cb) {
        var stream = """
        <?xml version='1.0' encoding='UTF-8'?>
        <stream:stream
                to='example.com'
                xmlns='jabber:client'
                xmlns:stream='http://etherx.jabber.org/streams'
                version='1.0'>
            <message from='laurence@example.net/churchyard'
                    to='juliet@example.com'
                    xml:lang='en'>
                <body> I'll send a friar with speed, to Mantua, with my letters to thy lord.</body>
            </message>
        </stream:stream>
        """;
        var root_node_cmp = new StanzaNode.build("stream", "http://etherx.jabber.org/streams")
                .put_attribute("to", "example.com")
                .put_attribute("xmlns", "jabber:client")
                .put_attribute("stream", "http://etherx.jabber.org/streams", XMLNS_URI)
                .put_attribute("version", "1.0");
        var node_cmp = new StanzaNode.build("message")
                .put_attribute("from", "laurence@example.net/churchyard")
                .put_attribute("to", "juliet@example.com")
                .put_attribute("lang", "en", XML_URI)
                .put_node(new StanzaNode.build("body")
                        .put_node(new StanzaNode.text(" I'll send a friar with speed, to Mantua, with my letters to thy lord.")));

        var reader = new StanzaReader.for_string(stream);
        fail_if_not_eq_node(root_node_cmp, yield reader.read_root_node());
        fail_if_not_eq_node(node_cmp, yield reader.read_node());
        yield reader.read_node();
        yield fail_if_not_end_of_stream(reader);
        cb();
    }

    private async void fail_if_not_end_of_stream(StanzaReader reader) {
        try {
            yield reader.read_node();
            fail_if_reached("end of stream should be reached");
        } catch (IOError.CLOSED e) {
            return;
        } catch (Error e) {
            fail_if_reached("Unexpected error");
        }
    }

    private async void test_unknown_prefix(Gee.TestFinishedCallback cb) {
        var xml = """
        <message xmlns='jabber:client'><foo:bar>hello</foo:bar></message>
        <message xmlns='jabber:client'><body>ok</body></message>
        """;
        var reader = new StanzaReader.for_string(xml);
        var first = yield reader.read_node();
        fail_if_not_eq_str(first.name, "message");
        StanzaNode? opaque = first.get_subnode("bar", "");
        if (fail_if(opaque == null)) { cb(); return; }
        fail_if_not_eq_str(opaque.ns_uri, "");

        var second = yield reader.read_node();
        StanzaNode? body = second.get_subnode("body");
        if (fail_if(body == null)) { cb(); return; }
        fail_if_not_eq_str(body.get_string_content(), "ok");

        // Opaque elements keep their prefix so they can be written again.
        string opaque_xml = first.to_xml();
        fail_if_not(opaque_xml.contains("<foo:bar>"), opaque_xml);
        var opaque_roundtrip = yield new StanzaReader.for_string(opaque_xml).read_node();
        StanzaNode? opaque_again = ((!)opaque_roundtrip).get_subnode("bar", "");
        if (fail_if(opaque_again == null)) { cb(); return; }

        var attr_reader = new StanzaReader.for_string("<message xmlns='jabber:client' foo:bar='baz'><body>ok</body></message>");
        var attr_message = yield attr_reader.read_node();
        string attr_xml = attr_message.to_xml();
        fail_if_not(attr_xml.contains("foo:bar='baz'"), attr_xml);
        cb();
    }

    private async void test_ack_stream(Gee.TestFinishedCallback cb) {
        var stream = """
        <?xml version='1.0' encoding='UTF-8'?>
        <stream:stream
                to='example.com'
                xmlns='jabber:client'
                xmlns:stream='http://etherx.jabber.org/streams'
                xmlns:ack='http://jabber.org/protocol/ack'
                version='1.0'>
            <stream:features>
                <ack:ack/>
                <bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>
                    <required/>
                </bind>
            </stream:features>
            <ack:r/>
        </stream:stream>
        """;
        var root_node_cmp = new StanzaNode.build("stream", "http://etherx.jabber.org/streams")
                .put_attribute("to", "example.com")
                .put_attribute("xmlns", "jabber:client")
                .put_attribute("stream", "http://etherx.jabber.org/streams", XMLNS_URI)
                .put_attribute("ack", "http://jabber.org/protocol/ack", XMLNS_URI)
                .put_attribute("version", "1.0");
        var node_cmp = new StanzaNode.build("features", XmppStream.NS_URI)
                .put_node(new StanzaNode.build("ack", "http://jabber.org/protocol/ack"))
                .put_node(new StanzaNode.build("bind", "urn:ietf:params:xml:ns:xmpp-bind")
                        .add_self_xmlns()
                        .put_node(new StanzaNode.build("required", "urn:ietf:params:xml:ns:xmpp-bind")));
        var node2_cmp = new StanzaNode.build("r", "http://jabber.org/protocol/ack");

        var reader = new StanzaReader.for_string(stream);
        fail_if_not_eq_node(root_node_cmp, yield reader.read_root_node());
        fail_if_not_eq_node(node_cmp, yield reader.read_node());
        fail_if_not_eq_node(node2_cmp, yield reader.read_node());
        yield reader.read_node();
        yield fail_if_not_end_of_stream(reader);
        cb();
    }

    private async void test_buffer_refills(Gee.TestFinishedCallback cb) {
        string long_value = string.nfill(10000, 'a');
        var xml = "<message xmlns='jabber:client' note='" + long_value + "'><body>" + long_value + "</body></message>";
        var reader = new StanzaReader.for_stream(new MemoryInputStream.from_data(xml.data, null));
        var node = yield reader.read_node();
        fail_if_not_eq_str(node.get_attribute("note"), long_value);
        StanzaNode? body = node.get_subnode("body");
        if (fail_if(body == null)) { cb(); return; }
        fail_if_not_eq_str(body.get_string_content(), long_value);
        cb();
    }

    private void test_encoded_val() {
        var attr = new StanzaAttribute.build("ns", "foo", "b\"a<'>r&me");
        fail_if_not_eq_str(attr.val, "b\"a<'>r&me");
        fail_if_not_eq_str(attr.encoded_val, "b&quot;a&lt;&apos;&gt;r&amp;me");

        attr.encoded_val = "b&quot;a&lt;&apos;&gt;r&amp;me";
        fail_if_not_eq_str(attr.val, "b\"a<'>r&me");
        fail_if_not_eq_str(attr.encoded_val, "b&quot;a&lt;&apos;&gt;r&amp;me");

        var plain = new StanzaAttribute.build("ns", "plain value", "plain value");
        fail_if_not_eq_str(plain.encoded_val, "plain value");

        var numeric = new StanzaAttribute.build("ns", "v", "");
        numeric.encoded_val = "&#65;&#x42;&bogus;&#xZZ;";
        fail_if_not_eq_str(numeric.val, "AB&bogus;&#xZZ;");
        fail_if_not_eq_str(numeric.encoded_val, "AB&amp;bogus;&amp;#xZZ;");
    }

    private void test_get_attribute_int() {
        var stanza_node = new StanzaNode.build("test", "ns").add_self_xmlns().put_attribute("bar", "42");
        fail_if_not_eq_int(stanza_node.get_attribute_int("bar", -2), 42);
        fail_if_not_eq_uint(stanza_node.get_attribute_uint("bar", 3), 42);

        stanza_node = new StanzaNode.build("test", "ns").add_self_xmlns().put_attribute("bar", "-42");
        fail_if_not_eq_int(stanza_node.get_attribute_int("bar", -2), -42);
        fail_if_not_eq_uint(stanza_node.get_attribute_uint("bar", 3), 3);

        stanza_node = new StanzaNode.build("test", "ns").add_self_xmlns();
        fail_if_not_eq_int(stanza_node.get_attribute_int("bar", -2), -2);
        fail_if_not_eq_uint(stanza_node.get_attribute_uint("bar", 3), 3);

        stanza_node = new StanzaNode.build("test", "ns").add_self_xmlns().put_attribute("bar", "0x42");
        fail_if_not_eq_int(stanza_node.get_attribute_int("bar", -2), -2);
        fail_if_not_eq_uint(stanza_node.get_attribute_uint("bar", 3), 3);

        stanza_node = new StanzaNode.build("test", "ns").add_self_xmlns().put_attribute("bar", "str");
        fail_if_not_eq_int(stanza_node.get_attribute_int("bar", -2), -2);
        fail_if_not_eq_uint(stanza_node.get_attribute_uint("bar", 3), 3);

    }

}

}
