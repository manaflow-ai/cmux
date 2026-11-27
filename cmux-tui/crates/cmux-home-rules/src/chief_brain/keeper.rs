//! `ChiefBrainKeeper`: when the app starts its Chief's brain, and what it does with the
//! pid a start returns. Swift reads the lock, the shutdown marker and `canStart`, and runs
//! the effects in order.

use serde::{Deserialize, Serialize};

/// `HomeChiefName.muxID`: the Chief's own participant id.
pub const MUX_ID: &str = "agent_mux";

/// What the keeper knows at an `ensure`.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct KeeperView {
    /// `HomeBrainHost.canStart()`.
    pub can_start: bool,
    /// `home.shutdownMarker` exists.
    pub shutdown_marker: bool,
    /// A start is in flight (`starting`).
    pub starting: bool,
    /// The keeper has a watch.
    pub has_watch: bool,
    /// `watch.isStopped`.
    pub watch_stopped: bool,
    /// `watch.isWatching`.
    pub watch_watching: bool,
    /// `ChiefHostStop.runningHostPID(home:)` (read only when the answer needs it).
    pub running_pid: Option<i32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Answer {
    Yes,
    No,
    /// `ensure` started a start: answer whether `starting` is now set (a start
    /// without a daemon connection does not begin).
    IfStarted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum KeeperEffect {
    RemoveShutdownMarker,
    /// `watch.watch(pid)`.
    #[serde(rename_all = "camelCase")]
    Watch {
        pid: i32,
    },
    /// `watch?.stop(); watch = nil`.
    DropWatch,
    /// `start()`.
    Start,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnsureReply {
    pub answer: Answer,
    pub effects: Vec<KeeperEffect>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnsureRequest {
    #[serde(default)]
    pub asked: bool,
    #[serde(default)]
    pub keeper: KeeperView,
}

/// `ensure(asked:)`.
pub fn ensure(asked: bool, k: &KeeperView) -> EnsureReply {
    let no = || EnsureReply { answer: Answer::No, effects: Vec::new() };
    if (k.has_watch && k.watch_stopped) || !k.can_start {
        return no();
    }
    let mut effects = Vec::new();
    if k.shutdown_marker {
        if !asked {
            return no();
        }
        effects.push(KeeperEffect::RemoveShutdownMarker);
    }
    if k.starting || (k.has_watch && k.watch_watching) {
        return EnsureReply { answer: Answer::Yes, effects };
    }
    if k.has_watch
        && let Some(pid) = k.running_pid
    {
        effects.push(KeeperEffect::Watch { pid });
        return EnsureReply { answer: Answer::Yes, effects };
    }
    if k.has_watch {
        effects.push(KeeperEffect::DropWatch);
    }
    effects.push(KeeperEffect::Start);
    EnsureReply { answer: Answer::IfStarted, effects }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeeperRequest {
    #[serde(default)]
    pub keeper: KeeperView,
}

/// `ensureForChat()`.
pub fn ensure_for_chat(k: &KeeperView) -> EnsureReply {
    if k.starting {
        return EnsureReply { answer: Answer::Yes, effects: Vec::new() };
    }
    if k.has_watch && !k.watch_watching {
        return EnsureReply { answer: Answer::No, effects: Vec::new() };
    }
    ensure(false, k)
}

/// `isRunning`.
pub fn is_running(k: &KeeperView) -> bool {
    k.starting || (k.has_watch && k.watch_watching) || k.running_pid.is_some()
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Participant {
    pub id: String,
    /// `ParticipantKind` raw value (`human`, `agent`, ...).
    #[serde(default)]
    pub kind: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AskRequest {
    /// The new message's author.
    pub author: String,
    /// The conversation's participants (None: no summary).
    pub participants: Option<Vec<Participant>>,
    #[serde(default)]
    pub keeper: KeeperView,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AskReply {
    /// The message asks the Chief: `ensure(asked: true)` runs.
    pub asks: bool,
    /// That `ensure`'s reply, when it runs.
    pub ensure: Option<EnsureReply>,
}

/// `ask(after:in:)`: a person's message in a chat with the Chief.
pub fn asks(author: &str, participants: Option<&[Participant]>) -> bool {
    let Some(participants) = participants else {
        return false;
    };
    author != MUX_ID
        && participants.iter().any(|p| p.id == MUX_ID)
        && participants
            .iter()
            .find(|p| p.id == author)
            .is_some_and(|p| p.kind.as_deref() == Some("human"))
}

pub fn ask(r: &AskRequest) -> AskReply {
    let asks = asks(&r.author, r.participants.as_deref());
    AskReply { asks, ensure: asks.then(|| ensure(true, &r.keeper)) }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AfterStartRequest {
    /// The started pid.
    pub pid: Option<i32>,
    #[serde(default)]
    pub has_watch: bool,
    #[serde(default)]
    pub watch_stopped: bool,
    /// `pid` runs an `optchat-chief` or the "cmux Files (dev)" launcher.
    #[serde(default)]
    pub pid_is_host: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum AfterStart {
    /// Quit came first: `kill(pid, SIGTERM)` a host this start launched.
    #[serde(rename_all = "camelCase")]
    Terminate { pid: i32 },
    /// Quit came first and the pid is no host: nothing.
    Nothing,
    /// `watch.watch(pid)` on the keeper's watch.
    #[serde(rename_all = "camelCase")]
    Watch { pid: Option<i32> },
    /// Make the watch (restart: launch again; watching: `hostChanged`), then `watch(pid)`.
    #[serde(rename_all = "camelCase")]
    CreateWatch { pid: Option<i32> },
}

/// `watchHost(_:pid:)`.
pub fn after_start(r: &AfterStartRequest) -> AfterStart {
    if r.has_watch && r.watch_stopped {
        return match r.pid {
            Some(pid) if r.pid_is_host => AfterStart::Terminate { pid },
            _ => AfterStart::Nothing,
        };
    }
    if r.has_watch {
        AfterStart::Watch { pid: r.pid }
    } else {
        AfterStart::CreateWatch { pid: r.pid }
    }
}
