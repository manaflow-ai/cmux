//! Applying a [`Plan`]: each [`Step`] through a [`Cloud`] (the app's own `cmux cloud` verbs, or
//! the headless journey on Linux, both in the CLI) and a [`Local`] (this computer's files and git),
//! recorded in the [`Ledger`] step by step, so a rerun goes on where the last one stopped and makes
//! nothing twice. Pure over those two traits: tests drive it with fakes.
//!
//! What crosses: the repo is cloned on the machine (never copied); local work a clone misses goes
//! as one `git bundle` ([`LocalWork`]: local branches and tags past the remote, the uncommitted
//! work as one commit) fetched there, the whole history when the source had no remote; agent chat histories go as their JSONL files,
//! renamed into the folder the agent looks in for the machine's checkout; machine-wide carry (shell,
//! git and editor settings, agent settings) goes as text files under the machine user's home.
//! Secret values never go through here: `deliver-secrets` sends them from the Keychain over the
//! daemon link, and an agent's login is passed at each chat start, so login files stay put.

use crate::ledger::{Ledger, Stage};
use crate::plan::{Plan, Source, SourceKind, Step};

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
    /// Whether this route can write files and run commands on a machine it made. The headless
    /// journey cannot: its carry steps are skipped, said once each, never failed.
    fn carries_files(&self) -> bool {
        true
    }
}

/// Local work a clone would miss, carried as one `git bundle` (the way `cloud move` carries a
/// chat's folder): every local branch and tag past what the remote has, with the commits exactly
/// as made (ids, merges, authors kept), and the uncommitted work (untracked files included) as one
/// more commit on HEAD that the machine unpacks back into its working tree, uncommitted again.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LocalWork {
    /// The bundle in base64; empty when the clone lacks nothing.
    pub bundle: String,
    /// HEAD's commit on the source; `None` before the first commit.
    pub head: Option<String>,
    /// A commit on `head` whose tree is the working tree; `None` when it is clean.
    pub work: Option<String>,
    /// The merge base of HEAD and its upstream (else the remote's default branch); `None` when the
    /// checkout has no remote to share a commit with (the bundle then holds its whole history).
    pub base: Option<String>,
    /// The source's branch, made on the machine at `head`; `None` when HEAD is detached.
    pub branch: Option<String>,
    /// Commits on local branches, tags and HEAD that no remote branch has.
    pub commits: u32,
    /// Files the working tree changes, adds or deletes against HEAD.
    pub files: u32,
}

/// A bundle larger than this is not carried: the step fails and says to push.
pub const MAX_BUNDLE_BYTES: usize = 256 * 1024 * 1024;

/// Where a project's local work is read from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PatchRoute {
    /// The checkout is a folder of this computer.
    Local,
    /// The checkout is on the source: [`WORK_SCRIPT`] runs there as `program args` with the
    /// script on stdin (`ssh HOST sh -s`, `gh codespace ssh -c NAME -- sh -s`).
    Remote { program: String, args: Vec<String> },
    /// No route reads it yet: the step is skipped with this note.
    Unsupported(String),
}

/// How `project`'s checkout in a plan from `source` is read.
pub fn patch_route(source: &Source, project: &str) -> PatchRoute {
    match source.kind {
        SourceKind::Laptop
        | SourceKind::Devcontainer
        | SourceKind::Compose
        | SourceKind::Nix
        | SourceKind::Gitpod
        | SourceKind::Ci
        | SourceKind::AgentClient => PatchRoute::Local,
        SourceKind::SshHost => {
            let host = source.id.strip_prefix("ssh:").unwrap_or(&source.label);
            PatchRoute::Remote {
                program: "ssh".into(),
                args: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, "sh", "-s"]
                    .map(str::to_owned)
                    .to_vec(),
            }
        }
        SourceKind::Codespaces => PatchRoute::Remote {
            program: "gh".into(),
            args: ["codespace", "ssh", "-c", project, "--", "sh", "-s"].map(str::to_owned).to_vec(),
        },
        SourceKind::Coder | SourceKind::Daytona | SourceKind::OtherCloud | SourceKind::Team => {
            PatchRoute::Unsupported(format!(
                "local work on {} is not read from here yet: push it (or `cmux migrate plan ssh:HOST` \
             the workspace) and the clone has it",
                source.label
            ))
        }
    }
}

