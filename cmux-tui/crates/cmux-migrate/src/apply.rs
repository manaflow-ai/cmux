//! Applying a [`Plan`]: each [`Step`] through a [`Cloud`] (the app's own `cmux cloud` verbs, or
//! the headless journey on Linux, both in the CLI) and a [`Local`] (this computer's files and git),
//! recorded in the [`Ledger`] step by step, so a rerun goes on where the last one stopped and makes
//! nothing twice. Pure over those two traits: tests drive it with fakes.
//!
//! What crosses: the repo is cloned on the machine (never copied); local work a clone misses goes
//! as two text patches (`git format-patch` of unpushed commits, `git diff --binary` of the working
//! tree and untracked files) applied on the machine; agent chat histories go as their JSONL files,
//! renamed into the folder the agent looks in for the machine's checkout; machine-wide carry (shell,
//! git and editor settings, agent settings) goes as text files under the machine user's home.
//! Secret values never go through here: `deliver-secrets` sends them from the Keychain over the
//! daemon link, and an agent's login is passed at each chat start, so login files stay put.

use crate::ledger::{Ledger, Stage};
use crate::plan::{Plan, Step};

/// The machine user's home, where `~/` paths land.
pub const MACHINE_HOME: &str = "/home/cmux";
/// A carried file larger than this is left out (and said so).
pub const MAX_FILE_BYTES: u64 = 1024 * 1024;
/// All carried machine-wide files together.
pub const MAX_CARRY_BYTES: u64 = 32 * 1024 * 1024;
/// One chat history file.
pub const MAX_CHAT_BYTES: u64 = 16 * 1024 * 1024;
/// The ledger's entry for machine-wide carry, per source.
pub const MACHINE_WIDE: &str = "_machine-wide";

/// A machine a step made.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Created {
    pub machine_id: String,
    /// The checkout's folder on the machine, when the create says.
    pub checkout: Option<String>,
    /// Create to first chat reply, when the route measures it (the headless journey).
    pub first_chat_ms: Option<i64>,
}

/// Cloud calls a step makes.
pub trait Cloud {
    fn create_machine(
        &mut self,
        name: &str,
        repo: Option<&str>,
        machine_toml: &str,
    ) -> Result<Created, String>;
    /// Sends the values of `names` (declared in the machine config) from this computer's store.
    /// Answers the names still missing.
    fn deliver_secrets(
        &mut self,
        machine_id: &str,
        names: &[String],
    ) -> Result<Vec<String>, String>;
    fn write_file(&mut self, machine_id: &str, path: &str, text: &str) -> Result<(), String>;
    /// Runs `command` on the machine; an exit other than 0 is an `Err` with its output.
    fn exec(&mut self, machine_id: &str, command: &str) -> Result<String, String>;
    fn delete_machine(&mut self, machine_id: &str) -> Result<(), String>;
}

/// Local work a clone would miss, as text.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WorkPatch {
    /// `git format-patch --stdout` of the commits the remote lacks; empty when none.
    pub commits: String,
    /// `git diff --binary` of the working tree, untracked files included; empty when clean.
    pub work: String,
}

/// This computer's side. Paths are as the plan writes them (`~/…` or absolute).
pub trait Local {
    /// A file's text: `None` when missing, a folder, not UTF-8 or over `max` bytes.
    fn read_text(&self, path: &str, max: u64) -> Option<String>;
    /// The files under `path` (itself when a file), as plan paths, with their sizes.
    fn files(&self, path: &str) -> Vec<(String, u64)>;
    fn work_patch(&self, checkout: &str) -> Result<WorkPatch, String>;
    /// Milliseconds since the epoch.
    fn now_ms(&self) -> i64;
}

/// What happened to one step.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Done { step: String, project: String, detail: String },
    Skipped { step: String, project: String, why: String },
    Failed { step: String, project: String, error: String },
}

/// The run's sum.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Outcome {
    pub done: usize,
    pub skipped: usize,
    pub failed: usize,
}

/// A step's ledger name.
pub fn step_name(step: &Step) -> &'static str {
    match step {
        Step::CreateMachine { .. } => "create-machine",
        Step::CarryWorktree { .. } => "carry-worktree",
        Step::DeliverSecrets { .. } => "deliver-secrets",
        Step::CarryFiles { .. } => "carry-files",
        Step::CarrySecretFiles { .. } => "carry-secret-files",
        Step::MoveChats { .. } => "move-chats",
    }
}

