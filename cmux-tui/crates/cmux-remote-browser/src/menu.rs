//! Menu token lifecycle on the host (remote-tab-protocol.md section 5.2,
//! vectors `schemas/remote-tab/menu-token.json`).
//!
//! Chromium shows at most one context menu or `<select>` popup at a time and
//! waits for one answer. The host gives each menu a token that never repeats
//! in the session, so a late or repeated answer from a viewer can never pick
//! an item of a different menu.

use serde::{Deserialize, Serialize};

use crate::proto::{Menu, MenuChoice, MenuItem, MenuKind};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenMenu {
    pub token: u64,
    pub kind: MenuKind,
    /// Context menus: the command ids a viewer may choose.
    pub item_ids: Vec<i64>,
    /// `<select>`: the number of options.
    pub item_count: u32,
    pub multiple: bool,
}

impl OpenMenu {
    /// The menu `menu` shown under `token`: the command ids of a context
    /// menu (separators and submenu headers are not choices; nested
    /// commands are) or the option count of a `<select>`.
    pub fn for_menu(token: u64, menu: &Menu) -> Self {
        let mut item_ids = Vec::new();
        command_ids(&menu.items, &mut item_ids);
        Self {
            token,
            kind: menu.kind,
            item_ids,
            item_count: u32::try_from(menu.items.len()).unwrap_or(u32::MAX),
            multiple: menu.multiple,
        }
    }

    /// Whether `choice` is an answer this menu offered.
    pub fn accepts(&self, choice: &MenuChoice) -> bool {
        choice_is_valid(self, choice)
    }
}

/// The ids a context menu answer may name: every item that is not a
/// separator or a submenu header, nested items included.
pub fn command_ids(items: &[MenuItem], out: &mut Vec<i64>) {
    for item in items {
        if item.item_type != "separator" && item.item_type != "submenu" {
            out.push(item.id);
        }
        command_ids(&item.items, out);
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum MenuInput {
    /// Chromium asks for a menu.
    Show { kind: MenuKind, item_ids: Vec<i64>, item_count: u32, multiple: bool },
    /// A viewer answered.
    Result { token: u64, choice: MenuChoice },
    /// Chromium closed the menu itself (navigation, the element went away).
    PageCancel { token: u64 },
    /// The viewer that shows menus left.
    ViewerGone,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum MenuEffect {
    /// Show the menu with this token on the viewer (`rb.menu.show`).
    ViewerShow { token: u64 },
    /// Close the menu with this token on the viewer (`rb.menu.cancel`).
    ViewerCancel { token: u64 },
    /// Answer Chromium's callback for this token.
    ChromeContinue { token: u64, choice: MenuChoice },
    /// Cancel Chromium's callback for this token.
    ChromeCancel { token: u64 },
}

/// Accepted inputs that do nothing say why.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MenuNote {
    /// A second answer for a menu that is already closed.
    Duplicate,
    /// A page cancel for a menu that is already closed.
    Stale,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MenuReject {
    UnknownToken,
    InvalidChoice,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct MenuOutcome {
    pub effects: Vec<MenuEffect>,
    pub note: Option<MenuNote>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MenuTokens {
    /// The token the next menu gets. Tokens start at 1.
    pub next_token: u64,
    pub open: Option<OpenMenu>,
}

impl Default for MenuTokens {
    fn default() -> Self {
        Self { next_token: 1, open: None }
    }
}

impl MenuTokens {
    /// Applies one input. On a reject the state is unchanged.
    pub fn apply(&mut self, input: MenuInput) -> Result<MenuOutcome, MenuReject> {
        let mut out = MenuOutcome::default();
        match input {
            MenuInput::Show { kind, item_ids, item_count, multiple } => {
                if let Some(old) = self.open.take() {
                    out.effects.push(MenuEffect::ChromeCancel { token: old.token });
                    out.effects.push(MenuEffect::ViewerCancel { token: old.token });
                }
                let token = self.next_token;
                self.next_token += 1;
                self.open = Some(OpenMenu { token, kind, item_ids, item_count, multiple });
                out.effects.push(MenuEffect::ViewerShow { token });
            }
            MenuInput::Result { token, choice } => match &self.open {
                Some(open) if open.token == token => {
                    if !choice_is_valid(open, &choice) {
                        return Err(MenuReject::InvalidChoice);
                    }
                    self.open = None;
                    out.effects.push(MenuEffect::ChromeContinue { token, choice });
                }
                _ if token != 0 && token < self.next_token => out.note = Some(MenuNote::Duplicate),
                _ => return Err(MenuReject::UnknownToken),
            },
            MenuInput::PageCancel { token } => match &self.open {
                Some(open) if open.token == token => {
                    self.open = None;
                    out.effects.push(MenuEffect::ViewerCancel { token });
                }
                _ => out.note = Some(MenuNote::Stale),
            },
            MenuInput::ViewerGone => {
                if let Some(open) = self.open.take() {
                    out.effects.push(MenuEffect::ChromeContinue {
                        token: open.token,
                        choice: MenuChoice::Cancel,
                    });
                }
            }
        }
        Ok(out)
    }
}

fn choice_is_valid(open: &OpenMenu, choice: &MenuChoice) -> bool {
    match (open.kind, choice) {
        (_, MenuChoice::Cancel) => true,
        (MenuKind::Context, MenuChoice::Command { id }) => open.item_ids.contains(id),
        (MenuKind::Select, MenuChoice::Indices { indices }) => {
            let count_ok = open.multiple || indices.len() == 1;
            let in_range = indices.iter().all(|&i| i < open.item_count);
            let mut sorted = indices.clone();
            sorted.sort_unstable();
            sorted.dedup();
            count_ok && in_range && sorted.len() == indices.len()
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_never_repeat() {
        let mut m = MenuTokens::default();
        let mut seen = Vec::new();
        for _ in 0..5 {
            let out = m
                .apply(MenuInput::Show {
                    kind: MenuKind::Context,
                    item_ids: vec![1],
                    item_count: 0,
                    multiple: false,
                })
                .unwrap();
            let Some(MenuEffect::ViewerShow { token }) = out.effects.last().cloned() else {
                panic!("no show effect");
            };
            assert!(!seen.contains(&token));
            seen.push(token);
        }
    }
}
