//! This Mac (or Linux laptop): its git checkouts, each with the `.cmux/machine.toml` its lockfiles
//! imply, the agent chats that ran in it, and the machine-wide things that follow a person
//! (shell and editor settings, agent settings, histories and logins, `~/.ssh/config`).
//!
//! The core ([`plan`]) is pure over a home folder: it reads files, never runs anything, and never
//! puts a secret's contents in the plan (an `.env`, an agent login, an SSH key: names and sizes
//! only). The two facts a file read cannot give cheaply (uncommitted files, unpushed commits) come
//! from a [`GitFacts`]; [`GitCli`] fills them with `git`, [`NoGitFacts`] leaves them zero.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::plan::{
    Agent, Carry, CarryKind, ChatRef, MachineConfig, Plan, Project, Repo, Source, SourceKind,
    Unsupported, machine_name, strip_login,
};

/// Where people keep checkouts, home-relative. Projects agent histories mention are added to these.
pub const DEFAULT_ROOTS: &[&str] =
    &["code", "src", "Projects", "Developer", "dev", "work", "repos", "github"];

/// Folders a checkout walk never enters (besides hidden ones).
const SKIP_DIRS: &[&str] = &[
    "node_modules",
    "Library",
    "target",
    "vendor",
    "Pods",
    "DerivedData",
    "__pycache__",
    "venv",
    "Applications",
    "Movies",
    "Music",
    "Pictures",
];

/// Directories one walk reads at most, across all roots.
const MAX_DIRS_READ: usize = 50_000;
/// Agent history files read for a working folder, per agent.
const MAX_HISTORY_FILES: usize = 5_000;
/// Bytes read from the head of one history file to find its working folder.
const HISTORY_HEAD_BYTES: u64 = 1 << 20;
/// Entries counted when totalling a folder's size.
const MAX_SIZE_ENTRIES: usize = 200_000;

/// What to read and how far.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Options {
    /// The machine's name: the source id is `laptop:<host>`.
    pub host: String,
    /// Folders searched for checkouts. `None`: [`DEFAULT_ROOTS`] under the home.
    pub roots: Option<Vec<PathBuf>>,
    /// How deep under a root a checkout may sit (a root's child is depth 1).
    pub max_depth: usize,
    /// Checkouts read at most; past it the plan warns.
    pub max_repos: usize,
    /// Reading a Mac: Claude Code's login sits in the Keychain, not a file.
    pub macos: bool,
}

impl Options {
    pub fn new(host: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            roots: None,
            max_depth: 4,
            max_repos: 500,
            macos: cfg!(target_os = "macos"),
        }
    }
}

/// Local work a clone would not have.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Work {
    pub dirty_files: u32,
    pub unpushed_commits: u32,
}

/// The git facts a file read cannot give: filled by the CLI ([`GitCli`]) or a test.
pub trait GitFacts {
    fn work(&self, checkout: &Path) -> Work;
}

/// Leaves every count at zero (a dry run that must not run `git`).
#[derive(Clone, Copy, Debug, Default)]
pub struct NoGitFacts;

impl GitFacts for NoGitFacts {
    fn work(&self, _checkout: &Path) -> Work {
        Work::default()
    }
}

impl<F: Fn(&Path) -> Work> GitFacts for F {
    fn work(&self, checkout: &Path) -> Work {
        self(checkout)
    }
}

/// The plan for this machine.
pub fn plan(home: &Path, options: &Options, git: &dyn GitFacts) -> Plan {
    let mut plan = Plan::new(Source {
        kind: SourceKind::Laptop,
        label: if options.macos { "this Mac".to_owned() } else { "this laptop".to_owned() },
        id: format!("laptop:{}", options.host),
    });

    let history = History::read(home);
    let roots = options
        .roots
        .clone()
        .unwrap_or_else(|| DEFAULT_ROOTS.iter().map(|r| home.join(r)).collect());
    let found = find_checkouts(&roots, &history.folders(), options.max_depth, options.max_repos);
    if found.truncated {
        plan.warnings.push(format!(
            "stopped looking after {} checkouts; pass the folders to read to see the rest",
            options.max_repos
        ));
    }

    let mut names = BTreeSet::new();
    for checkout in &found.checkouts {
        let project = project(home, checkout, &history, git, &mut plan.warnings);
        let mut name = project.name.clone();
        let mut n = 2usize;
        while !names.insert(name.clone()) {
            let suffix = format!("-{n}");
            let stem: String =
                project.name.chars().take(40usize.saturating_sub(suffix.len())).collect();
            name = format!("{}{suffix}", stem.trim_end_matches('-'));
            n = n.saturating_add(1);
        }
        plan.projects.push(Project { name, ..project });
    }

    carry(home, options, &mut plan);
    plan
}

