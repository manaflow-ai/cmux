//! An existing VM or server reached over SSH: "move this server".
//!
//! The CLI runs [`PROBE`] on the host (`ssh HOST sh -s < PROBE`, read-only, bounded) and hands
//! its output to [`plan`]; nothing here opens a connection. The same probe reads any box a
//! competitor makes SSH-reachable (`coder.<ws>`, `<vm>.exe.xyz`, `devpod ssh <ws>`:
//! [`super::competitors::route`]).

use std::collections::BTreeMap;

use serde_json::Value;

use super::detect::setup_for;
use crate::plan::{
    Agent, Carry, CarryKind, Plan, Project, Repo, Source, SourceKind, Unsupported, machine_name,
    strip_login,
};

/// One POSIX sh script, run as `ssh HOST sh -s < PROBE`. Read-only; every command has a timeout
/// (where the host has `timeout`) and reads `/dev/null`; checkouts at most 4 levels under `$HOME`,
/// at most 200. Prints one JSON object per line, `{"t":KIND,...}` with string values, and never a
/// file's contents: dotfiles and agent logins are named with their sizes only.
pub const PROBE: &str = include_str!("ssh_probe.sh");

/// The disk a new machine gets before `cloud resize-machine --disk` (the small size's 16 GiB in
/// the plan allowance); a host whose code is bigger is warned to grow it.
pub const DEFAULT_DISK_BYTES: u64 = 16 * 1024 * 1024 * 1024;

const GIB: f64 = 1024.0 * 1024.0 * 1024.0;

/// One probe line: its kind and its fields.
struct Fact {
    kind: String,
    fields: BTreeMap<String, String>,
}

impl Fact {
    fn get(&self, key: &str) -> Option<&str> {
        self.fields.get(key).map(String::as_str).filter(|v| !v.is_empty())
    }
    fn num(&self, key: &str) -> u64 {
        self.get(key).and_then(|v| v.trim().parse().ok()).unwrap_or(0)
    }
}

fn parse_line(line: &str) -> Option<Fact> {
    let Value::Object(map) = serde_json::from_str::<Value>(line.trim()).ok()? else {
        return None;
    };
    let mut fields = BTreeMap::new();
    let mut kind = None;
    for (k, v) in map {
        let v = match v {
            Value::String(s) => s,
            Value::Number(n) => n.to_string(),
            Value::Bool(b) => b.to_string(),
            _ => continue,
        };
        if k == "t" {
            kind = Some(v);
        } else {
            fields.insert(k, v);
        }
    }
    Some(Fact { kind: kind?, fields })
}