/// Run on the source with `cd CHECKOUT` before it ([`work_script`]): prints the branch, HEAD, the
/// base commit, the uncommitted-work commit and the counts, each after a marker line, then the
/// bundle in base64. The person's index, refs and branches are never touched: the working tree is
/// read through a throwaway index, and the bundle is cut from a scratch repository that borrows
/// the checkout's objects (`objects/info/alternates`). The one write is the work commit's objects,
/// unreachable, which `git gc` prunes like a dropped stash.
pub const WORK_SCRIPT: &str = r#"g() { git -c core.fsmonitor=false -c core.quotepath=off "$@"; }
top=$(g rev-parse --show-toplevel) || exit 3
cd "$top" || exit 3
up=$(g rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || up=
[ -n "$up" ] || up=$(g rev-parse --abbrev-ref origin/HEAD 2>/dev/null) || up=
branch=$(g symbolic-ref --short -q HEAD) || branch=
head=$(g rev-parse -q --verify 'HEAD^{commit}') || head=
base=
[ -n "$up" ] && [ -n "$head" ] && { base=$(g merge-base "$up" HEAD 2>/dev/null) || base=; }
s=$(mktemp -d) || exit 4
trap 'rm -rf "$s"' EXIT
cp "$(g rev-parse --git-path index)" "$s/index" 2>/dev/null
GIT_INDEX_FILE=$s/index g add -A >/dev/null 2>&1
tree=$(GIT_INDEX_FILE=$s/index g write-tree) || exit 5
if [ -n "$head" ]; then
  files=$(GIT_INDEX_FILE=$s/index g diff --cached --name-only --no-renames HEAD | wc -l)
else
  files=$(GIT_INDEX_FILE=$s/index g ls-files | wc -l)
fi
files=$((files + 0))
work=
if [ "$files" -gt 0 ]; then
  if [ -n "$head" ]; then
    work=$(g -c user.name=cmux -c user.email=cmux@localhost commit-tree "$tree" -p "$head" -m "cmux migrate: uncommitted work") || exit 5
  else
    work=$(g -c user.name=cmux -c user.email=cmux@localhost commit-tree "$tree" -m "cmux migrate: uncommitted work") || exit 5
  fi
fi
commits=0
[ -n "$head" ] && commits=$(g rev-list --count HEAD --branches --tags --not --remotes 2>/dev/null)
commits=$((commits + 0))
echo "@@cmux-migrate:branch@@ $branch"
echo "@@cmux-migrate:head@@ $head"
echo "@@cmux-migrate:base@@ $base"
echo "@@cmux-migrate:work@@ $work"
echo "@@cmux-migrate:counts@@ $commits $files"
echo "@@cmux-migrate:bundle@@"
if [ "$commits" -gt 0 ] || [ -n "$work" ]; then
  common=$(cd "$(g rev-parse --git-common-dir)" && pwd) || exit 6
  git init -q --bare "$s/g.git" || exit 6
  echo "$common/objects" > "$s/g.git/objects/info/alternates"
  g for-each-ref --format='create %(refname) %(objectname)' refs/heads refs/tags > "$s/refs"
  [ -n "$head" ] && echo "create refs/cmux-migrate/head $head" >> "$s/refs"
  [ -n "$work" ] && echo "create refs/cmux-migrate/work $work" >> "$s/refs"
  git --git-dir="$s/g.git" update-ref --stdin < "$s/refs" || exit 6
  g for-each-ref --format='^%(objectname)' refs/remotes > "$s/not"
  git --git-dir="$s/g.git" bundle create "$s/b" --all --stdin < "$s/not" 2>"$s/err" || { cat "$s/err" >&2; exit 7; }
  base64 < "$s/b" | tr -d '\n'
fi
echo
echo "@@cmux-migrate:end@@"
"#;

/// The script a source runs: into `checkout`, then [`WORK_SCRIPT`].
pub fn work_script(checkout: &str) -> String {
    let dir = match checkout.strip_prefix("~/") {
        Some(rest) => format!("\"$HOME\"/{}", shq(rest)),
        None => shq(checkout),
    };
    format!("cd {dir} || exit 3\n{WORK_SCRIPT}")
}

/// [`WORK_SCRIPT`]'s output.
pub fn parse_work(out: &str) -> Result<LocalWork, String> {
    let mut work = LocalWork::default();
    let (mut in_bundle, mut ended) = (false, false);
    let some = |rest: &str| Some(rest.trim().to_owned()).filter(|v| !v.is_empty());
    for line in out.lines() {
        if line == "@@cmux-migrate:end@@" {
            ended = true;
            break;
        } else if in_bundle {
            work.bundle.push_str(line.trim());
        } else if line == "@@cmux-migrate:bundle@@" {
            in_bundle = true;
        } else if let Some(rest) = line.strip_prefix("@@cmux-migrate:branch@@") {
            work.branch = some(rest);
        } else if let Some(rest) = line.strip_prefix("@@cmux-migrate:head@@") {
            work.head = some(rest);
        } else if let Some(rest) = line.strip_prefix("@@cmux-migrate:base@@") {
            work.base = some(rest);
        } else if let Some(rest) = line.strip_prefix("@@cmux-migrate:work@@") {
            work.work = some(rest);
        } else if let Some(rest) = line.strip_prefix("@@cmux-migrate:counts@@") {
            let mut n = rest.split_whitespace().map(|n| n.parse().unwrap_or(0));
            work.commits = n.next().unwrap_or(0);
            work.files = n.next().unwrap_or(0);
        }
    }
    if !ended {
        return Err("the source's checkout could not be read (is it a git checkout?)".into());
    }
    // Base64 is 4 characters per 3 bytes.
    if work.bundle.len() / 4 * 3 > MAX_BUNDLE_BYTES {
        return Err(format!(
            "the local work is over {} MiB as a git bundle: push it and the clone has it",
            MAX_BUNDLE_BYTES >> 20
        ));
    }
    Ok(work)
}

/// This computer's side. Paths are as the plan writes them (`~/…` or absolute).
pub trait Local {
    /// A file's text: `None` when missing, a folder, not UTF-8 or over `max` bytes.
    fn read_text(&self, path: &str, max: u64) -> Option<String>;
    /// The files under `path` (itself when a file), as plan paths, with their sizes.
    fn files(&self, path: &str) -> Vec<(String, u64)>;
    /// The local work in `checkout` of `project`, read from the source by [`patch_route`] (this
    /// computer for a laptop or a folder; over the source's shell for an SSH host or a codespace).
    fn work_patch(
        &self,
        source: &Source,
        project: &str,
        checkout: &str,
    ) -> Result<LocalWork, String>;
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
    apply_saving(plan, only, ledger, cloud, local, report, &mut |_| {})
}

/// [`apply`], handing `checkpoint` the ledger after every step, so a caller can save it then: a
/// crash or Ctrl-C after a machine is made keeps its id for the rerun and for undo.
pub fn apply_saving(
    plan: &Plan,
    only: &[String],
    ledger: &mut Ledger,
    cloud: &mut dyn Cloud,
    local: &dyn Local,
    report: &mut dyn FnMut(&Event),
    checkpoint: &mut dyn FnMut(&Ledger),
) -> Outcome {
    let source = plan.source.id.clone();
    let mut outcome = Outcome::default();
    let mut checkouts: std::collections::BTreeMap<String, String> = Default::default();
    let mut emit = |event: Event, outcome: &mut Outcome, ledger: &Ledger| {
        checkpoint(ledger);
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
        let carries = matches!(
            step,
            Step::CarryWorktree { .. } | Step::MoveChats { .. } | Step::CarryFiles { .. }
        );
        if carries && !cloud.carries_files() {
            emit(
                Event::Skipped {
                    step: name,
                    project,
                    why: "this route only makes machines: run it without --headless to carry this"
                        .into(),
                },
                &mut outcome,
                ledger,
            );
            continue;
        }
        if let Step::CarryWorktree { project: key, .. } = &step
            && !ledger.is_done(&source, &project, &name)
            && let PatchRoute::Unsupported(why) = patch_route(&plan.source, key)
        {
            emit(Event::Skipped { step: name, project, why }, &mut outcome, ledger);
            continue;
        }
        if project != MACHINE_WIDE && ledger.is_done(&source, &project, &name) {
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
                ledger,
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
                ledger,
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
                let patch = local.work_patch(&plan.source, &project, path);
                patch.and_then(|patch| {
                    let entry = ledger.entry_mut(&source, &project);
                    carry_worktree(cloud, &mut entry.done, &id, &patch, &checkout)
                })
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
                // Recorded per machine (on its project's entry), so a machine a later run makes
                // gets them too, and one that has them is not written again.
                let prefix = format!("{source}/");
                let up: Vec<(String, String, bool)> = ledger
                    .projects
                    .iter()
                    .filter(|(key, entry)| {
                        key.starts_with(&prefix)
                            && !key.ends_with(&format!("/{MACHINE_WIDE}"))
                            && entry.stage == Stage::Done
                    })
                    .filter_map(|(key, entry)| {
                        let has = entry.done.iter().any(|d| d == &name);
                        Some((key.get(prefix.len()..)?.to_owned(), entry.machine_id.clone()?, has))
                    })
                    .collect();
                let (machines, keys): (Vec<String>, Vec<String>) =
                    up.iter().filter(|u| !u.2).map(|u| (u.1.clone(), u.0.clone())).unzip();
                if up.is_empty() {
                    Err("no machine of this move is up to carry them to".to_owned())
                } else if machines.is_empty() {
                    emit(
                        Event::Skipped {
                            step: name,
                            project,
                            why: "every machine has them from an earlier run".into(),
                        },
                        &mut outcome,
                        ledger,
                    );
                    continue;
                } else {
                    let result = carry_files(cloud, local, &machines, paths);
                    if result.is_ok() {
                        for key in &keys {
                            ledger.entry_mut(&source, key).done.push(name.clone());
                        }
                    }
                    result
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
                    ledger,
                );
                continue;
            }
        };
        match result {
            Ok(detail) => {
                // Machine-wide carry is recorded per machine (above), never as an entry of its
                // own: a `_machine-wide` entry would count as a project in `Ledger::stats`.
                if project != MACHINE_WIDE {
                    let entry = ledger.entry_mut(&source, &project);
                    let prefix = format!("{name}:");
                    entry.done.retain(|d| !d.starts_with(&prefix));
                    entry.done.push(name.clone());
                }
                emit(Event::Done { step: name, project, detail }, &mut outcome, ledger);
            }
            Err(error) => {
                if !matches!(step, Step::CreateMachine { .. }) && project != MACHINE_WIDE {
                    ledger.entry_mut(&source, &project).error = Some(error.clone());
                }
                emit(Event::Failed { step: name, project, error }, &mut outcome, ledger);
            }
        }
    }
    outcome
}