/// The machine's name for the source id: `$HOSTNAME`, else `hostname`, else "laptop".
pub fn host_name() -> String {
    let from_env = std::env::var("HOSTNAME").ok().filter(|h| !h.trim().is_empty());
    let name = from_env.or_else(|| {
        let out = Command::new("hostname").stderr(Stdio::null()).output().ok()?;
        let text = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        (!text.is_empty()).then_some(text)
    });
    let name = name.unwrap_or_else(|| "laptop".to_owned());
    name.trim().trim_end_matches(".local").to_owned()
}

// ---- checkouts ------------------------------------------------------------------------------

/// The checkouts found, deduplicated by real path, in the order found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Found {
    pub checkouts: Vec<PathBuf>,
    /// The repo bound or the folder bound was reached.
    pub truncated: bool,
}

/// Git checkouts under `roots` (at most `max_depth` deep, never entering hidden, dependency or
/// macOS library folders, nor a checkout's own subfolders) and the checkouts holding `extra`
/// folders (the ones agent histories mention).
pub fn find_checkouts(
    roots: &[PathBuf],
    extra: &[PathBuf],
    max_depth: usize,
    max_repos: usize,
) -> Found {
    let mut found = Found::default();
    let mut seen = BTreeSet::new();
    let mut dirs_read = 0usize;
    let mut add = |found: &mut Found, path: &Path| {
        let real = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        if found.checkouts.len() >= max_repos {
            found.truncated = true;
            return;
        }
        if seen.insert(real.clone()) {
            found.checkouts.push(real);
        }
    };
    for root in roots {
        let mut stack = vec![(root.clone(), 0usize)];
        while let Some((dir, depth)) = stack.pop() {
            if is_checkout(&dir) {
                add(&mut found, &dir);
                continue;
            }
            if depth >= max_depth {
                continue;
            }
            if dirs_read >= MAX_DIRS_READ {
                found.truncated = true;
                break;
            }
            dirs_read = dirs_read.saturating_add(1);
            let Ok(entries) = fs::read_dir(&dir) else { continue };
            let mut children: Vec<PathBuf> = entries
                .filter_map(Result::ok)
                .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                .filter(|e| {
                    let name = e.file_name();
                    let name = name.to_string_lossy();
                    !name.starts_with('.') && !SKIP_DIRS.contains(&name.as_ref())
                })
                .map(|e| e.path())
                .collect();
            children.sort();
            stack.extend(children.into_iter().rev().map(|c| (c, depth.saturating_add(1))));
        }
    }
    for folder in extra {
        if let Some(root) = checkout_of(folder) {
            add(&mut found, &root);
        }
    }
    found
}

fn is_checkout(dir: &Path) -> bool {
    let git = dir.join(".git");
    git.is_dir() || git.is_file()
}

/// The checkout holding `folder`: it or its nearest ancestor with a `.git`.
fn checkout_of(folder: &Path) -> Option<PathBuf> {
    if !folder.is_dir() {
        return None;
    }
    folder.ancestors().take(64).find(|dir| is_checkout(dir)).map(Path::to_path_buf)
}

/// The git dir of a checkout: `.git`, or the folder a worktree's `.git` file points to.
fn git_dir(checkout: &Path) -> Option<PathBuf> {
    let dot = checkout.join(".git");
    if dot.is_dir() {
        return Some(dot);
    }
    let text = fs::read_to_string(&dot).ok()?;
    let target = text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim();
    let target = Path::new(target);
    Some(if target.is_absolute() { target.to_path_buf() } else { checkout.join(target) })
}

/// The shared git dir holding `config` and packed refs (a worktree's `commondir`).
fn common_dir(git_dir: &Path) -> PathBuf {
    match fs::read_to_string(git_dir.join("commondir")) {
        Ok(text) => {
            let p = Path::new(text.trim());
            if p.is_absolute() { p.to_path_buf() } else { git_dir.join(p) }
        }
        Err(_) => git_dir.to_path_buf(),
    }
}

