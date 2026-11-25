//! What the model sees of a window, the same on every platform:
//!
//! - [`ids`]: small integer element ids that stay the same across trees of a
//!   window for the same element, mapped back to the desktop's own ids. An id
//!   that is not in the window's latest tree is refused with a clear error,
//!   never guessed.
//! - [`outline`]: the compact text form of a tree, one line per element
//!   (`[12] button "Save" cmd+s disabled`), with structural containers folded.
//! - [`diff`]: after an agent's first look at a window, every later look
//!   (get_ui_tree, or the state an action returns) is the change since its
//!   last one: `+` added, `~` changed (with what it was), `-` removed. An
//!   unchanged window says so, so a model cannot take an action that did
//!   nothing for one that worked.
//! - [`guards`]: checks before an action that would do nothing or the wrong
//!   thing (a disabled element, a title bar, typing with no text focus, an
//!   element scrolled out of view), refused with what to do instead.

pub mod diff;
pub mod guards;
pub mod ids;
pub mod outline;

/// A stable 64-bit hash of a platform id that already names the same object
/// across walks (AT-SPI object paths), for [`crate::desktop::Element::identity`].
/// FNV-1a, so it is the same in every process.
pub fn hash_identity(id: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in id.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h
}

/// How a look is shown, from a call's arguments.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Look {
    /// `format: "json"`: the tree as JSON (`root`), every element, no diff.
    pub json: bool,
    /// `full: true`: the whole outline even after a first look, elements
    /// scrolled out of view included.
    pub full: bool,
    /// `frames: true`: each line ends with its frame in screenshot pixels.
    pub frames: bool,
    /// `menus: true`: every menu bar menu's items, not only the menu titles.
    pub menus: bool,
}

impl Look {
    pub fn from_args(args: &serde_json::Value) -> Self {
        let flag = |k: &str| args.get(k).and_then(serde_json::Value::as_bool) == Some(true);
        Self {
            json: args.get("format").and_then(serde_json::Value::as_str) == Some("json"),
            full: flag("full"),
            frames: flag("frames"),
            menus: flag("menus"),
        }
    }

    pub fn outline_options(&self) -> outline::Options {
        outline::Options {
            frames: self.frames,
            menus: self.menus,
            offscreen: self.full,
            ..outline::Options::default()
        }
    }
}

#[cfg(test)]
#[path = "observe_tests.rs"]
mod tests;
