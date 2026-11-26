//! The cmux NEXT app's small agent-side rules, pure: the app reads its
//! models and the daemon's answers, sends the facts here over the app FFI
//! (`cmux-layout-reducer-ffi` ops `app_agents_*`) and acts on the answer.
//!
//! - [`subagent_limit`]: Subagent Limit… (`_acpmux/subsession/limits`).
//! - [`closed`]: the New Tab page's Recently Closed rows.
//! - [`new_tab`]: `newTab.submit`'s plan from the field's intent.
//! - [`control`]: control session qualifier names.
//! - [`apps`]: which runs reach an app, and provider registration refusals.
//! - [`chat_key`]: acpmux's `<harness>:<session id>` chat keys.

pub mod apps;
pub mod chat_key;
pub mod closed;
pub mod control;
pub mod new_tab;
pub mod subagent_limit;