/// `origin`'s URL (else the first remote's), from git config text.
pub fn remote_url(config: &str) -> Option<String> {
    let mut remotes: Vec<(String, String)> = Vec::new();
    let mut section: Option<String> = None;
    for line in config.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            section = line
                .strip_prefix("[remote \"")
                .and_then(|r| r.strip_suffix("\"]"))
                .map(str::to_owned);
            continue;
        }
        let Some(remote) = &section else { continue };
        if let Some((key, value)) = line.split_once('=')
            && key.trim() == "url"
            && !remotes.iter().any(|(r, _)| r == remote)
        {
            remotes.push((remote.clone(), value.trim().trim_matches('"').to_owned()));
        }
    }
    remotes
        .iter()
        .find(|(r, _)| r == "origin")
        .or_else(|| remotes.first())
        .map(|(_, url)| strip_login(url))
}

fn read_repo(checkout: &Path) -> Repo {
    let mut repo = Repo::default();
    let Some(git) = git_dir(checkout) else { return repo };
    let common = common_dir(&git);
    repo.url = fs::read_to_string(common.join("config")).ok().and_then(|c| remote_url(&c));
    let head = fs::read_to_string(git.join("HEAD")).unwrap_or_default();
    let head = head.trim();
    if let Some(reference) = head.strip_prefix("ref:") {
        let reference = reference.trim();
        repo.branch = reference.strip_prefix("refs/heads/").map(str::to_owned);
        repo.commit = read_ref(&common, reference);
    } else if is_sha(head) {
        repo.commit = Some(head.to_owned());
    }
    repo
}

fn read_ref(common: &Path, reference: &str) -> Option<String> {
    if let Ok(text) = fs::read_to_string(common.join(reference)) {
        let sha = text.trim();
        return is_sha(sha).then(|| sha.to_owned());
    }
    let packed = fs::read_to_string(common.join("packed-refs")).ok()?;
    packed.lines().find_map(|line| {
        let (sha, name) = line.split_once(' ')?;
        (name.trim() == reference && is_sha(sha)).then(|| sha.to_owned())
    })
}

