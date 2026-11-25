//! The one shape every source produces: the dry run a person (or an org's script) reads, edits by
//! unchecking, and applies.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// The plan layout this build writes (`--json`).
pub const VERSION: u32 = 1;

/// Where people come from. One reader per kind in [`crate::sources`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SourceKind {
    /// This Mac (or Linux laptop): its git checkouts, dotfiles, editor settings and agent state.
    Laptop,
    /// A `.devcontainer/devcontainer.json` (Codespaces, DevPod, Daytona and Coder's envbuilder
    /// read the same file).
    Devcontainer,
    /// A `docker-compose.yml` / `compose.yaml` without a devcontainer.
    Compose,
    /// A `flake.nix` / `shell.nix` / `devbox.json`.
    Nix,
    /// An existing VM or server reached over SSH.
    SshHost,
    /// GitHub Codespaces.
    Codespaces,
    /// Gitpod / Ona (`.gitpod.yml`).
    Gitpod,
    /// Coder (templates and workspaces).
    Coder,
    /// Daytona.
    Daytona,
    /// Any other cloud dev environment reached over SSH (exe.dev, Namespace, Devin, Capy...).
    OtherCloud,
    /// A CI config (`.github/workflows`, `.gitlab-ci.yml`, `.circleci`) read for setup steps and
    /// secret names.
    Ci,
    /// A team roster: many people, each with their own plan.
    Team,
}

/// The source a plan was read from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Source {
    pub kind: SourceKind,
    /// What a person reads: "this Mac", "devbox.example.com", "codespace fluffy-space-x".
    pub label: String,
    /// Stable across runs: the ledger's namespace for this source.
    pub id: String,
}

/// A dry-run plan: everything that would move, nothing moved yet.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Plan {
    pub version: u32,
    pub source: Source,
    pub projects: Vec<Project>,
    /// Machine-wide things that follow the person to every machine (dotfiles, logins).
    #[serde(default)]
    pub carry: Vec<Carry>,
    /// What a person should know before applying (a dirty tree, an unpushed branch).
    #[serde(default)]
    pub warnings: Vec<String>,
    /// What this source has that AutoCloud cannot take yet, each with why.
    #[serde(default)]
    pub unsupported: Vec<Unsupported>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Unsupported {
    pub what: String,
    pub why: String,
}

/// One project: a repo and what makes its machine ready.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Project {
    /// Stable within the source: the ledger key (a path, a codespace name, a compose service).
    pub key: String,
    /// The machine's name: plain, lowercase, `[a-z0-9-]`, at most 40 characters ([`machine_name`]).
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo: Option<Repo>,
    pub machine: MachineConfig,
    /// A container image the source ran in, when it named one. AutoCloud machines are full VMs:
    /// the image's setup is replayed by `[setup]`, and the image is noted for the person.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    /// Ports the source forwarded.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ports: Vec<u16>,
    /// Sidecar services (compose's databases, caches), started on the machine by `[setup]`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub services: Vec<String>,
    /// Agent chats that belong to this project (Claude Code, Codex, Cursor), linked by path.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub chats: Vec<ChatRef>,
    /// Unchecked projects are listed and skipped. Defaults on.
    #[serde(default = "yes")]
    pub checked: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
}

fn yes() -> bool {
    true
}

/// Where the code comes from. A repo with a remote is cloned there; uncommitted or unpushed work
/// rides along as a git bundle ([`Repo::carry_worktree`]) so nothing is lost.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Repo {
    /// The clone URL with any login or token removed (`cloud new-machine --repo` refuses one).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    /// The checkout on the source, when it has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// Files changed and not committed.
    #[serde(default)]
    pub dirty_files: u32,
    /// Commits on local branches no remote has.
    #[serde(default)]
    pub unpushed_commits: u32,
}

impl Repo {
    /// Whether the move must carry the working tree, not just clone: no remote, or local work a
    /// clone would not have.
    pub fn carry_worktree(&self) -> bool {
        self.url.is_none() || self.dirty_files > 0 || self.unpushed_commits > 0
    }
}

/// The parts of `.cmux/machine.toml` a migration fills ([`crate::machine_toml::render`]).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MachineConfig {
    /// Plain values (never a secret): `[env]`.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// Names only: `[secrets] names`. Values go over `cloud deliver-secrets`.
    #[serde(default)]
    pub secret_names: BTreeSet<String>,
    /// `[setup] run`, in order.
    #[serde(default)]
    pub setup: Vec<String>,
    /// `[setup] check`.
    #[serde(default)]
    pub check: Vec<String>,
}

