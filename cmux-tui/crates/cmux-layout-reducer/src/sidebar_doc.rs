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
//! - [`model`]: sections, items, bodies, the wire ops, the refusal codes and
//!   their text (`Refusal::text`, `change_failure_text`).
//! - [`doc`]: the document and its indexes (id, sibling lists, refs).
//! - [`order_key`]: fractional order keys.
//! - [`reduce`]: the reducer, in place, with the inverse ops for undo.
//! - `stale`: each op rebased onto the document as it is now (a gone item drops
//!   out, a gone target falls back), so a stale op is never refused.
//! - [`check`]: the invariants (the touched rows per op; all at open).
//! - [`view`]: the flat rows one window draws.
//! - [`view_cache`]: one window's view kept between changes: a change
//!   rebuilds the blocks (top-level trees) it touches, not every row.
//! - [`project`]: those rows as the sections the app's list draws.
//! - [`plan`]: the ops of New Subgroup and of a remote group, planned on the document.
//! - [`accept`]: the drop acceptance table of one drag.
//! - [`reset`]: the default sections again, and removal by old layout ref.
//! - [`migrate`]: the one-time move from the old sidebar stores.

pub mod accept;
mod archive;
#[cfg(test)]
mod archive_group_tests;
#[cfg(test)]
mod archive_tests;
pub mod check;
pub mod doc;
pub mod migrate;
pub mod model;
#[cfg(test)]
mod nested_pin_tests;
pub mod order_key;
#[cfg(test)]
mod pin_tests;
pub mod plan;
pub mod project;
#[cfg(test)]
mod project_tests;
pub mod reduce;
#[cfg(test)]
mod refusal_text_tests;
pub mod reset;
#[cfg(test)]
mod scale_tests;
mod stale;
#[cfg(test)]
mod stale_tests;
pub mod view;
pub mod view_cache;
#[cfg(test)]
mod view_cache_tests;
pub mod view_splice;

#[cfg(test)]
mod host_group_tests;
#[cfg(test)]
mod nested_group_tests;

pub use doc::Doc;
pub use model::*;
