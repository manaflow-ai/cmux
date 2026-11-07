//! `cmux agent skills install|uninstall|status [claude|agents ...]`: cmux's own skills in the
//! person's global skill folders, so every agent they start anywhere (a plain terminal, an editor,
//! another app) knows how to drive cmux.
//!
//! Opt-in. cmux never writes these folders by itself: a plain terminal agent gets no cmux skill
//! until the person installs them here, from Settings > Agents > Agent integrations, or with this
//! command (Aziz 2026-11-06: "terminals don't need to have the skills by default, to avoid being
//! intrusive"). Agent chats keep getting the same skills per session as a plugin that touches no
//! global folder (`agent_tools.rs`).
//!
//! - Targets: `claude` is Claude Code's user skills folder (`$CLAUDE_CONFIG_DIR/skills`, else
//!   `~/.claude/skills`); `agents` is the shared `~/.agents/skills` that Codex, OpenCode and other
//!   harnesses following the Agent Skills layout read. `codex` and `opencode` name `agents`.
//! - Skills: the ones that work from any shell through the `cmux` CLI ([`SKILLS`]). The computer
//!   use and chat skills need tools only an agent chat has, so they stay chat-only.
//! - Ownership: each installed folder carries [`MARKER`] with its content hash. Install replaces
//!   only folders with that marker; a folder of the same name without it (the person's own) is a
//!   `conflict` and stays untouched. Uninstall removes only marked folders.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

/// The marker file in each folder this command wrote.
pub const MARKER: &str = ".cmux-skill.json";

/// The skills installed globally, as folder names.
pub const SKILLS: &[&str] = &["cmux", "cmux-browser", "cmux-customization", "acpmux"];

/// The core `cmux` control skill, which agent chats do not carry as a plugin skill.
const CORE_FILES: &[(&str, &str)] = &[
    ("cmux/SKILL.md", include_str!("../../../../skills/cmux/SKILL.md")),
    (
        "cmux/references/handles-and-identify.md",
        include_str!("../../../../skills/cmux/references/handles-and-identify.md"),
    ),
    (
        "cmux/references/panes-surfaces.md",
        include_str!("../../../../skills/cmux/references/panes-surfaces.md"),
    ),
    (
        "cmux/references/trigger-flash-and-health.md",
        include_str!("../../../../skills/cmux/references/trigger-flash-and-health.md"),
    ),
    (
        "cmux/references/windows-workspaces.md",
        include_str!("../../../../skills/cmux/references/windows-workspaces.md"),
    ),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Install,
    Uninstall,
    Status,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    pub action: Action,
    /// `claude`, `agents` (or its names `codex`, `opencode`), `all`; empty means every target.
    pub targets: Vec<String>,
}

#[derive(Debug)]
pub struct RunResult {
    pub value: Value,
    pub failed: bool,
}

/// A global skills folder.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Target {
    id: &'static str,
    dir: PathBuf,
}

/// Where the folders are, from the environment (tests pass their own).
pub struct Env<'a> {
    pub home: Option<PathBuf>,
    pub var: &'a dyn Fn(&str) -> Option<String>,
}

impl Env<'_> {
    fn targets(&self) -> anyhow::Result<Vec<Target>> {
        let home = self.home.clone().ok_or_else(|| anyhow::anyhow!("no home folder"))?;
        let claude = (self.var)("CLAUDE_CONFIG_DIR")
            .map(|v| v.trim().to_owned())
            .filter(|v| !v.is_empty())
            .map(|v| match v.strip_prefix("~/") {
                Some(rest) => home.join(rest),
                None => PathBuf::from(v),
            })
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| home.join(".claude"));
        Ok(vec![
            Target { id: "claude", dir: claude.join("skills") },
            Target { id: "agents", dir: home.join(".agents").join("skills") },
        ])
    }
}

/// The skill files to install, as `(path inside the skills folder, text)`.
pub fn files() -> Vec<(&'static str, &'static str)> {
    let mut out: Vec<(&str, &str)> = CORE_FILES.to_vec();
    out.extend(
        crate::agent_tools::SKILL_FILES
            .iter()
            .filter(|(p, _)| SKILLS.iter().any(|s| *s != "cmux" && p.starts_with(&format!("{s}/"))))
            .copied(),
    );
    out
}

/// One skill's files (paths relative to its folder, in path order) and their content hash.
fn skill_files(skill: &str) -> (Vec<(&'static str, &'static str)>, String) {
    let prefix = format!("{skill}/");
    let mut mine: Vec<(&str, &str)> = files()
        .into_iter()
        .filter_map(|(p, t)| p.strip_prefix(prefix.as_str()).map(|rel| (rel, t)))
        .collect();
    mine.sort_by_key(|(p, _)| *p);
    let hash = content_hash(mine.iter().map(|(p, t)| (*p, t.as_bytes())));
    (mine, hash)
}

