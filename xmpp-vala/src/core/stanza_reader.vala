using Gee;

namespace Xmpp {

public const string XMLNS_URI = "http://www.w3.org/2000/xmlns/";
public const string XML_URI = "http://www.w3.org/XML/1998/namespace";
public const string JABBER_URI = "jabber:client";

public class StanzaReader {
    private static int BUFFER_MAX = 4096;

    private InputStream? input;
    private uint8[] buffer;
    private int buffer_fill = 0;
    private int buffer_pos = 0;
    private Cancellable? cancellable;

    private NamespaceState ns_state = new NamespaceState();

    public StanzaReader.for_buffer(uint8[] buffer) {
        this.buffer = buffer;
        this.buffer_fill = buffer.length;
    }

    public StanzaReader.for_string(string s) {
        this.for_buffer(s.data);
    }

    public StanzaReader.for_stream(InputStream input, Cancellable? cancellable = null) {
        this.input = input;
        this.cancellable = cancellable;
        buffer = new uint8[BUFFER_MAX];
    }

    private async void update_buffer() throws IOError {
        InputStream? input = this.input;
        if (input == null) throw new IOError.CLOSED("No input stream specified and end of buffer reached.");
        if (cancellable != null && cancellable.is_cancelled()) throw new IOError.CANCELLED("Input stream is canceled.");
        try {
            buffer_fill = (int) yield ((!)input).read_async(buffer, GLib.Priority.DEFAULT, cancellable);
        } catch (TlsError.EOF e) {
            throw new IOError.CLOSED("End of TLS stream reached");
        }
        if (buffer_fill == 0) throw new IOError.CLOSED("End of input stream reached.");
        buffer_pos = 0;
    }

    private async char read_single() throws IOError {
        if (buffer_pos >= buffer_fill) {
            yield update_buffer();
        }
        return (char) buffer[buffer_pos++];
    }

    private async char peek_single() throws IOError {
        if (buffer_pos >= buffer_fill) {
            yield update_buffer();
        }
        return (char) buffer[buffer_pos];
    }

    private bool is_ws(uint8 what) {
        return what == ' ' || what == '\t' || what == '\r' || what == '\n';
    }

    private void skip_single() {
        buffer_pos++;
    }

    private async void skip_until_non_ws() throws IOError {
        if (buffer_pos >= buffer_fill) {
            yield update_buffer();
        }
        while (is_ws(buffer[buffer_pos])) {
            buffer_pos++;
            if (buffer_pos >= buffer_fill) {
                yield update_buffer();
            }
        }
    }

    private async string read_until_ws() throws IOError {
        if (buffer_pos >= buffer_fill) {
            yield update_buffer();
        }
        int start = buffer_pos;
        var res = new StringBuilder();
        while (true) {
            while (buffer_pos < buffer_fill && !is_ws(buffer[buffer_pos])) {
                buffer_pos++;
            }
            if (buffer_pos < buffer_fill) {
                if (res.len == 0) return ((string) buffer).substring(start, buffer_pos - start);
                res.append(((string) buffer).substring(start, buffer_pos - start));
                return res.str;
            }
            res.append(((string) buffer).substring(start, buffer_fill - start));
            yield update_buffer();
            start = 0;
        }
    }

    private async string read_until_char_or_ws(char x, char y = 0) throws IOError {
        if (buffer_pos >= buffer_fill) {
            yield update_buffer();
        }
        int start = buffer_pos;
        var res = new StringBuilder();
        while (true) {
            while (buffer_pos < buffer_fill) {
                uint8 c = buffer[buffer_pos];
                if (c == x || c == y || is_ws(c)) break;
                buffer_pos++;
            }
            if (buffer_pos < buffer_fill) {
                if (res.len == 0) return ((string) buffer).substring(start, buffer_pos - start);
                res.append(((string) buffer).substring(start, buffer_pos - start));
                return res.str;
            }
            res.append(((string) buffer).substring(start, buffer_fill - start));
            yield update_buffer();
            start = 0;
        }
    }

    private async string read_until_char(char x) throws IOError {
        if (buffer_pos >= buffer_fill) {
            yield update_buffer();
        }
        int start = buffer_pos;
        var res = new StringBuilder();
        while (true) {
            char* found = GLibFixes.memchr((char*) buffer + buffer_pos, x, buffer_fill - buffer_pos);
            int end = found != null ? (int) (found - (char*) buffer) : buffer_fill;
            if (found != null) {
                buffer_pos = end;
                if (res.len == 0) return ((string) buffer).substring(start, end - start);
                res.append(((string) buffer).substring(start, end - start));
                return res.str;
            }
            res.append(((string) buffer).substring(start, buffer_fill - start));
            buffer_pos = buffer_fill;
            yield update_buffer();
            start = 0;
        }
    }

    private async StanzaAttribute read_attribute() throws IOError {
        var res = new StanzaAttribute();
        res.name = yield read_until_char_or_ws('=');
        if ((yield read_single()) == '=') {
            var quot = yield peek_single();
            if (quot == '\'' || quot == '"') {
                skip_single();
                res.encoded_val = yield read_until_char(quot);
                skip_single();
            } else {
                res.encoded_val = yield read_until_ws();
            }
        }
        return res;
    }

