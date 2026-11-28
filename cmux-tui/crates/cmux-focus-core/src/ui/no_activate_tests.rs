//! The Swift `NoActivateKeyboardGuardTests`, over the Rust guard: the test
//! host applies the effects as the app does (a give-back or step-aside
//! hands back to the previous app's pid, a schedule queues a settle).

use super::*;

const SECOND: i64 = 1_000_000_000;
const MS: i64 = 1_000_000;

struct Host {
    mouse_button_down: bool,
    command_held: bool,
    is_app_active: bool,
    now: i64,
    /// The pid handed back to (`Some(None)`: handed back with no pid).
    handed_back_to: Option<Option<i32>>,
    scheduled: Vec<(i64, u64)>,
    chose: usize,
}

impl Host {
    fn new() -> Self {
        Host {
            mouse_button_down: false,
            command_held: false,
            is_app_active: true,
            now: 1_000 * SECOND,
            handed_back_to: None,
            scheduled: Vec::new(),
            chose: 0,
        }
    }

    fn reading(&self) -> HostReading {
        HostReading {
            mouse_button_down: self.mouse_button_down,
            command_held: self.command_held,
            is_app_active: self.is_app_active,
            now_ns: self.now,
        }
    }

    fn send(&mut self, guardian: &mut NoActivateGuard, event: Event) -> Answer {
        let answer = guardian.handle(self.reading(), event);
        for effect in &answer.effects {
            match effect {
                Effect::GiveBack { .. } | Effect::StepAside => {
                    self.handed_back_to = Some(guardian.previous_app_pid);
                }
                Effect::Chose => self.chose += 1,
                Effect::Schedule { delay_ns, generation } => {
                    self.scheduled.push((*delay_ns, *generation));
                }
            }
        }
        answer
    }

    /// Lets the waits run out: time passes, then every scheduled deadline fires.
    fn elapse(&mut self, guardian: &mut NoActivateGuard, duration: i64) {
        self.now += duration;
        let due = std::mem::take(&mut self.scheduled);
        for (_, generation) in due {
            self.send(guardian, Event::SettleWait { generation });
        }
    }
}

fn give_back(trigger: Trigger, pid: Option<i32>) -> GiveBack {
    GiveBack { trigger, cause: "no_user_input".to_owned(), restored_to: pid }
}

#[test]
fn give_back_uses_the_already_resolved_application_and_pid() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(4242));
    host.send(&mut guardian, Event::Start);
    assert_eq!(host.handed_back_to, Some(Some(4242)));
    assert_eq!(guardian.give_backs, vec![give_back(Trigger::AppActivated, Some(4242))]);
}

#[test]
fn later_activation_replaces_the_resolved_target_without_lookup() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(11));
    let answer =
        host.send(&mut guardian, Event::OtherAppActivated { pid: Some(22), sequence: None });
    assert_eq!(answer.accepted, Some(true));
    host.send(&mut guardian, Event::Start);
    assert_eq!(host.handed_back_to, Some(Some(22)));
    assert_eq!(guardian.give_backs.last().unwrap().restored_to, Some(22));
}

#[test]
fn an_older_background_resolution_cannot_replace_the_newest_activation() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(None);
    let first = host.send(&mut guardian, Event::BeginOtherAppActivation).sequence;
    let second = host.send(&mut guardian, Event::BeginOtherAppActivation).sequence;
    let older =
        host.send(&mut guardian, Event::OtherAppActivated { pid: Some(11), sequence: first });
    assert_eq!(older.accepted, Some(false));
    host.send(&mut guardian, Event::OtherAppActivated { pid: Some(22), sequence: second });
    host.send(&mut guardian, Event::Start);
    assert_eq!(host.handed_back_to, Some(Some(22)));
    assert_eq!(guardian.give_backs.last().unwrap().restored_to, Some(22));
}

#[test]
fn an_activation_with_intent_reports_the_user_chose_and_a_stopped_guard_steps_aside() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(7));
    host.command_held = true;
    host.send(&mut guardian, Event::AppDidBecomeActive);
    assert_eq!(host.chose, 1);
    assert_eq!(host.handed_back_to, None);
    host.command_held = false;
    host.send(&mut guardian, Event::SetEnabled { enabled: false });
    host.send(&mut guardian, Event::AppDidBecomeActive);
    host.send(&mut guardian, Event::WindowDidBecomeKey);
    assert_eq!(host.handed_back_to, None);
    assert!(guardian.give_backs.is_empty());
}

