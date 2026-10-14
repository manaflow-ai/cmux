//! Vendor adapters: which processes are coding-agent runtimes, and their
//! role. A process is recognized by its executable name, or by the script a
//! `node`/`bun` launcher runs, never by its terminal.

use serde::Serialize;

use crate::process_inventory::InventoryProcess;

/// The agent a runtime belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Vendor {
    Codex,
    Claude,
    Opencode,
}

/// What a runtime does for its agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    /// The interactive CLI a user runs.
    Cli,
    /// A non-interactive run (`codex exec`, `claude -p`).
    Task,
    /// A server one client started for itself.
    Server,
    /// A background server shared by several clients (Codex's managed
    /// app-server daemon).
    SharedServer,
    /// A background updater.
    Updater,
    /// A `node`/`bun` launcher that runs the agent's real executable.
    Launcher,
}

impl Role {
    pub(super) fn is_client(self) -> bool {
        matches!(self, Self::Cli | Self::Task | Self::Launcher)
    }

    pub(super) fn is_server(self) -> bool {
        matches!(self, Self::Server | Self::SharedServer)
    }
}

/// The vendor and role of an agent process, or `None` for any other one.
pub fn recognize(process: &InventoryProcess) -> Option<(Vendor, Role)> {
    let args: Vec<&str> = process.args.iter().skip(1).map(String::as_str).collect();
    if let Some(vendor) = launched_script(process) {
        return Some((vendor, Role::Launcher));
    }
    let name = process.name.as_str();
    let exe = process.exe.as_deref().unwrap_or_default();
    if name == "codex" || name.starts_with("codex-") {
        return Some((Vendor::Codex, codex_role(&args)));
    }
    // The native installer names the binary after its version, under
    // `.../claude/versions/<version>`.
    if name == "claude" || exe.contains("/claude/versions/") {
        return Some((Vendor::Claude, claude_role(&args)));
    }
    if name == "opencode" || name == ".opencode" {
        return Some((Vendor::Opencode, opencode_role(&args)));
    }
    None
}

/// The vendor of the script a `node`/`bun` process runs.
fn launched_script(process: &InventoryProcess) -> Option<Vendor> {
    if !matches!(process.name.as_str(), "node" | "bun") {
        return None;
    }
    let script = process.args.get(1)?;
    if script.contains("/@openai/codex/") {
        Some(Vendor::Codex)
    } else if script.contains("/@anthropic-ai/claude-code/") {
        Some(Vendor::Claude)
    } else if script.contains("/opencode-ai/") {
        Some(Vendor::Opencode)
    } else {
        None
    }
}

fn codex_role(args: &[&str]) -> Role {
    match args.first().copied() {
        Some("app-server") if args.contains(&"--managed-daemon") => Role::SharedServer,
        Some("app-server" | "mcp-server") => Role::Server,
        Some("pid-update-loop") => Role::Updater,
        Some("exec" | "e") => Role::Task,
        _ => Role::Cli,
    }
}

fn claude_role(args: &[&str]) -> Role {
    if args.first() == Some(&"mcp") && args.get(1) == Some(&"serve") {
        Role::Server
    } else if args.iter().any(|arg| matches!(*arg, "-p" | "--print")) {
        Role::Task
    } else {
        Role::Cli
    }
}

fn opencode_role(args: &[&str]) -> Role {
    match args.first().copied() {
        Some("serve" | "acp") => Role::Server,
        Some("run") => Role::Task,
        _ => Role::Cli,
    }
}

/// The version the install layout names, when it names one.
pub(super) fn version(vendor: Vendor, process: &InventoryProcess) -> Option<String> {
    let exe = process.exe.as_deref()?;
    match vendor {
        Vendor::Claude => {
            let version = exe.split_once("/claude/versions/")?.1.split('/').next()?;
            version.starts_with(|c: char| c.is_ascii_digit()).then(|| version.to_string())
        }
        Vendor::Codex | Vendor::Opencode => None,
    }
}