    private void handle_entry_ns(StanzaEntry entry, string default_uri = ns_state.current_ns_uri) throws IOError {
        if (entry.ns_uri != null) return;
        if (entry.name.contains(":")) {
            var split = entry.name.split(":");
            entry.prefix = split[0];
            try {
                entry.ns_uri = ns_state.find_uri(split[0]);
            } catch (IOError e) {
                // Unknown prefixes are kept as opaque, unbound elements instead of
                // failing the stream.
                info("Unknown XML prefix %s, treating element as opaque", split[0]);
                entry.ns_uri = "";
            }
            entry.name = split[1];
        } else {
            entry.ns_uri = default_uri;
        }
    }

    private void handle_stanza_ns(StanzaNode res) throws IOError {
        foreach (StanzaAttribute attr in res.attributes) {
            if (attr.name == "xmlns" && attr.val != null) {
                attr.ns_uri = XMLNS_URI;
                ns_state.set_current((!)attr.val);
            } else if (attr.name.contains(":") && attr.val != null) {
                var split = attr.name.split(":");
                if (split[0] == "xmlns") {
                    attr.ns_uri = XMLNS_URI;
                    attr.name = split[1];
                    ns_state.add_assoc((!)attr.val, attr.name);
                }
            }
        }
        handle_entry_ns(res);
        foreach (StanzaAttribute attr in res.attributes) {
            handle_entry_ns(attr, res.ns_uri ?? ns_state.current_ns_uri);
        }
    }

    public async StanzaNode read_node_start() throws IOError {
        var res = new StanzaNode();
        res.attributes = new ArrayList<StanzaAttribute>();
        var eof = false;
        if ((yield peek_single()) == '<') skip_single();
        if ((yield peek_single()) == '?') res.pseudo = true;
        if ((yield peek_single()) == '/') {
            eof = true;
            skip_single();
            res.name = yield read_until_char_or_ws('>');
            while ((yield peek_single()) != '>') {
                skip_single();
            }
            skip_single();
            res.has_nodes = false;
            res.pseudo = false;
            handle_stanza_ns(res);
            return res;
        }
        res.name = yield read_until_char_or_ws('>', '/');
        yield skip_until_non_ws();
        char next_char = yield peek_single();
        while (next_char != '/' && next_char != '>' && next_char != '?') {
            res.attributes.add(yield read_attribute());
            yield skip_until_non_ws();
            next_char = yield peek_single();
        }
        if ((yield read_single()) == '/' || res.pseudo) {
            res.has_nodes = false;
            skip_single();
        } else {
            res.has_nodes = true;
        }
        handle_stanza_ns(res);
        return res;
    }

    public async StanzaNode read_text_node() throws IOError {
        var res = new StanzaNode();
        res.name = "#text";
        res.ns_uri = ns_state.current_ns_uri;
        res.encoded_val = (yield read_until_char('<'));
        return res;
    }

    public async StanzaNode read_root_node() throws IOError {
        yield skip_until_non_ws();
        if ((yield peek_single()) == '<') {
            var res = yield read_node_start();
            if (res.pseudo) {
                return yield read_root_node();
            }
            return res;
        } else {
            throw new IOError.INVALID_DATA("XML: Content before root node");
        }
    }

    public async StanzaNode read_stanza_node() throws IOError {
        ns_state = ns_state.push();
        try {
            var res = yield read_node_start();
            if (res.has_nodes) {
                bool finish_node_seen = false;
                StanzaNode? text_node = null;
                do {
                    text_node = yield read_text_node();
                    if ((yield peek_single()) == '<') {
                        skip_single();
                        if ((yield peek_single()) == '/') {
                            skip_single();
                            string desc = yield read_until_char('>');
                            skip_single();
                            if (desc.contains(":")) {
                                var split = desc.split(":");
                                string? expected_prefix = null;
                                try {
                                    expected_prefix = ns_state.find_name((!)res.ns_uri);
                                } catch (IOError e) {
                                    // Opaque element with an unknown prefix.
                                }
                                if (expected_prefix != null && split[0] != expected_prefix) throw new IOError.INVALID_DATA("XML: Closing namespace prefix mismatch");
                                if (split[1] != res.name) throw new IOError.INVALID_DATA("XML: Closing element name mismatch");
                            } else {
                                if (ns_state.current_ns_uri != res.ns_uri) throw new IOError.INVALID_DATA("XML: Closing element namespace mismatch");
                                if (desc != res.name) throw new IOError.INVALID_DATA("XML: Closing element name mismatch");
                            }
                            finish_node_seen = true;
                        } else {
                            res.sub_nodes.add(yield read_stanza_node());
                        }
                    }
                } while (!finish_node_seen);
                if (res.sub_nodes.size == 0) {
                    if (text_node == null || text_node.val.length == 0) {
                        res.has_nodes = false;
                    } else {
                        res.sub_nodes.add(text_node);
                    }
                }
            }
            return res;
        } catch (IOError.INVALID_DATA e) {
            uint8[] buffer_cpy = new uint8[buffer.length + 1];
            Memory.copy(buffer_cpy, buffer, buffer.length);
            warning("invalid data at: %s".printf((string)buffer_cpy) + "\n");
            throw e;
        } finally {
            ns_state = ns_state.pop();
        }
    }

    public async StanzaNode read_node() throws IOError {
        yield skip_until_non_ws();
        if ((yield peek_single()) == '<') {
            return yield read_stanza_node();
        } else {
            return yield read_text_node();
        }
    }
}

}
