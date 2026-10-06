//! Bounded, generic terminal metadata collected from PTY output.
//!
//! The OSC string framing state machine is adapted from herdrdev/herdr's
//! `src/pane/osc.rs`, Apache-2.0, commit
//! `7b675f42af35508eab66ac42fe1598628597a893`. The cmux implementation is
//! modified by manaflow: it retains OSC 9 progress text and desktop
//! notifications (OSC 9, OSC 777 `notify`, kitty OSC 99, classified as
//! Ghostty's `osc9.zig`, `rxvt_extension.zig` and `kitty_notification.zig`
//! do), applies strict byte and character bounds, accepts C1 ST, and exposes
//! the result as a terminal primitive. It has no agent names, manifests, or
//! roster policy.

use base64::Engine;
use std::time::{Duration, Instant};

const MAX_OSC_BODY_BYTES: usize = 4096;
pub(crate) const MAX_PROGRESS_CHARS: usize = 256;
/// Shown text bounds for a terminal notification.
pub(crate) const MAX_NOTIFICATION_TITLE_CHARS: usize = 256;
pub(crate) const MAX_NOTIFICATION_BODY_CHARS: usize = 1024;
/// Notifications waiting for the owner to take them. A reader that never
/// drains the queue (a terminal host) keeps only the newest ones.
pub(crate) const MAX_PENDING_NOTIFICATIONS: usize = 8;
/// Kitty accumulates chunked title and body text per notification; Ghostty
/// bounds each buffer at `Parser.MAX_BUF`.
const MAX_KITTY_PENDING_BYTES: usize = 2048;
/// Ghostty's `showDesktopNotification` limits: one per second, and the same
/// text at most once per five seconds.
const NOTIFICATION_MIN_SPACING: Duration = Duration::from_secs(1);
const NOTIFICATION_REPEAT_SPACING: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
enum OscState {
    #[default]
    Ground,
    Escape,
    Body,
    BodyEscape,
    IgnoringString,
    IgnoringStringEscape,
    Discarding,
    DiscardingEscape,
}

#[derive(Debug, Default)]
struct OscCollector {
    state: OscState,
    body: Vec<u8>,
    /// Number of UTF-8 continuation bytes still expected after a lead byte.
    /// Raw C1 values share this byte range, so framing is recognized only at
    /// code-point boundaries. The first continuation also has a lead-specific
    /// range, which rejects overlong encodings and surrogate encodings before
    /// they can hide a C1 framing byte.
    utf8_continuations: u8,
    utf8_min: u8,
    utf8_max: u8,
}

