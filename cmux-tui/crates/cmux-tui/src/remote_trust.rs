//! `cmux remote trust`: what each paired peer may do on this machine.
//!
//! Records are local to this machine and never set by the peer. Nothing
//! remote consults them yet; `machine.session.request` will.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::anyhow;
use cmux_remote::identity::default_state_dir;
use cmux_remote::peer_trust::{
    AuditDecision, PeerAgent, PeerTrust, PeerTrustBook, TrustTier, read_audit,
};

use crate::localization::catalog;

const MAX_EXPIRY_HOURS: u64 = 24 * 365;
const DEFAULT_AUDIT_LIMIT: usize = 50;
const MAX_AUDIT_LIMIT: usize = 10_000;

#[derive(Debug, PartialEq, Eq)]
enum Action {
    List,
    Set { fingerprint: String, tier: TrustTier },
    Forget { fingerprint: String },
    Audit,
}

#[derive(Debug, PartialEq, Eq)]
struct TrustArgs {
    action: Action,
    folders: Vec<PathBuf>,
    agents: Vec<PeerAgent>,
    expires_in: Option<Duration>,
    limit: usize,
    state_dir: Option<PathBuf>,
    json: bool,
}

pub(crate) fn run(args: &[String]) -> anyhow::Result<()> {
    let parsed = parse_args(args)?;
    let messages = &catalog().peer_trust;
    let root = parsed
        .state_dir
        .clone()
        .or_else(default_state_dir)
        .ok_or_else(|| anyhow!(catalog().remote_client.known_state_dir_unavailable))?;
    match parsed.action {
        Action::List => {
            let book = PeerTrustBook::load(&root)?;
            if parsed.json {
                println!("{}", serde_json::to_string_pretty(book.peers())?);
            } else if book.peers().is_empty() {
                println!("{}", messages.empty);
            } else {
                for peer in book.peers() {
                    print_peer(peer);
                }
            }
        }
        Action::Set { fingerprint, tier } => {
            if tier != TrustTier::None && (parsed.folders.is_empty() || parsed.agents.is_empty()) {
                return Err(anyhow!(messages.grant_needs_scope));
            }
            let folders = parsed
                .folders
                .iter()
                .map(|folder| allowed_folder(folder))
                .collect::<anyhow::Result<Vec<_>>>()?;
            let now = now_unix();
            let peer = PeerTrust {
                fingerprint,
                tier,
                folders,
                agents: parsed.agents,
                expires_at_unix: parsed.expires_in.map(|duration| now + duration.as_secs()),
                updated_at_unix: now,
            };
            let fingerprint = peer.fingerprint.clone();
            // The stored record has its folders resolved; print that one.
            let peer = PeerTrustBook::update(&root, |book| {
                book.set(peer)?;
                Ok(book.get(&fingerprint).cloned())
            })?
            .ok_or_else(|| anyhow!(messages.not_known(&fingerprint)))?;
            if parsed.json {
                println!("{}", serde_json::to_string_pretty(&peer)?);
            } else {
                print_peer(&peer);
            }
        }
        Action::Forget { fingerprint } => {
            if !PeerTrustBook::update(&root, |book| Ok(book.forget(&fingerprint)))? {
                return Err(anyhow!(messages.not_known(&fingerprint)));
            }
            if parsed.json {
                println!(
                    "{}",
                    serde_json::json!({ "forgotten": true, "fingerprint": fingerprint })
                );
            } else {
                println!("{}", messages.forgotten(&fingerprint));
            }
        }
        Action::Audit => {
            let entries = read_audit(&root, parsed.limit)?;
            if parsed.json {
                println!("{}", serde_json::to_string_pretty(&entries)?);
            } else if entries.is_empty() {
                println!("{}", messages.audit_empty);
            } else {
                for entry in entries {
                    let decision = match entry.decision {
                        AuditDecision::Refused(reason) => {
                            format!("refused:{}", kebab(&reason))
                        }
                        other => kebab(&other),
                    };
                    println!(
                        "{}\t{}\t{}\t{}\t{}\t{}",
                        entry.at_unix,
                        entry.peer,
                        entry.method,
                        entry.agent.map(PeerAgent::as_str).unwrap_or("-"),
                        entry
                            .cwd
                            .as_deref()
                            .map(Path::display)
                            .map(|cwd| cwd.to_string())
                            .unwrap_or_else(|| "-".into()),
                        decision
                    );
                }
            }
        }
    }
    Ok(())
}

