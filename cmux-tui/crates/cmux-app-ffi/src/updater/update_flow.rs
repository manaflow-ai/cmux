//! The install gate over Sparkle's flow (R114, SIDEBAR-FOOTER-MINIMAL), the
//! decisions the macOS app's `UpdateFlow` (CmuxNextUpdater/UpdateFlow.swift)
//! used to make in Swift: downloads stay invisible, a staged update is the
//! footer's "Update Ready" pill, and a click or approved idle install passes
//! through the relaunch gate before Sparkle relaunches. A quit installs a
//! staged update unless `updates.installOnQuit` is off. A pure value: the app
//! feeds events and performs the effects.
//!
//! The phase is its kind only: the app keeps the phase's payload (the
//! download's transfer, a note, a version) and maps the answers back to it.
//!
//! Without automatic download (`updates.downloadAutomatically` off) the flow
//! asks twice, as Sparkle's own UI does: a found update waits on the
//! update-found step until Update (`downloadRequested`), and the staged update
//! waits on the Update Ready card until Restart to Update
//! (`installRequested`). With `updates.oneClickInstall` (off by default) the
//! first ask is the only one. Hide, or no answer, never relaunches.

use serde::{Deserialize, Serialize};

/// What the rail's update circle shows, by kind (the app's `UpdateIndicatorPhase`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    #[default]
    Hidden,
    Checking,
    Downloading,
    Available,
    Ready,
    Installing,
    Note,
}

/// The gate's state (the app's `UpdateFlow` less the phase's payload).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Flow {
    pub phase: Phase,
    /// The user asked to install; held until the update is staged.
    pub install_requested: bool,
    /// The user asked to check: checking, downloading and the result show.
    /// Only the person's own check sets it; a scheduled (background) check
    /// clears it (Lawrence 2026-10-20: "if there is a background check for
    /// updates, it should not be visible to the user").
    pub user_asked: bool,
    /// The person started this download: only then does its progress show
    /// (Lawrence 2026-11-07: "i think i enabled auto updates but it was
    /// automatically downloading updates just now").
    pub download_asked: bool,
    /// The person's request waits for its check to start: the next `checking`
    /// is theirs. A check that starts without one is a scheduled check.
    pub ask_pending: bool,
}

/// Inputs of the gate (the app's `UpdateFlowEvent`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Event {
    /// Sparkle's flow moved (a scheduled check or the user's).
    Sparkle {
        next: Phase,
    },
    /// The user asked to check (palette, menu, CLI).
    CheckRequested,
    /// Attempt Update with nothing found yet: a check whose update downloads
    /// and installs at once, its progress shown.
    AttemptRequested,
    /// Install and relaunch once staged.
    InstallRequested,
    /// Update on the Update Available step.
    DownloadRequested,
    QuitRequested,
    /// A note's display time ended.
    NoteExpired,
}

/// The update settings the gate reads (`updates.*`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Preferences {
    pub install_on_quit: bool,
    pub one_click_install: bool,
}

/// What the gate asks the app to do (the app's `UpdateFlowEffect`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Effect {
    /// Install the staged update and relaunch now.
    Install,
    /// Download the update that waits for the click.
    Download,
    /// Let the quit go on; Sparkle installs a staged update as the app terminates.
    QuitProceed,
    /// `updates.installOnQuit` is off: cancel Sparkle's pending installer first.
    QuitCancelPendingInstall,
}

/// The notice card's update status, by kind (the app's `UpdateCard`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Card {
    Checking,
    Downloading,
    Available,
    Installing,
    Note,
}

/// The footer's update pill (the app's `UpdateFooterPill`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Pill {
    Ready,
    Installing,
}

