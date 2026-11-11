//! Menus and the engine ([`crate::menus`]): the desktop learns the menu
//! setting and the deny list's app names before every acting call, and
//! every tree the agent sees has the menu items that lead to a denied app
//! taken out.

use super::*;
use crate::menus::{self, MenuPolicy};

impl Engine {
    /// The menu policy under `config`: the setting, and the names of the
    /// denied apps (known names of the deny list, and the running apps it covers).
    pub(super) fn menu_policy(&self, config: &PolicyConfig) -> MenuPolicy {
        let running = self.desktop.list_apps().unwrap_or_default();
        MenuPolicy { mode: config.menus, denied_names: menus::denied_names(config, &running) }
    }

    /// Hands the desktop the menu policy for the acting call about to run.
    pub(super) fn sync_menu_policy(&self, config: &PolicyConfig) {
        self.desktop.set_menu_policy(self.menu_policy(config));
    }

    /// Takes the menu items that lead to a denied app out of a tree the
    /// agent will see.
    pub(super) fn hide_denied_menu_items(&self, config: &PolicyConfig, root: &mut Element) {
        menus::hide_denied(root, &self.menu_policy(config));
    }
}