fn print_peer(peer: &PeerTrust) {
    let agents = peer.agents.iter().map(|agent| agent.as_str()).collect::<Vec<_>>().join(",");
    let expires = peer.expires_at_unix.map(|at| at.to_string()).unwrap_or_else(|| "-".into());
    println!(
        "{}\t{}\t{}\t{}",
        peer.fingerprint,
        kebab(&peer.tier),
        if agents.is_empty() { "-".into() } else { agents },
        expires
    );
    for folder in &peer.folders {
        println!("  {}", folder.display());
    }
}

fn kebab(value: &impl serde::Serialize) -> String {
    match serde_json::to_value(value) {
        Ok(serde_json::Value::String(text)) => text,
        Ok(serde_json::Value::Object(object)) => object
            .get("decision")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        _ => String::new(),
    }
}

/// Resolves a folder through symlinks and refuses the filesystem root, the
/// home folder and its ancestors: a grant names a project, not the account.
fn allowed_folder(folder: &Path) -> anyhow::Result<PathBuf> {
    let invalid = || anyhow!(catalog().peer_trust.invalid_folder(&folder.display().to_string()));
    let resolved = std::fs::canonicalize(folder).map_err(|_| invalid())?;
    if !resolved.is_dir() || resolved.parent().is_none() {
        return Err(invalid());
    }
    let home = std::env::var_os("HOME").and_then(|home| std::fs::canonicalize(home).ok());
    if home.is_some_and(|home| home.starts_with(&resolved)) {
        return Err(invalid());
    }
    Ok(resolved)
}

fn now_unix() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|elapsed| elapsed.as_secs()).unwrap_or(0)
}