fn is_sha(s: &str) -> bool {
    (s.len() == 40 || s.len() == 64) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn project(
    home: &Path,
    checkout: &Path,
    history: &History,
    git: &dyn GitFacts,
    warnings: &mut Vec<String>,
) -> Project {
    let shown = tilde(home, checkout);
    let mut repo = read_repo(checkout);
    let work = git.work(checkout);
    repo.dirty_files = work.dirty_files;
    repo.unpushed_commits = work.unpushed_commits;
    repo.path = Some(shown.clone());
    if repo.url.is_none() {
        warnings.push(format!("{shown}: no remote; the working tree is carried as a git bundle"));
    } else if repo.carry_worktree() {
        warnings.push(format!(
            "{shown}: {} uncommitted files and {} unpushed commits ride along as a git bundle",
            repo.dirty_files, repo.unpushed_commits
        ));
    }
    let (machine, mut notes) = machine_config(checkout);
    for env in [".env", ".env.local"] {
        if checkout.join(env).is_file() {
            warnings.push(format!(
                "{shown}/{env}: its values will be offered for delivery as secrets (never printed)"
            ));
        }
    }
    if checkout.join(".git").is_file() {
        notes.push("a git worktree: its main checkout's remote is used".to_owned());
    }
    let name = checkout
        .file_name()
        .map(|n| machine_name(&n.to_string_lossy()))
        .unwrap_or_else(|| "project".to_owned());
    Project {
        key: shown,
        name,
        repo: Some(repo),
        machine,
        chats: history.chats_for(home, checkout),
        checked: true,
        notes,
        ..Project::default()
    }
}

// ---- machine config -------------------------------------------------------------------------

/// The `.cmux/machine.toml` a checkout's lockfiles and toolchain files imply, and notes for the
/// person. A checkout that already has `.cmux/machine.toml` keeps its own: setup stays empty.
pub fn machine_config(checkout: &Path) -> (MachineConfig, Vec<String>) {
    let mut machine = MachineConfig::default();
    let mut notes = Vec::new();
    let has = |name: &str| checkout.join(name).exists();

    machine.secret_names = secret_names(checkout);
    if has(".devcontainer/devcontainer.json") || has(".devcontainer.json") {
        notes.push("devcontainer found: see the devcontainer source".to_owned());
    }
    if has(".cmux/machine.toml") {
        notes.push(
            "has its own .cmux/machine.toml: the machine applies the checkout's own".to_owned(),
        );
        return (machine, notes);
    }

    let setup = &mut machine.setup;
    if has(".tool-versions") || has("mise.toml") || has(".mise.toml") {
        setup.push("mise install".to_owned());
    } else if let Ok(text) = fs::read_to_string(checkout.join(".nvmrc")) {
        let version = text.trim().trim_start_matches('v');
        if !version.is_empty()
            && version.chars().all(|c| c.is_ascii_alphanumeric() || ".-_/".contains(c))
        {
            setup.push(format!("mise use --global node@{version}"));
        } else {
            notes.push(format!(".nvmrc names {:?}: install that Node by hand", text.trim()));
        }
    }
    if has("bun.lock") || has("bun.lockb") {
        setup.push("bun install".to_owned());
    } else if has("pnpm-lock.yaml") {
        setup.push("pnpm install --frozen-lockfile".to_owned());
    } else if has("yarn.lock") {
        setup.push(if has(".yarnrc.yml") {
            "yarn install --immutable".to_owned()
        } else {
            "yarn install --frozen-lockfile".to_owned()
        });
    } else if has("package-lock.json") {
        setup.push("npm ci".to_owned());
    }
    if has("uv.lock") {
        setup.push("uv sync".to_owned());
    } else if has("poetry.lock") {
        setup.push("poetry install".to_owned());
    } else if has("requirements.txt") {
        setup.push("pip install -r requirements.txt".to_owned());
    }
    if has("Cargo.toml") {
        setup.push("cargo fetch".to_owned());
    }
    if has("go.mod") {
        setup.push("go mod download".to_owned());
    }
    if has("Gemfile.lock") {
        setup.push("bundle install".to_owned());
    }
    (machine, notes)
}

/// The variable names an `.env.example` / `.env.sample` / `.env.template` lists. Values are never
/// kept.
pub fn secret_names(checkout: &Path) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    for file in [".env.example", ".env.sample", ".env.template"] {
        let Ok(text) = fs::read_to_string(checkout.join(file)) else { continue };
        for line in text.lines() {
            let line = line.trim();
            let line = line.strip_prefix("export ").unwrap_or(line);
            let Some((key, _value)) = line.split_once('=') else { continue };
            let key = key.trim();
            if !key.is_empty()
                && !key.starts_with('#')
                && !key.starts_with(|c: char| c.is_ascii_digit())
                && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            {
                names.insert(key.to_owned());
            }
        }
    }
    names
}

// ---- agent histories ------------------------------------------------------------------------

/// The working folders agent histories record, each with the chat that ran there.
#[derive(Clone, Debug, Default)]
struct History {
    /// (working folder, chat).
    chats: Vec<(PathBuf, ChatRef)>,
    /// Claude Code project folders by name, for the slug fallback.
    claude_folders: BTreeMap<String, PathBuf>,
}

impl History {
    fn read(home: &Path) -> Self {
        let mut history = Self::default();
        history.read_claude(home);
        history.read_codex(home);
        history.read_cursor(home);
        history
    }

    fn folders(&self) -> Vec<PathBuf> {
        let set: BTreeSet<&PathBuf> = self.chats.iter().map(|(cwd, _)| cwd).collect();
        set.into_iter().cloned().collect()
    }

    fn read_claude(&mut self, home: &Path) {
        let Ok(entries) = fs::read_dir(home.join(".claude/projects")) else { return };
        for entry in entries.filter_map(Result::ok).take(MAX_HISTORY_FILES) {
            let folder = entry.path();
            if !folder.is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            self.claude_folders.insert(name, folder.clone());
            let mut transcripts: Vec<PathBuf> = fs::read_dir(&folder)
                .into_iter()
                .flatten()
                .filter_map(Result::ok)
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
                .collect();
            transcripts.sort();
            let cwd = transcripts.iter().take(3).find_map(|t| head_cwd(t, 50));
            if let Some(cwd) = cwd {
                let chat = ChatRef { agent: Agent::Claude, path: tilde(home, &folder) };
                self.chats.push((real(&cwd), chat));
            }
        }
    }