impl Flow {
    pub fn handle(&mut self, event: Event, preferences: Preferences) -> Vec<Effect> {
        match event {
            Event::Sparkle { next } => self.sparkle_moved(next),
            Event::AttemptRequested => {
                // Attempt Update with nothing found yet: a fresh check that downloads and installs at once.
                self.download_asked = true;
                self.user_asked = true;
                self.ask_pending = self.phase != Phase::Checking;
                vec![]
            }
            Event::CheckRequested => {
                self.user_asked = true;
                // Joining a check that already runs needs no new start.
                self.ask_pending = self.phase != Phase::Checking;
                vec![]
            }
            Event::InstallRequested => match self.phase {
                Phase::Ready => {
                    // The staged update card took the click: its own button says
                    // Installing…, so the notice card does not take its place.
                    self.install_requested = true;
                    self.user_asked = false;
                    self.install_if_staged()
                }
                Phase::Downloading | Phase::Checking => {
                    // Installs once staged; the check or the download's progress shows meanwhile.
                    self.install_requested = true;
                    self.user_asked = true;
                    self.download_asked = true;
                    vec![]
                }
                Phase::Available => {
                    // Downloads, shows its progress, installs once staged.
                    self.install_requested = true;
                    self.user_asked = true;
                    self.download_asked = true;
                    vec![Effect::Download]
                }
                Phase::Hidden | Phase::Installing | Phase::Note => vec![],
            },
            Event::DownloadRequested => {
                // The answer to the update-found step: download, show its progress, then ask
                // again before the relaunch. With `updates.oneClickInstall` this click is the
                // relaunch's ask too (Leo 2026-11-04: "me clicking it enabling it to auto install
                // and restart is... interesting").
                if self.phase != Phase::Available {
                    return vec![];
                }
                self.user_asked = true;
                self.download_asked = true;
                if preferences.one_click_install {
                    self.install_requested = true;
                }
                vec![Effect::Download]
            }
            Event::QuitRequested => {
                if self.phase == Phase::Ready && !preferences.install_on_quit {
                    vec![Effect::QuitCancelPendingInstall]
                } else {
                    vec![Effect::QuitProceed]
                }
            }
            Event::NoteExpired => {
                if self.phase == Phase::Note {
                    self.phase = Phase::Hidden;
                }
                self.user_asked = false;
                vec![]
            }
        }
    }

    fn sparkle_moved(&mut self, next: Phase) -> Vec<Effect> {
        let previous = self.phase;
        self.phase = next;
        match next {
            Phase::Checking => {
                // A check the person did not ask for (scheduled) shows nothing,
                // even while an earlier result of theirs still waits for its x.
                if self.ask_pending {
                    self.ask_pending = false;
                } else if previous != Phase::Checking {
                    self.user_asked = false;
                }
            }
            Phase::Hidden => {
                // A check or download that ended with nothing ends the request.
                if previous == Phase::Checking || previous == Phase::Downloading {
                    self.user_asked = false;
                }
            }
            Phase::Note
            | Phase::Available
            | Phase::Downloading
            | Phase::Ready
            | Phase::Installing => {
                self.ask_pending = false;
            }
        }
        match next {
            Phase::Ready => {
                self.user_asked = false;
                self.download_asked = false;
                self.install_if_staged()
            }
            Phase::Installing => {
                // A person who watched the check and download on the notice card
                // keeps watching it there until the relaunch.
                self.install_requested = false;
                vec![]
            }
            Phase::Hidden | Phase::Note => {
                // The flow ended, failed or was cancelled: a held click does not
                // carry over to a later update.
                self.install_requested = false;
                self.download_asked = false;
                vec![]
            }
            Phase::Available => {
                // A click held while the check ran: download now, install once staged.
                if !self.install_requested {
                    return vec![];
                }
                self.user_asked = true;
                self.download_asked = true;
                vec![Effect::Download]
            }
            Phase::Checking | Phase::Downloading => vec![],
        }
    }

    /// Installs when the user asked and the update is staged.
    fn install_if_staged(&mut self) -> Vec<Effect> {
        if !self.install_requested || self.phase != Phase::Ready {
            return vec![];
        }
        self.install_requested = false;
        vec![Effect::Install]
    }

    /// The notice card's update status, or None: what the user asked for (a
    /// check, its download's progress, its result), and a found update that
    /// waits for a click (`updates.downloadAutomatically` off). A scheduled
    /// check, its download and its result show nothing (Leo 2026-11-03: "it's
    /// already downloaded you click this button to accept the button and
    /// restart"). A staged update is never this card.
    pub fn card(&self, downloads_automatically: bool) -> Option<Card> {
        if self.phase == Phase::Available && (self.user_asked || !downloads_automatically) {
            return Some(Card::Available);
        }
        if !self.user_asked {
            return None;
        }
        match self.phase {
            Phase::Checking => Some(Card::Checking),
            Phase::Downloading => self.download_asked.then_some(Card::Downloading),
            Phase::Installing => Some(Card::Installing),
            Phase::Note => Some(Card::Note),
            Phase::Hidden | Phase::Available | Phase::Ready => None,
        }
    }

    /// The footer's update pill: "Update Ready" while an update is staged,
    /// disabled while it installs; None otherwise and, for a staged update,
    /// under `updates.notify` silent.
    pub fn footer_pill(&self, silent: bool) -> Option<Pill> {
        match self.phase {
            Phase::Ready => (!silent).then_some(Pill::Ready),
            Phase::Installing => Some(Pill::Installing),
            Phase::Hidden
            | Phase::Checking
            | Phase::Downloading
            | Phase::Available
            | Phase::Note => None,
        }
    }
}

#[cfg(test)]
#[path = "update_flow_tests.rs"]
mod tests;
