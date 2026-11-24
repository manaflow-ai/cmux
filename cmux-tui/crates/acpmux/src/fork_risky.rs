//! Fork before a risky step (RFD 0163 row 25, on RFD 0168's machine fork), behind the hidden
//! setting `cloud.autoCloud` (default off).
//!
//! When a chat on a Cloud machine asks to run a step that is hard to undo (a force push, a hard
//! reset, a recursive remove of the checkout, a database migration, or anything the hand's own
//! destructive classifier refuses on a Mac), its `permission_request` carries a `forkOffer`
//! (`{machine, reason, clientKey}`). The person's "Fork first" answers the request with
//! `forkFirst: true` (`_acpmux/permission_respond`): the daemon forks its own machine (memory and
//! disk, cmux-platform `POST /v1/machines/{id}/fork`, the `machine.fork` call sub VMs use), logs
//! `fork_checkpoint` with the copy's id and how long the fork took, and only then lets the step
//! run here. The copy stays as the checkpoint: the state before the step, running, which the
//! person can open or go back to. A fork that fails leaves the request waiting, so the person can
//! still allow it without one, or refuse it.
//!
//! Only the decision and the classifier live here, pure, so the tests need no machine.

use serde_json::{Value, json};
use std::time::Instant;

/// The longest `clientKey` cmux-platform takes for a fork.
const MAX_CLIENT_KEY: usize = 128;

/// Why `request` (a `session/request_permission`'s params) is a step worth a checkpoint, or None.
/// Only a shell call is judged: an edit is undone by the agent's own file history.
pub fn risky(request: &Value) -> Option<String> {
    let call = request.get("toolCall")?;
    let kind = call.get("kind").and_then(Value::as_str).unwrap_or("");
    let script = script(call)?;
    if !kind.is_empty() && kind != "execute" {
        return None;
    }
    risky_script(&script)
}

/// The shell script a tool call runs: `rawInput.command` as a string, or an argv (the script of
/// `bash -lc SCRIPT`, else the words joined). A call with neither is not judged.
fn script(call: &Value) -> Option<String> {
    match call.pointer("/rawInput/command").or_else(|| call.pointer("/rawInput/cmd"))? {
        Value::String(s) => Some(s.clone()),
        Value::Array(argv) => {
            let words: Vec<&str> = argv.iter().filter_map(Value::as_str).collect();
            let shell = words.first().map(|w| w.rsplit('/').next().unwrap_or(w));
            let dash_c = words.get(1).is_some_and(|f| f.starts_with('-') && f.ends_with('c'));
            if matches!(shell, Some("bash" | "sh" | "zsh")) && dash_c && words.len() == 3 {
                Some(words[2].to_owned())
            } else {
                Some(words.join(" "))
            }
        }
        _ => None,
    }
}

/// Why one shell script is risky, or None.
pub fn risky_script(script: &str) -> Option<String> {
    let argv: Vec<String> = script.split_whitespace().map(str::to_owned).collect();
    if let Some(why) = crate::hand::policy::destructive_exec_reason(&argv, dirs::home_dir()) {
        return Some(why);
    }
    // One command at a time: `a && b; c | d`.
    for cmd in script.split(['&', ';', '|', '\n']) {
        let words: Vec<&str> = cmd
            .split_whitespace()
            .map(|w| w.trim_matches(|c| c == '"' || c == '\''))
            .filter(|w| !w.is_empty())
            .collect();
        if let Some(why) = risky_words(&words) {
            return Some(why);
        }
    }
    let upper = script.to_ascii_uppercase();
    for sql in ["DROP TABLE", "DROP DATABASE", "DROP SCHEMA", "TRUNCATE "] {
        if upper.contains(sql) {
            return Some(format!("{} drops data", sql.trim()));
        }
    }
    None
}