impl MachineConfig {
    pub fn is_empty(&self) -> bool {
        self.env.is_empty()
            && self.secret_names.is_empty()
            && self.setup.is_empty()
            && self.check.is_empty()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Agent {
    Claude,
    Codex,
    Cursor,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatRef {
    pub agent: Agent,
    /// The transcript or session folder on the source.
    pub path: String,
}

/// What a machine-wide carry item is. Kinds marked secret travel only over the secret channel
/// (`cloud deliver-secrets` / `cmux file receive`, 0600), never the exec channel or a log.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CarryKind {
    /// `.zshrc`, `.bashrc`, `.profile`, `.inputrc`, `.tmux.conf`, starship, aliases.
    Shell,
    /// Shell history. Unchecked by default: it can hold tokens typed on a command line.
    ShellHistory,
    /// `.gitconfig` (identity, aliases; never a credential helper's store).
    GitConfig,
    /// Editor settings: VS Code / Cursor `settings.json`, keybindings, extension list; nvim, vim,
    /// helix, zed.
    Editor,
    /// An agent's settings and instructions (`~/.claude/settings.json`, `CLAUDE.md`, skills,
    /// `~/.codex/config.toml`, `AGENTS.md`).
    AgentSettings,
    /// An agent's chat histories.
    AgentHistory,
    /// An agent's login (OAuth tokens): secret.
    AgentLogin,
    /// `~/.ssh/config` (never private keys: the machine gets its own, and GitHub its own deploy
    /// path through `cloud setup-github`).
    SshConfig,
    /// A dotfiles repo the person already keeps (`~/.dotfiles` with a remote).
    DotfilesRepo,
}

impl CarryKind {
    pub fn is_secret(self) -> bool {
        matches!(self, CarryKind::AgentLogin)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Carry {
    pub kind: CarryKind,
    /// On the source, home-relative where it can be (`~/.zshrc`).
    pub path: String,
    #[serde(default)]
    pub bytes: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<Agent>,
    #[serde(default = "yes")]
    pub checked: bool,
}

/// One action that applies part of a plan, through Cloud actions that already exist. The CLI and
/// the app run them in order; each finished one is recorded in the ledger before the next.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "step", rename_all = "kebab-case")]
pub enum Step {
    /// `cloud new-machine --name NAME [--repo URL] --machine-config FILE`.
    CreateMachine {
        project: String,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        repo: Option<String>,
        machine_toml: String,
    },
    /// Local work a clone would miss, as a git bundle pushed to the machine and fetched there.
    CarryWorktree { project: String, path: String },
    /// `cloud deliver-secrets` for these names (values read on the source, never printed).
    DeliverSecrets { project: String, names: Vec<String> },
    /// Machine-wide files to every new machine.
    CarryFiles { paths: Vec<String> },
    /// Secret machine-wide files (agent logins) over the secret channel.
    CarrySecretFiles { paths: Vec<String> },
    /// `cloud move` / `agent move` of the project's chats onto its machine.
    MoveChats { project: String, chats: Vec<String> },
}

impl Plan {
    pub fn new(source: Source) -> Self {
        Self {
            version: VERSION,
            source,
            projects: Vec::new(),
            carry: Vec::new(),
            warnings: Vec::new(),
            unsupported: Vec::new(),
        }
    }

    /// The steps that apply the checked parts of this plan, projects first (so the first chat can
    /// start as soon as its machine is up), then machine-wide carry.
    pub fn steps(&self) -> Vec<Step> {
        let mut steps = Vec::new();
        for project in self.projects.iter().filter(|p| p.checked) {
            steps.push(Step::CreateMachine {
                project: project.key.clone(),
                name: project.name.clone(),
                repo: project.repo.as_ref().and_then(|r| r.url.clone()),
                machine_toml: crate::machine_toml::render(&project.machine),
            });
            if let Some(repo) = &project.repo
                && repo.carry_worktree()
                && let Some(path) = &repo.path
            {
                steps
                    .push(Step::CarryWorktree { project: project.key.clone(), path: path.clone() });
            }
            if !project.machine.secret_names.is_empty() {
                steps.push(Step::DeliverSecrets {
                    project: project.key.clone(),
                    names: project.machine.secret_names.iter().cloned().collect(),
                });
            }
            if !project.chats.is_empty() {
                steps.push(Step::MoveChats {
                    project: project.key.clone(),
                    chats: project.chats.iter().map(|c| c.path.clone()).collect(),
                });
            }
        }
        let (secret, plain): (Vec<&Carry>, Vec<&Carry>) =
            self.carry.iter().filter(|c| c.checked).partition(|c| c.kind.is_secret());
        if !plain.is_empty() {
            steps.push(Step::CarryFiles { paths: plain.iter().map(|c| c.path.clone()).collect() });
        }
        if !secret.is_empty() {
            steps.push(Step::CarrySecretFiles {
                paths: secret.iter().map(|c| c.path.clone()).collect(),
            });
        }
        steps
    }
}

/// A machine name from anything: lowercase `[a-z0-9-]`, no leading or trailing dash, at most 40
/// characters, never empty.
pub fn machine_name(from: &str) -> String {
    let mut out = String::new();
    for c in from.chars() {
        let c = c.to_ascii_lowercase();
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if !out.ends_with('-') && !out.is_empty() {
            out.push('-');
        }
    }
    let mut out: String = out.chars().take(40).collect();
    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() { "project".to_owned() } else { out }
}

/// A clone URL with any `user:token@` removed, and `git@host:owner/repo` kept as is.
pub fn strip_login(url: &str) -> String {
    let url = url.trim();
    if let Some((scheme, rest)) = url.split_once("://")
        && let Some((auth, host)) = rest.split_once('@')
        && !auth.contains('/')
    {
        return format!("{scheme}://{host}");
    }
    url.to_owned()
}

#[cfg(test)]
mod tests;
