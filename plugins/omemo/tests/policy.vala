using Gee;

namespace Omemo.Test {

using Dino.Plugins.Omemo;
using Xmpp.Xep.Omemo;

class PolicyTest : Gee.TestCase {
    public PolicyTest() {
        base("Policy");

        add_test("send", test_send);
        add_test("waiting_for_device_list", test_waiting_for_device_list);
        add_test("waiting_for_own_list", test_waiting_for_own_list);
        add_test("waiting_for_sessions", test_waiting_for_sessions);
        add_test("no_own_devices", test_no_own_devices);
        add_test("no_recipient_devices", test_no_recipient_devices);
        add_test("unencrypted", test_unencrypted);
        add_test("all_recipient_devices_lost", test_all_recipient_devices_lost);
        add_test("retry_backoff", test_retry_backoff);
        add_test("device_list_result", test_device_list_result);
    }

    private static EncryptState ready_state() {
        var state = new EncryptState();
        state.encrypted = true;
        state.own_list = true;
        state.own_devices = 1;
        state.own_success = 1;
        state.other_devices = 1;
        state.other_success = 1;
        return state;
    }

    private void test_send() {
        assert_cmpint(SendPolicy.decide(ready_state()), CompareOperator.EQ, MessageSendDecision.SEND);
    }

    private void test_waiting_for_device_list() {
        var state = ready_state();
        state.other_waiting_lists = 1;
        assert_cmpint(SendPolicy.decide(state), CompareOperator.EQ, MessageSendDecision.WAIT);
    }

    private void test_waiting_for_own_list() {
        var state = ready_state();
        state.own_list = false;
        assert_cmpint(SendPolicy.decide(state), CompareOperator.EQ, MessageSendDecision.WAIT);
    }

    private void test_waiting_for_sessions() {
        var state = ready_state();
        state.other_unknown = 1;
        assert_cmpint(SendPolicy.decide(state), CompareOperator.EQ, MessageSendDecision.WAIT);
    }

    private void test_no_own_devices() {
        var state = ready_state();
        state.own_devices = 0;
        assert_cmpint(SendPolicy.decide(state), CompareOperator.EQ, MessageSendDecision.WAIT);
    }

    private void test_no_recipient_devices() {
        // A known address with no usable recipient device must never be sent:
        // the stanza would carry no <key> element at all.
        var state = ready_state();
        state.other_devices = 0;
        state.other_success = 0;
        assert_cmpint(SendPolicy.decide(state), CompareOperator.EQ, MessageSendDecision.WONT_SEND);
    }

    private void test_unencrypted() {
        var state = ready_state();
        state.encrypted = false;
        assert_cmpint(SendPolicy.decide(state), CompareOperator.EQ, MessageSendDecision.WONT_SEND);
    }

    private void test_all_recipient_devices_lost() {
        var state = ready_state();
        state.other_devices = 2;
        state.other_lost = 2;
        assert_cmpint(SendPolicy.decide(state), CompareOperator.EQ, MessageSendDecision.WONT_SEND);
    }

    private void test_retry_backoff() {
        assert_cmpuint(RetryPolicy.delay_seconds(0), CompareOperator.EQ, 2);
        assert_cmpuint(RetryPolicy.delay_seconds(1), CompareOperator.EQ, 4);
        assert_cmpuint(RetryPolicy.delay_seconds(2), CompareOperator.EQ, 8);
        assert_cmpuint(RetryPolicy.delay_seconds(3), CompareOperator.EQ, 16);
        assert_cmpuint(RetryPolicy.delay_seconds(4), CompareOperator.EQ, 32);
        assert_cmpuint(RetryPolicy.delay_seconds(10), CompareOperator.EQ, RetryPolicy.MAX_DELAY_SECONDS);
    }

    private void test_device_list_result() {
        assert_true(DeviceListResult.failure().success == false);
        assert_true(DeviceListResult.ok(new ArrayList<int32>()).success == true);
        assert_cmpint(DeviceListResult.failure().devices.size, CompareOperator.EQ, 0);
    }
}

}
