//! The name a cmux NEXT workspace takes, as pure rules the macOS app calls over the app FFI
//! (`cmux_layout_reducer_json`, ops `workspace_naming_*`, [`ops`]):
//!
//! - [`new_name`]: the name a new workspace takes from the tab it starts with or the group it
//!   is made of, and the name a workspace keeps when its last tab moves out.
//! - [`auto_name`]: the live sidebar label of a workspace nobody named, and the generated chat
//!   title variant B persists through the daemon (`workspaces.autoName.variant`).
//! - [`activity`]: Name from Activity's prompt, completion parameters and reply cleanup.
//! - [`hold`]: the last name each tab gave a row, so the row keeps it while that tab's name is
//!   briefly unknown.
//! - [`namer`]: variant B's submission ledger: at most one rename in flight per workspace.
//!
//! The app reads the facts (its models, the turn store, the browser) and applies the result;
//! localized text, timers and observation stay in Swift.

pub mod activity;
pub mod auto_name;
pub mod hold;
pub mod namer;
pub mod new_name;
pub mod ops;
pub mod text;

#[cfg(test)]
mod tests;