    fn read_codex(&mut self, home: &Path) {
        let mut files = Vec::new();
        walk_files(&home.join(".codex/sessions"), 4, &mut files, MAX_HISTORY_FILES);
        for file in files.iter().filter(|f| f.extension().is_some_and(|x| x == "jsonl")) {
            if let Some(cwd) = head_cwd(file, 1) {
                let chat = ChatRef { agent: Agent::Codex, path: tilde(home, file) };
                self.chats.push((real(&cwd), chat));
            }
        }
    }

    fn read_cursor(&mut self, home: &Path) {
        for user in editor_user_dirs(home, "Cursor") {
            let Ok(entries) = fs::read_dir(user.join("workspaceStorage")) else { continue };
            for entry in entries.filter_map(Result::ok).take(MAX_HISTORY_FILES) {
                let Ok(text) = fs::read_to_string(entry.path().join("workspace.json")) else {
                    continue;
                };
                let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else { continue };
                let Some(folder) = value.get("folder").and_then(|f| f.as_str()) else { continue };
                let Some(path) = folder.strip_prefix("file://") else { continue };
                let chat = ChatRef { agent: Agent::Cursor, path: tilde(home, &entry.path()) };
                self.chats.push((real(Path::new(&percent_decode(path))), chat));
            }
        }
    }

    /// The chats that ran in `checkout` or a folder inside it, plus Claude Code's folder for the
    /// checkout's own path.
    fn chats_for(&self, home: &Path, checkout: &Path) -> Vec<ChatRef> {
        let mut chats: Vec<ChatRef> = self
            .chats
            .iter()
            .filter(|(cwd, _)| cwd.starts_with(checkout))
            .map(|(_, chat)| chat.clone())
            .collect();
        if let Some(folder) = self.claude_folders.get(&claude_slug(checkout)) {
            let chat = ChatRef { agent: Agent::Claude, path: tilde(home, folder) };
            if !chats.contains(&chat) {
                chats.push(chat);
            }
        }
        chats.sort_by(|a, b| (a.agent, &a.path).cmp(&(b.agent, &b.path)));
        chats.dedup();
        chats
    }
}

