//! AutoCloud readiness, 0 to 100 (RFD 0139 §"Readiness"; RFD 0078 "AutoCloud: how full the cloud copy is").
//!
//! Two halves, so the number never sits still while something is happening:
//!
//! - 0 to 60 is the link: signed in, the machine dialed, the link up, the daemon answering, the chat
//!   open, its history replayed. Every step is a fact this client sees itself, so the figure is
//!   honest on any backend (a GCP, AWS, Azure or Freestyle machine, an SSH box, this machine).
//! - 60 to 100 is the machine's fill: how much of the project the machine holds (RFD 0078's
//!   figure, prefix first, then what the agent asked for, then the rest). A daemon that reports no
//!   fill has nothing left to fill from this client's view, so the chat counts as 100 once live.
//!
//! Gone at 100: the bar leaves the header when the chat is fully ready.

/// The link's steps, in order. Each later step implies the earlier ones.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Phase {
    /// Nothing yet.
    Start,
    /// A credential is held (or the link needs none: a local or SSH daemon).
    SignedIn,
    /// The link command runs: ssh, `cmux carrier dial`, or a local `acpmux stdio`.
    Dialing,
    /// The first byte came back.
    LinkUp,
    /// `initialize` answered.
    Initialized,
    /// `session/new` or the chat to continue answered.
    ChatOpen,
    /// The chat's history is on screen.
    Replayed,
}

impl Phase {
    /// Where on 0..=60 a phase sits.
    pub fn link_percent(self) -> u8 {
        match self {
            Phase::Start => 0,
            Phase::SignedIn => 8,
            Phase::Dialing => 15,
            Phase::LinkUp => 30,
            Phase::Initialized => 40,
            Phase::ChatOpen => 52,
            Phase::Replayed => 60,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Phase::Start => "starting",
            Phase::SignedIn => "signed in",
            Phase::Dialing => "dialing the machine",
            Phase::LinkUp => "link up",
            Phase::Initialized => "agent daemon answered",
            Phase::ChatOpen => "chat open",
            Phase::Replayed => "history replayed",
        }
    }
}

/// What the header shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Readiness {
    pub phase: Phase,
    /// The machine's fill, 0..=100, when its daemon reports one.
    pub fill: Option<u8>,
}

impl Default for Readiness {
    fn default() -> Self {
        Self { phase: Phase::Start, fill: None }
    }
}

impl Readiness {
    /// 0..=100.
    pub fn percent(&self) -> u8 {
        if self.phase < Phase::Replayed {
            return self.phase.link_percent();
        }
        match self.fill {
            Some(fill) => 60u8.saturating_add(fill.min(100).saturating_mul(2) / 5),
            None => 100,
        }
    }

    pub fn label(&self) -> String {
        match (self.phase, self.fill) {
            (Phase::Replayed, Some(f)) if f < 100 => format!("filling the machine {f}%"),
            (Phase::Replayed, _) => "ready".to_owned(),
            (p, _) => p.label().to_owned(),
        }
    }

    /// Moves forward only: a reconnect drops the phase back by calling [`Readiness::reset_link`].
    pub fn advance(&mut self, phase: Phase) {
        if phase > self.phase {
            self.phase = phase;
        }
    }

    /// A dropped link: back to dialing, the fill kept (the machine still holds what it held).
    pub fn reset_link(&mut self) {
        self.phase = self.phase.min(Phase::Dialing).max(Phase::Dialing);
    }

    /// A fill figure from the daemon (`_meta.acpmux.fill` or a `fill` event), clamped.
    pub fn set_fill(&mut self, fill: u64) {
        self.fill = Some(fill.min(100) as u8);
    }
}

#[cfg(test)]
#[path = "readiness_tests.rs"]
mod tests;
