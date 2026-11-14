//! cmux NEXT's action catalog, the source of truth for every action descriptor.
//!
//! Each action is declared once here (`catalog/<group>.rs`): its id, title, CLI name, default
//! shortcut and chord, arguments, targets, the surfaces that offer it (palette, CLI, right-click
//! menus, MCP) with a reason for each that does not, its menu bar menu and its run flags. The
//! titles of actions, arguments, values and menus are translated in [`strings`], in every
//! language the app ships. The default key bindings beyond an action's own shortcut are in
//! [`bindings`], the palette's tables in [`palette`].
//!
//! The macOS app reads the catalog at launch through the C ABI in [`ffi`]
//! (`cmux_action_catalog_json`), as JSON in its language ([`json::catalog`]). The Swift handlers
//! bind to these ids; they are not here.

// `json!` objects with every descriptor field nest deeper than the default limit.
#![recursion_limit = "512"]

pub mod bindings;
pub mod catalog;
pub mod ffi;
pub mod json;
pub mod model;
pub mod palette;
pub mod strings;
pub mod tables;
pub mod text;

use std::collections::HashMap;
use std::sync::OnceLock;

pub use model::*;
pub use strings::LOCALES;

/// Every action, in catalog order.
pub fn actions() -> impl Iterator<Item = &'static Action> {
    catalog::GROUPS.iter().flat_map(|group| group.iter())
}

fn index() -> &'static HashMap<&'static str, &'static Action> {
    static INDEX: OnceLock<HashMap<&'static str, &'static Action>> = OnceLock::new();
    INDEX.get_or_init(|| {
        let mut map = HashMap::new();
        for action in actions() {
            map.entry(action.id).or_insert(action);
        }
        map
    })
}

/// The action with `id`, following a legacy alias (`app.quit` -> `quit`).
pub fn find(id: &str) -> Option<&'static Action> {
    let index = index();
    index
        .get(id)
        .copied()
        .or_else(|| legacy_alias(id).and_then(|canonical| index.get(canonical).copied()))
}

/// The catalog id an old id stands for, if `id` is one.
pub fn legacy_alias(id: &str) -> Option<&'static str> {
    tables::LEGACY_ALIASES.iter().find(|(old, _)| *old == id).map(|(_, new)| *new)
}

/// The category with `id` (`ActionCategory` raw value).
pub fn category(id: &str) -> Option<&'static Category> {
    tables::CATEGORIES.iter().find(|category| category.id == id)
}

/// The palette's frequency tier of an action.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PaletteTier {
    Daily,
    Standard,
    Niche,
}

impl PaletteTier {
    pub fn name(self) -> &'static str {
        match self {
            PaletteTier::Daily => "daily",
            PaletteTier::Standard => "standard",
            PaletteTier::Niche => "niche",
        }
    }
}

impl Action {
    /// The palette family whose row stands for this action on the empty query (the first
    /// family that lists it).
    pub fn palette_family(&self) -> Option<&'static PaletteFamily> {
        palette::FAMILIES.iter().find(|family| family.members.contains(&self.id))
    }

    pub fn palette_tier(&self) -> PaletteTier {
        // Debug-only rows ("Debug: <name>", Internal Developer Mode) share one tier, so they keep the
        // catalog's order: last, sorted by name (the app's `withDebugActionsLast`).
        if self.is_debug_only {
            PaletteTier::Niche
        } else if palette::DAILY.contains(&self.id) {
            PaletteTier::Daily
        } else if palette::NICHE.contains(&self.id) || self.palette_family().is_some() {
            PaletteTier::Niche
        } else {
            PaletteTier::Standard
        }
    }

    /// The action whose name this one carries: itself unless the palette folds it into another.
    pub fn canonical_action_id(&self) -> &'static str {
        palette::DUPLICATES
            .iter()
            .find(|(duplicate, _)| *duplicate == self.id)
            .map_or(self.id, |(_, canonical)| *canonical)
    }

    /// The rank of the action among the palette's empty-query suggestions.
    pub fn palette_suggestion_rank(&self) -> Option<usize> {
        palette::SUGGESTIONS.iter().position(|id| *id == self.id)
    }

    /// The default bindings for this action beyond its own shortcut, in table order, each key
    /// sequence once.
    pub fn default_aliases(&self) -> Vec<&'static Binding> {
        let mut seen: Vec<&'static [Shortcut]> = Vec::new();
        let mut aliases = Vec::new();
        for binding in bindings::alias_entries() {
            if binding.command == self.id && !seen.contains(&binding.keys) {
                seen.push(binding.keys);
                aliases.push(binding);
            }
        }
        aliases
    }
}