#[test]
fn held_input_right_after_an_update_relaunch_is_not_intent() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(7));
    let until = host.now + LAUNCH_ACTIVATION_GRACE_NS;
    host.send(&mut guardian, Event::IgnoreHeldInputUntil { until_ns: Some(until) });
    host.command_held = true;
    host.send(&mut guardian, Event::Start);
    assert_eq!(host.chose, 0);
    assert_eq!(guardian.give_back_count(), 1);
    host.send(&mut guardian, Event::AppDidResignActive);
    host.now += 3 * SECOND;
    host.send(&mut guardian, Event::AppDidBecomeActive);
    assert_eq!(host.chose, 1, "Cmd-Tab after the launch is the user's");
}

#[test]
fn a_click_whose_mouse_down_arrives_after_the_activation_keeps_the_front() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(7));
    host.send(&mut guardian, Event::AppDidBecomeActive);
    host.send(&mut guardian, Event::WindowDidBecomeKey);
    assert_eq!(
        host.handed_back_to, None,
        "nothing goes back before the click's input had its chance"
    );
    assert_eq!(host.scheduled.len(), 1, "one wait for the activation's two notifications");
    assert_eq!(host.scheduled[0].0, INTENT_ARRIVAL_WINDOW_NS);
    host.send(&mut guardian, Event::UserInput { pointer: true });
    host.elapse(&mut guardian, INTENT_ARRIVAL_WINDOW_NS);
    assert_eq!(host.handed_back_to, None);
    assert!(guardian.give_backs.is_empty());
}

#[test]
fn a_reopen_around_the_activation_keeps_the_front() {
    let mut host = Host::new();
    let mut after = NoActivateGuard::new(Some(7));
    host.send(&mut after, Event::AppDidBecomeActive);
    host.send(&mut after, Event::ReopenRequested);
    host.elapse(&mut after, INTENT_ARRIVAL_WINDOW_NS);
    assert!(after.give_backs.is_empty());

    let mut before = NoActivateGuard::new(Some(7));
    host.send(&mut before, Event::ReopenRequested);
    host.send(&mut before, Event::AppDidBecomeActive);
    assert!(host.scheduled.is_empty(), "a reopen just before is intent at once");
    assert!(before.give_backs.is_empty());
    assert_eq!(host.handed_back_to, None);
}

#[test]
fn a_key_typed_during_the_wait_is_not_intent() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(7));
    host.send(&mut guardian, Event::AppDidBecomeActive);
    host.now += 50 * MS;
    host.send(&mut guardian, Event::UserInput { pointer: false });
    assert_eq!(host.scheduled.len(), 1, "the key does not end the wait");
    host.elapse(&mut guardian, INTENT_ARRIVAL_WINDOW_NS);
    assert_eq!(host.handed_back_to, Some(Some(7)));
    assert_eq!(guardian.give_back_count(), 1);

    host.send(&mut guardian, Event::AppDidResignActive);
    host.handed_back_to = None;
    host.send(&mut guardian, Event::UserInput { pointer: false });
    host.send(&mut guardian, Event::AppDidBecomeActive);
    assert!(host.scheduled.is_empty(), "a key just before the activation is intent");
    assert_eq!(host.handed_back_to, None);
}

#[test]
fn an_old_reopen_is_not_intent() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(7));
    host.send(&mut guardian, Event::ReopenRequested);
    host.now += INTENT_ARRIVAL_WINDOW_NS + 100 * MS;
    host.send(&mut guardian, Event::AppDidBecomeActive);
    host.elapse(&mut guardian, INTENT_ARRIVAL_WINDOW_NS);
    assert_eq!(guardian.give_back_count(), 1);
}

#[test]
fn an_activation_with_no_input_still_goes_back_after_the_wait() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(7));
    host.send(&mut guardian, Event::AppDidBecomeActive);
    host.send(&mut guardian, Event::WindowDidBecomeKey);
    host.elapse(&mut guardian, INTENT_ARRIVAL_WINDOW_NS + SECOND);
    assert_eq!(host.handed_back_to, Some(Some(7)));
    assert_eq!(guardian.give_backs, vec![give_back(Trigger::AppActivated, Some(7))]);

    host.send(&mut guardian, Event::AppDidResignActive);
    host.handed_back_to = None;
    host.send(&mut guardian, Event::AppDidBecomeActive);
    host.send(&mut guardian, Event::AppDidResignActive);
    host.elapse(&mut guardian, INTENT_ARRIVAL_WINDOW_NS);
    assert_eq!(host.handed_back_to, None);
    assert_eq!(guardian.give_back_count(), 1);
}

