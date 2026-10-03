//! cmux Tasks service (plans/cmux-next/tasks.md): the single writer of a
//! team's Tasks state. The same code runs as the `tasks` app in the team VM
//! and as the local dev owner (`cmux task serve`, or in-process under the
//! store lock when no server runs).

pub mod cli;
pub mod client;
pub mod engine;
pub mod identity;
pub mod owner;
pub mod protocol;
#[cfg(unix)]
pub mod server;
pub mod store;