/// A clone URL the machine's start takes: `git@host:owner/name(.git)` becomes
/// `https://host/owner/name`; anything else is kept (the start refuses what it cannot clone).
pub fn https_clone_url(url: &str) -> String {
    let url = crate::plan::strip_login(url);
    if let Some(rest) = url.strip_prefix("git@")
        && let Some((host, path)) = rest.split_once(':')
    {
        return format!("https://{host}/{}", path.trim_end_matches(".git"));
    }
    if let Some(rest) = url.strip_prefix("ssh://") {
        let rest = rest.rsplit_once('@').map_or(rest, |(_, host)| host);
        let (host, path) = rest.split_once('/').unwrap_or((rest, ""));
        let host = host.split(':').next().unwrap_or(host);
        return format!("https://{host}/{}", path.trim_end_matches(".git"));
    }
    url
}

/// A plan path on the machine: `~/x` under [`MACHINE_HOME`].
pub fn machine_path(path: &str) -> String {
    match path.strip_prefix("~/") {
        Some(rest) => format!("{MACHINE_HOME}/{rest}"),
        None => path.to_owned(),
    }
}

/// Where a chat history file goes on the machine: a Claude Code transcript into the projects
/// folder named for the machine's checkout (so `claude --resume` there lists it); a Codex or other
/// file at its own home-relative path.
pub fn chat_destination(chat: &str, checkout: &str) -> String {
    let parts: Vec<&str> = chat.split('/').collect();
    if let Some(i) = parts.iter().position(|p| *p == "projects")
        && i.checked_sub(1).and_then(|before| parts.get(before)) == Some(&".claude")
        && let Some(rest) = parts.get(i.saturating_add(2)..)
        && !rest.is_empty()
    {
        let slug: String =
            checkout.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
        let file = rest.join("/");
        return format!("{MACHINE_HOME}/.claude/projects/{slug}/{file}");
    }
    machine_path(chat)
}

/// Whether a carried file is a login or key, which never goes as a plain file.
pub fn is_secret_file(path: &str) -> bool {
    let name = path.rsplit('/').next().unwrap_or(path);
    matches!(
        name,
        ".credentials.json" | "auth.json" | "credentials" | ".netrc" | ".git-credentials"
    ) || name.starts_with("id_")
        || name.ends_with(".pem")
        || name.ends_with(".key")
        || path.contains("/.ssh/") && name != "config"
}