/// The plan for an SSH host from [`PROBE`]'s output. `host_label` is what the person typed (an
/// `~/.ssh/config` alias, `user@host`); it names the source and the ledger namespace.
pub fn plan(host_label: &str, probe_output: &str) -> Plan {
    let mut plan = Plan::new(Source {
        kind: SourceKind::SshHost,
        label: host_label.to_owned(),
        id: format!("ssh:{host_label}"),
    });
    let mut facts = Vec::new();
    let mut unreadable = 0usize;
    for line in probe_output.lines().filter(|l| !l.trim().is_empty()) {
        match parse_line(line) {
            Some(f) => facts.push(f),
            None => unreadable = unreadable.saturating_add(1),
        }
    }
    if unreadable > 0 {
        plan.warnings.push(format!(
            "{unreadable} probe line(s) from {host_label} were not readable and were skipped"
        ));
    }
    if !facts.iter().any(|f| f.kind == "done") {
        plan.warnings.push(format!(
            "the probe on {host_label} did not finish (a timeout or a dropped connection): this \
             plan may be missing projects; run it again"
        ));
    }

    let tools: Vec<String> = facts
        .iter()
        .filter(|f| f.kind == "tool")
        .filter_map(|f| {
            let name = f.get("name")?;
            Some(match f.get("version") {
                Some(v) => format!("{name} ({v})"),
                None => name.to_owned(),
            })
        })
        .collect();

    for f in facts.iter().filter(|f| f.kind == "os") {
        if f.get("os") == Some("Darwin") {
            plan.warnings.push(format!(
                "{host_label} is a Mac; AutoCloud machines run Linux, so macOS-only tools \
                 (Xcode, brew casks) do not come along"
            ));
        }
        if let Some(arch) = f.get("arch")
            && !matches!(arch, "x86_64" | "amd64" | "aarch64" | "arm64")
        {
            plan.warnings.push(format!(
                "{host_label} is {arch}; AutoCloud machines are x86_64 or arm64, so binaries built \
                 there must be rebuilt"
            ));
        }
    }

    let mut repo_bytes = 0u64;
    for f in facts.iter().filter(|f| f.kind == "repo") {
        let Some(path) = f.get("path") else { continue };
        let files: Vec<&str> = f
            .get("files")
            .map(|s| s.split(',').filter(|x| !x.is_empty()).collect())
            .unwrap_or_default();
        let bytes = f.num("bytes");
        repo_bytes = repo_bytes.saturating_add(bytes);
        let repo = Repo {
            url: f.get("url").map(strip_login),
            branch: f.get("branch").filter(|b| *b != "HEAD").map(str::to_owned),
            commit: f
                .get("commit")
                .filter(|c| c.len() >= 7 && c.chars().all(|ch| ch.is_ascii_hexdigit()))
                .map(str::to_owned),
            path: Some(path.to_owned()),
            dirty_files: u32::try_from(f.num("dirty")).unwrap_or(u32::MAX),
            unpushed_commits: u32::try_from(f.num("unpushed")).unwrap_or(u32::MAX),
        };
        let base = path.trim_end_matches('/').rsplit('/').next().unwrap_or(path);
        let mut project = Project {
            key: path.to_owned(),
            name: machine_name(base),
            machine: Default::default(),
            checked: true,
            ..Default::default()
        };
        project.machine.setup = setup_for(&files);
        if files.iter().any(|f| f.contains("devcontainer")) {
            project.notes.push(
                "has a devcontainer: the devcontainer reader fills its setup from the clone".into(),
            );
        }
        if files.iter().any(|f| f.starts_with("docker-compose") || f.starts_with("compose.")) {
            project.notes.push("has a compose file: the compose reader adds its services".into());
        }
        if files.iter().any(|f| matches!(*f, "flake.nix" | "shell.nix" | "devbox.json")) {
            project.notes.push("has a Nix or devbox environment: the Nix reader adds it".into());
        }
        if files.contains(&".cmux/machine.toml") {
            project.notes.push("already has a .cmux/machine.toml: it is used as is".into());
        }
        if !tools.is_empty() {
            project.notes.push(format!("{host_label} had {}", tools.join(", ")));
        }
        if repo.url.is_none() {
            plan.warnings.push(format!(
                "{path} on {host_label} has no remote: its whole tree is carried as a git bundle"
            ));
        } else if repo.dirty_files > 0 || repo.unpushed_commits > 0 {
            plan.warnings.push(format!(
                "{path} on {host_label} has {} uncommitted file(s) and {} unpushed commit(s): they \
                 are carried as a git bundle",
                repo.dirty_files, repo.unpushed_commits
            ));
        }
        if bytes > DEFAULT_DISK_BYTES {
            plan.warnings.push(format!(
                "{path} is {:.1} GiB, more than a new machine's {:.0} GiB disk: grow it with \
                 `cloud resize-machine --disk`",
                bytes as f64 / GIB,
                DEFAULT_DISK_BYTES as f64 / GIB
            ));
        }
        project.repo = Some(repo);
        plan.projects.push(project);
    }
    if repo_bytes > DEFAULT_DISK_BYTES && plan.projects.len() > 1 {
        plan.warnings.push(format!(
            "the checkouts on {host_label} total {:.1} GiB, more than one machine's {:.0} GiB \
             disk: each project gets its own machine, but grow any that share one",
            repo_bytes as f64 / GIB,
            DEFAULT_DISK_BYTES as f64 / GIB
        ));
    }

    // Containers: a compose project's go to the repo it runs from, the rest are named.
    let mut loose_containers = Vec::new();
    for f in facts.iter().filter(|f| f.kind == "container") {
        let Some(name) = f.get("name") else { continue };
        let image = f.get("image").unwrap_or("?");
        let ports = f.get("ports").map(host_ports).unwrap_or_default();
        let owner = f.get("dir").and_then(|dir| {
            plan.projects.iter_mut().find(|p| {
                dir == p.key || dir.starts_with(&format!("{}/", p.key.trim_end_matches('/')))
            })
        });
        match owner {
            Some(project) => {
                project.services.push(format!("{name} ({image})"));
                for port in ports {
                    if !project.ports.contains(&port) {
                        project.ports.push(port);
                    }
                }
            }
            None => loose_containers.push(format!("{name} ({image})")),
        }
    }
    if !loose_containers.is_empty() {
        plan.warnings.push(format!(
            "{host_label} runs container(s) outside any checkout: {}; recreate them in a \
             project's [setup] (docker run) if a project needs them",
            loose_containers.join(", ")
        ));
    }

    let units: Vec<&str> =
        facts.iter().filter(|f| f.kind == "unit").filter_map(|f| f.get("name")).collect();
    if !units.is_empty() {
        plan.warnings.push(format!(
            "{host_label} runs systemd user service(s): {}; start the ones a project needs from \
             its [setup]",
            units.join(", ")
        ));
    }

    let claimed: Vec<u16> = plan.projects.iter().flat_map(|p| p.ports.iter().copied()).collect();
    let listening: Vec<String> = facts
        .iter()
        .filter(|f| f.kind == "listen")
        .filter_map(|f| f.get("port")?.parse::<u16>().ok())
        .filter(|p| *p != 22 && *p != 53 && !claimed.contains(p))
        .map(|p| p.to_string())
        .collect();
    if !listening.is_empty() {
        plan.warnings.push(format!(
            "{host_label} listens on port(s) {} that no project claims: whatever serves them is \
             not moved",
            listening.join(", ")
        ));
    }

    let cron: u64 = facts.iter().filter(|f| f.kind == "cron").map(|f| f.num("lines")).sum();
    if cron > 0 {
        plan.unsupported.push(Unsupported {
            what: "cron jobs".into(),
            why: "become AutoCloud automations: see automations-and-webhooks".into(),
        });
        plan.warnings.push(format!("{host_label} has {cron} crontab line(s); they are not moved"));
    }

    for f in facts.iter().filter(|f| f.kind == "dotfile") {
        let Some(path) = f.get("path") else { continue };
        let (kind, agent) = match path {
            "~/.zshrc" | "~/.bashrc" | "~/.profile" => (CarryKind::Shell, None),
            "~/.gitconfig" => (CarryKind::GitConfig, None),
            "~/.config/nvim" => (CarryKind::Editor, None),
            "~/.ssh/config" => (CarryKind::SshConfig, None),
            "~/.claude" => (CarryKind::AgentSettings, Some(Agent::Claude)),
            "~/.codex" => (CarryKind::AgentSettings, Some(Agent::Codex)),
            "~/.claude/.credentials.json" => (CarryKind::AgentLogin, Some(Agent::Claude)),
            "~/.codex/auth.json" => (CarryKind::AgentLogin, Some(Agent::Codex)),
            _ => continue,
        };
        plan.carry.push(Carry {
            kind,
            path: path.to_owned(),
            bytes: f.num("bytes"),
            agent,
            checked: true,
        });
    }
    plan
}