impl OscCollector {
    fn observe(&mut self, bytes: &[u8], mut receive: impl FnMut(&[u8])) {
        for &byte in bytes {
            if self.utf8_continuations > 0 {
                if (self.utf8_min..=self.utf8_max).contains(&byte) {
                    self.utf8_continuations -= 1;
                    if self.state == OscState::Body {
                        self.push(byte);
                    }
                    // Only the first continuation is constrained by the
                    // lead byte. Remaining continuation bytes use the full
                    // UTF-8 continuation range.
                    self.utf8_min = 0x80;
                    self.utf8_max = 0xbf;
                    continue;
                }
                // An invalid or truncated UTF-8 sequence cannot hide the
                // next control byte. Process this byte again as framing.
                self.reset_utf8();
            }
            let (continuations, min, max) = utf8_sequence_bounds(byte);
            self.utf8_continuations = continuations;
            self.utf8_min = min;
            self.utf8_max = max;
            match self.state {
                OscState::Ground => match byte {
                    0x1b => self.state = OscState::Escape,
                    // C1 OSC. This is uncommon in UTF-8 PTYs but valid in an
                    // 8-bit control stream.
                    0x9d => {
                        self.body.clear();
                        self.state = OscState::Body;
                    }
                    // C1 DCS, SOS, PM, and APC. Their payloads are ignored
                    // so an embedded OSC cannot leak metadata.
                    0x90 | 0x98 | 0x9e | 0x9f => {
                        self.state = OscState::IgnoringString;
                    }
                    _ => {}
                },
                OscState::Escape => match byte {
                    b']' => {
                        self.body.clear();
                        self.state = OscState::Body;
                    }
                    0x18 | 0x1a => self.state = OscState::Ground,
                    0x1b => self.state = OscState::Escape,
                    b'P' | b'X' | b'^' | b'_' => {
                        // DCS, SOS, PM, and APC are string controls. Ignore
                        // their bodies so embedded OSC bytes cannot leak.
                        self.state = OscState::IgnoringString;
                    }
                    _ => self.state = OscState::Ground,
                },
                OscState::Body => match byte {
                    0x18 | 0x1a => self.cancel(),
                    0x07 | 0x9c => self.finish(&mut receive),
                    0x1b => self.state = OscState::BodyEscape,
                    _ => self.push(byte),
                },
                OscState::BodyEscape => match byte {
                    0x18 | 0x1a => self.cancel(),
                    b'\\' => self.finish(&mut receive),
                    0x07 | 0x9c => self.finish(&mut receive),
                    0x1b => {
                        // A second ESC remains a possible ST prefix. Keep
                        // one literal ESC in the bounded body and wait.
                        self.push(0x1b);
                        if self.state == OscState::Body {
                            self.state = OscState::BodyEscape;
                        }
                    }
                    _ => {
                        // The ESC was not an ST prefix. Preserve it and the
                        // current byte as payload, unless the body overflowed.
                        self.push(0x1b);
                        if self.state == OscState::Body {
                            self.push(byte);
                        }
                    }
                },
                OscState::IgnoringString => match byte {
                    0x18 | 0x1a => self.cancel(),
                    0x1b => self.state = OscState::IgnoringStringEscape,
                    0x9c => self.state = OscState::Ground,
                    _ => {}
                },
                OscState::IgnoringStringEscape => match byte {
                    0x18 | 0x1a => self.cancel(),
                    b'\\' | 0x9c => self.state = OscState::Ground,
                    0x1b => self.state = OscState::IgnoringStringEscape,
                    _ => self.state = OscState::IgnoringString,
                },
                OscState::Discarding => match byte {
                    0x18 | 0x1a => self.cancel(),
                    0x07 | 0x9c => self.state = OscState::Ground,
                    0x1b => self.state = OscState::DiscardingEscape,
                    _ => {}
                },
                OscState::DiscardingEscape => match byte {
                    0x18 | 0x1a => self.cancel(),
                    b'\\' | 0x9c => self.state = OscState::Ground,
                    0x1b => self.state = OscState::DiscardingEscape,
                    _ => self.state = OscState::Discarding,
                },
            }
        }
    }

    fn push(&mut self, byte: u8) {
        if self.body.len() >= MAX_OSC_BODY_BYTES {
            self.body.clear();
            self.state = OscState::Discarding;
            return;
        }
        self.body.push(byte);
        self.state = OscState::Body;
    }

    fn finish(&mut self, receive: &mut impl FnMut(&[u8])) {
        receive(&self.body);
        self.body.clear();
        self.state = OscState::Ground;
        self.reset_utf8();
    }

    fn cancel(&mut self) {
        self.body.clear();
        self.state = OscState::Ground;
        self.reset_utf8();
    }

    fn reset_utf8(&mut self) {
        self.utf8_continuations = 0;
        self.utf8_min = 0;
        self.utf8_max = 0;
    }
}

fn utf8_sequence_bounds(byte: u8) -> (u8, u8, u8) {
    match byte {
        0xc2..=0xdf => (1, 0x80, 0xbf),
        0xe0 => (2, 0xa0, 0xbf),
        0xe1..=0xec | 0xee..=0xef => (2, 0x80, 0xbf),
        0xed => (2, 0x80, 0x9f),
        0xf0 => (3, 0x90, 0xbf),
        0xf1..=0xf3 => (3, 0x80, 0xbf),
        0xf4 => (3, 0x80, 0x8f),
        _ => (0, 0, 0),
    }
}

fn utf8_continuation_count(byte: u8) -> u8 {
    utf8_sequence_bounds(byte).0
}

fn is_string_opener(byte: u8) -> bool {
    matches!(byte, 0x90 | 0x98 | 0x9d | 0x9f | 0x9e)
}

/// The state of an OSC 9;4 progress report (ConEmu and Windows Terminal).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ProgressState {
    Normal,
    Error,
    Indeterminate,
    Paused,
}

/// A terminal's OSC 9;4 progress while one is shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TerminalProgress {
    pub(crate) state: ProgressState,
    /// Percent, 0-100; absent for indeterminate progress.
    pub(crate) value: Option<u8>,
}