/// Claude Code's folder name for `path`: every character that is not an ASCII letter or digit
/// becomes `-` (the rule `cmux-conductor-import` links by).
pub fn claude_slug(path: &Path) -> String {
    path.to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// The first `cwd` field in the first `lines` lines of a JSONL file (top level or in `payload`),
/// reading at most [`HISTORY_HEAD_BYTES`].
fn head_cwd(file: &Path, lines: usize) -> Option<PathBuf> {
    let reader = BufReader::new(fs::File::open(file).ok()?.take(HISTORY_HEAD_BYTES));
    for line in reader.split(b'\n').take(lines) {
        let line = line.ok()?;
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(&line) else { continue };
        let cwd = value
            .get("cwd")
            .or_else(|| value.get("payload").and_then(|p| p.get("cwd")))
            .and_then(|c| c.as_str());
        if let Some(cwd) = cwd.filter(|c| c.starts_with('/')) {
            return Some(PathBuf::from(cwd));
        }
    }
    None
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0usize;
    while let Some(&byte) = bytes.get(i) {
        if byte == b'%'
            && let Some(hex) = bytes.get(i.saturating_add(1)..i.saturating_add(3))
            && let Ok(hex) = std::str::from_utf8(hex)
            && let Ok(b) = u8::from_str_radix(hex, 16)
        {
            out.push(b);
            i = i.saturating_add(3);
        } else {
            out.push(byte);
            i = i.saturating_add(1);
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ---- machine-wide carry ---------------------------------------------------------------------

const SHELL: &[&str] = &[
    ".zshrc",
    ".zprofile",
    ".zshenv",
    ".bashrc",
    ".bash_profile",
    ".profile",
    ".bash_aliases",
    ".aliases",
    ".inputrc",
    ".tmux.conf",
    ".config/starship.toml",
    ".config/fish/config.fish",
];
const SHELL_HISTORY: &[&str] = &[".zsh_history", ".bash_history", ".local/share/fish/fish_history"];
const EDITOR: &[&str] = &[
    ".config/nvim",
    ".vimrc",
    ".vim",
    ".config/zed/settings.json",
    ".config/zed/keymap.json",
    ".config/helix",
];
const AGENT_SETTINGS: &[(&str, Agent)] = &[
    (".claude/settings.json", Agent::Claude),
    (".claude/CLAUDE.md", Agent::Claude),
    (".claude/skills", Agent::Claude),
    (".claude/agents", Agent::Claude),
    (".claude/commands", Agent::Claude),
    (".codex/config.toml", Agent::Codex),
    (".codex/AGENTS.md", Agent::Codex),
];
const AGENT_HISTORY: &[(&str, Agent)] =
    &[(".claude/projects", Agent::Claude), (".codex/sessions", Agent::Codex)];
const AGENT_LOGIN: &[(&str, Agent)] =
    &[(".codex/auth.json", Agent::Codex), (".claude/.credentials.json", Agent::Claude)];

fn carry(home: &Path, options: &Options, plan: &mut Plan) {
    let add = |plan: &mut Plan, kind: CarryKind, path: &Path, agent: Option<Agent>| {
        if path.exists() {
            plan.carry.push(Carry {
                kind,
                path: tilde(home, path),
                bytes: size(path),
                agent,
                checked: true,
            });
        }
    };
    for rel in SHELL {
        add(plan, CarryKind::Shell, &home.join(rel), None);
    }
    for rel in SHELL_HISTORY {
        add(plan, CarryKind::ShellHistory, &home.join(rel), None);
    }

    for rel in [".gitconfig", ".config/git/config"] {
        let path = home.join(rel);
        let Ok(text) = fs::read_to_string(&path) else { continue };
        if stores_credentials(&text) {
            plan.warnings.push(format!(
                "~/{rel} uses git's credential store (plain-text tokens): not carried; \
                 the machine signs in to GitHub through `cloud setup-github`"
            ));
        } else {
            add(plan, CarryKind::GitConfig, &path, None);
        }
    }
    if home.join(".git-credentials").exists() {
        plan.warnings.push(
            "~/.git-credentials holds plain-text tokens: not carried; the machine signs in to \
             GitHub through `cloud setup-github`"
                .to_owned(),
        );
    }

    for app in ["Code", "Cursor"] {
        for user in editor_user_dirs(home, app) {
            for file in ["settings.json", "keybindings.json", "snippets"] {
                add(plan, CarryKind::Editor, &user.join(file), None);
            }
        }
    }
    for dir in [".vscode/extensions", ".cursor/extensions"] {
        add(plan, CarryKind::Editor, &home.join(dir).join("extensions.json"), None);
    }
    for rel in EDITOR {
        add(plan, CarryKind::Editor, &home.join(rel), None);
    }

    for (rel, agent) in AGENT_SETTINGS {
        add(plan, CarryKind::AgentSettings, &home.join(rel), Some(*agent));
    }
    for (rel, agent) in AGENT_HISTORY {
        add(plan, CarryKind::AgentHistory, &home.join(rel), Some(*agent));
    }
    for (rel, agent) in AGENT_LOGIN {
        add(plan, CarryKind::AgentLogin, &home.join(rel), Some(*agent));
    }
    if options.macos && !home.join(".claude/.credentials.json").exists() {
        plan.unsupported.push(Unsupported {
            what: "Claude Code login (macOS Keychain)".to_owned(),
            why: "Claude Code keeps its Mac login in the Keychain, which no file copy reaches; \
                  the cmux sign-in flow carries it instead"
                .to_owned(),
        });
    }

    add(plan, CarryKind::SshConfig, &home.join(".ssh/config"), None);

    for rel in [".dotfiles", "dotfiles"] {
        let dir = home.join(rel);
        if is_checkout(&dir) && read_repo(&dir).url.is_some() {
            plan.carry.push(Carry {
                kind: CarryKind::DotfilesRepo,
                path: tilde(home, &dir),
                bytes: 0,
                agent: None,
                checked: true,
            });
        }
    }
}

/// Whether git config text sets `credential.helper` to `store` (tokens in a plain file).
pub fn stores_credentials(config: &str) -> bool {
    let mut in_credential = false;
    for line in config.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_credential = line.trim_start_matches('[').trim_start().starts_with("credential");
            continue;
        }
        if !in_credential {
            continue;
        }
        if let Some((key, value)) = line.split_once('=')
            && key.trim().eq_ignore_ascii_case("helper")
            && value.trim().trim_matches('"').split_whitespace().next() == Some("store")
        {
            return true;
        }
    }
    false
}

/// VS Code's or Cursor's `User` folder, on macOS and Linux.
fn editor_user_dirs(home: &Path, app: &str) -> Vec<PathBuf> {
    [
        home.join("Library/Application Support").join(app).join("User"),
        home.join(".config").join(app).join("User"),
    ]
    .into_iter()
    .filter(|p| p.is_dir())
    .collect()
}

/// The extensions installed for `app` (`"vscode"` or `"cursor"`), by folder name, for the CLI to
/// list or install. Not run through the editor.
pub fn editor_extensions(home: &Path, app: &str) -> Vec<String> {
    let Ok(entries) = fs::read_dir(home.join(format!(".{app}/extensions"))) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.starts_with('.'))
        .collect();
    names.sort();
    names
}

// ---- small helpers --------------------------------------------------------------------------

/// `~/rest` for a path under the home, else the path.
fn tilde(home: &Path, path: &Path) -> String {
    let home_real = real(home);
    let path_real = real(path);
    for (h, p) in [(home, path), (home_real.as_path(), path_real.as_path())] {
        if let Ok(rest) = p.strip_prefix(h) {
            return if rest.as_os_str().is_empty() {
                "~".to_owned()
            } else {
                format!("~/{}", rest.to_string_lossy())
            };
        }
    }
    path.to_string_lossy().into_owned()
}

fn real(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// A file's size, or a folder's total (symlinks not followed, bounded).
fn size(path: &Path) -> u64 {
    let Ok(meta) = fs::symlink_metadata(path) else { return 0 };
    if !meta.is_dir() {
        return meta.len();
    }
    let mut total = 0u64;
    let mut stack = vec![path.to_path_buf()];
    let mut seen = 0usize;
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.filter_map(Result::ok) {
            seen = seen.saturating_add(1);
            if seen > MAX_SIZE_ENTRIES {
                return total;
            }
            let Ok(meta) = entry.metadata() else { continue };
            if entry.file_type().is_ok_and(|t| t.is_symlink()) {
                continue;
            }
            if meta.is_dir() {
                stack.push(entry.path());
            } else {
                total = total.saturating_add(meta.len());
            }
        }
    }
    total
}

/// Files under `dir`, at most `depth` folders down and `max` in all, sorted.
fn walk_files(dir: &Path, depth: usize, out: &mut Vec<PathBuf>, max: usize) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    let mut entries: Vec<_> = entries.filter_map(Result::ok).collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        if out.len() >= max {
            return;
        }
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() && depth > 0 {
            walk_files(&entry.path(), depth.saturating_sub(1), out, max);
        } else if kind.is_file() {
            out.push(entry.path());
        }
    }
}