/// The hash of `(relative path, bytes)` pairs in path order: what a folder holds.
fn content_hash<'a>(entries: impl Iterator<Item = (&'a str, &'a [u8])>) -> String {
    let mut all = Vec::new();
    for (path, bytes) in entries {
        all.extend_from_slice(path.as_bytes());
        all.push(0);
        all.extend_from_slice(bytes);
        all.push(0);
    }
    crate::sha256::sha256_hex(&all)[..16].to_owned()
}

/// Every regular file under `dir` but the marker, as `(relative path, bytes)` in path order;
/// `None` when the folder holds anything else (a symlink, a special file) or cannot be read.
fn disk_files(dir: &Path) -> Option<Vec<(String, Vec<u8>)>> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, Vec<u8>)>) -> Option<()> {
        for entry in std::fs::read_dir(dir).ok()? {
            let entry = entry.ok()?;
            let path = entry.path();
            let kind = entry.file_type().ok()?;
            if kind.is_dir() {
                walk(root, &path, out)?;
            } else if kind.is_file() {
                let rel = path.strip_prefix(root).ok()?.to_str()?.replace('\\', "/");
                if rel != MARKER {
                    out.push((rel, std::fs::read(&path).ok()?));
                }
            } else {
                return None;
            }
        }
        Some(())
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out)?;
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Some(out)
}

/// One skill folder's state in a target.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SkillState {
    Current,
    Outdated,
    Absent,
    /// Something cmux did not write is at that name.
    NotOwned,
    Symlink,
    NotADirectory,
}

fn skill_state(dir: &Path, hash: &str) -> SkillState {
    let Ok(meta) = std::fs::symlink_metadata(dir) else { return SkillState::Absent };
    if meta.file_type().is_symlink() {
        return SkillState::Symlink;
    }
    if !meta.is_dir() {
        return SkillState::NotADirectory;
    }
    let marker = std::fs::read(dir.join(MARKER))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .filter(|v| v.get("owner").and_then(Value::as_str) == Some("cmux"));
    let Some(written) = marker.as_ref().and_then(|v| v.get("hash")).and_then(Value::as_str) else {
        return SkillState::NotOwned;
    };
    // A folder the person changed since cmux wrote it is theirs now: never replaced or removed.
    let on_disk = disk_files(dir)
        .map(|files| content_hash(files.iter().map(|(p, b)| (p.as_str(), b.as_slice()))));
    if on_disk.as_deref() != Some(written) {
        return SkillState::NotOwned;
    }
    if written == hash { SkillState::Current } else { SkillState::Outdated }
}

fn conflict_reason(state: SkillState) -> Option<&'static str> {
    match state {
        SkillState::NotOwned => Some("not_owned"),
        SkillState::Symlink => Some("symlink"),
        SkillState::NotADirectory => Some("not_a_directory"),
        _ => None,
    }
}