#[test]
fn launch_activations_go_back_without_waiting() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(7));
    host.send(&mut guardian, Event::Start);
    assert!(host.scheduled.is_empty());
    assert_eq!(guardian.give_back_count(), 1);
    host.send(&mut guardian, Event::AppDidResignActive);
    host.now += 500 * MS;
    host.send(&mut guardian, Event::AppDidBecomeActive);
    assert!(host.scheduled.is_empty());
    assert_eq!(guardian.give_back_count(), 2);
    host.send(&mut guardian, Event::AppDidResignActive);
    host.now += LAUNCH_ACTIVATION_GRACE_NS;
    host.send(&mut guardian, Event::AppDidBecomeActive);
    assert_eq!(host.scheduled.len(), 1, "after the launch an activation waits for its click");
}

#[test]
fn a_space_switch_around_the_activation_keeps_the_front() {
    let mut host = Host::new();
    let mut after = NoActivateGuard::new(Some(7));
    host.send(&mut after, Event::AppDidBecomeActive);
    host.send(&mut after, Event::ActiveSpaceChanged);
    host.elapse(&mut after, INTENT_ARRIVAL_WINDOW_NS);
    assert!(after.give_backs.is_empty());
    assert_eq!(host.handed_back_to, None);
    assert_eq!(host.chose, 1);

    let mut before = NoActivateGuard::new(Some(7));
    host.send(&mut before, Event::ActiveSpaceChanged);
    host.now += 120 * MS;
    host.send(&mut before, Event::AppDidBecomeActive);
    assert!(host.scheduled.is_empty(), "a Space switch just before is intent at once");
    assert!(before.give_backs.is_empty());
    assert_eq!(host.handed_back_to, None);
}

#[test]
fn a_chosen_activation_keeps_later_key_windows() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(7));
    host.send(&mut guardian, Event::ActiveSpaceChanged);
    host.send(&mut guardian, Event::AppDidBecomeActive);
    host.now += 14 * SECOND;
    host.send(&mut guardian, Event::WindowDidBecomeKey);
    host.elapse(&mut guardian, INTENT_ARRIVAL_WINDOW_NS);
    assert!(guardian.give_backs.is_empty());
    host.send(&mut guardian, Event::AppDidResignActive);
    host.send(&mut guardian, Event::AppDidBecomeActive);
    host.elapse(&mut guardian, INTENT_ARRIVAL_WINDOW_NS);
    assert_eq!(host.handed_back_to, Some(Some(7)));
    assert_eq!(guardian.give_back_count(), 1);
}

#[test]
fn an_old_or_launch_space_switch_is_not_intent() {
    let mut host = Host::new();
    let mut old = NoActivateGuard::new(Some(7));
    host.send(&mut old, Event::ActiveSpaceChanged);
    host.now += INTENT_ARRIVAL_WINDOW_NS + 100 * MS;
    host.send(&mut old, Event::AppDidBecomeActive);
    host.elapse(&mut old, INTENT_ARRIVAL_WINDOW_NS);
    assert_eq!(old.give_back_count(), 1);

    let mut launching = NoActivateGuard::new(Some(7));
    host.is_app_active = false;
    host.send(&mut launching, Event::Start);
    host.send(&mut launching, Event::ActiveSpaceChanged);
    host.is_app_active = true;
    host.send(&mut launching, Event::AppDidBecomeActive);
    assert_eq!(launching.give_back_count(), 1, "the launch's activation still goes back at once");
}

#[test]
fn the_kept_give_backs_are_bounded_and_the_count_is_not() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(7));
    for _ in 0..40 {
        host.send(&mut guardian, Event::Start);
        host.send(&mut guardian, Event::AppDidResignActive);
    }
    assert_eq!(guardian.give_backs.len(), KEPT_GIVE_BACKS);
    assert_eq!(guardian.give_back_count(), 40);
}

#[test]
fn the_state_round_trips_in_the_wire_shape() {
    let mut host = Host::new();
    let mut guardian = NoActivateGuard::new(Some(7));
    host.send(&mut guardian, Event::AppDidBecomeActive);
    let json = serde_json::to_value(&guardian).unwrap();
    assert_eq!(json["waitingTrigger"], "app_activated");
    assert_eq!(json["isEnabled"], true);
    let back: NoActivateGuard = serde_json::from_value(json).unwrap();
    assert_eq!(back, guardian);
    let fresh: NoActivateGuard = serde_json::from_str("{}").unwrap();
    assert!(fresh.is_enabled, "an empty state is a new, enabled guard");
}