// ---- the git facts, by running git (not part of the pure core) ------------------------------

/// Fills [`Work`] by running `git` in each checkout through `cmux-git`: read-only, bounded, and
/// confined (no hook, filter, fsmonitor or transport from the repository runs), each call bounded
/// by `timeout`.
#[derive(Clone, Copy, Debug)]
pub struct GitCli {
    pub timeout: Duration,
}

impl Default for GitCli {
    fn default() -> Self {
        Self { timeout: Duration::from_secs(20) }
    }
}

impl GitCli {
    fn run(&self, checkout: &Path, args: &[&str]) -> Option<String> {
        let overrides = cmux_git::filter_overrides(checkout).ok()?;
        let output =
            cmux_git::run::run_git_within(checkout, &overrides, args, 16 << 20, self.timeout)
                .ok()?;
        Some(String::from_utf8_lossy(&output.stdout).into_owned())
    }
}

impl GitFacts for GitCli {
    fn work(&self, checkout: &Path) -> Work {
        let dirty = self
            .run(checkout, &["status", "--porcelain", "--untracked-files=normal"])
            .map(|out| out.lines().filter(|l| !l.trim().is_empty()).count())
            .unwrap_or(0);
        let unpushed = self
            .run(checkout, &["rev-list", "--count", "--branches", "--not", "--remotes"])
            .and_then(|out| out.trim().parse::<u32>().ok())
            .unwrap_or(0);
        Work { dirty_files: u32::try_from(dirty).unwrap_or(u32::MAX), unpushed_commits: unpushed }
    }
}

#[cfg(test)]
#[path = "laptop_tests.rs"]
mod tests;
