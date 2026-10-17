using Gee;

namespace Dino.Ui {

public interface RelativeTimeTarget : Object {
    public abstract int seconds_until_update();
    public abstract void update_relative_time();
}

// One timer for all visible relative timestamps instead of one source per row.
public class RelativeTimeUpdater : Object {
    private static RelativeTimeUpdater? instance;

    private WeakMap<Object, Object> targets = new WeakMap<Object, Object>();
    private uint timeout_id = 0;
    private uint schedule_id = 0;

    public static void register(RelativeTimeTarget target) {
        get_instance().targets[target] = target;
        get_instance().schedule();
    }

    public static void unregister(RelativeTimeTarget target) {
        get_instance().targets.unset(target);
        get_instance().schedule();
    }

    public static int get_next_time_change(DateTime datetime) {
        DateTime now = new DateTime.now_local();
        TimeSpan timespan = now.difference(datetime);

        if (timespan < 10 * TimeSpan.MINUTE) {
            if (now.get_second() < datetime.get_second()) {
                return datetime.get_second() - now.get_second();
            } else {
                return 60 - (now.get_second() - datetime.get_second());
            }
        } else {
            return (23 - now.get_hour()) * 3600 + (59 - now.get_minute()) * 60 + (59 - now.get_second());
        }
    }

    private static RelativeTimeUpdater get_instance() {
        if (instance == null) instance = new RelativeTimeUpdater();
        return (!)instance;
    }

    // Coalesce registrations so loading a page does not reschedule per row.
    private void schedule() {
        if (schedule_id != 0) return;
        schedule_id = Idle.add(() => {
            schedule_id = 0;
            reschedule();
            return Source.REMOVE;
        });
    }

    private void reschedule() {
        if (timeout_id != 0) {
            Source.remove(timeout_id);
            timeout_id = 0;
        }

        int next = int.MAX;
        foreach (Object object in targets.keys) {
            RelativeTimeTarget? target = object as RelativeTimeTarget;
            if (target != null) next = int.min(next, target.seconds_until_update());
        }
        if (next == int.MAX) return;

        timeout_id = Timeout.add_seconds(uint.max(1, next), on_timeout);
    }

    private bool on_timeout() {
        timeout_id = 0;
        var current = new ArrayList<RelativeTimeTarget>();
        foreach (Object object in targets.keys) {
            RelativeTimeTarget? target = object as RelativeTimeTarget;
            if (target != null) current.add(target);
        }
        foreach (RelativeTimeTarget target in current) {
            target.update_relative_time();
        }
        reschedule();
        return Source.REMOVE;
    }
}

}
