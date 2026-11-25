//! The rules of the cmux NEXT Cloud action handlers (`cloud …` on the CLI, the
//! palette's and the machine menus' Cloud actions), in Rust so the macOS app
//! keeps only the platform work (Leo, 2026-11-06: "ok we need to go all hands
//! on deck here. don't just do baby steps. we can just... do it"). Pure: no I/O.
//!
//! The app reads the facts (the invocation's arguments, its machine models, the
//! Cloud API's answers), asks here, and acts on the answer: the sheet, the tab,
//! the API call, the localized refusal. Served over the app FFI's JSON channel
//! (`cmux-layout-reducer-ffi`, ops `cloud_handler_*`).
//!
//! - [`args`]: every argument check of the Cloud actions, with its refusal.
//! - [`decide`]: which machine a run means, what New Cloud Workspace and New
//!   Cloud Machine do, how a creation settles, which desktop viewer opens,
//!   the diagnostics summary, the team switch and the destructive prompts.
//! - [`fields`]: the `action.run` result fields of the machine actions.
//! - [`answers`]: the text and fields of the actions whose answer someone reads.
//! - [`repo`]: the `--repo` spec parser, which refuses a login or token in the URL.
//!
//! A refusal is a [`Said`]: a key the app turns into its localized text (the
//! words stay in the app's string tables), with the values it names.

pub mod answers;
pub mod args;
pub mod decide;
pub mod fields;
pub mod repo;
mod said;
pub mod time;

pub use said::Said;

/// `action.run` result fields: a JSON object.
pub type Fields = serde_json::Map<String, serde_json::Value>;
