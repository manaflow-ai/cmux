//! The first-run state matrix: a capture fixture named by the agent CLIs a
//! person has and their sign-in, instead of a hand-written file
//! (`ACPMUX_HARNESS_FIXTURE=matrix:CELL`). Leo, 2026-11-12: "the combination,
//! the matrix of states where it's, like, okay, does somebody have Claude,
//! Codex, Cursor, Grok, Gemini, whatever? ... We need to, like, actually
//! properly, like, click through and utilize every single thing."
//!
//! A cell is a named cell (`CELLS`) or a list `agent=state,...`:
//!
//! ```text
//! matrix:none                               a new Mac: no agent CLI at all
//! matrix:leo-2026-11-12                     Claude and Codex expired, Antigravity and OpenCode signed in
//! matrix:claude=signedIn,cursor=signedOut   any combination
//! ```
//!
//! Agents: `claude`, `codex`, `cursor`, `grok`, `gemini`, `antigravity`,
//! `opencode` (`AGENTS`). States: `signedIn`, `signedOut`, `expired`,
//! `unknown` (installed, sign-in not provable: a keychain login), or
//! `absent` (not installed, the same as leaving it out). Each agent present
//! is the profile discovery would add for it (`config/discover.rs`, the ACP
//! Registry for Antigravity) and a health row in its state, so the daemon,
//! and every surface reading it, sees that person's agents. As with a file,
//! nothing about these harnesses is read from the host or updated, and each
//! program is a path under `FIXTURE_BIN`, so one never starts the host's own
//! CLI. Discovery's other harnesses (the bundled ones, Codex's aliases) are
//! not part of a cell.

use std::collections::BTreeMap;

use crate::config::{HarnessKind, HarnessProfile};
use crate::harness_health::channel::Channel;
use crate::harness_health::{Auth, HarnessHealth};

use super::Fixture;

/// What the variable starts with to name a cell instead of a file.
pub const PREFIX: &str = "matrix:";

/// Where a cell's programs claim to live: a folder no Mac has.
pub const FIXTURE_BIN: &str = "/opt/fixture/bin";

/// One agent CLI as discovery finds it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Agent {
    /// The name a cell uses.
    pub name: &'static str,
    /// The harness id the catalog lists it under.
    pub id: &'static str,
    pub kind: HarnessKind,
    /// The program and the arguments discovery starts it with.
    pub argv: &'static [&'static str],
    pub channel: Channel,
    pub package: Option<&'static str>,
    /// The command its health card offers to sign in.
    pub login: &'static str,
}

/// Every agent a cell can name, in the order Leo named them.
pub const AGENTS: &[Agent] = &[
    Agent {
        name: "claude",
        id: "claude",
        kind: HarnessKind::ClaudeStdio,
        argv: &["claude"],
        channel: Channel::Native,
        package: None,
        login: "claude auth login",
    },
    Agent {
        name: "codex",
        id: "codex",
        kind: HarnessKind::Acp,
        argv: &["codex", "app-server"],
        channel: Channel::Npm,
        package: Some("@openai/codex"),
        login: "codex login",
    },
    Agent {
        name: "cursor",
        id: "cursor",
        kind: HarnessKind::Acp,
        argv: &["cursor-agent", "acp"],
        channel: Channel::Native,
        package: None,
        login: "cursor-agent login",
    },
    Agent {
        name: "grok",
        id: "grok",
        kind: HarnessKind::Acp,
        argv: &["grok", "agent", "stdio"],
        channel: Channel::Native,
        package: None,
        login: "grok login",
    },
    Agent {
        name: "gemini",
        id: "gemini",
        kind: HarnessKind::Acp,
        argv: &["gemini", "--experimental-acp"],
        channel: Channel::Npm,
        package: Some("@google/gemini-cli"),
        login: "gemini",
    },
    Agent {
        name: "antigravity",
        id: "antigravity",
        kind: HarnessKind::Acp,
        argv: &["agy_acp_server.par"],
        channel: Channel::Standalone,
        package: None,
        login: "cmux harness login antigravity",
    },
    Agent {
        name: "opencode",
        id: "opencode",
        kind: HarnessKind::Acp,
        argv: &["opencode", "acp"],
        channel: Channel::Npm,
        package: Some("opencode-ai"),
        login: "opencode auth login",
    },
];

