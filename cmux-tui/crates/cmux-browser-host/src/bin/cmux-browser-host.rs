//! `cmux-browser-host`: the browser host until `cmux browser host` exists in
//! the Rust cmux binary (#16174).
//!
//!   cmux-browser-host serve [--socket PATH]
//!   cmux-browser-host eval [--session NAME] [--engine E] [--max-output N] [--timeout-ms N] (-|CODE)
//!   cmux-browser-host list | close --session NAME | guide | version
//!
//! `eval` starts the host on demand when no host answers on the socket.
//! MCP clients use `cmux mcp serve` (one MCP entry point, cmux.json
//! mcp.enabled); this binary has no MCP server.
//!
//! The macOS app ships it as `Contents/Resources/bin/cmux-browser-host`,
//! beside `bin/cmux`: the daemon runs the sibling of its own executable
//! (scripts/cmux-next/bundle-cmux-tui.sh, check-bundled-browser-host.sh).

#[cfg(unix)]
fn main() {
    std::process::exit(cmux_browser_host::cli::run(std::env::args().skip(1).collect()));
}

#[cfg(not(unix))]
fn main() {
    eprintln!("cmux-browser-host needs a Unix host");
    std::process::exit(2);
}
