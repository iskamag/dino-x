using Gee;

public class WeakMap<K, V> : Gee.AbstractMap<K, V> {

    private HashMap<K, weak V> hash_map;
    private HashMap<K, WeakNotifyWrapper> notify_map;

    public HashDataFunc<K>? key_hash_func = null;
    public EqualDataFunc<K>? key_equal_func = null;
    public EqualDataFunc<V>? value_equal_func = null;

    public WeakMap(owned HashDataFunc<K>? key_hash_func = null, owned EqualDataFunc<K>? key_equal_func = null, owned EqualDataFunc<V>? value_equal_func = null) {
        if (!typeof(V).is_object()) {
            error("WeakMap only takes values that are Objects");
        }

        this.key_hash_func = (owned)key_hash_func;
        this.key_equal_func = (owned)key_equal_func;
        this.value_equal_func = (owned)value_equal_func;

        initialize_maps<K, V>(this);
    }

    // Static helpers avoid Vala capturing the instance for generic type metadata.
    private static void initialize_maps<K, V>(WeakMap<K, V> map) {
        weak WeakMap<K, V> self = map;
        HashDataFunc<K>? hash_func = null;
        EqualDataFunc<K>? key_equal = null;
        EqualDataFunc<V>? value_equal = null;
        if (self.key_hash_func != null) hash_func = key => self.key_hash_func(key);
        if (self.key_equal_func != null) key_equal = (a, b) => self.key_equal_func(a, b);
        if (self.value_equal_func != null) value_equal = (a, b) => self.value_equal_func(a, b);
        self.hash_map = new HashMap<K, weak V>((owned) hash_func, (owned) key_equal, (owned) value_equal);
        self.notify_map = new HashMap<K, WeakNotifyWrapper>(
            key => self.hash_map.key_hash_func(key), (a, b) => self.hash_map.key_equal_func(a, b));
    }

    public override void clear() {
        foreach (K key in notify_map.keys) {
            Object o = (Object) hash_map[key];
            o.weak_unref(notify_map[key].func);
        }
        hash_map.clear();
        notify_map.clear();
    }

    public override V @get(K key) {
        if (!hash_map.has_key(key)) return null;

        var v = hash_map[key];

        return (owned) v;
    }

    public override bool has(K key, V value) {
        return has_key(key) && (this.value_equal_func != null ? this.value_equal_func(hash_map[key], value) : hash_map[key] == value);
    }

    public override bool has_key(K key) {
        return hash_map.has_key(key);
    }

    public override Gee.MapIterator<K,V> map_iterator() {
        assert_not_reached();
    }

    public override void @set(K key, V value) {
        assert(value != null);

        unset(key);

        Object v_obj = (Object) value;
        var notify_wrap = create_notify<K, V>(this, key);
        notify_map[key] = notify_wrap;
        v_obj.weak_ref(notify_wrap.func);

        hash_map[key] = value;
    }

    private static WeakNotifyWrapper create_notify<K, V>(WeakMap<K, V> map, K key) {
        weak WeakMap<K, V> self = map;
        return new WeakNotifyWrapper((obj) => {
            self.hash_map.unset(key);
            self.notify_map.unset(key);
        });
    }

    public override bool unset(K key, out V value = null) {
        if (!hash_map.has_key(key)) {
            value = null;
            return false;
        }

        Object v_obj = (Object) hash_map[key];
        v_obj.weak_unref(notify_map[key].func);
        notify_map.unset(key);
        return hash_map.unset(key, out value);
    }
    public override Gee.Set<Gee.Map.Entry<K,V>> entries { owned get; }

    public override Gee.Set<K> keys {
        owned get { return hash_map.keys; }
    }

    public override bool read_only { get { assert_not_reached(); } }

    public override int size { get { return hash_map.size; } }

    public override Gee.Collection<V> values {
        owned get {
            assert_not_reached();
        }
    }

    public override void dispose() {
        clear();
        base.dispose();
    }
}

internal class WeakNotifyWrapper {
    public WeakNotify func;

    public WeakNotifyWrapper(owned WeakNotify func) {
        this.func = (owned) func;
    }
}
