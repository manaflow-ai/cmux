//! An OptChat Chief for cmux-next Home. It keeps the brain-host contract of
//! `mux/host` (the app starts it through `CMUX_NEXT_MUX_HOST`, it holds the
//! same kernel lock, talks to the conversation owner as `agent_mux` and to
//! acpmux), and replaces the long-lived `mux` session with Victor Taelin's
//! OptChat turn loop: every turn is a fresh acpmux session that reads the
//! OptChat view, and everything it does is logged into the memory.
//! Section numbers in comments refer to the OptChat specification.

pub mod acpmux;
pub mod acpmux_daemon;
pub mod agents;
pub mod brain;
pub mod cli;
pub mod daemon;
pub mod fold;
pub mod host;
pub mod lock;
pub mod log;
pub mod mcp;
pub mod paths;
pub mod prompt;
pub mod rpc;
pub mod session_dir;
pub mod state;
pub mod tools;
pub mod turn;