/// The host-side ports of `docker ps`'s Ports column (`0.0.0.0:5432->5432/tcp, :::5432->...`).
fn host_ports(column: &str) -> Vec<u16> {
    let mut out = Vec::new();
    for part in column.split(',') {
        let Some((host, _)) = part.split_once("->") else { continue };
        let Some(port) = host.rsplit(':').next().and_then(|p| p.trim().parse::<u16>().ok()) else {
            continue;
        };
        if !out.contains(&port) {
            out.push(port);
        }
    }
    out
}

/// The hosts in an `~/.ssh/config` a person can pick from ("move this server"): every `Host`
/// pattern that names one host (no `*`, `?` or `!`), in file order, once each. `Match` blocks
/// and `Include`d files are not followed.
pub fn ssh_config_hosts(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        let (key, rest) = match line.split_once(|c: char| c.is_whitespace() || c == '=') {
            Some((k, r)) => (k, r.trim_start_matches(|c: char| c.is_whitespace() || c == '=')),
            None => continue,
        };
        if !key.eq_ignore_ascii_case("host") {
            continue;
        }
        let rest = rest.split('#').next().unwrap_or("");
        for pattern in rest.split_whitespace() {
            let pattern = pattern.trim_matches('"');
            if pattern.is_empty() || pattern.contains(['*', '?', '!']) {
                continue;
            }
            if !out.iter().any(|h| h == pattern) {
                out.push(pattern.to_owned());
            }
        }
    }
    out
}

#[cfg(test)]
#[path = "ssh_host_tests.rs"]
mod tests;
