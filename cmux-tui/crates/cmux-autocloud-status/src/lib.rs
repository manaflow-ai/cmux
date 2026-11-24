//! What the sidebar's AutoCloud status icon shows.
//!
//! Leo, 2026-11-24: "honestly there's something incredibly google docs-y about this. discord-y. ...
//! i think there's even situations where we can have an icon maybe toggle somewhere omnipresent...
//! say the bottom left of the sidebar area, which is currently not used for anything. because we
//! hid spaces by default".
//!
//! AutoCloud: a local chat starts at once while a cloud VM warms in the background, the Mac and the VM
//! sync both ways, the phone shows whichever is most truthful, and agents on separate VMs talk to each
//! other. The icon answers three questions at a glance: is the cloud there ([`Cloud`]), is my work
//! safe ([`Sync`]), who is here ([`Here`]).
//!
//! The feeds fill an [`AutoCloudStatus`]: the VM's phase from the cloud record, the sync state from the
//! `cmux-sync` crate and `here` from acpmux's machine-wide `_acpmux/here`. The views (the native sidebar
//! footer, the web gallery's mock of it) only draw what [`AutoCloudStatus::headline`] and
//! [`AutoCloudStatus::tone`] say, so the precedence below is decided once, here, and no view re-derives it.
//! `webviews/src/sidebar/autocloudStatus.fixtures.json` holds every state the design shows with the
//! headline each must give; `tests` reads it, and the gallery draws from the same file.

use serde::{Deserialize, Serialize};

/// The cloud VM's phase.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Cloud {
    /// AutoCloud is off: chats stay on this Mac and nothing syncs.
    Off,
    /// The VM is getting ready while the local chat runs: nothing waits on it.
    Warming,
    /// The VM is up and in sync, with no agent working on it.
    Ready,
    /// An agent is working on the VM now.
    Active,
}

/// The Mac<->VM sync state. Edits made offline queue and merge conflict-free on reconnect, so being
/// offline is a state to see, never an error.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum Sync {
    Synced,
    /// `changes` edits are on their way to the other side.
    Syncing {
        changes: u32,
    },
    /// The link is down; `pending` edits are queued.
    Offline {
        pending: u32,
    },
}

/// Whether someone here is a person or an agent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum HereKind {
    Person,
    Agent,
}

/// Where someone here is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum HereAt {
    /// On another Mac.
    Mac,
    /// On a cloud VM.
    Cloud,
    Phone,
}

/// One person or agent here besides you (`_acpmux/here`, without this window's own session).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Here {
    pub name: String,
    pub kind: HereKind,
    pub at: HereAt,
}

/// Everything the icon draws from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AutoCloudStatus {
    pub cloud: Cloud,
    pub sync: Sync,
    /// Everyone here but you, longest here first.
    #[serde(default)]
    pub here: Vec<Here>,
}

/// The one thing the glyph says, most urgent first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Headline {
    /// AutoCloud is off.
    Off,
    /// Offline, with edits queued.
    Offline,
    /// Edits are moving.
    Syncing,
    /// The VM is getting ready.
    Warming,
    /// The VM is up, synced and idle.
    Ready,
    /// The VM is up, synced and an agent is working on it.
    Active,
}

/// How loud the icon is: it is `Quiet` almost always, so the rare other state is seen.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Tone {
    /// Nothing to see: off, or in sync.
    Quiet,
    /// Something is in motion and will settle by itself: warming, syncing, an agent working.
    Working,
    /// Worth a glance, not an alarm: offline with edits queued.
    Attention,
}

impl AutoCloudStatus {
    /// The headline. Off hides the rest (with no VM there is nothing to sync); otherwise offline beats
    /// syncing beats warming beats the calm states, because the more urgent a state is the more it
    /// changes what the person should do next.
    pub fn headline(&self) -> Headline {
        if self.cloud == Cloud::Off {
            return Headline::Off;
        }
        match self.sync {
            Sync::Offline { .. } => Headline::Offline,
            Sync::Syncing { changes } if changes > 0 => Headline::Syncing,
            _ => match self.cloud {
                Cloud::Warming => Headline::Warming,
                Cloud::Active => Headline::Active,
                Cloud::Ready | Cloud::Off => Headline::Ready,
            },
        }
    }

    pub fn tone(&self) -> Tone {
        match self.headline() {
            Headline::Offline => Tone::Attention,
            Headline::Syncing | Headline::Warming | Headline::Active => Tone::Working,
            Headline::Off | Headline::Ready => Tone::Quiet,
        }
    }

    /// The number the glyph's badge carries: the edits moving or queued, else nothing. Presence has
    /// its own count ([`Self::people_here`], [`Self::agents_here`]).
    pub fn pending(&self) -> u32 {
        if self.cloud == Cloud::Off {
            return 0;
        }
        match self.sync {
            Sync::Synced => 0,
            Sync::Syncing { changes } => changes,
            Sync::Offline { pending } => pending,
        }
    }

    pub fn people_here(&self) -> usize {
        self.here.iter().filter(|h| h.kind == HereKind::Person).count()
    }

    pub fn agents_here(&self) -> usize {
        self.here.iter().filter(|h| h.kind == HereKind::Agent).count()
    }

    /// Whether anyone else is here: the icon grows its presence part only then, so alone it stays one glyph.
    pub fn someone_here(&self) -> bool {
        !self.here.is_empty()
    }

    /// The first `max` names to draw as avatars, people before agents, and how many more there are.
    pub fn avatars(&self, max: usize) -> (Vec<&Here>, usize) {
        let mut sorted: Vec<&Here> = self.here.iter().collect();
        // Stable: longest-here order holds within a kind.
        sorted.sort_by_key(|h| h.kind != HereKind::Person);
        let rest = sorted.len().saturating_sub(max);
        sorted.truncate(max);
        (sorted, rest)
    }
}

#[cfg(test)]
mod tests;
