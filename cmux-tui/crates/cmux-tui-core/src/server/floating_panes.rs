//! `floating-panes-v1`: the `float-pane` command and the `Screen.floating`
//! read shape (screen_json.rs).
//!
//! A floating pane stays a leaf of `Screen.layout`; `Screen.floating` names
//! the leaves the tiled layout leaves out, back to front, each with its frame
//! as four fractions of the screen's pane area. A client without the
//! capability ignores the list and shows every pane tiled.

#[cfg(test)]
#[path = "floating_panes_tests.rs"]
mod tests;