fn parse_args(args: &[String]) -> anyhow::Result<TrustArgs> {
    let client = &catalog().remote_client;
    let mut positionals = Vec::new();
    let mut tier = None;
    let mut folders = Vec::new();
    let mut agents = Vec::new();
    let mut expires_in = None;
    let mut limit = None;
    let mut state_dir = None;
    let mut json = false;
    let mut index = 0;
    while index < args.len() {
        let argument = args[index].as_str();
        index += 1;
        let mut value = |option: &str| -> anyhow::Result<String> {
            let value = args
                .get(index)
                .filter(|value| !value.starts_with("--"))
                .ok_or_else(|| anyhow!(client.option_needs_value(option)))?;
            index += 1;
            Ok(value.clone())
        };
        match argument {
            "--json" if !json => json = true,
            "--state-dir" if state_dir.is_none() => {
                state_dir = Some(PathBuf::from(value("--state-dir")?));
            }
            "--tier" if tier.is_none() => {
                tier = Some(match value("--tier")?.as_str() {
                    "none" => TrustTier::None,
                    "ask" => TrustTier::Ask,
                    "folders" => TrustTier::Folders,
                    _ => {
                        return Err(anyhow!(
                            client.invalid_option_value("--tier", "none|ask|folders")
                        ));
                    }
                });
            }
            "--folder" => folders.push(PathBuf::from(value("--folder")?)),
            "--agent" => {
                let agent = PeerAgent::parse(&value("--agent")?).ok_or_else(|| {
                    anyhow!(client.invalid_option_value("--agent", "claude|codex|opencode|pi"))
                })?;
                if !agents.contains(&agent) {
                    agents.push(agent);
                }
            }
            "--expires-in-hours" if expires_in.is_none() => {
                let hours = value("--expires-in-hours")?
                    .parse::<u64>()
                    .ok()
                    .filter(|hours| (1..=MAX_EXPIRY_HOURS).contains(hours))
                    .ok_or_else(|| {
                        anyhow!(client.invalid_option_value("--expires-in-hours", "1-8760"))
                    })?;
                expires_in = Some(Duration::from_secs(hours * 3600));
            }
            "--limit" if limit.is_none() => {
                limit = Some(
                    value("--limit")?
                        .parse::<usize>()
                        .ok()
                        .filter(|limit| (1..=MAX_AUDIT_LIMIT).contains(limit))
                        .ok_or_else(|| {
                            anyhow!(client.invalid_option_value("--limit", "1-10000"))
                        })?,
                );
            }
            "--json" | "--state-dir" | "--tier" | "--expires-in-hours" | "--limit" => {
                return Err(anyhow!(client.option_once(argument)));
            }
            option if option.starts_with('-') => {
                return Err(anyhow!(client.unknown_option_for_command(option, "trust")));
            }
            positional => positionals.push(positional.to_owned()),
        }
    }
    let messages = &catalog().peer_trust;
    let action = match positionals.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        [] | ["list"] => Action::List,
        ["audit"] => Action::Audit,
        ["set", fingerprint] => Action::Set {
            fingerprint: (*fingerprint).to_owned(),
            tier: tier.ok_or_else(|| anyhow!(client.option_needs_value("--tier")))?,
        },
        ["forget", fingerprint] => Action::Forget { fingerprint: (*fingerprint).to_owned() },
        [action, ..] if matches!(*action, "set" | "forget" | "list" | "audit") => {
            return Err(anyhow!(messages.help));
        }
        [action, ..] => return Err(anyhow!(client.unknown_action("trust", action))),
    };
    let set = matches!(action, Action::Set { .. });
    if !set && (tier.is_some() || !folders.is_empty() || !agents.is_empty() || expires_in.is_some())
    {
        return Err(anyhow!(messages.help));
    }
    if limit.is_some() && action != Action::Audit {
        return Err(anyhow!(messages.help));
    }
    Ok(TrustArgs {
        action,
        folders,
        agents,
        expires_in,
        limit: limit.unwrap_or(DEFAULT_AUDIT_LIMIT),
        state_dir,
        json,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn set_parses_tier_folders_agents_and_expiry() {
        let parsed = parse_args(&strings(&[
            "set",
            "AAAAAAAAAAAAAAAAAAAAAA",
            "--tier",
            "folders",
            "--folder",
            "/src/api",
            "--agent",
            "claude",
            "--agent",
            "claude",
            "--expires-in-hours",
            "2",
        ]))
        .unwrap();
        assert_eq!(
            parsed.action,
            Action::Set { fingerprint: "AAAAAAAAAAAAAAAAAAAAAA".into(), tier: TrustTier::Folders }
        );
        assert_eq!(parsed.folders, vec![PathBuf::from("/src/api")]);
        assert_eq!(parsed.agents, vec![PeerAgent::Claude]);
        assert_eq!(parsed.expires_in, Some(Duration::from_secs(7200)));
    }

    #[test]
    fn invalid_trust_arguments_are_rejected() {
        for args in [
            vec!["set", "fp"],
            vec!["set", "fp", "--tier", "shell"],
            vec!["set", "fp", "--tier", "ask", "--agent", "bash"],
            vec!["set", "fp", "--tier", "ask", "--expires-in-hours", "0"],
            vec!["list", "--tier", "ask"],
            vec!["forget"],
            vec!["audit", "--limit", "0"],
            vec!["list", "--limit", "5"],
            vec!["--json", "--json"],
            vec!["--folder"],
            vec!["grant", "fp"],
            vec!["--unknown"],
        ] {
            assert!(parse_args(&strings(&args)).is_err(), "accepted {args:?}");
        }
    }

    #[test]
    fn the_filesystem_root_and_home_are_not_allowed_folders() {
        assert!(allowed_folder(Path::new("/")).is_err());
        if let Some(home) = std::env::var_os("HOME") {
            assert!(allowed_folder(Path::new(&home)).is_err());
        }
        assert!(allowed_folder(Path::new("/definitely/missing/cmux-trust")).is_err());
        let project = tempfile::tempdir().unwrap();
        assert_eq!(
            allowed_folder(project.path()).unwrap(),
            std::fs::canonicalize(project.path()).unwrap()
        );
    }
}
