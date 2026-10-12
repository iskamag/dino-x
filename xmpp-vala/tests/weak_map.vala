namespace Xmpp.Test {

class WeakMapTest : Gee.TestCase {
    public WeakMapTest() {
        base("WeakMap");
        add_test("value_finalization", test_value_finalization);
        add_test("map_finalization", test_map_finalization);
        add_test("replacement", test_replacement);
        add_test("clear", test_clear);
        add_test("unset", test_unset);
        add_test("custom_key_functions", test_custom_key_functions);
        add_test("custom_map_finalization", test_custom_map_finalization);
        add_test("integer_keys", test_integer_keys);
        add_test("object_key_finalization", test_object_key_finalization);
        add_test("repeated_dispose", test_repeated_dispose);
        add_test("repeated_map_finalization", test_repeated_map_finalization);
    }

    private void test_value_finalization() {
        var map = new WeakMap<string, Object>();
        var value = new Object();
        var value_ref = WeakRef(value);
        map["key"] = value;
        assert_true(map["key"] == value);
        value = null;
        assert_null(value_ref.get());
        assert_cmpint(map.size, CompareOperator.EQ, 0);
    }

    private void test_map_finalization() {
        var value = new Object();
        var map = new WeakMap<string, Object>();
        var map_ref = WeakRef(map);
        map["key"] = value;
        map = null;
        assert_null(map_ref.get());
        // Finalizing the value must not invoke a callback on a destroyed map.
        value = null;
    }

    private void test_replacement() {
        var map = new WeakMap<string, Object>();
        var first = new Object();
        var second = new Object();
        map["key"] = first;
        map["key"] = second;
        first = null;
        assert_true(map["key"] == second);
        second = null;
        assert_false(map.has_key("key"));
    }

    private void test_clear() {
        var map = new WeakMap<string, Object>();
        var value = new Object();
        map["first"] = value;
        map["second"] = value;
        map.clear();
        assert_cmpint(map.size, CompareOperator.EQ, 0);
        map["first"] = new Object();
        assert_false(map.has_key("first"));
        value = null;
    }

    private void test_unset() {
        var map = new WeakMap<string, Object>();
        var value = new Object();
        map["key"] = value;
        Object? removed;
        assert_true(map.unset("key", out removed));
        assert_true(removed == value);
        assert_false(map.unset("missing"));
        map["key"] = new Object();
        assert_false(map.has_key("key"));
        value = null;
        removed = null;
    }

    private void test_custom_key_functions() {
        var map = new WeakMap<string, Object>(
            key => key.down().hash(), (a, b) => a.down() == b.down());
        var value = new Object();
        map["KEY"] = value;
        assert_true(map["key"] == value);
        value = null;
        assert_cmpint(map.size, CompareOperator.EQ, 0);
    }

    private void test_custom_map_finalization() {
        var value = new Object();
        var map = new WeakMap<string, Object>(
            key => key.hash(), (a, b) => a == b, (a, b) => a == b);
        var map_ref = WeakRef(map);
        map["key"] = value;
        map.clear();
        // Custom hash/equality delegates must not keep even an empty map alive.
        map = null;
        assert_null(map_ref.get());
    }

    private void test_integer_keys() {
        var map = new WeakMap<int, Object>();
        var value = new Object();
        map[42] = value;
        assert_true(map[42] == value);
        value = null;
        assert_false(map.has_key(42));
    }

    private void test_object_key_finalization() {
        var map = new WeakMap<Object, Object>();
        var key = new Object();
        var key_ref = WeakRef(key);
        var value = new Object();
        map[key] = value;
        key = null;
        var retained_key = key_ref.get();
        assert_nonnull(retained_key);
        retained_key = null;
        value = null;
        assert_null(key_ref.get());
        assert_cmpint(map.size, CompareOperator.EQ, 0);
    }

    private void test_repeated_dispose() {
        var value = new Object();
        var map = new WeakMap<string, Object>();
        map["key"] = value;
        map.dispose();
        map.dispose();
        assert_cmpint(map.size, CompareOperator.EQ, 0);
        map = null;
        value = null;
    }

    private void test_repeated_map_finalization() {
        var value = new Object();
        for (int i = 0; i < 1000; i++) {
            var map = new WeakMap<string, Object>(
                key => key.hash(), (a, b) => a == b, (a, b) => a == b);
            var map_ref = WeakRef(map);
            map["first"] = value;
            map["second"] = value;
            map = null;
            assert_null(map_ref.get());
        }
        value = null;
    }
}

}
