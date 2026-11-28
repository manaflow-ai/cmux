//! Program status protocol (OSC 7501) reports from libghostty-vt
//! (`GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS`, ported from ghostty-org/ghostty
//! #14560 into manaflow-ai/ghostty-next).
//!
//! libghostty parses and validates every report (keys, base64 text, ids,
//! limits) and keeps no records. The owner of the terminal keeps one record
//! per id; it also needs primary prompt starts in stream order, because the
//! specification removes `working` and `blocked` records at a new prompt.
//! Both arrive through one callback so their order is the stream order.

use std::ffi::c_void;

use super::{Callbacks, sys};

/// What a program says it is doing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProgramStatusState {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
    /// Removes the record with the report's id and every record beneath it;
    /// an empty id removes every record. A full reset (RIS) reports this
    /// with an empty id.
    Clear,
}

impl ProgramStatusState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Working => "working",
            Self::Done => "done",
            Self::Blocked => "blocked",
            Self::Error => "error",
            Self::Clear => "clear",
        }
    }
}

/// What a blocked program needs from the user.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProgramStatusKind {
    Permission,
    Question,
    Auth,
}

impl ProgramStatusKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Permission => "permission",
            Self::Question => "question",
            Self::Auth => "auth",
        }
    }
}

/// One validated report, copied out of the callback. Text the program did
/// not send is empty. `title` and `message` are decoded and free of control
/// characters but still untrusted program text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProgramStatusReport {
    pub state: ProgramStatusState,
    /// Only with `Blocked`.
    pub kind: Option<ProgramStatusKind>,
    /// 0 through 100, only with `Working` or `Blocked`.
    pub progress: Option<u8>,
    /// Empty for the root record; `/` separates hierarchy levels.
    pub id: String,
    pub app: String,
    pub title: String,
    pub message: String,
}

/// An event for the owner of the program status records, in stream order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProgramStatusEvent {
    Report(ProgramStatusReport),
    /// A primary shell prompt started (OSC 133;A).
    PromptStart,
}

/// Callback for program status events. It runs inside `vt_write` and must
/// not touch the terminal.
pub type ProgramStatusFn = Box<dyn FnMut(ProgramStatusEvent) + Send>;

fn owned(text: &sys::GhosttyString) -> String {
    if text.len == 0 || text.ptr.is_null() {
        return String::new();
    }
    let bytes = unsafe { std::slice::from_raw_parts(text.ptr, text.len) };
    String::from_utf8_lossy(bytes).into_owned()
}

fn deliver(userdata: *mut c_void, event: ProgramStatusEvent) {
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_program_status.as_mut() {
        f(event);
    }
}

pub(super) unsafe extern "C" fn program_status_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
    report: *const sys::GhosttyTerminalProgramStatus,
) {
    let report = unsafe { &*report };
    // Every field below has existed since the struct was introduced.
    if report.size < size_of::<sys::GhosttyTerminalProgramStatus>() {
        return;
    }
    let state = match report.state {
        sys::GHOSTTY_PROGRAM_STATUS_STATE_IDLE => ProgramStatusState::Idle,
        sys::GHOSTTY_PROGRAM_STATUS_STATE_WORKING => ProgramStatusState::Working,
        sys::GHOSTTY_PROGRAM_STATUS_STATE_DONE => ProgramStatusState::Done,
        sys::GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED => ProgramStatusState::Blocked,
        sys::GHOSTTY_PROGRAM_STATUS_STATE_ERROR => ProgramStatusState::Error,
        sys::GHOSTTY_PROGRAM_STATUS_STATE_CLEAR => ProgramStatusState::Clear,
        // A state this build does not know is not a report it can keep.
        _ => return,
    };
    let kind = match report.kind {
        sys::GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION => Some(ProgramStatusKind::Permission),
        sys::GHOSTTY_PROGRAM_STATUS_KIND_QUESTION => Some(ProgramStatusKind::Question),
        sys::GHOSTTY_PROGRAM_STATUS_KIND_AUTH => Some(ProgramStatusKind::Auth),
        _ => None,
    };
    let progress = u8::try_from(report.progress).ok().filter(|value| *value <= 100);
    deliver(
        userdata,
        ProgramStatusEvent::Report(ProgramStatusReport {
            state,
            kind,
            progress,
            id: owned(&report.id),
            app: owned(&report.app),
            title: owned(&report.title),
            message: owned(&report.message),
        }),
    );
}

pub(super) unsafe extern "C" fn semantic_prompt_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
    event: *const sys::GhosttyTerminalSemanticPrompt,
) {
    let event = unsafe { &*event };
    if event.kind == sys::GHOSTTY_SEMANTIC_PROMPT_PROMPT_START
        && event.prompt_kind == sys::GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY
    {
        deliver(userdata, ProgramStatusEvent::PromptStart);
    }
}