/// Carries `work` into `checkout` in up to three sub-steps, each recorded in `done` as
/// `carry-worktree:NAME` once it worked, so a rerun after a failure goes on from the one that
/// failed and never unpacks twice: `bundle` (the bundle written to the machine and fetched into
/// the checkout, a fresh repository when the source had no remote), `head` (the source's branch
/// checked out at its HEAD), `work` (the uncommitted work read into the working tree and left
/// uncommitted). The work commit stays at `refs/cmux-migrate/work` on the machine.
fn carry_worktree(
    cloud: &mut dyn Cloud,
    done: &mut Vec<String>,
    machine: &str,
    work: &LocalWork,
    checkout: &str,
) -> Result<String, String> {
    if work.bundle.is_empty() {
        return Ok("nothing the clone lacks".into());
    }
    let sub = |part: &str| format!("carry-worktree:{part}");
    let has = |done: &[String], part: &str| done.iter().any(|d| *d == sub(part));
    let dir = format!("{MACHINE_HOME}/.cmux/migrate");
    let cd = format!("cd {}", shq(checkout));
    if !has(done, "bundle") {
        let (text, file) = (format!("{dir}/worktree.bundle.b64"), format!("{dir}/worktree.bundle"));
        cloud.write_file(machine, &text, &work.bundle)?;
        // Detached first, so the fetch may move the branch the clone checked out. A bundle whose
        // prerequisites the clone lacks (a shallow or single-branch clone) gets origin's history.
        cloud.exec(
            machine,
            &format!(
                "mkdir -p {q} && {cd} && {{ git rev-parse --git-dir >/dev/null 2>&1 || git init -q; }} \
                 && base64 -d < {t} > {f} \
                 && {{ git checkout -q --detach 2>/dev/null; true; }} \
                 && {{ git bundle verify -q {f} >/dev/null 2>&1 || {{ git fetch -q --unshallow origin 2>/dev/null || git fetch -q origin; }}; }} \
                 && git fetch -q {f} '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' '+refs/cmux-migrate/*:refs/cmux-migrate/*' \
                 && rm -f {t} {f}",
                q = shq(checkout),
                t = shq(&text),
                f = shq(&file),
            ),
        )?;
        done.push(sub("bundle"));
    }
    if let Some(head) = &work.head
        && !has(done, "head")
    {
        let switch = match &work.branch {
            Some(branch) => format!("git checkout -q -B {} {}", shq(branch), shq(head)),
            None => format!("git checkout -q --detach {}", shq(head)),
        };
        cloud.exec(
            machine,
            &format!(
                "{cd} && {{ git cat-file -e {c} 2>/dev/null || git fetch -q origin {h}; }} && {switch}",
                c = shq(&format!("{head}^{{commit}}")),
                h = shq(head),
            ),
        )?;
        done.push(sub("head"));
    }
    if let Some(commit) = &work.work
        && !has(done, "work")
    {
        // Two-tree read-tree moves the files to the work commit's tree; the reset (or the emptied
        // index before a first commit) makes them uncommitted again, new files untracked.
        let unpack = match &work.head {
            Some(_) => format!("git read-tree -u -m HEAD {c} && git reset -q", c = shq(commit)),
            None => {
                format!("git read-tree -u --reset {c} && git read-tree --empty", c = shq(commit))
            }
        };
        cloud.exec(machine, &format!("{cd} && {unpack}"))?;
        done.push(sub("work"));
    }
    let on = work.branch.as_deref().map(|b| format!(" on {b}")).unwrap_or_default();
    Ok(format!(
        "{} commit(s) and {} changed file(s) in {checkout}{on}, as a git bundle",
        work.commits, work.files
    ))
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
        for file in chat_files(local, chat) {
            match local.read_text(&file, MAX_CHAT_BYTES) {
                Some(text) => {
                    cloud.write_file(machine, &chat_destination(&file, checkout), &text)?;
                    moved = moved.saturating_add(1);
                }
                None => left.push(file),
            }
        }
    }
    if moved == 0 && !left.is_empty() {
        return Err(format!("no chat history could be read: {}", left.join(", ")));
    }
    let mut detail = format!("{moved} chat histories, resumable in {checkout}");
    if !left.is_empty() {
        detail.push_str(&format!(
            "; left (unreadable, no JSONL transcript, or over 16 MiB): {}",
            left.len()
        ));
    }
    Ok(detail)
}

/// A chat reference as the files that move: itself when a file; a folder (Claude Code's project
/// folder, Cursor's workspace storage) as the `.jsonl` transcripts under it, or itself (left, said
/// so) when it holds none.
pub fn chat_files(local: &dyn Local, chat: &str) -> Vec<String> {
    let files = local.files(chat);
    if let [(only, _)] = files.as_slice()
        && only == chat
    {
        return vec![chat.to_owned()];
    }
    let mut transcripts: Vec<String> =
        files.into_iter().map(|(f, _)| f).filter(|f| f.ends_with(".jsonl")).collect();
    transcripts.sort();
    if transcripts.is_empty() { vec![chat.to_owned()] } else { transcripts }
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

#[cfg(test)]
#[path = "apply_carry_tests.rs"]
mod carry_tests;