fn shq(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// The checkout's folder on a machine that did not say (the bootstrap's `~/work/NAME`).
fn default_checkout(repo: Option<&str>, name: &str) -> String {
    let base = repo
        .and_then(|url| url.trim_end_matches('/').rsplit('/').next())
        .map(|last| last.trim_end_matches(".git").to_owned())
        .filter(|last| !last.is_empty())
        .unwrap_or_else(|| name.to_owned());
    format!("{MACHINE_HOME}/work/{base}")
}

/// Applies `plan`'s checked steps (only the projects in `only`, when given) and records each in
/// `ledger`. A failed project's later steps are skipped; other projects go on.
pub fn apply(
    plan: &Plan,
    only: &[String],
    ledger: &mut Ledger,
    cloud: &mut dyn Cloud,
    local: &dyn Local,
    report: &mut dyn FnMut(&Event),
) -> Outcome {
    let source = plan.source.id.clone();
    let mut outcome = Outcome::default();
    let mut checkouts: std::collections::BTreeMap<String, String> = Default::default();
    let mut emit = |event: Event, outcome: &mut Outcome| {
        match &event {
            Event::Done { .. } => outcome.done = outcome.done.saturating_add(1),
            Event::Skipped { .. } => outcome.skipped = outcome.skipped.saturating_add(1),
            Event::Failed { .. } => outcome.failed = outcome.failed.saturating_add(1),
        }
        report(&event);
    };
    let wanted = |project: &str| only.is_empty() || only.iter().any(|o| o == project);
    for step in plan.steps() {
        let name = step_name(&step).to_owned();
        let project = match &step {
            Step::CreateMachine { project, .. }
            | Step::CarryWorktree { project, .. }
            | Step::DeliverSecrets { project, .. }
            | Step::MoveChats { project, .. } => project.clone(),
            Step::CarryFiles { .. } | Step::CarrySecretFiles { .. } => MACHINE_WIDE.to_owned(),
        };
        if project != MACHINE_WIDE && !wanted(&project) {
            continue;
        }
        if ledger.is_done(&source, &project, &name) {
            if let (Step::CreateMachine { repo, name: machine, .. }, Some(entry)) =
                (&step, ledger.entry(&source, &project))
                && entry.machine_id.is_some()
            {
                let repo = repo.as_deref().map(https_clone_url);
                checkouts.insert(project.clone(), default_checkout(repo.as_deref(), machine));
            }
            emit(
                Event::Skipped { step: name, project, why: "done in an earlier run".into() },
                &mut outcome,
            );
            continue;
        }
        let machine_id = ledger.entry(&source, &project).and_then(|e| e.machine_id.clone());
        if project != MACHINE_WIDE
            && !matches!(step, Step::CreateMachine { .. })
            && (machine_id.is_none()
                || ledger.entry(&source, &project).is_some_and(|e| e.stage == Stage::Failed))
        {
            emit(
                Event::Skipped { step: name, project, why: "its machine was not made".into() },
                &mut outcome,
            );
            continue;
        }
        let result: Result<String, String> = match &step {
            Step::CreateMachine { name: machine, repo, machine_toml, .. } => {
                let repo = repo.as_deref().map(https_clone_url);
                let started = local.now_ms();
                {
                    let entry = ledger.entry_mut(&source, &project);
                    entry.started_ms = Some(started);
                    entry.stage = Stage::Pending;
                    entry.error = None;
                }
                match cloud.create_machine(machine, repo.as_deref(), machine_toml) {
                    Ok(created) => {
                        let checkout = created
                            .checkout
                            .clone()
                            .unwrap_or_else(|| default_checkout(repo.as_deref(), machine));
                        checkouts.insert(project.clone(), checkout.clone());
                        let entry = ledger.entry_mut(&source, &project);
                        entry.machine_id = Some(created.machine_id.clone());
                        entry.first_chat_ms =
                            created.first_chat_ms.map(|ms| started.saturating_add(ms));
                        entry.stage = Stage::Done;
                        Ok(format!("machine {} ({checkout})", created.machine_id))
                    }
                    Err(error) => {
                        let entry = ledger.entry_mut(&source, &project);
                        entry.stage = Stage::Failed;
                        entry.error = Some(error.clone());
                        Err(error)
                    }
                }
            }
            Step::CarryWorktree { path, .. } => {
                let id = machine_id.clone().unwrap_or_default();
                let checkout = checkouts.get(&project).cloned().unwrap_or_default();
                carry_worktree(cloud, local, &id, path, &checkout)
            }
            Step::DeliverSecrets { names, .. } => {
                let id = machine_id.clone().unwrap_or_default();
                cloud.deliver_secrets(&id, names).map(|missing| {
                    if missing.is_empty() {
                        format!("{} delivered", names.len())
                    } else {
                        format!(
                            "{} delivered; not on this computer yet (cmux cloud secret set NAME): {}",
                            names.len().saturating_sub(missing.len()),
                            missing.join(", ")
                        )
                    }
                })
            }
            Step::MoveChats { chats, .. } => {
                let id = machine_id.clone().unwrap_or_default();
                let checkout = checkouts.get(&project).cloned().unwrap_or_default();
                move_chats(cloud, local, &id, chats, &checkout)
            }
            Step::CarryFiles { paths } => {
                let machines: Vec<String> = ledger
                    .projects
                    .iter()
                    .filter(|(key, entry)| {
                        key.starts_with(&format!("{source}/")) && entry.stage == Stage::Done
                    })
                    .filter_map(|(_, entry)| entry.machine_id.clone())
                    .collect();
                if machines.is_empty() {
                    Err("no machine of this move is up to carry them to".to_owned())
                } else {
                    carry_files(cloud, local, &machines, paths)
                }
            }
            Step::CarrySecretFiles { paths } => {
                emit(
                    Event::Skipped {
                        step: name,
                        project,
                        why: format!(
                            "{} login file(s) stay on this computer: cmux passes your agent login to each chat it starts on the machine",
                            paths.len()
                        ),
                    },
                    &mut outcome,
                );
                continue;
            }
        };
        match result {
            Ok(detail) => {
                ledger.entry_mut(&source, &project).done.push(name.clone());
                emit(Event::Done { step: name, project, detail }, &mut outcome);
            }
            Err(error) => {
                if !matches!(step, Step::CreateMachine { .. }) {
                    ledger.entry_mut(&source, &project).error = Some(error.clone());
                }
                emit(Event::Failed { step: name, project, error }, &mut outcome);
            }
        }
    }
    outcome
}

fn carry_worktree(
    cloud: &mut dyn Cloud,
    local: &dyn Local,
    machine: &str,
    path: &str,
    checkout: &str,
) -> Result<String, String> {
    let patch = local.work_patch(path)?;
    if patch.commits.is_empty() && patch.work.is_empty() {
        return Ok("nothing the clone lacks".into());
    }
    let dir = format!("{MACHINE_HOME}/.cmux/migrate");
    let mut said = Vec::new();
    if !patch.commits.is_empty() {
        let file = format!("{dir}/commits.patch");
        cloud.write_file(machine, &file, &patch.commits)?;
        cloud.exec(
            machine,
            &format!(
                "cd {} && git -c user.name=cmux -c user.email=cmux@localhost am --3way --keep-cr {} >/dev/null",
                shq(checkout),
                shq(&file)
            ),
        )?;
        said.push(format!("{} commit(s)", patch.commits.matches("\nSubject: ").count().max(1)));
    }
    if !patch.work.is_empty() {
        let file = format!("{dir}/work.patch");
        cloud.write_file(machine, &file, &patch.work)?;
        cloud.exec(
            machine,
            &format!(
                "cd {} && git apply --binary --whitespace=nowarn {}",
                shq(checkout),
                shq(&file)
            ),
        )?;
        said.push(format!(
            "{} changed file(s)",
            patch
                .work
                .matches("\ndiff --git ")
                .count()
                .saturating_add(usize::from(patch.work.starts_with("diff --git ")))
        ));
    }
    Ok(format!("{} in {checkout}", said.join(" and ")))
}

fn move_chats(
    cloud: &mut dyn Cloud,
    local: &dyn Local,
    machine: &str,
    chats: &[String],
    checkout: &str,
) -> Result<String, String> {
    let (mut moved, mut left) = (0usize, Vec::new());
    for chat in chats {
        match local.read_text(chat, MAX_CHAT_BYTES) {
            Some(text) => {
                cloud.write_file(machine, &chat_destination(chat, checkout), &text)?;
                moved = moved.saturating_add(1);
            }
            None => left.push(chat.clone()),
        }
    }
    if moved == 0 && !left.is_empty() {
        return Err(format!("no chat history could be read: {}", left.join(", ")));
    }
    let mut detail = format!("{moved} chat histories, resumable in {checkout}");
    if !left.is_empty() {
        detail.push_str(&format!("; left (unreadable or over 16 MiB): {}", left.len()));
    }
    Ok(detail)
}

fn carry_files(
    cloud: &mut dyn Cloud,
    local: &dyn Local,
    machines: &[String],
    paths: &[String],
) -> Result<String, String> {
    let (mut sent, mut total, mut left) = (0usize, 0u64, 0usize);
    for path in paths {
        for (file, size) in local.files(path) {
            if is_secret_file(&file)
                || size > MAX_FILE_BYTES
                || total.saturating_add(size) > MAX_CARRY_BYTES
            {
                left = left.saturating_add(1);
                continue;
            }
            let Some(text) = local.read_text(&file, MAX_FILE_BYTES) else {
                left = left.saturating_add(1);
                continue;
            };
            for machine in machines {
                cloud.write_file(machine, &machine_path(&file), &text)?;
            }
            total = total.saturating_add(size);
            sent = sent.saturating_add(1);
        }
    }
    let mut detail = format!("{sent} file(s) to {} machine(s)", machines.len());
    if left > 0 {
        detail.push_str(&format!("; {left} left (logins, keys, binary or too big)"));
    }
    Ok(detail)
}

/// Deletes every machine `source_id`'s moves made and marks them undone. Nothing on this computer
/// was changed by the move, so this is the whole undo.
pub fn undo(
    source_id: &str,
    ledger: &mut Ledger,
    cloud: &mut dyn Cloud,
    report: &mut dyn FnMut(&Event),
) -> Outcome {
    let mut outcome = Outcome::default();
    for step in ledger.undo_steps(source_id) {
        let event = match cloud.delete_machine(&step.machine_id) {
            Ok(()) => {
                let entry = ledger.entry_mut(source_id, &step.key);
                entry.stage = Stage::Undone;
                entry.done.clear();
                outcome.done = outcome.done.saturating_add(1);
                Event::Done {
                    step: "delete-machine".into(),
                    project: step.key.clone(),
                    detail: format!("machine {} deleted", step.machine_id),
                }
            }
            Err(error) => {
                outcome.failed = outcome.failed.saturating_add(1);
                Event::Failed { step: "delete-machine".into(), project: step.key.clone(), error }
            }
        };
        report(&event);
    }
    outcome
}

#[cfg(test)]
#[path = "apply_tests.rs"]
mod tests;
