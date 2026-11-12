//! Menus and the engine ([`crate::menus`]): the desktop learns the menu
//! setting before every acting call. The deny list reaches menus through
//! the desktop's [`crate::desktop::MenuGuard`] (set once in `Engine::new`),
//! which hides and refuses the items of the menu bar and of any menu the
//! desktop opens.

use super::*;
use crate::menus::MenuPolicy;

impl Engine {
    /// Hands the desktop the menu setting for the acting call about to run.
    pub(super) fn sync_menu_policy(&self, config: &PolicyConfig) {
        self.desktop.set_menu_policy(MenuPolicy { mode: config.menus });
    }
}
