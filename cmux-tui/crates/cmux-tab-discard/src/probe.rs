//! What a hidden page says right before it freezes or is discarded, and what that keeps.
//!
//! Keep rules (Lawrence 2026-10-24, cmux CLAUDE.md "Copy Chrome's performance model"): a page with
//! audio, capture, the person's form input (also in a child frame it cannot read), a
//! `beforeunload` that asks, a WebRTC connection or an open device is never discarded, at any
//! memory pressure. Chrome lets an urgent discard take a page with form interaction; cmux does not.

use crate::plan::{Exemption, Pressure};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A page's answer to the probe (the app's `PageProbe`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PageProbe {
    /// Unmuted media playing, media the tab's mute silences, or Picture in Picture.
    pub playing_media: bool,
    /// The tab reports media the person resumes from outside the page (macOS Now Playing, the
    /// media keys, the tab's media menu), paused too. A frozen page runs none of those, so it
    /// keeps the page from a freeze only; a discard ends the session with the page (issue 51079).
    pub media_session: bool,
    /// The person's form edits in the tab's frames.
    pub edited_form: bool,
    /// Camera, microphone or screen capture the page started.
    pub capturing: bool,
    /// A running Web Audio context. It may be silent; only the page knows whether it is heard, so
    /// it counts as audio at every pressure.
    pub web_audio: bool,
    /// The page would ask before it unloads (a child frame's `beforeunload`).
    pub before_unload: bool,
    /// The person used the top document and it has a `beforeunload` handler: it may ask. Not a
    /// keep reason by itself; the app runs the handlers right before the discard.
    pub unload_handler: bool,
    /// A connected WebRTC peer connection.
    pub web_rtc: bool,
    /// An open USB, HID or serial device, or a connected Bluetooth GATT server.
    pub connected_device: bool,
    /// The person moved into a child frame whose fields cannot be read: its edits are unknown, so
    /// they count as the person's input.
    pub unreadable_frame: bool,
    /// False when the page did not answer: only what the tab reported on its own is known.
    pub answered: bool,
}

impl Default for PageProbe {
    fn default() -> Self {
        PageProbe {
            playing_media: false,
            media_session: false,
            edited_form: false,
            capturing: false,
            web_audio: false,
            before_unload: false,
            unload_handler: false,
            web_rtc: false,
            connected_device: false,
            unreadable_frame: false,
            answered: true,
        }
    }
}

impl PageProbe {
    /// Why the answer keeps the page loaded, or `None` when nothing it said does.
    pub fn exemption(&self) -> Option<Exemption> {
        if self.capturing {
            Some(Exemption::Capturing)
        } else if self.playing_media {
            Some(Exemption::Audio)
        } else if self.edited_form {
            Some(Exemption::FormInput)
        } else if self.unreadable_frame {
            Some(Exemption::UnreadableFrame)
        } else if self.before_unload {
            Some(Exemption::BeforeUnload)
        } else if self.web_rtc {
            Some(Exemption::WebRtc)
        } else if self.connected_device {
            Some(Exemption::ConnectedDevice)
        } else if self.web_audio {
            Some(Exemption::WebAudio)
        } else {
            None
        }
    }

    /// The page does something a freeze stops (a freeze keeps memory and state, so form input and
    /// a `beforeunload` do not count), or holds a media session the person resumes from outside it.
    pub fn stops_when_frozen(&self) -> bool {
        self.playing_media
            || self.media_session
            || self.capturing
            || self.web_audio
            || self.web_rtc
            || self.connected_device
    }

    /// Why the probed page stays loaded now, or `None` when it may be discarded.
    ///
    /// What the page said keeps it at every pressure, and so does a form result (BR-R1). A page
    /// that did not answer stays while it gets the benefit of the doubt ([`ProbeHistory`]), and
    /// without memory pressure always: its form edits are unknown.
    pub fn keep_reason(
        &self,
        pressure: Pressure,
        doubted: bool,
        shows_form_submission: bool,
    ) -> Option<Exemption> {
        if let Some(reason) = self.exemption() {
            return Some(reason);
        }
        if shows_form_submission {
            return Some(Exemption::FormSubmission);
        }
        (!self.answered && (doubted || pressure == Pressure::Normal))
            .then_some(Exemption::Unanswered)
    }
}

/// What the doubt is for.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Step {
    /// Freezing a hidden page: its timers, tasks and rendering stop; memory and state stay.
    Freeze,
    /// Discarding a hidden page: its engine page closes.
    #[default]
    Discard,
}

/// What the hidden pages' recent probes said: the benefit of the doubt a page keeps while it does
/// not answer (plans/cmux-next/tab-lifecycle.md, section 3).
///
/// A page that does not answer counts as idle once it missed [`ProbeHistory::UNANSWERED_LIMIT`]
/// probes in a row. A page whose last answer said it holds something the step would break keeps
/// the doubt for as long as it does not answer.
#[derive(Clone, Debug, Default)]
pub struct ProbeHistory {
    unanswered: HashMap<String, u32>,
    last_answer: HashMap<String, PageProbe>,
}

impl ProbeHistory {
    /// Probes in a row a page may leave unanswered before it counts as idle.
    pub const UNANSWERED_LIMIT: u32 = 3;

    /// Records a probe of page `key`; returns whether the page still gets the benefit of the doubt
    /// for `step` (always false for an answer).
    pub fn record(&mut self, probe: PageProbe, key: &str, step: Step) -> bool {
        if probe.answered {
            self.unanswered.remove(key);
            self.last_answer.insert(key.to_owned(), probe);
            return false;
        }
        if !self.said_busy(key, step) {
            *self.unanswered.entry(key.to_owned()).or_default() += 1;
        }
        self.doubted(key, step)
    }

    /// True while page `key` still gets the benefit of the doubt for `step`, without counting a probe.
    pub fn doubted(&self, key: &str, step: Step) -> bool {
        self.said_busy(key, step)
            || self.unanswered.get(key).copied().unwrap_or(0) < Self::UNANSWERED_LIMIT
    }

    /// The page was shown: its misses start again (what it last said still holds).
    pub fn clear_misses(&mut self, key: &str) {
        self.unanswered.remove(key);
    }

    pub fn forget(&mut self, key: &str) {
        self.unanswered.remove(key);
        self.last_answer.remove(key);
    }

    fn said_busy(&self, key: &str, step: Step) -> bool {
        self.last_answer.get(key).is_some_and(|last| match step {
            Step::Freeze => last.stops_when_frozen(),
            Step::Discard => last.exemption().is_some(),
        })
    }
}
