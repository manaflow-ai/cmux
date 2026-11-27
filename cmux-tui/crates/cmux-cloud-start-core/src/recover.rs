//! The one recovery table of a Cloud chat start, shared by both starts (Leo, goals/cloud-errors-self-recover: "Fix
//! the cause"): `cmux cloud start-chat` (cmux-tui `cli/cloud_start_chat/recover.rs`, which runs each [`Action`]) and
//! the app's own chat pane start (`CloudStartChat.reply`, op `cloud_start_pane_recovery`, [`pane_step`]). Every
//! Cloud chat error class the start answers, and the action that runs on its own for it, with no click. A class with
//! no action ([`recovery`] answers `None`) is the only one that reaches the person, who then clicks through (signs
//! in, opens the app, adds a connection).
//!
//! [`recovery`] is one exhaustive `match`: a new [`Class`] without a row does not compile.

use std::time::Duration;

use serde::{Deserialize, Serialize};

/// Declares [`Class`] and [`Class::ALL`] from one list, so `ALL` names every variant by construction.
macro_rules! classes {
    ($($(#[$doc:meta])* $name:ident,)*) => {
        /// A Cloud chat error class of the start path, read from the error's `code` (and, for the app's own
        /// `unavailable`, its words) by [`classify`].
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum Class {
            $($(#[$doc])* $name,)*
        }

        impl Class {
            /// Every class, in declaration order.
            pub const ALL: &'static [Class] = &[$(Class::$name,)*];
            /// Each class's variant name, in [`Class::ALL`]'s order (the CLI's `CMUX_CLOUD_FAULT` reads it).
            pub const NAMES: &'static [&'static str] = &[$(stringify!($name),)*];
        }
    };
}

classes! {
    /// `cloud.machine_stuck`: a machine this run made never came up within the start's bound.
    MachineStuck,
    /// `cloud.start_pending` with no chat yet: the machine (or its create) is still on its way.
    StartPending,
    /// `cloud.list_unread`: a connected app has not loaded its Cloud machines yet (`retryable: true`).
    ListUnread,
    /// `cloud.machine_cap`: the account is at its machine cap.
    MachineCap,
    /// `cloud.spend_cap`: the account is at its spend cap.
    SpendCap,
    /// `cloud.signed_out`: the app is signed out of Cloud.
    SignedOut,
    /// `cloud.account_changed`: the app is signed in to another account than the start's.
    AccountChanged,
    /// `cloud.app_not_connected`: the Mac app is closed, or its Mac locked or asleep.
    AppNotConnected,
    /// The app's `unavailable` "No Cloud connection serves AGENT yet": no gateway serves the agent.
    NoConnection,
    /// `auth.*` (but `auth.required`): the machine's agent is not signed in to its own account.
    AgentSignIn,
    /// `agent.limit_reached`: the agent's account is out of usage until a time.
    AgentLimit,
    /// `agent_session.*`: the machine's acpmux refused the session (bad request, untrusted folder, ...).
    AgentRefused,
    /// `cloud.start_failed`: the machine failed at a final stage, or its create failed.
    StartFailed,
    /// `cloud.name_taken`: the `--name` is another machine's.
    NameTaken,
    /// `cloud.make_room_failed` and `cloud.make_room_archiving`: making room could not free a machine now.
    MakeRoomFailed,
    /// `chat.turn_failed`: the started chat's turn failed.
    TurnFailed,
    /// `chat.wait_timeout`: the wait on the turn ran out.
    TurnTimeout,
    /// `chat.lost` and `chat.unreachable`: the started chat cannot be read any more.
    ChatUnreachable,
    /// `chat.send_failed`: the prompt was not taken.
    SendFailed,
    /// `chat.permission_waiting`: the turn waits on a person's permission answer.
    PermissionWaiting,
}

/// What runs on its own for a [`Class`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Action {
    /// Release the stuck machine and start on a fresh one (the CLI's `fresh::replace_stuck`).
    FreshMachine,
    /// Pause, then start again on the machine the error names (never a second new machine), within the deadline.
    RerunOnMachine,
    /// Pause, then start again from the top, within the deadline.
    Rerun,
    /// Free the machine the cap refusal offers and start again once; only with the person's consent to delete a
    /// machine (the CLI's `--make-room`), so the default stays as it was.
    MakeRoom,
}

/// THE table: the action for each class, or `None` where only a person can act, which is the one case that falls
/// to click-through. Exhaustive on purpose: a new class needs its row here to compile.
pub fn recovery(class: Class) -> Option<Action> {
    match class {
        Class::MachineStuck => Some(Action::FreshMachine),
        Class::StartPending => Some(Action::RerunOnMachine),
        Class::ListUnread => Some(Action::Rerun),
        Class::MachineCap => Some(Action::MakeRoom),
        // A person signs in, opens or unlocks the app, picks the account, or adds a Cloud connection (the
        // platform answers it `x-should-retry: false`): a rerun meets the same refusal.
        Class::SignedOut
        | Class::AccountChanged
        | Class::AppNotConnected
        | Class::NoConnection
        | Class::AgentSignIn => None,
        // Money or plan: raising a cap or waiting out an account's usage window is the person's call.
        Class::SpendCap | Class::AgentLimit => None,
        // Definitive refusals: the same request is refused again, and a refused start's machine is rolled back.
        Class::AgentRefused | Class::NameTaken | Class::MakeRoomFailed => None,
        // A final-stage failure is not proven to be this run's own machine from its answer alone, so starting on
        // a new one (and deleting this one) is not yet safe from here.
        Class::StartFailed => None,
        // The chat started: the machine's acpmux resumes a failed turn itself (turn_errors::resume_cause), and a
        // rerun here would start a second chat with the same prompt.
        Class::TurnFailed
        | Class::TurnTimeout
        | Class::ChatUnreachable
        | Class::SendFailed
        | Class::PermissionWaiting => None,
    }
}

/// The code of a machine this start made that never came up.
pub const STUCK_CODE: &str = "cloud.machine_stuck";

/// The class of a start error, from its `code` and `message` (the app's words for `unavailable`); `None` for a code
/// no class names, which passes through as before. `chat_may_exist`: a pending answer whose prompt may be on the
/// machine (`sent: unknown`) or whose chat started, which is not a machine still starting.
pub fn classify(code: &str, message: &str, chat_may_exist: bool) -> Option<Class> {
    let class = match code {
        STUCK_CODE => Class::MachineStuck,
        "cloud.start_pending" if !chat_may_exist => Class::StartPending,
        "cloud.list_unread" => Class::ListUnread,
        "cloud.machine_cap" => Class::MachineCap,
        "cloud.spend_cap" => Class::SpendCap,
        "cloud.signed_out" => Class::SignedOut,
        "cloud.account_changed" => Class::AccountChanged,
        "cloud.app_not_connected" => Class::AppNotConnected,
        "unavailable" if message.starts_with("No Cloud connection serves") => Class::NoConnection,
        "agent.limit_reached" => Class::AgentLimit,
        "cloud.start_failed" => Class::StartFailed,
        "cloud.name_taken" => Class::NameTaken,
        "cloud.make_room_failed" | "cloud.make_room_archiving" => Class::MakeRoomFailed,
        "chat.turn_failed" => Class::TurnFailed,
        "chat.wait_timeout" => Class::TurnTimeout,
        "chat.lost" | "chat.unreachable" => Class::ChatUnreachable,
        "chat.send_failed" => Class::SendFailed,
        "chat.permission_waiting" => Class::PermissionWaiting,
        code if code.starts_with("agent_session.") => Class::AgentRefused,
        code if code.starts_with("auth.") && code != "auth.required" => Class::AgentSignIn,
        _ => return None,
    };
    Some(class)
}

/// The first pause before a rerun; each next one doubles, up to [`RERUN_MAX_PAUSE`], always within the deadline.
pub const RERUN_PAUSE: Duration = Duration::from_secs(5);
/// The longest pause between reruns.
pub const RERUN_MAX_PAUSE: Duration = Duration::from_secs(30);

/// How many times the pane starts again on its own before its card shows the failure (and its Retry).
pub const PANE_RERUNS: u32 = 2;
/// How long into the start the pane still starts again on its own: past it the card shows the failure.
pub const PANE_BUDGET: Duration = Duration::from_secs(120);

/// The codes the pane gives a start that failed on its way with no reason of its own (`CloudStartChat`'s catch-all):
/// none, or `cloud_start_failed`.
const PANE_GENERIC: &[&str] = &["", "cloud_start_failed"];

/// A pane start's failure, as `CloudStartChat.reply` read it, and how far its recovery went.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneFailure {
    /// The failure's code (`CloudMove.Failure.code`, the CLI answer's), or empty for none.
    #[serde(default)]
    pub code: String,
    /// Its words, which name the app's `unavailable`.
    #[serde(default)]
    pub message: String,
    /// The card would offer Retry: the same send under the same key, on the machine it was on (`retry`) or again
    /// (`sendAgain`).
    pub retryable: bool,
    /// How many times the pane already started again on its own for this send.
    pub reruns: u32,
    /// Milliseconds since the send's first try began.
    pub elapsed_ms: u64,
}

/// What the pane does with a failed start: start again on its own after `pause_ms`, or show the card.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "next", rename_all = "camelCase")]
pub enum PaneStep {
    /// Pause `pause_ms`, then do what the card's Retry does (the same send, the same key), before the card shows.
    #[serde(rename_all = "camelCase")]
    Rerun {
        pause_ms: u64,
        /// The table's class it ran for (its [`Class`] name), or `None` for a start that failed on its way with
        /// no reason of its own, whose Retry the card would offer.
        class: Option<String>,
    },
    /// The card shows the failure: a person acts, the table's action is not the pane's, or recovery is used up.
    Surface,
}

/// The pane's step for `failure`, from the same table as the CLI's: a class whose action is a rerun starts again on
/// its own; so does a start that failed on its way with no reason of its own when the card would offer Retry, since
/// that Retry is the same send under the same key. Each within [`PANE_RERUNS`] and [`PANE_BUDGET`], so the loop
/// ends. A class whose action is [`Action::FreshMachine`] or [`Action::MakeRoom`] shows its card: the pane's own
/// cap card asks before freeing a machine, and its fresh machine is not run from here yet.
pub fn pane_step(failure: &PaneFailure) -> PaneStep {
    let class = classify(&failure.code, &failure.message, false);
    let reruns = match class.map(recovery) {
        Some(Some(Action::Rerun | Action::RerunOnMachine)) => true,
        Some(_) => false,
        None => failure.retryable && PANE_GENERIC.contains(&failure.code.as_str()),
    };
    if !reruns || failure.reruns >= PANE_RERUNS {
        return PaneStep::Surface;
    }
    let pause = RERUN_PAUSE.saturating_mul(1 << failure.reruns.min(8)).min(RERUN_MAX_PAUSE);
    let left = PANE_BUDGET.saturating_sub(Duration::from_millis(failure.elapsed_ms));
    if left <= pause {
        return PaneStep::Surface;
    }
    PaneStep::Rerun {
        pause_ms: u64::try_from(pause.as_millis()).unwrap_or(u64::MAX),
        class: class.map(|class| format!("{class:?}")),
    }
}

#[cfg(test)]
mod tests;
