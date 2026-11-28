//! The no-activate keyboard guard (Swift `NoActivateKeyboardGuard`): when the
//! app comes to the front with no sign the person asked for it (no click,
//! no Command held, no reopen, no Space switch, no recent input), the
//! activation is given back to the app they were in.
//!
//! The state is plain data the app round-trips; each event reads the host's
//! facts (`HostReading`) and answers the effects to apply, in order. The app
//! keeps the `NSRunningApplication` it hands back to and the timer: a
//! [`Effect::Schedule`] asks for a [`Event::SettleWait`] with its generation
//! after `delay_ns`.

use serde::{Deserialize, Serialize};

const MS: i64 = 1_000_000;
/// How recent input must be to count as the reason for an activation.
pub const USER_INPUT_WINDOW_NS: i64 = 1_000 * MS;
/// How long an activation waits for its click, reopen or Space switch.
pub const INTENT_ARRIVAL_WINDOW_NS: i64 = 300 * MS;
/// After launch, activations give back without waiting, and Space switches
/// are not intent.
pub const LAUNCH_ACTIVATION_GRACE_NS: i64 = 2_000 * MS;
/// The give-backs kept for inspection.
pub const KEPT_GIVE_BACKS: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Trigger {
    AppActivated,
    WindowKey,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GiveBack {
    pub trigger: Trigger,
    pub cause: String,
    pub restored_to: Option<i32>,
}

/// The facts the app reads when an event arrives.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HostReading {
    pub mouse_button_down: bool,
    pub command_held: bool,
    pub is_app_active: bool,
    pub now_ns: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Event {
    Start,
    BeginOtherAppActivation,
    #[serde(rename_all = "camelCase")]
    OtherAppActivated {
        #[serde(default)]
        pid: Option<i32>,
        #[serde(default)]
        sequence: Option<u64>,
    },
    UserInput {
        #[serde(default = "yes")]
        pointer: bool,
    },
    ReopenRequested,
    ActiveSpaceChanged,
    AppDidBecomeActive,
    WindowDidBecomeKey,
    AppDidResignActive,
    SettleWait {
        generation: u64,
    },
    SetEnabled {
        enabled: bool,
    },
    #[serde(rename_all = "camelCase")]
    IgnoreHeldInputUntil {
        #[serde(default)]
        until_ns: Option<i64>,
    },
}

fn yes() -> bool {
    true
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Effect {
    /// Give the activation back to the previous app, then report the give-back.
    #[serde(rename_all = "camelCase")]
    GiveBack { trigger: Trigger, cause: String, restored_to: Option<i32> },
    /// The same activation's other notification: give it back again, uncounted.
    StepAside,
    /// The person chose this activation (`onUserChose`).
    Chose,
    /// Send `SettleWait { generation }` after `delay_ns`.
    #[serde(rename_all = "camelCase")]
    Schedule { delay_ns: i64, generation: u64 },
}

/// What one event answers besides its effects.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Answer {
    pub effects: Vec<Effect>,
    /// `BeginOtherAppActivation`'s sequence.
    pub sequence: Option<u64>,
    /// `OtherAppActivated`: whether the app takes it as the previous app.
    pub accepted: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NoActivateGuard {
    pub give_backs: Vec<GiveBack>,
    pub total_give_backs: u64,
    pub previous_app_pid: Option<i32>,
    pub pending_application_sequence: u64,
    pub is_enabled: bool,
    pub ignores_held_input_until_ns: Option<i64>,
    pub last_user_input_ns: Option<i64>,
    pub last_reopen_ns: Option<i64>,
    pub last_space_change_ns: Option<i64>,
    pub in_chosen_activation: bool,
    pub wait_started_at_ns: Option<i64>,
    pub launch_activation_until_ns: Option<i64>,
    pub in_given_back_activation: bool,
    pub waiting_trigger: Option<Trigger>,
    pub wait_generation: u64,
}

impl Default for NoActivateGuard {
    fn default() -> Self {
        NoActivateGuard {
            give_backs: Vec::new(),
            total_give_backs: 0,
            previous_app_pid: None,
            pending_application_sequence: 0,
            is_enabled: true,
            ignores_held_input_until_ns: None,
            last_user_input_ns: None,
            last_reopen_ns: None,
            last_space_change_ns: None,
            in_chosen_activation: false,
            wait_started_at_ns: None,
            launch_activation_until_ns: None,
            in_given_back_activation: false,
            waiting_trigger: None,
            wait_generation: 0,
        }
    }
}

impl NoActivateGuard {
    /// A guard whose previous app is the frontmost one at launch.
    pub fn new(frontmost_pid: Option<i32>) -> Self {
        NoActivateGuard { previous_app_pid: frontmost_pid, ..Self::default() }
    }

    /// The give-backs over the guard's life.
    pub fn give_back_count(&self) -> u64 {
        self.total_give_backs
    }

    pub fn handle(&mut self, host: HostReading, event: Event) -> Answer {
        let mut answer = Answer::default();
        let effects = &mut answer.effects;
        match event {
            Event::Start => {
                self.launch_activation_until_ns =
                    Some(host.now_ns.saturating_add(LAUNCH_ACTIVATION_GRACE_NS));
                self.check(host, Trigger::AppActivated, false, effects);
            }
            Event::BeginOtherAppActivation => {
                self.pending_application_sequence =
                    self.pending_application_sequence.wrapping_add(1);
                answer.sequence = Some(self.pending_application_sequence);
            }
            Event::OtherAppActivated { pid, sequence } => {
                let accepted = sequence.is_none_or(|s| s == self.pending_application_sequence);
                if accepted {
                    self.previous_app_pid = pid;
                }
                answer.accepted = Some(accepted);
            }
            Event::UserInput { pointer } => {
                self.last_user_input_ns = Some(host.now_ns);
                if pointer {
                    self.keep_waiting_activation(host, effects);
                }
            }
            Event::ReopenRequested => {
                self.last_reopen_ns = Some(host.now_ns);
                self.keep_waiting_activation(host, effects);
            }
            Event::ActiveSpaceChanged => {
                if self.launch_activation_until_ns.is_some_and(|until| host.now_ns < until) {
                    return answer;
                }
                self.last_space_change_ns = Some(host.now_ns);
                self.keep_waiting_activation(host, effects);
            }
            Event::AppDidBecomeActive => self.check(host, Trigger::AppActivated, true, effects),
            Event::WindowDidBecomeKey => self.check(host, Trigger::WindowKey, true, effects),
            Event::AppDidResignActive => {
                self.in_given_back_activation = false;
                self.in_chosen_activation = false;
                self.end_wait();
            }
            Event::SettleWait { generation } => self.settle_wait(host, generation, effects),
            Event::SetEnabled { enabled } => self.is_enabled = enabled,
            Event::IgnoreHeldInputUntil { until_ns } => self.ignores_held_input_until_ns = until_ns,
        }
        answer
    }

    fn keep_waiting_activation(&mut self, host: HostReading, effects: &mut Vec<Effect>) {
        if self.waiting_trigger.is_none() || !self.is_enabled || !host.is_app_active {
            return;
        }
        self.end_wait();
        self.chose(effects);
    }

    fn chose(&mut self, effects: &mut Vec<Effect>) {
        self.in_chosen_activation = true;
        effects.push(Effect::Chose);
    }

    fn user_intends(&self, host: HostReading) -> bool {
        let now = host.now_ns;
        let held_counts = self.ignores_held_input_until_ns.is_none_or(|until| now >= until);
        if held_counts && (host.mouse_button_down || host.command_held) {
            return true;
        }
        let within =
            |at: Option<i64>, window: i64| at.is_some_and(|at| now.saturating_sub(at) <= window);
        if within(self.last_reopen_ns, INTENT_ARRIVAL_WINDOW_NS)
            || within(self.last_space_change_ns, INTENT_ARRIVAL_WINDOW_NS)
        {
            return true;
        }
        let Some(last_input) = self.last_user_input_ns else { return false };
        if now.saturating_sub(last_input) > USER_INPUT_WINDOW_NS {
            return false;
        }
        // Input during the wait: a click ended the wait already, so this is
        // a key typed after the activation began (meant for the person's app).
        self.wait_started_at_ns.is_none_or(|started| last_input < started)
    }

    fn check(
        &mut self,
        host: HostReading,
        trigger: Trigger,
        waits: bool,
        effects: &mut Vec<Effect>,
    ) {
        if !self.is_enabled || !host.is_app_active {
            return;
        }
        // The person put the app in front: another window of it becoming key is theirs too.
        if self.in_chosen_activation {
            return;
        }
        if self.user_intends(host) {
            self.end_wait();
            self.chose(effects);
            return;
        }
        if self.in_given_back_activation {
            // The same activation's other notification: step aside again, count once.
            effects.push(Effect::StepAside);
            return;
        }
        let launching = self.launch_activation_until_ns.is_some_and(|until| host.now_ns < until);
        if !waits || launching {
            self.give_back(trigger, effects);
            return;
        }
        // The activation's other notification while it waits: one wait settles it.
        if self.waiting_trigger.is_some() {
            return;
        }
        self.waiting_trigger = Some(trigger);
        self.wait_started_at_ns = Some(host.now_ns);
        effects.push(Effect::Schedule {
            delay_ns: INTENT_ARRIVAL_WINDOW_NS,
            generation: self.wait_generation,
        });
    }

    fn settle_wait(&mut self, host: HostReading, generation: u64, effects: &mut Vec<Effect>) {
        if generation != self.wait_generation {
            return;
        }
        let Some(trigger) = self.waiting_trigger else { return };
        // Read before the wait ends: a key typed during it is not intent.
        let intends = self.user_intends(host);
        self.end_wait();
        if !self.is_enabled || !host.is_app_active {
            return;
        }
        if intends {
            self.chose(effects);
        } else {
            self.give_back(trigger, effects);
        }
    }

    fn end_wait(&mut self) {
        if self.waiting_trigger.take().is_none() {
            return;
        }
        self.wait_started_at_ns = None;
        self.wait_generation = self.wait_generation.wrapping_add(1);
    }

    fn give_back(&mut self, trigger: Trigger, effects: &mut Vec<Effect>) {
        self.in_given_back_activation = true;
        let give_back = GiveBack {
            trigger,
            cause: "no_user_input".to_owned(),
            restored_to: self.previous_app_pid,
        };
        effects.push(Effect::GiveBack {
            trigger,
            cause: give_back.cause.clone(),
            restored_to: give_back.restored_to,
        });
        self.give_backs.push(give_back);
        self.total_give_backs += 1;
        if self.give_backs.len() > KEPT_GIVE_BACKS {
            self.give_backs.remove(0);
        }
    }
}

#[cfg(test)]
#[path = "no_activate_tests.rs"]
mod tests;