/// The named cells: the first-run states worth clicking through by name.
pub const CELLS: &[(&str, &str)] = &[
    // A new Mac: nothing to start a chat with.
    ("none", ""),
    // Leo's Mac on 2026-11-12: "I only really have Claude and Codex, but,
    // like, they're expired right now ... I do have Anti-Gravity, and I do
    // have Open Code."
    ("leo-2026-11-12", "claude=expired,codex=expired,antigravity=signedIn,opencode=signedIn"),
    ("claude-only", "claude=signedIn"),
    ("codex-only", "codex=signedIn"),
    // Installed, never signed in: the first launch after `npm i -g`.
    (
        "all-signed-out",
        "claude=signedOut,codex=signedOut,cursor=signedOut,grok=signedOut,gemini=signedOut,antigravity=signedOut,opencode=signedOut",
    ),
    (
        "all-expired",
        "claude=expired,codex=expired,cursor=expired,grok=expired,gemini=expired,antigravity=expired,opencode=expired",
    ),
    (
        "all-signed-in",
        "claude=signedIn,codex=signedIn,cursor=signedIn,grok=signedIn,gemini=signedIn,antigravity=signedIn,opencode=signedIn",
    ),
    // Installed with a keychain login acpmux never reads: sign-in unknown.
    (
        "all-unknown",
        "claude=unknown,codex=unknown,cursor=unknown,grok=unknown,gemini=unknown,antigravity=unknown,opencode=unknown",
    ),
];

/// An agent's state in a cell; None is absent.
fn state(word: &str) -> Result<Option<Auth>, String> {
    Ok(Some(match word {
        "absent" => return Ok(None),
        "signedIn" => Auth::SignedIn,
        "signedOut" => Auth::SignedOut,
        "expired" => Auth::Expired,
        "unknown" => Auth::Unknown,
        other => {
            return Err(format!(
                "unknown state `{other}` (absent, signedIn, signedOut, expired, unknown)"
            ));
        }
    }))
}

/// The agents a cell names with their states, in `AGENTS` order; absent
/// agents are left out.
pub fn parse(cell: &str) -> Result<Vec<(&'static Agent, Auth)>, String> {
    let spec = CELLS.iter().find(|(name, _)| *name == cell).map_or(cell, |(_, spec)| *spec);
    let mut chosen: BTreeMap<usize, Option<Auth>> = BTreeMap::new();
    for pair in spec.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let (name, word) = pair.split_once('=').ok_or_else(|| {
            let names: Vec<_> = CELLS.iter().map(|(name, _)| *name).collect();
            format!("`{pair}` is neither agent=state nor a named cell ({})", names.join(", "))
        })?;
        let at = AGENTS.iter().position(|a| a.name == name.trim()).ok_or_else(|| {
            let names: Vec<_> = AGENTS.iter().map(|a| a.name).collect();
            format!("unknown agent `{}` ({})", name.trim(), names.join(", "))
        })?;
        if chosen.insert(at, state(word.trim())?).is_some() {
            return Err(format!("`{}` is named twice", name.trim()));
        }
    }
    Ok(chosen.into_iter().filter_map(|(at, auth)| Some((&AGENTS[at], auth?))).collect())
}

/// The fixture a cell describes.
pub fn fixture(cell: &str) -> Result<Fixture, String> {
    let mut fixture = Fixture::default();
    for (agent, auth) in parse(cell)? {
        let program = agent.argv[0];
        // The row's path, never a bare name: a chat started on a cell's harness fails to
        // start instead of finding this host's real CLI on PATH, signed in as its owner.
        let path = format!("{FIXTURE_BIN}/{program}");
        let argv = std::iter::once(path.clone())
            .chain(agent.argv[1..].iter().map(|a| (*a).to_owned()))
            .collect();
        fixture.harnesses.insert(
            agent.id.to_owned(),
            HarnessProfile {
                kind: agent.kind,
                argv,
                env: BTreeMap::new(),
                description: Some("found on PATH".into()),
                fallback: None,
                family: None,
                models: vec![],
                model: None,
                effort: None,
                policy: None,
            },
        );
        let detail = match auth {
            Auth::SignedIn => "matrix: signed in",
            Auth::SignedOut => "matrix: not signed in",
            Auth::Expired => "matrix: credential expired",
            Auth::Unknown => "matrix: sign-in not provable without the keychain",
        };
        fixture.health.push(HarnessHealth {
            id: agent.id.to_owned(),
            program: program.to_owned(),
            path: Some(path),
            channel: agent.channel,
            package: agent.package.map(str::to_owned),
            version: Some("1.0.0".into()),
            latest: Some("1.0.0".into()),
            latest_checked_at: Some(1),
            outdated: false,
            auth,
            auth_detail: Some(detail.into()),
            login: Some(agent.login.to_owned()),
            update: None,
            problem: None,
            checked_at: 1,
            auto_update: false,
            last_auto_update: None,
        });
    }
    Ok(fixture)
}

#[cfg(test)]
mod tests;
