//! `cmux help keys`: the TUI's key bindings as text, for an agent or a
//! person outside the TUI (W5-Q, bench round 4 #10). The rows are the ones
//! the TUI's shortcut list shows (`Keys::resolved_shortcuts`), with each
//! action's label in the catalog's language.

use crate::config::{Action, Keys};
use crate::localization::Catalog;

/// The help text for `keys`: an intro line, then one row per bound action.
pub(super) fn help(keys: &Keys, catalog: &Catalog) -> String {
    let prefix = keys.prefix.display_label().unwrap_or_else(|| "-".to_owned());
    let show = keys.shortcut_label(Action::ShowShortcuts).unwrap_or_else(|| "-".to_owned());
    let mut text =
        catalog.shortcuts.cli_intro.replace("{prefix}", &prefix).replace("{show}", &show);
    text.push_str("\n\n");
    let rows: Vec<(&str, String)> = keys
        .resolved_shortcuts()
        .into_iter()
        .map(|(definition, shortcuts)| {
            (catalog.action_label(definition.action), shortcuts.join(", "))
        })
        .collect();
    let width = rows.iter().map(|(label, _)| label.chars().count()).max().unwrap_or(0);
    for (label, shortcuts) in rows {
        let pad = width.saturating_sub(label.chars().count());
        text.push_str(&format!("  {label}{}  {shortcuts}\n", " ".repeat(pad)));
    }
    text
}