impl TerminalProgress {
    pub(crate) fn to_json(self) -> serde_json::Value {
        let state = match self.state {
            ProgressState::Normal => "normal",
            ProgressState::Error => "error",
            ProgressState::Indeterminate => "indeterminate",
            ProgressState::Paused => "paused",
        };
        serde_json::json!({"state": state, "value": self.value})
    }
}

/// Parse retained OSC 9 text as `4;state[;percent]`. State 0 removes the
/// progress; any other OSC 9 text (a notification) is not progress.
pub(crate) fn parse_progress(text: &str) -> Option<TerminalProgress> {
    let mut parts = text.strip_prefix("4;")?.split(';');
    let state = parts.next()?.trim();
    let value = parts
        .next()
        .and_then(|value| value.trim().parse::<u16>().ok())
        .map(|value| u8::try_from(value.min(100)).unwrap_or(100));
    let state = match state {
        "1" => ProgressState::Normal,
        "2" => ProgressState::Error,
        "3" => return Some(TerminalProgress { state: ProgressState::Indeterminate, value: None }),
        "4" => ProgressState::Paused,
        _ => return None,
    };
    Some(TerminalProgress { state, value: value.or(Some(0)) })
}

/// A desktop notification a program in the terminal asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalNotification {
    /// Never empty: a notification with only body text shows it as the title,
    /// as Ghostty's kitty parser does.
    pub title: String,
    pub body: String,
}

impl TerminalNotification {
    fn new(title: &[u8], body: &[u8]) -> Option<Self> {
        let mut title = shown_text(title, MAX_NOTIFICATION_TITLE_CHARS);
        let mut body = shown_text(body, MAX_NOTIFICATION_BODY_CHARS);
        if title.is_empty() {
            if body.is_empty() {
                return None;
            }
            title = body.chars().take(MAX_NOTIFICATION_TITLE_CHARS).collect();
            body = String::new();
        }
        Some(Self { title, body })
    }
}

fn shown_text(bytes: &[u8], limit: usize) -> String {
    String::from_utf8_lossy(bytes)
        .chars()
        .filter(|character| !character.is_control())
        .take(limit)
        .collect()
}

/// Kitty OSC 99 text accumulated across `d=0` chunks.
#[derive(Debug, Default)]
struct KittyPending {
    active: bool,
    id: Option<String>,
    title: Vec<u8>,
    body: Vec<u8>,
}

