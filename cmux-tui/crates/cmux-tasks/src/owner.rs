//! `owner_for`: where a team's Tasks owner lives, and who the local caller is.
//!
//! Today every team resolves to the local dev owner (`cmux-tasks serve` or
//! the CLI's in-process mode under the store lock). When `TeamVmDO` reports
//! a team VM, `resolve` returns `Owner::TeamVm` and clients go through the
//! API Worker instead; that path belongs to the team VM lead and is not
//! wired yet (UNVERIFIED in plans/cmux-next/tasks.md).

use std::env;
use std::path::PathBuf;

use cmux_tasks_core::ids::{AgentClass, AgentRef, Principal, is_valid_id, prefix};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalOwner {
    pub team: String,
    pub dir: PathBuf,
    pub socket: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Owner {
    Local(LocalOwner),
    /// Routed through the API Worker and `TeamVmDO` (not implemented here).
    TeamVm { team: String },
}

pub const DEFAULT_TEAM: &str = "local";

fn state_root() -> PathBuf {
    if let Some(dir) = env::var_os("CMUX_TASKS_HOME") {
        return PathBuf::from(dir);
    }
    let home = env::var_os("HOME").map(PathBuf::from).unwrap_or_else(env::temp_dir);
    if cfg!(target_os = "macos") {
        home.join("Library/Application Support/cmux/tasks")
    } else if let Some(xdg) = env::var_os("XDG_STATE_HOME") {
        PathBuf::from(xdg).join("cmux/tasks")
    } else {
        home.join(".local/state/cmux/tasks")
    }
}

fn valid_team(team: &str) -> bool {
    !team.is_empty() && team.len() <= 64 && team.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// Resolve the owner of `team` (default `local`). `data_dir` overrides the
/// store directory (tests, explicit `--data`).
pub fn resolve(team: Option<&str>, data_dir: Option<PathBuf>) -> Result<Owner, String> {
    let team = team.unwrap_or(DEFAULT_TEAM);
    if !valid_team(team) {
        return Err(format!("invalid team name: {team}"));
    }
    let dir = data_dir.unwrap_or_else(|| state_root().join(team));
    let socket = dir.join("tasks.sock");
    Ok(Owner::Local(LocalOwner { team: team.to_owned(), dir, socket }))
}

/// The local caller. Locally the trust boundary is the user (same uid, a
/// 0700 store directory and socket), like the control socket: an agent
/// process states its principal through `CMUX_AGENT_PRINCIPAL` (set by
/// acpmux), everyone else acts as the local person. Remote owners take the
/// actor from the authenticated connection instead.
pub fn local_actor() -> Principal {
    let person = env::var("CMUX_TASKS_USER")
        .ok()
        .filter(|u| is_valid_id(u, prefix::USER))
        .unwrap_or_else(|| {
            let name: String = env::var("USER")
                .unwrap_or_else(|_| "me".to_owned())
                .to_ascii_lowercase()
                .chars()
                .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
                .collect();
            format!("{}{}", prefix::USER, if name.is_empty() { "me".to_owned() } else { name })
        });
    match env::var("CMUX_AGENT_PRINCIPAL") {
        Ok(agent) if is_valid_id(&agent, prefix::AGENT) => Principal::Agent(AgentRef {
            principal: agent,
            class: match env::var("CMUX_AGENT_CLASS").as_deref() {
                Ok("mux") => AgentClass::Mux,
                _ => AgentClass::Ordinary,
            },
            harness: env::var("CMUX_AGENT_HARNESS").unwrap_or_else(|_| "unknown".to_owned()),
            on_behalf_of: person,
        }),
        _ => Principal::user(person),
    }
}

/// Mint a time-ordered public id: `<prefix><ms base36><8 random base36>`.
pub fn mint(prefix: &str) -> String {
    const ALPHABET: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    let mut time = Vec::new();
    while ms > 0 {
        time.push(ALPHABET[(ms % 36) as usize]);
        ms /= 36;
    }
    time.reverse();
    let mut random = [0u8; 8];
    let _ = getrandom::fill(&mut random);
    let tail: String = random.iter().map(|b| ALPHABET[usize::from(*b) % 36] as char).collect();
    format!("{prefix}{}{tail}", String::from_utf8_lossy(&time))
}
