//! The turn sessions' working directory, written once per host start: every
//! turn runs in it, so the harness sees the same CLAUDE.md, settings and MCP
//! servers each time (section 7.2: byte-identical prompt and tools).
//!
//! A turn should see only what this directory holds (section 7: a fresh call,
//! nothing carried over; section 7.2: MASTER, then VIEW_DOC, then the
//! instructions at the end). The turn sessions' acpmux preset points
//! `CLAUDE_CONFIG_DIR` at `optchat/claude`, whose settings turn auto-memory
//! off and hold no hooks, so the user's own ~/.claude/CLAUDE.md, settings,
//! hooks and project memory never reach a turn. What stays outside our
//! control: Claude Code's own system prompt (with its date and environment
//! lines) and any machine-wide managed settings.
//!
//! Deviation: acpmux drops `mcpServers` from `session/new` (it always starts
//! the agent with `[]`), so mux/host's way of passing MCP servers reaches no
//! harness. The servers go in the directory's `.mcp.json` instead, enabled
//! by the project settings, which Claude Code harnesses read.

use std::collections::BTreeMap;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use serde_json::{Value, json};

use crate::paths::Paths;
use crate::prompt::claude_md;

/// What the session directory is made of.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionSetup {
    /// This executable (absolute), which serves `mcp` and the `chief` launcher.
    pub exe: String,
    /// `CMUX_MCP_COMMAND`: the cmux binary whose `mcp serve` is the cmux MCP server.
    pub cmux_mcp: Option<String>,
    /// Env the turn's tools see (MUX_HOME, CMUX_SOCKET_PATH, ACPMUX_*, PATH).
    pub env: BTreeMap<String, String>,
    /// The user's instructions file, read at host start (section 7.2).
    pub instructions: Option<String>,
}

pub fn shell_quote(value: &str) -> String {
    let plain = !value.is_empty()
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_./:@=-".contains(&b));
    if plain {
        value.to_owned()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
}

/// The `.mcp.json` of the session directory.
pub fn mcp_json(setup: &SessionSetup, paths: &Paths) -> Value {
    let mut servers = serde_json::Map::new();
    servers.insert(
        "optchat".into(),
        json!({"type": "stdio", "command": setup.exe, "args": ["mcp", "--socket", paths.tools_socket.to_string_lossy()], "env": {}}),
    );
    if let Some(cmux) = &setup.cmux_mcp {
        servers.insert(
            "cmux".into(),
            json!({"type": "stdio", "command": cmux, "args": ["mcp", "serve"], "env": {}}),
        );
    }
    json!({"mcpServers": servers})
}

/// The project settings: the MCP servers above enabled, the tools' env with
/// the launcher directory first on PATH, and Claude Code's subagents denied.
pub fn settings_json(setup: &SessionSetup, paths: &Paths) -> Value {
    let mut names = vec!["optchat"];
    if setup.cmux_mcp.is_some() {
        names.push("cmux");
    }
    let mut env: serde_json::Map<String, Value> = setup
        .env
        .iter()
        .map(|(k, v)| (k.clone(), Value::String(v.clone())))
        .collect();
    let path = setup
        .env
        .get("PATH")
        .map_or("/usr/bin:/bin", String::as_str);
    env.insert(
        "PATH".into(),
        Value::String(format!("{}:{path}", paths.bin.display())),
    );
    // Claude Code's own subagents (Task/Agent) stream their steps through the
    // same session as the turn, and acpmux's translator cannot tell them
    // apart, so they would land in the log as the Chief's own (section 9:
    // a subagent's tool calls stay in its own session). The Chief starts
    // agents with `chief agents`, whose reports come back as `[name]` messages.
    json!({
        "enableAllProjectMcpServers": true,
        "enabledMcpjsonServers": names,
        "env": env,
        "permissions": {"deny": TURN_DENIED_TOOLS},
    })
}

/// Tools a turn session never offers: Claude Code's own subagents (above),
/// and the tools that wait for a human (a question, plan mode), which
/// acpmux keeps for a human under every policy and nobody answers in a
/// turn, so one call would hang the turn until its limit.
pub const TURN_DENIED_TOOLS: [&str; 5] = [
    "Task",
    "Agent",
    "AskUserQuestion",
    "EnterPlanMode",
    "ExitPlanMode",
];

/// Days Claude Code keeps a turn session's transcript in the isolated
/// configuration (the memory is the record; these only help debugging).
pub const TURN_TRANSCRIPT_DAYS: u64 = 2;

/// `bin/chief`: runs this executable with the host's env baked in, because
/// the harness runs tools in the acpmux daemon's environment, not the host's.
pub fn launcher(setup: &SessionSetup) -> String {
    let mut text = String::from("#!/bin/sh\n");
    for (key, value) in &setup.env {
        if key != "PATH" {
            text.push_str(&format!("{key}={}; export {key}\n", shell_quote(value)));
        }
    }
    text.push_str(&format!("exec {} \"$@\"\n", shell_quote(&setup.exe)));
    text
}

/// The isolated Claude Code configuration's user settings: no auto-memory
/// (continuity is the view alone), no hooks, no extra memory files, and a
/// short transcript retention (each turn's transcript holds the whole view).
pub fn claude_settings() -> Value {
    json!({"autoMemoryEnabled": false, "hooks": {}, "cleanupPeriodDays": TURN_TRANSCRIPT_DAYS})
}

/// The env of the turn sessions' acpmux preset.
pub fn isolation_env(paths: &Paths) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    env.insert(
        "CLAUDE_CONFIG_DIR".to_owned(),
        paths.claude_config.display().to_string(),
    );
    env.insert("CLAUDE_CODE_DISABLE_AUTO_MEMORY".to_owned(), "1".to_owned());
    env
}