impl KittyPending {
    fn reset(&mut self) {
        self.active = false;
        self.id = None;
        self.title.clear();
        self.body.clear();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KittyPayload {
    Title,
    Body,
}

/// Parse one OSC 99 body (after `99;`), following Ghostty's
/// `kitty_notification.zig`: `meta;payload`, where meta is `:`-separated
/// `key=value` pairs (`p` payload kind, `d` done, `e` base64, `i` id).
fn observe_kitty_notification(
    pending: &mut KittyPending,
    data: &[u8],
) -> Option<TerminalNotification> {
    let separator = data.iter().position(|byte| *byte == b';')?;
    let (meta, payload) = (&data[..separator], &data[separator + 1..]);
    let mut kind = Some(KittyPayload::Title);
    let mut done = true;
    let mut base64 = false;
    let mut id = None;
    for part in meta.split(|byte| *byte == b':') {
        let Some(equals) = part.iter().position(|byte| *byte == b'=') else { continue };
        if equals == 0 {
            continue;
        }
        let value = &part[equals + 1..];
        let flag = |default: bool| match value.first() {
            Some(b'0') => false,
            Some(b'1') => true,
            _ => default,
        };
        match part[0] {
            b'p' => {
                kind = match value {
                    b"title" => Some(KittyPayload::Title),
                    b"body" => Some(KittyPayload::Body),
                    _ => None,
                }
            }
            b'd' => done = flag(true),
            b'e' => base64 = flag(false),
            b'i' => {
                let valid = !value.is_empty()
                    && value.iter().all(|byte| {
                        byte.is_ascii_alphanumeric()
                            || matches!(byte, b'-' | b'_' | b'+' | b'.' | b':')
                    });
                if valid {
                    id = Some(String::from_utf8_lossy(value).into_owned());
                }
            }
            _ => {}
        }
    }
    // close, alive, queries and unknown kinds carry nothing to show.
    let kind = kind?;
    let decoded;
    let payload = if base64 {
        decoded = base64::engine::general_purpose::STANDARD.decode(payload).ok()?;
        decoded.as_slice()
    } else {
        payload
    };
    if std::str::from_utf8(payload).is_err() {
        return None;
    }
    match id {
        Some(id) if pending.active && pending.id.as_deref() == Some(id.as_str()) => {}
        Some(id) => {
            pending.reset();
            pending.active = true;
            pending.id = Some(id);
        }
        None => {
            pending.reset();
            pending.active = true;
        }
    }
    let buffer = match kind {
        KittyPayload::Title => &mut pending.title,
        KittyPayload::Body => &mut pending.body,
    };
    if buffer.len() + payload.len() >= MAX_KITTY_PENDING_BYTES {
        pending.reset();
        return None;
    }
    buffer.extend_from_slice(payload);
    if !done {
        return None;
    }
    let notification = TerminalNotification::new(&pending.title, &pending.body);
    pending.reset();
    notification
}

/// Whether an OSC 9 body (after `9;`) is an iTerm2 desktop notification.
/// Everything Ghostty's `osc9.zig` parses as a ConEmu command is not.
fn osc9_is_notification(data: &[u8]) -> bool {
    let at = |index: usize| data.get(index).copied();
    match at(0) {
        None => true,
        Some(b'1') => match at(1) {
            Some(b';') => false,
            Some(b'0') => match (data.len(), at(2), at(3)) {
                (2, _, _) => false,
                (length, Some(b';'), Some(b'0'..=b'3')) if length >= 4 => false,
                _ => true,
            },
            Some(b'1') => at(2) != Some(b';'),
            Some(b'2') => false,
            _ => true,
        },
        Some(b'2' | b'3' | b'6' | b'7' | b'8' | b'9') => at(1) != Some(b';'),
        Some(b'4') => !(at(1) == Some(b';') && matches!(at(2), Some(b'0'..=b'4'))),
        Some(b'5') => false,
        Some(_) => true,
    }
}

/// Ghostty's desktop notification limits, per terminal. Computed on arrival:
/// no timer runs for it.
#[derive(Debug, Default)]
pub(crate) struct NotificationGate {
    last: Option<(Instant, u64)>,
}

impl NotificationGate {
    /// Whether `notification` may be shown at `now`; records it when it may.
    pub(crate) fn admit(&mut self, notification: &TerminalNotification, now: Instant) -> bool {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        notification.title.hash(&mut hasher);
        notification.body.hash(&mut hasher);
        let digest = hasher.finish();
        if let Some((last, last_digest)) = self.last {
            let elapsed = now.saturating_duration_since(last);
            if elapsed < NOTIFICATION_MIN_SPACING
                || (last_digest == digest && elapsed < NOTIFICATION_REPEAT_SPACING)
            {
                return false;
            }
        }
        self.last = Some((now, digest));
        true
    }
}

/// Generic terminal metadata retained from the output stream.
#[derive(Debug, Default)]
pub(crate) struct TerminalMetadata {
    osc: OscCollector,
    progress: String,
    /// The parsed progress last handed to the public graph.
    published_progress: Option<TerminalProgress>,
    kitty: KittyPending,
    notifications: Vec<TerminalNotification>,
    gate: NotificationGate,
    /// OSC 133 prompt marks since the last take (shell command history).
    shell_marks: Vec<crate::shell_history::ShellMark>,
}

impl TerminalMetadata {
    /// Observe raw child output. The fast path avoids the state machine for
    /// ordinary output, which is the common case for non-OSC terminals.
    pub(crate) fn observe_output(&mut self, bytes: &[u8]) {
        // A framed string can cross reader chunks. Continue feeding bytes
        // while the collector is inside a control sequence, even when this
        // chunk contains no new ESC or C1 introducer.
        if self.osc.state == OscState::Ground
            && self.osc.utf8_continuations == 0
            && !bytes.iter().any(|byte| {
                *byte == 0x1b || is_string_opener(*byte) || utf8_continuation_count(*byte) != 0
            })
        {
            return;
        }
        let progress = &mut self.progress;
        let kitty = &mut self.kitty;
        let notifications = &mut self.notifications;
        let shell_marks = &mut self.shell_marks;
        self.osc.observe(bytes, |body| {
            let Some(separator) = body.iter().position(|byte| *byte == b';') else {
                return;
            };
            let data = &body[separator + 1..];
            let notification = match &body[..separator] {
                b"9" => {
                    *progress = String::from_utf8_lossy(data)
                        .chars()
                        .filter(|character| !character.is_control())
                        .take(MAX_PROGRESS_CHARS)
                        .collect();
                    osc9_is_notification(data)
                        .then(|| TerminalNotification::new(b"", data))
                        .flatten()
                }
                b"777" => {
                    let Some(rest) = data.strip_prefix(b"notify;") else { return };
                    let Some(title_end) = rest.iter().position(|byte| *byte == b';') else {
                        return;
                    };
                    TerminalNotification::new(&rest[..title_end], &rest[title_end + 1..])
                }
                b"99" => observe_kitty_notification(kitty, data),
                b"133" => {
                    if let Some(mark) = crate::shell_history::ShellMark::parse(data) {
                        if shell_marks.len() == crate::shell_history::MAX_PENDING_MARKS {
                            shell_marks.remove(0);
                        }
                        shell_marks.push(mark);
                    }
                    None
                }
                _ => None,
            };
            if let Some(notification) = notification {
                if notifications.len() == MAX_PENDING_NOTIFICATIONS {
                    notifications.remove(0);
                }
                notifications.push(notification);
            }
        });
    }

    /// OSC 133 marks parsed since the last call, oldest first.
    pub(crate) fn take_shell_marks(&mut self) -> Vec<crate::shell_history::ShellMark> {
        std::mem::take(&mut self.shell_marks)
    }

    /// Desktop notifications parsed since the last call, oldest first.
    pub(crate) fn take_notifications(&mut self) -> Vec<TerminalNotification> {
        std::mem::take(&mut self.notifications)
    }

    /// `take_notifications` filtered by this terminal's rate limit.
    pub(crate) fn take_admitted_notifications(
        &mut self,
        now: Instant,
    ) -> Vec<TerminalNotification> {
        if self.notifications.is_empty() {
            return Vec::new();
        }
        let mut taken = self.take_notifications();
        taken.retain(|notification| self.gate.admit(notification, now));
        taken
    }

    pub(crate) fn osc_progress(&self) -> &str {
        &self.progress
    }

    /// The parsed OSC 9;4 progress, when the retained text is one.
    pub(crate) fn progress(&self) -> Option<TerminalProgress> {
        parse_progress(&self.progress)
    }

    /// The parsed progress when it differs from the last one taken, marking
    /// it taken. `Some(None)` reports a removed progress.
    pub(crate) fn take_progress_change(&mut self) -> Option<Option<TerminalProgress>> {
        let current = self.progress();
        (current != self.published_progress).then(|| {
            self.published_progress = current;
            current
        })
    }

    /// Restore a progress value carried by an authenticated terminal-host
    /// snapshot. Reject malformed values instead of silently changing the
    /// host's state at a reconnect boundary.
    pub(crate) fn set_osc_progress(&mut self, progress: &str) -> bool {
        if progress.chars().count() > MAX_PROGRESS_CHARS || progress.chars().any(char::is_control) {
            return false;
        }
        self.progress.clear();
        self.progress.push_str(progress);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn osc_9_4_progress_parses_states_and_reports_each_change_once() {
        assert_eq!(
            parse_progress("4;1;42"),
            Some(TerminalProgress { state: ProgressState::Normal, value: Some(42) })
        );
        assert_eq!(
            parse_progress("4;2;250"),
            Some(TerminalProgress { state: ProgressState::Error, value: Some(100) })
        );
        assert_eq!(
            parse_progress("4;3"),
            Some(TerminalProgress { state: ProgressState::Indeterminate, value: None })
        );
        assert_eq!(parse_progress("4;0;0"), None);
        assert_eq!(parse_progress("hello from a notification"), None);

        let mut metadata = TerminalMetadata::default();
        assert_eq!(metadata.take_progress_change(), None);
        metadata.observe_output(b"\x1b]9;4;1;10\x07");
        assert_eq!(
            metadata.take_progress_change(),
            Some(Some(TerminalProgress { state: ProgressState::Normal, value: Some(10) }))
        );
        assert_eq!(metadata.take_progress_change(), None);
        metadata.observe_output(b"\x1b]9;4;0\x1b\\");
        assert_eq!(metadata.take_progress_change(), Some(None));
    }

    #[test]
    fn shell_history_osc_133_marks_cross_chunks_and_stay_bounded() {
        use crate::shell_history::{MAX_PENDING_MARKS, ShellMark};
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"prompt \x1b]133;B\x07ls\r\n\x1b]13");
        metadata.observe_output(b"3;C\x1b\\output\x1b]133;D;1\x07");
        assert_eq!(
            metadata.take_shell_marks(),
            vec![
                ShellMark::InputStart,
                ShellMark::CommandStart,
                ShellMark::CommandEnd { exit_code: Some(1) }
            ]
        );
        assert!(metadata.take_shell_marks().is_empty());
        for _ in 0..(MAX_PENDING_MARKS + 5) {
            metadata.observe_output(b"\x1b]133;A\x07");
        }
        assert_eq!(metadata.take_shell_marks().len(), MAX_PENDING_MARKS);
    }

    #[test]
    fn captures_bel_st_and_c1_osc_progress() {
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"\x1b]9;4;3;\x07");
        assert_eq!(metadata.osc_progress(), "4;3;");
        metadata.observe_output(b"\x1b]9;4;1;50\x1b\\");
        assert_eq!(metadata.osc_progress(), "4;1;50");
        metadata.observe_output(b"\x9d9;4;2;\x9c");
        assert_eq!(metadata.osc_progress(), "4;2;");
    }

    #[test]
    fn preserves_chunk_boundaries_and_ignores_other_strings() {
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"\x1b]9;4");
        metadata.observe_output(b";2;");
        metadata.observe_output(b"\x07");
        assert_eq!(metadata.osc_progress(), "4;2;");
        metadata.observe_output(b"\x1b]0;title\x07\x1bP+q9;bad\x1b\\");
        assert_eq!(metadata.osc_progress(), "4;2;");
    }

