//! `AttentionSettings.swift`: how a pane that needs attention rings, and whether its tab and
//! sidebar row show the mark (`notifications.attention.*`).
//!
//! Ops (after `layout_`): `attention_defaults`, `attention_surface`, `attention_rules`,
//! `attention_ranges`.

use crate::ops::{OpError, OpResult, parse, reply};
use crate::tokens::color::Color;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

raw_enum! {
    /// `AttentionStyle` (`notifications.attention.style`).
    AttentionStyle {
        /// No ring.
        None = "none",
        /// A ring that stays until the notification is dismissed.
        Steady = "steady",
        /// The ring breathes for `duration`, then stays.
        Pulse = "pulse",
        /// The ring blinks `blinkCount` times, then stays.
        Blink = "blink",
    }
}

raw_enum! {
    /// `AttentionMarkLook` (`notifications.attention.mark`).
    AttentionMarkLook {
        /// The unread dot or status mark (the default).
        Badge = "badge",
        /// A soft halo in the mark's colour until seen.
        Glow = "glow",
    }
}

raw_enum! {
    /// `FocusRingStyle` (FocusRingSettings.swift), the look a ring draws with.
    FocusRingStyle {
        /// A stroke on the pane's rounded content rect.
        Ring = "ring",
        /// A soft glow inside the content rect's edge.
        Glow = "glow",
        /// No ring.
        None = "none",
    }
}

/// `AttentionSettings.blinkRange`.
pub const BLINK_RANGE: (i64, i64) = (1, 10);
/// `AttentionSettings.durationRange`.
pub const DURATION_RANGE: (f64, f64) = (0.3, 30.0);

/// `AttentionSettings`: the pane attention ring and the tab and row marks. A field missing from
/// JSON takes Swift's default.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AttentionSettings {
    /// `style` (default `steady`).
    pub style: AttentionStyle,
    /// `color`: nil takes the theme accent.
    pub color: Option<Color>,
    /// `terminalRing` (default `glow`).
    pub terminal_ring: FocusRingStyle,
    /// `agentChatRing` (default `none`).
    pub agent_chat_ring: FocusRingStyle,
    /// `agentChatBlinkCount` (default 1).
    pub agent_chat_blink_count: i64,
    /// `ringStyle`: the look of the pane being drawn (default `glow`).
    pub ring_style: FocusRingStyle,
    /// `width` (default 2).
    pub width: f64,
    /// `blinkCount` (default 2).
    pub blink_count: i64,
    /// `duration`: seconds the pulse runs (default 3).
    pub duration: f64,
    /// `persists` (default true).
    pub persists: bool,
    /// `flashesOnRead` (default true).
    pub flashes_on_read: bool,
    /// `flashesOnTyping` (default true).
    pub flashes_on_typing: bool,
    /// `showsOnTab` (default true).
    pub shows_on_tab: bool,
    /// `showsOnSidebar` (default true).
    pub shows_on_sidebar: bool,
    /// `mark` (default `badge`).
    pub mark: AttentionMarkLook,
    /// `movesToTop` (default true).
    pub moves_to_top: bool,
    /// `movesToTopOnAgentFinish` (default false).
    pub moves_to_top_on_agent_finish: bool,
}

impl Default for AttentionSettings {
    fn default() -> Self {
        AttentionSettings {
            style: AttentionStyle::Steady,
            color: None,
            terminal_ring: FocusRingStyle::Glow,
            agent_chat_ring: FocusRingStyle::None,
            agent_chat_blink_count: 1,
            ring_style: FocusRingStyle::Glow,
            width: 2.0,
            blink_count: 2,
            duration: 3.0,
            persists: true,
            flashes_on_read: true,
            flashes_on_typing: true,
            shows_on_tab: true,
            shows_on_sidebar: true,
            mark: AttentionMarkLook::Badge,
            moves_to_top: true,
            moves_to_top_on_agent_finish: false,
        }
    }
}