fn risky_words(words: &[&str]) -> Option<String> {
    // Skip `sudo`, `env A=B`, `npx`, `bunx`, `pnpm exec` and the like before the program.
    let mut i = 0;
    while let Some(w) = words.get(i) {
        let base = w.rsplit('/').next().unwrap_or(w);
        if matches!(base, "sudo" | "env" | "npx" | "bunx" | "time" | "nice" | "exec")
            || (w.contains('=') && !w.starts_with('-'))
        {
            i += 1;
        } else {
            break;
        }
    }
    let words = &words[i..];
    let base = words.first().map(|w| w.rsplit('/').next().unwrap_or(w))?;
    let rest = &words[1..];
    let has = |f: &str| rest.contains(&f);
    let sub = |n: usize| rest.get(n).copied().unwrap_or("");
    match base {
        "git" => {
            // `git -C DIR push`: the subcommand is the first word that is not an option or its value.
            let mut j = 0;
            while j < rest.len() && rest[j].starts_with('-') {
                j += if matches!(rest[j], "-C" | "-c") { 2 } else { 1 };
            }
            let cmd = rest.get(j).copied().unwrap_or("");
            let args = rest.get(j + 1..).unwrap_or(&[]);
            let arg = |f: &str| args.contains(&f);
            match cmd {
                "push"
                    if arg("--force")
                        || arg("-f")
                        || args.iter().any(|a| {
                            a.starts_with("--force-with-lease")
                                || a.starts_with("--mirror")
                                || a.starts_with("+")
                                || *a == "--delete"
                                || *a == "-d"
                        }) =>
                {
                    Some("git push rewrites or deletes a remote branch".into())
                }
                "reset" if arg("--hard") => Some("git reset --hard drops uncommitted work".into()),
                "clean" if args.iter().any(|a| a.starts_with('-') && a.contains('f')) => {
                    Some("git clean removes untracked files".into())
                }
                "checkout" | "restore" if arg(".") => {
                    Some(format!("git {cmd} . drops uncommitted edits"))
                }
                "branch" if arg("-D") => Some("git branch -D deletes a branch".into()),
                "stash" if matches!(args.first().copied(), Some("drop" | "clear")) => {
                    Some("git stash drop loses stashed work".into())
                }
                "filter-branch" | "filter-repo" => Some(format!("git {cmd} rewrites history")),
                "rebase" => Some("git rebase rewrites history".into()),
                _ => None,
            }
        }
        "rm" => {
            let recursive = rest.iter().any(|a| {
                a.starts_with('-') && !a.starts_with("--") && (a.contains('r') || a.contains('R'))
                    || *a == "--recursive"
            });
            let checkout = rest.iter().any(|a| {
                matches!(*a, "." | "./" | "*" | "./*" | ".git" | "./.git" | ".." | "../")
                    || a.ends_with("/.git")
            });
            (recursive && checkout).then(|| "rm -r removes the checkout or its history".into())
        }
        // Database migrations.
        "prisma" if sub(0) == "migrate" || (sub(0) == "db" && sub(1) == "push") => {
            Some(format!("prisma {} changes the database", sub(0)))
        }
        "drizzle-kit" if matches!(sub(0), "push" | "migrate") => {
            Some(format!("drizzle-kit {} changes the database", sub(0)))
        }
        "rails" | "rake" if sub(0).starts_with("db:") => {
            Some(format!("{base} {} changes the database", sub(0)))
        }
        "alembic" if matches!(sub(0), "upgrade" | "downgrade") => {
            Some(format!("alembic {} changes the database", sub(0)))
        }
        "sqlx" | "diesel" | "knex" | "sequelize" | "typeorm" | "goose" | "migrate" | "dbmate"
            if rest.iter().any(|a| a.contains("migrat") || matches!(*a, "up" | "down" | "run")) =>
        {
            Some(format!("{base} runs a database migration"))
        }
        "python" | "python3"
            if has("manage.py") && rest.iter().any(|a| *a == "migrate" || *a == "flush") =>
        {
            Some("manage.py changes the database".into())
        }
        "terraform" | "tofu" if matches!(sub(0), "apply" | "destroy") => {
            Some(format!("{base} {} changes infrastructure", sub(0)))
        }
        "kubectl" if matches!(sub(0), "delete" | "apply") => {
            Some(format!("kubectl {} changes a cluster", sub(0)))
        }
        "npm" | "pnpm" | "yarn" | "bun"
            if rest.iter().any(|a| a.contains("migrate") || a.starts_with("db:")) =>
        {
            Some(format!("{base} runs a database migration"))
        }
        _ => None,
    }
}

/// The offer a `permission_request` carries, or None: the setting off, the chat not on a Cloud
/// machine, or the step not risky. `permission` names the request, so a retried "Fork first"
/// answers the same copy, never a second one.
pub fn offer(
    enabled: bool,
    machine: Option<&str>,
    request: &Value,
    permission: &str,
) -> Option<Value> {
    if !enabled {
        return None;
    }
    let machine = machine.map(str::trim).filter(|m| valid_machine(m))?;
    let reason = risky(request)?;
    let client_key: String = format!("risky-{permission}").chars().take(MAX_CLIENT_KEY).collect();
    Some(json!({"machine": machine, "reason": reason, "clientKey": client_key}))
}

/// The offer for a request on this daemon now: the setting as the settings file says it, the
/// machine as the Cloud image says it (`CMUX_VM_ID`).
pub fn offer_here(request: &Value, permission: &str) -> Option<Value> {
    let enabled = crate::placement::auto_cloud_on();
    if !enabled {
        return None;
    }
    offer(true, crate::placement::sub_fork::this_machine().as_deref(), request, permission)
}

/// Carry out an offer with `machines`: fork, and answer the `fork_checkpoint` record.
pub async fn fork_first<M: crate::placement::sub_fork::Machines>(
    machines: &M,
    offer: &Value,
    permission: &str,
) -> Result<Value, String> {
    let machine = offer["machine"].as_str().ok_or("the offer names no machine")?;
    let key = offer["clientKey"].as_str().ok_or("the offer has no clientKey")?;
    let started = Instant::now();
    let fork = machines.fork(machine, key).await?;
    let ms = started.elapsed().as_millis() as u64;
    Ok(json!({
        "permissionId": permission,
        "machine": machine,
        "fork": fork,
        "forkMs": ms,
        "reason": offer["reason"],
    }))
}

/// A path-safe machine id: 1 to 64 of letters, digits, `_` and `-`.
fn valid_machine(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

#[cfg(test)]
#[path = "fork_risky_tests.rs"]
mod tests;