/// Writes the directory; a file is rewritten only when its bytes differ.
pub fn write(paths: &Paths, setup: &SessionSetup) -> io::Result<()> {
    std::fs::create_dir_all(paths.session.join(".claude"))?;
    std::fs::create_dir_all(&paths.bin)?;
    write_if_changed(
        &paths.session.join("CLAUDE.md"),
        claude_md(setup.instructions.as_deref()).as_bytes(),
    )?;
    let pretty = |v: &Value| format!("{}\n", serde_json::to_string_pretty(v).expect("json"));
    write_if_changed(
        &paths.session.join(".mcp.json"),
        pretty(&mcp_json(setup, paths)).as_bytes(),
    )?;
    let settings = pretty(&settings_json(setup, paths));
    write_if_changed(
        &paths.session.join(".claude").join("settings.json"),
        settings.as_bytes(),
    )?;
    // The same switches in the local project settings, which some harness
    // versions read for MCP approval instead of the shared file.
    write_if_changed(
        &paths.session.join(".claude").join("settings.local.json"),
        settings.as_bytes(),
    )?;
    std::fs::create_dir_all(&paths.claude_config)?;
    write_if_changed(
        &paths.claude_config.join("settings.json"),
        pretty(&claude_settings()).as_bytes(),
    )?;
    let chief = paths.bin.join("chief");
    write_if_changed(&chief, launcher(setup).as_bytes())?;
    std::fs::set_permissions(&chief, std::fs::Permissions::from_mode(0o755))?;
    Ok(())
}

/// Replaces `path` through a temporary file, so a reader never sees half a file.
pub fn write_if_changed(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if std::fs::read(path).is_ok_and(|old| old == bytes) {
        return Ok(());
    }
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> SessionSetup {
        let mut env = BTreeMap::new();
        env.insert("MUX_HOME".to_string(), "/h".to_string());
        env.insert("PATH".to_string(), "/usr/bin".to_string());
        SessionSetup {
            exe: "/x/optchat-chief".into(),
            cmux_mcp: Some("/x/cmux".into()),
            env,
            instructions: None,
        }
    }

    #[test]
    fn files_are_byte_stable_across_writes() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::new(dir.path());
        paths.create().unwrap();
        write(&paths, &setup()).unwrap();
        let first = std::fs::read(paths.session.join("CLAUDE.md")).unwrap();
        let modified = std::fs::metadata(paths.session.join("CLAUDE.md"))
            .unwrap()
            .modified()
            .unwrap();
        write(&paths, &setup()).unwrap();
        assert_eq!(
            std::fs::read(paths.session.join("CLAUDE.md")).unwrap(),
            first
        );
        assert_eq!(
            std::fs::metadata(paths.session.join("CLAUDE.md"))
                .unwrap()
                .modified()
                .unwrap(),
            modified,
            "an unchanged file is not rewritten"
        );
        assert_eq!(first, claude_md(None).as_bytes());
        let mcp: Value =
            serde_json::from_slice(&std::fs::read(paths.session.join(".mcp.json")).unwrap())
                .unwrap();
        assert_eq!(mcp["mcpServers"]["optchat"]["args"][0], "mcp");
        assert_eq!(mcp["mcpServers"]["cmux"]["args"], json!(["mcp", "serve"]));
        // Audit round 2: Claude Code's own subagents would stream their
        // steps into the turn's events (section 9: they stay out of the log);
        // the Chief starts agents with `chief agents` instead.
        let settings: Value = serde_json::from_slice(
            &std::fs::read(paths.session.join(".claude").join("settings.json")).unwrap(),
        )
        .unwrap();
        // Audit round 3, M3: acpmux keeps questions and plan approval for a
        // human under every policy, and nobody answers them in a turn.
        assert_eq!(
            settings["permissions"]["deny"],
            json!([
                "Task",
                "Agent",
                "AskUserQuestion",
                "EnterPlanMode",
                "ExitPlanMode"
            ])
        );
        // Audit round 3, M6: turn transcripts are kept a short while only.
        let user: Value = serde_json::from_slice(
            &std::fs::read(paths.claude_config.join("settings.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(user["cleanupPeriodDays"], TURN_TRANSCRIPT_DAYS);
        let launcher = std::fs::read_to_string(paths.bin.join("chief")).unwrap();
        assert!(launcher.contains("MUX_HOME=/h; export MUX_HOME\n"));
        assert!(launcher.ends_with("exec /x/optchat-chief \"$@\"\n"));
    }

    #[test]
    fn quoting() {
        assert_eq!(shell_quote("/a/b"), "/a/b");
        assert_eq!(shell_quote("a b'c"), "'a b'\\''c'");
    }
}
