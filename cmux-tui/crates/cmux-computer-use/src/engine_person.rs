//! What the engine asks of the person and their input: the approval question and its answers,
//! the person's own activity, and how long an acting call waits and settles.

use super::*;

/// A question for the person.
#[derive(Clone, Debug, PartialEq)]
pub struct Question {
    pub session: String,
    pub agent: String,
    pub app: TargetApp,
    /// Offer "Always allow" and "Never" (Approved apps mode).
    pub remember: bool,
    /// Set when the agent runs on another machine.
    pub from_machine: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Answer {
    AllowOnce,
    AllowSession,
    AlwaysAllow,
    Deny,
    Never,
    /// No way to ask here, or nobody answered in time.
    Unavailable,
}

/// Asks the person (an approval panel on the machine). Blocks.
pub trait Approver: Send + Sync {
    fn ask(&self, question: &Question) -> Answer;
}

pub struct NoApprover;

impl Approver for NoApprover {
    fn ask(&self, _question: &Question) -> Answer {
        Answer::Unavailable
    }
}

/// The person's own use of the mouse and keyboard.
pub trait PersonActivity: Send + Sync {
    /// Waits until the person has been idle (or `limit` passes); true when idle.
    fn wait_idle(&self, limit: Duration) -> bool;
    /// How many deliberate inputs (keys, clicks, scrolls, drags) the person
    /// has made so far, counted by a detector that tells theirs from ours;
    /// `None` when nothing watches. The focus guard compares two readings to
    /// know whether the person moved focus during a call.
    fn input_count(&self) -> Option<u64> {
        None
    }
    /// While input_count counts the person's keys too: an epoch that rises
    /// whenever their keys may have gone uncounted (Secure Event Input, a
    /// blind detector, dictation). `None` while the count does not cover keys
    /// (macOS: no Input Monitoring). Two equal readings mean every key of the
    /// person was counted between them.
    fn keys_epoch(&self) -> Option<u64> {
        None
    }
}

pub struct NoTakeover;

impl PersonActivity for NoTakeover {
    fn wait_idle(&self, _limit: Duration) -> bool {
        true
    }
}

/// How long an acting call waits for the person to stop.
pub const TAKEOVER_WAIT: Duration = Duration::from_secs(15);

/// How an acting call waits before it reports the window's new state: a
/// `floor` first (most apps redraw within it; the app's accessibility signal
/// ends it early, and a watched app that signals nothing and shows nothing
/// new after it gets no more screenshots), then a screenshot every
/// `step` until the pixels differ from what the agent last saw, never past
/// `ceiling`. A fixed delay with change detection, not "until quiet": an app
/// that keeps animating never holds the reply past the ceiling.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Settle {
    pub floor: Duration,
    pub step: Duration,
    pub ceiling: Duration,
}

impl Default for Settle {
    fn default() -> Self {
        Self {
            floor: Duration::from_millis(120),
            step: Duration::from_millis(100),
            ceiling: Duration::from_millis(1000),
        }
    }
}

/// Anthropic's computer-use reference tool (`BaseComputerTool`): the fixed
/// wait before the screenshot after an action, and typing in groups of
/// [`ANTHROPIC_TYPING_GROUP`] characters at [`ANTHROPIC_TYPING_DELAY`] per key.
pub const ANTHROPIC_SCREENSHOT_DELAY: Duration = Duration::from_millis(2000);
pub const ANTHROPIC_TYPING_DELAY: Duration = Duration::from_millis(12);
pub const ANTHROPIC_TYPING_GROUP: usize = 50;
/// Anthropic's double and triple clicks (`--repeat N --delay 10`).
pub const ANTHROPIC_CLICK_GAP: Duration = Duration::from_millis(10);
/// The `wait` tool: OpenAI's handlers wait 2000 ms; Anthropic's `wait` takes
/// a duration of at most 100 s.
pub const WAIT_DEFAULT: Duration = Duration::from_millis(2000);
pub const WAIT_MAX: Duration = Duration::from_secs(100);
/// The most actions one `batch` runs.
pub const BATCH_MAX: usize = 20;
/// The longest one `batch` runs: its waits and `wait_for` timeouts together
/// are refused past it before anything runs, and no step starts after it.
pub const BATCH_TIME_MAX: Duration = Duration::from_secs(120);
