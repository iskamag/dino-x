using Gee;

namespace Xmpp {

public class NamespaceState {
    private HashMap<string, string> uri_to_name = new HashMap<string, string> ();
    private HashMap<string, string> name_to_uri = new HashMap<string, string> ();
    private string? own_current_ns_uri = null;
    private NamespaceState? parent = null;

    public string current_ns_uri {
        get {
            if (own_current_ns_uri != null) return (!)own_current_ns_uri;
            if (parent != null) return parent.current_ns_uri;
            return XML_URI;
        }
        set {
            own_current_ns_uri = value;
        }
    }

    public NamespaceState() {
        add_assoc(XMLNS_URI, "xmlns");
        add_assoc(XML_URI, "xml");
        current_ns_uri = XML_URI;
    }

    public NamespaceState.for_stanza() {
        this();
        add_assoc("http://etherx.jabber.org/streams", "stream");
        current_ns_uri = "jabber:client";
    }

    private NamespaceState.with_parent(NamespaceState parent) {
        this.parent = parent;
    }

    public NamespaceState.with_assoc(NamespaceState old, string ns_uri, string name) {
        this.parent = old;
        add_assoc(ns_uri, name);
    }

    public NamespaceState.with_current(NamespaceState old, string current_ns_uri) {
        this.parent = old;
        this.current_ns_uri = current_ns_uri;
    }

    public void add_assoc(string ns_uri, string name) {
        name_to_uri[name] = ns_uri;
        uri_to_name[ns_uri] = name;
    }

    public void set_current(string current_ns_uri) {
        this.current_ns_uri = current_ns_uri;
    }

    public string find_name(string ns_uri) throws IOError {
        if (uri_to_name.has_key(ns_uri)) {
            return uri_to_name[ns_uri];
        }
        if (parent != null) return parent.find_name(ns_uri);
        throw new IOError.INVALID_DATA(@"XML: NS URI $ns_uri not found.");
    }

    public string find_uri(string name) throws IOError {
        if (name_to_uri.has_key(name)) {
            return name_to_uri[name];
        }
        if (parent != null) return parent.find_uri(name);
        throw new IOError.INVALID_DATA(@"XML: NS name $name not found.");
    }

    public NamespaceState push() {
        return new NamespaceState.with_parent(this);
    }

    public NamespaceState pop() {
        return parent;
    }

    public string to_string() {
        StringBuilder sb = new StringBuilder ();
        sb.append ("NamespaceState{");
        NamespaceState? state = this;
        while (state != null) {
            foreach (string key in state.uri_to_name.keys) {
                sb.append(key);
                sb.append_c('=');
                sb.append(state.uri_to_name[key]);
                sb.append_c(',');
            }
            state = state.parent;
        }
        sb.append("current=");
        sb.append(current_ns_uri);
        sb.append_c('}');
        return sb.str;
    }
}

}
