//! `acpmux-mcp-relay`: the agent tool relay as a program of its own
//! (`mcp_relay.rs`), linked without the acpmux library so it stays under 1 MB.

// The names only acpmux reads (the program name, the hello for `cmux mcp serve`).
#[allow(dead_code)]
#[path = "mcp_relay.rs"]
mod mcp_relay;

#[cfg(unix)]
fn main() -> std::process::ExitCode {
    match mcp_relay::main() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("acpmux-mcp-relay: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

/// Windows: the daemon tool servers stay stdio servers (`agent_tools.rs`).
#[cfg(not(unix))]
fn main() -> std::process::ExitCode {
    eprintln!("acpmux-mcp-relay: unix only");
    std::process::ExitCode::FAILURE
}
