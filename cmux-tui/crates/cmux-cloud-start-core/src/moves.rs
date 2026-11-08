//! Move to Cloud, Bring Back Local and a chat start's machine steps: the rules the app's
//! `CmuxNextCloud` once kept in Swift around the cmux-tui CLIs it runs (`link/sync_cli.rs`,
//! `link/agent_cli.rs`, `link/start_chat_cli.rs`). Pure: the app runs the process, reads the
//! disk and the defaults, and asks here what the output means and what to do next. Served over
//! the app FFI's JSON channel as ops `cloud_move_*` (`cmux-layout-reducer-ffi/src/cloud_move.rs`).

pub mod autosize;
pub mod cli;
pub mod folder;
pub mod ledger;
pub mod pin;
pub mod seed;
pub mod wait;