    #[test]
    fn preserves_non_st_escape_bytes_inside_an_osc_payload() {
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"\x1b]9;before\x1bXafter\x07");
        // The ESC is a control character and is removed from the exposed
        // text, but the following byte and the remainder of the payload must
        // survive the framing state transition.
        assert_eq!(metadata.osc_progress(), "beforeXafter");
    }

    #[test]
    fn utf8_continuation_bytes_are_not_c1_framing() {
        let mut metadata = TerminalMetadata::default();
        // U+00DD is encoded as C3 9D. The continuation byte is numerically
        // equal to C1 OSC, but it is ordinary text in this stream.
        metadata.observe_output("Ý".as_bytes());
        let mut first = b"\x1b]9;before".to_vec();
        first.extend_from_slice("Ýafter\x07".as_bytes());
        metadata.observe_output(&first);
        assert_eq!(metadata.osc_progress(), "beforeÝafter");

        // U+00DC is encoded as C3 9C. It must not terminate an OSC payload.
        let mut second = b"\x1b]9;left".to_vec();
        second.extend_from_slice("Üright\x07".as_bytes());
        metadata.observe_output(&second);
        assert_eq!(metadata.osc_progress(), "leftÜright");
    }

    #[test]
    fn invalid_utf8_does_not_swallow_a_c1_string_terminator() {
        let mut metadata = TerminalMetadata::default();
        // E0 must be followed by A0..BF as its first UTF-8 continuation.
        // 9C is therefore a raw C1 ST here and must close the OSC body.
        let mut bytes = vec![0x9d, b'9', b';'];
        bytes.extend_from_slice(b"old");
        bytes.extend_from_slice(&[0xe0, 0x9c]);
        metadata.observe_output(&bytes);
        metadata.observe_output(b"\x1b]9;new\x07");
        assert_eq!(metadata.osc_progress(), "new");
    }

    #[test]
    fn c1_string_openers_are_isolated_from_osc() {
        let mut metadata = TerminalMetadata::default();
        for opener in [0x90, 0x98, 0x9e, 0x9f] {
            let mut bytes = vec![opener];
            bytes.extend_from_slice(b"payload \x9d9;leaked\x9c");
            metadata.observe_output(&bytes);
        }
        assert_eq!(metadata.osc_progress(), "");
        metadata.observe_output(b"\x1b]9;valid\x07");
        assert_eq!(metadata.osc_progress(), "valid");
    }

    #[test]
    fn can_and_sub_cancel_all_string_states() {
        let mut metadata = TerminalMetadata::default();
        for cancel in [0x18, 0x1a] {
            metadata.observe_output(&[0x1b, b']', b'9', b';', b'b', b'a', cancel]);
            metadata.observe_output(b"\x1b]9;valid\x07");
            assert_eq!(metadata.osc_progress(), "valid");

            metadata.observe_output(&[0x90, b'\x9d', cancel]);
            metadata.observe_output(b"\x1b]9;valid-again\x07");
            assert_eq!(metadata.osc_progress(), "valid-again");
        }
    }

    #[test]
    fn discards_oversized_bodies_and_bounds_text() {
        let mut metadata = TerminalMetadata::default();
        let mut body = b"\x1b]9;".to_vec();
        body.extend(std::iter::repeat_n(b'x', MAX_OSC_BODY_BYTES + 1));
        body.push(0x07);
        metadata.observe_output(&body);
        assert_eq!(metadata.osc_progress(), "");

        let mut bounded = b"\x1b]9;".to_vec();
        bounded.extend(std::iter::repeat_n(b'x', MAX_PROGRESS_CHARS + 32));
        bounded.push(0x07);
        metadata.observe_output(&bounded);
        assert_eq!(metadata.osc_progress().chars().count(), MAX_PROGRESS_CHARS);
    }

    fn notes(metadata: &mut TerminalMetadata) -> Vec<(String, String)> {
        metadata.take_notifications().into_iter().map(|note| (note.title, note.body)).collect()
    }

    #[test]
    fn cmux_next_terminal_notification_osc9_text_is_a_notification() {
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"\x1b]9;Build finished\x07");
        assert_eq!(notes(&mut metadata), vec![("Build finished".into(), String::new())]);
        // The ST terminator, a chunk boundary and C1 OSC frame the same text.
        metadata.observe_output(b"\x1b]9;two");
        metadata.observe_output(b" parts\x1b\\");
        metadata.observe_output(b"\x9d9;c1\x9c");
        assert_eq!(
            notes(&mut metadata),
            vec![("two parts".into(), String::new()), ("c1".into(), String::new())]
        );
        // Taking drains the queue.
        assert!(notes(&mut metadata).is_empty());
    }

    #[test]
    fn cmux_next_terminal_notification_osc9_conemu_forms_are_not_notifications() {
        // Ghostty's osc9.zig treats these as ConEmu commands, not iTerm2
        // desktop notifications.
        let mut metadata = TerminalMetadata::default();
        for body in [
            "9;1;100",
            "9;10",
            "9;10;1",
            "9;11;comment",
            "9;12",
            "9;2;box",
            "9;3;",
            "9;3;tab",
            "9;4;0",
            "9;4;1;50",
            "9;4;2",
            "9;4;3",
            "9;4;4;10",
            "9;5",
            "9;5 minutes",
            "9;6;macro",
            "9;7;run",
            "9;8;VAR",
            "9;9;/tmp",
        ] {
            metadata.observe_output(format!("\x1b]{body}\x07").as_bytes());
            assert!(notes(&mut metadata).is_empty(), "{body} must not notify");
        }
        // Near misses fall through to a notification, as in Ghostty.
        for (body, text) in [
            ("9;1", "1"),
            ("9;10;7", "10;7"),
            ("9;11", "11"),
            ("9;2", "2"),
            ("9;4", "4"),
            ("9;4;9", "4;9"),
            ("9;6", "6"),
            ("9;done", "done"),
        ] {
            metadata.observe_output(format!("\x1b]{body}\x07").as_bytes());
            assert_eq!(notes(&mut metadata), vec![(text.to_string(), String::new())], "{body}");
        }
        // An empty OSC 9 has nothing to show.
        metadata.observe_output(b"\x1b]9;\x07");
        assert!(notes(&mut metadata).is_empty());
    }

    #[test]
    fn cmux_next_terminal_notification_osc777_notify_has_title_and_body() {
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"\x1b]777;notify;Title;Body; with semicolon\x07");
        assert_eq!(notes(&mut metadata), vec![("Title".into(), "Body; with semicolon".into())]);
        // Missing title separator, other extensions and empty text are ignored.
        metadata.observe_output(b"\x1b]777;notify;only\x07");
        metadata.observe_output(b"\x1b]777;other;a;b\x07");
        metadata.observe_output(b"\x1b]777;notify;;\x07");
        assert!(notes(&mut metadata).is_empty());
        // An empty title shows the body as the title.
        metadata.observe_output(b"\x1b]777;notify;;body only\x07");
        assert_eq!(notes(&mut metadata), vec![("body only".into(), String::new())]);
    }

    #[test]
    fn cmux_next_terminal_notification_osc99_kitty_chunks_and_base64() {
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"\x1b]99;;Hello\x1b\\");
        assert_eq!(notes(&mut metadata), vec![("Hello".into(), String::new())]);

        // Chunks with one id accumulate until d=1 (the default).
        metadata.observe_output(b"\x1b]99;i=job:d=0;Deploy\x1b\\");
        assert!(notes(&mut metadata).is_empty());
        metadata.observe_output(b"\x1b]99;i=job:d=0:p=body;done in \x1b\\");
        metadata.observe_output(b"\x1b]99;i=job:p=body;3s\x1b\\");
        assert_eq!(notes(&mut metadata), vec![("Deploy".into(), "done in 3s".into())]);

        // Base64 payloads (e=1) decode; "SGk=" is "Hi".
        metadata.observe_output(b"\x1b]99;e=1;SGk=\x1b\\");
        assert_eq!(notes(&mut metadata), vec![("Hi".into(), String::new())]);

        // Body only becomes the title; close/alive/unknown payloads are ignored.
        metadata.observe_output(b"\x1b]99;p=body;just body\x1b\\");
        assert_eq!(notes(&mut metadata), vec![("just body".into(), String::new())]);
        metadata.observe_output(b"\x1b]99;p=close;x\x1b\\\x1b]99;p=alive;x\x1b\\");
        metadata.observe_output(b"\x1b]99;p=?;x\x1b\\\x1b]99;no-separator\x1b\\");
        assert!(notes(&mut metadata).is_empty());

        // A new id drops an unfinished notification with another id.
        metadata.observe_output(b"\x1b]99;i=a:d=0;lost\x1b\\");
        metadata.observe_output(b"\x1b]99;i=b;kept\x1b\\");
        assert_eq!(notes(&mut metadata), vec![("kept".into(), String::new())]);

        // Invalid base64 is dropped.
        metadata.observe_output(b"\x1b]99;e=1;***\x1b\\");
        assert!(notes(&mut metadata).is_empty());
    }

    #[test]
    fn cmux_next_terminal_notification_text_is_bounded_and_queue_is_capped() {
        let mut metadata = TerminalMetadata::default();
        let mut long = b"\x1b]777;notify;".to_vec();
        long.extend(std::iter::repeat_n(b't', MAX_NOTIFICATION_TITLE_CHARS + 10));
        long.push(b';');
        long.extend(std::iter::repeat_n(b'b', MAX_NOTIFICATION_BODY_CHARS + 10));
        long.push(0x07);
        metadata.observe_output(&long);
        let taken = notes(&mut metadata);
        assert_eq!(taken[0].0.chars().count(), MAX_NOTIFICATION_TITLE_CHARS);
        assert_eq!(taken[0].1.chars().count(), MAX_NOTIFICATION_BODY_CHARS);

        // Control characters are removed from the shown text.
        metadata.observe_output(b"\x1b]777;notify;a\tb;c\x1bXd\x07");
        assert_eq!(notes(&mut metadata), vec![("ab".into(), "cXd".into())]);

        // A reader that never drains (a terminal host) keeps a bounded queue.
        for index in 0..(MAX_PENDING_NOTIFICATIONS + 5) {
            metadata.observe_output(format!("\x1b]9;n{index}\x07").as_bytes());
        }
        let taken = notes(&mut metadata);
        assert_eq!(taken.len(), MAX_PENDING_NOTIFICATIONS);
        assert_eq!(taken.last().unwrap().0, format!("n{}", MAX_PENDING_NOTIFICATIONS + 4));
    }

    #[test]
    fn cmux_next_terminal_notification_osc9_progress_text_is_still_retained() {
        let mut metadata = TerminalMetadata::default();
        metadata.observe_output(b"\x1b]9;4;1;50\x07");
        assert_eq!(metadata.osc_progress(), "4;1;50");
        assert!(notes(&mut metadata).is_empty());
    }

    #[test]
    fn cmux_next_terminal_notification_gate_limits_rate_and_repeats() {
        let start = Instant::now();
        let mut gate = NotificationGate::default();
        let note = |title: &str| TerminalNotification { title: title.into(), body: String::new() };
        assert!(gate.admit(&note("a"), start));
        // Within one second of the last shown notification: dropped.
        assert!(!gate.admit(&note("b"), start + Duration::from_millis(500)));
        assert!(gate.admit(&note("b"), start + Duration::from_millis(1_100)));
        // The same text again within five seconds: dropped.
        assert!(!gate.admit(&note("b"), start + Duration::from_millis(3_000)));
        assert!(gate.admit(&note("b"), start + Duration::from_millis(6_200)));
    }
}
