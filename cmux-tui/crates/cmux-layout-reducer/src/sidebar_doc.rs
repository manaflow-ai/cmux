//! The sidebar document (`sidebar-doc-v1`, sidebar rewrite slice S2): one
//! per-user document of ordered sections that hold ordered items. A machine's
//! workspace list, Pinned, custom sections, app sections and the built-in
//! bands are all sections; a workspace or a group is placed exactly once.
//!
//! Pure, no I/O. The home daemon stores the document and commits every op
//! with [`reduce::apply`]; the app's mirror (cmux-layout-reducer-ffi) folds
//! its pending intents with the same function, so the row the app shows is
//! the row the daemon will store.
//!
//! - [`model`]: sections, items, bodies, the wire ops and the refusal codes.
//! - [`doc`]: the document and its indexes (id, sibling lists, refs).
//! - [`order_key`]: fractional order keys.
//! - [`reduce`]: the reducer, in place, with the inverse ops for undo.
//! - [`check`]: the invariants (the touched rows per op; all at open).
//! - [`view`]: the flat rows one window draws.
//! - [`accept`]: the drop acceptance table of one drag.
//! - [`reset`]: the default sections again, and removal by old layout ref.
//! - [`migrate`]: the one-time move from the old sidebar stores.

pub mod accept;
pub mod check;
pub mod doc;
pub mod migrate;
pub mod model;
pub mod order_key;
pub mod reduce;
pub mod reset;
pub mod view;

pub use doc::Doc;
pub use model::*;

#[cfg(test)]
mod nesting_tests;