impl AttentionSettings {
    /// `movesToTop(finishedTurn:)`: every notification with `movesToTop`, an agent's finished
    /// turn with `movesToTopOnAgentFinish` too.
    pub fn moves_to_top_for(&self, finished_turn: bool) -> bool {
        self.moves_to_top || (finished_turn && self.moves_to_top_on_agent_finish)
    }

    /// `drawsRing`: the pane's look and the arrival style are not none.
    pub fn draws_ring(&self) -> bool {
        self.style != AttentionStyle::None && self.ring_style != FocusRingStyle::None
    }

    /// `surface(agentChat:)`: the settings one pane draws with.
    pub fn surface(&self, agent_chat: bool) -> AttentionSettings {
        let mut settings = self.clone();
        settings.ring_style = if agent_chat { self.agent_chat_ring } else { self.terminal_ring };
        if agent_chat {
            settings.blink_count = self.agent_chat_blink_count;
        }
        settings
    }

    /// `drawsAnyRing`: a terminal's look or an agent chat's, with an arrival style.
    pub fn draws_any_ring(&self) -> bool {
        self.style != AttentionStyle::None
            && (self.terminal_ring != FocusRingStyle::None
                || self.agent_chat_ring != FocusRingStyle::None)
    }

    /// `rings(agentChat:)`.
    pub fn rings(&self, agent_chat: bool) -> bool {
        self.surface(agent_chat).draws_ring()
    }
}

/// `AttentionMark`: one pane's attention mark as the layout draws it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttentionMark {
    /// Per-source colour override; nil uses `AttentionSettings.color`.
    #[serde(default)]
    pub color: Option<Color>,
    /// The newest event's id.
    pub generation: u64,
    /// The pane shows an agent chat.
    #[serde(default)]
    pub agent_chat: bool,
    /// The ring arrives at rest with no pulse.
    #[serde(default)]
    pub quiet: bool,
}

impl AttentionMark {
    /// `init(generation:)` with Swift's defaults (no colour, not a chat, not quiet).
    pub fn new(generation: u64) -> Self {
        AttentionMark { color: None, generation, agent_chat: false, quiet: false }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SurfaceRequest {
    #[serde(default)]
    settings: AttentionSettings,
    agent_chat: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RulesRequest {
    #[serde(default)]
    settings: AttentionSettings,
    #[serde(default)]
    finished_turn: bool,
}

/// `attention_rules`'s reply.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AttentionRules {
    /// `drawsRing`.
    pub draws_ring: bool,
    /// `drawsAnyRing`.
    pub draws_any_ring: bool,
    /// `rings(agentChat: false)`.
    pub rings_terminal: bool,
    /// `rings(agentChat: true)`.
    pub rings_agent_chat: bool,
    /// `movesToTop(finishedTurn:)`.
    pub moves_to_top: bool,
}

/// The rules of `settings` for a notification (`finished_turn`: an agent's finished turn).
pub fn rules(settings: &AttentionSettings, finished_turn: bool) -> AttentionRules {
    AttentionRules {
        draws_ring: settings.draws_ring(),
        draws_any_ring: settings.draws_any_ring(),
        rings_terminal: settings.rings(false),
        rings_agent_chat: settings.rings(true),
        moves_to_top: settings.moves_to_top_for(finished_turn),
    }
}

/// Runs the `attention_*` ops (the name after `layout_`).
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "attention_defaults" => reply(&AttentionSettings::default()),
        "attention_surface" => {
            let r: SurfaceRequest = parse(request)?;
            reply(&r.settings.surface(r.agent_chat))
        }
        "attention_rules" => {
            let r: RulesRequest = parse(request)?;
            reply(&rules(&r.settings, r.finished_turn))
        }
        "attention_ranges" => Ok(json!({
            "blink": [BLINK_RANGE.0, BLINK_RANGE.1],
            "duration": [DURATION_RANGE.0, DURATION_RANGE.1],
        })),
        _ => Err(OpError::Unknown),
    }
}