/// Writes `skill` into `root` (a fresh folder renamed into place).
fn install_skill(root: &Path, skill: &str) -> anyhow::Result<()> {
    let (files, hash) = skill_files(skill);
    std::fs::create_dir_all(root)?;
    let tmp = root.join(format!("{TMP_PREFIX}{}-{skill}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    let written = write_skill(root, skill, &tmp, &files, &hash);
    if written.is_err() {
        let _ = std::fs::remove_dir_all(&tmp);
    }
    written
}

/// The folder an install writes before renaming it into place; one left by a run that died is
/// removed by the next install.
const TMP_PREFIX: &str = ".cmux-skill-tmp-";

/// Removes temporary folders an earlier install left in `root`.
fn remove_stale_tmp(root: &Path) {
    let Ok(entries) = std::fs::read_dir(root) else { return };
    for entry in entries.flatten() {
        let is_dir = entry.file_type().is_ok_and(|t| t.is_dir());
        if is_dir && entry.file_name().to_string_lossy().starts_with(TMP_PREFIX) {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

fn write_skill(
    root: &Path,
    skill: &str,
    tmp: &Path,
    files: &[(&str, &str)],
    hash: &str,
) -> anyhow::Result<()> {
    {
        for (rel, text) in files {
            let file = tmp.join(rel);
            if let Some(parent) = file.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&file, text)?;
            #[cfg(unix)]
            if rel.ends_with(".sh") {
                use std::os::unix::fs::PermissionsExt as _;
                std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755))?;
            }
        }
        let marker = json!({
            "owner": "cmux",
            "skill": skill,
            "hash": hash,
            "note": "Installed by `cmux agent skills install`; `cmux agent skills uninstall` removes it.",
        });
        std::fs::write(tmp.join(MARKER), serde_json::to_vec_pretty(&marker)?)?;
        let dest = root.join(skill);
        match skill_state(&dest, hash) {
            SkillState::Absent => {}
            SkillState::Current | SkillState::Outdated => std::fs::remove_dir_all(&dest)?,
            _ => anyhow::bail!("{} is not cmux's", dest.display()),
        }
        std::fs::rename(tmp, &dest)?;
        Ok(())
    }
}

/// Runs `plan` against the person's real folders.
pub fn run(plan: &Plan) -> RunResult {
    let var = |name: &str| std::env::var(name).ok();
    run_with(plan, &Env { home: dirs::home_dir(), var: &var })
}

/// Runs `plan` against the folders `env` names.
pub fn run_with(plan: &Plan, env: &Env<'_>) -> RunResult {
    let action = match plan.action {
        Action::Install => "install",
        Action::Uninstall => "uninstall",
        Action::Status => "status",
    };
    let fail = |error: String| RunResult {
        value: json!({"action": action, "providers": [], "errors": [error]}),
        failed: true,
    };
    let all = match env.targets() {
        Ok(all) => all,
        Err(e) => return fail(format!("{e:#}")),
    };
    let mut selected: Vec<Target> = Vec::new();
    for word in &plan.targets {
        let id = match word.as_str() {
            "claude" | "claude-code" => "claude",
            "agents" | "codex" | "opencode" => "agents",
            "all" => {
                selected = all.clone();
                continue;
            }
            other => {
                return fail(format!(
                    "unknown skills target {other:?}; use claude, agents (Codex, OpenCode and others) or all"
                ));
            }
        };
        if !selected.iter().any(|t| t.id == id) {
            selected.extend(all.iter().filter(|t| t.id == id).cloned());
        }
    }
    if selected.is_empty() {
        selected = all;
    }
    let mut rows = Vec::new();
    let mut errors = Vec::new();
    for target in &selected {
        if plan.action == Action::Install {
            remove_stale_tmp(&target.dir);
        }
        let mut changed = false;
        let mut skills = Vec::new();
        for skill in SKILLS {
            let (_, hash) = skill_files(skill);
            let dir = target.dir.join(skill);
            let mut state = skill_state(&dir, &hash);
            match (plan.action, state) {
                (Action::Install, SkillState::Absent | SkillState::Outdated) => {
                    match install_skill(&target.dir, skill) {
                        Ok(()) => {
                            changed = true;
                            state = SkillState::Current;
                        }
                        Err(e) => errors.push(format!("{}: {skill}: {e:#}", target.id)),
                    }
                }
                (Action::Install, other) if conflict_reason(other).is_some() => {
                    errors.push(format!(
                        "{}: {} is not cmux's; move it away, then install again",
                        target.id,
                        dir.display()
                    ));
                }
                (Action::Uninstall, SkillState::Current | SkillState::Outdated) => {
                    match std::fs::remove_dir_all(&dir) {
                        Ok(()) => {
                            changed = true;
                            state = SkillState::Absent;
                        }
                        Err(e) => errors.push(format!("{}: {skill}: {e:#}", target.id)),
                    }
                }
                _ => {}
            }
            let name = match state {
                SkillState::Current => "installed",
                SkillState::Outdated => "outdated",
                SkillState::Absent => "absent",
                _ => "conflict",
            };
            let mut entry = json!({"skill": skill, "state": name});
            if let Some(reason) = conflict_reason(state) {
                entry["reason"] = json!(reason);
            }
            skills.push((entry, state));
        }
        let states: Vec<SkillState> = skills.iter().map(|(_, s)| *s).collect();
        let conflicts: Vec<&str> = SKILLS
            .iter()
            .zip(&states)
            .filter(|(_, s)| conflict_reason(**s).is_some())
            .map(|(n, _)| *n)
            .collect();
        let row_state = if states.iter().all(|s| *s == SkillState::Current) {
            "installed"
        } else if !conflicts.is_empty() {
            "conflict"
        } else if states.iter().all(|s| *s == SkillState::Absent) {
            "absent"
        } else {
            "partial"
        };
        let mut row = json!({
            "provider": target.id,
            "path": target.dir,
            "state": row_state,
            "changed": changed,
            "skills": skills.into_iter().map(|(e, _)| e).collect::<Vec<_>>(),
        });
        if let Some(first) = conflicts.first() {
            let state = states[SKILLS.iter().position(|s| s == first).unwrap_or(0)];
            row["reason"] = json!(conflict_reason(state));
            row["detail"] = json!(format!(
                "{} already holds {} that cmux did not install; cmux leaves {} alone",
                target.dir.display(),
                conflicts.join(", "),
                if conflicts.len() == 1 { "it" } else { "them" },
            ));
        }
        rows.push(row);
    }
    let mut value = json!({"action": action, "providers": rows, "errors": errors});
    if plan.action != Action::Uninstall {
        value["note"] = json!(
            "Agents read their skills folder when they start; restart a running agent to pick these up."
        );
    }
    RunResult { failed: !errors.is_empty(), value }
}
