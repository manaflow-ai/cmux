//! T3 Code: the projects, thread worktrees and native agent transcripts of another agent client on
//! this computer (cmuxterm-hq#23822, the switch kit).
//!
//! T3 Code keeps everything in one SQLite file, `$T3CODE_HOME/userdata/statev2.sqlite`
//! (`~/.t3` when unset). Its threads run Claude Code or Codex underneath, and it records each
//! thread's native session id, so a move carries the very transcript the thread ran, and the
//! agent resumes it on the Cloud machine.
//!
//! What is read, read-only (the database is opened `SQLITE_OPEN_READ_ONLY`, T3 Code may be
//! running; nothing under its home is written, created or locked):
//!
//! - `projection_projects`: each project's folder (`workspace_root`), title, archive and delete
//!   marks, and its script **names**.
//! - `orchestration_v2_projection_threads` (and the older `projection_threads`): each thread's
//!   title, branch, worktree, model and archive and delete marks.
//! - `orchestration_v2_projection_provider_threads`: `nativeThreadRef`, the Claude Code or Codex
//!   session id behind each thread.
//! - `orchestration_v2_projection_messages`: a count per thread, for the preview. The text is
//!   never read: the native transcript is the history that moves.
//!
//! Never read, and listed as such in the plan: the `auth_*` tables, `userdata/secrets/`, peer
//! environment links (other people's or other machines' T3 servers), script commands (data, never
//! run on the new machine), attachments and keybindings.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags};
use serde_json::Value;

use super::laptop::{self, GitFacts, History};
use crate::plan::{Agent, ChatRef, Plan, Project, Source, SourceKind, Unsupported, machine_name};

/// The database under a T3 home.
pub const DATABASE: &str = "userdata/statev2.sqlite";

/// Rows read per table at most: a damaged or huge database cannot take unbounded memory.
const MAX_ROWS: usize = 5_000;

/// The T3 home: `T3CODE_HOME` when it is an absolute path, else `~/.t3`.
pub fn home_dir(home: &Path, t3code_home: Option<&str>) -> PathBuf {
    match t3code_home.map(str::trim).filter(|v| v.starts_with('/')) {
        Some(explicit) => PathBuf::from(explicit),
        None => home.join(".t3"),
    }
}

/// One T3 project.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct T3Project {
    pub id: String,
    pub title: String,
    pub root: PathBuf,
    pub archived: bool,
    pub deleted: bool,
    /// Script names only (`scripts_json[].name`); their commands are never read into a plan.
    pub script_names: Vec<String>,
}

/// The agent behind a thread, and its own session id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NativeRef {
    pub agent: Agent,
    pub id: String,
}

/// One T3 thread.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct T3Thread {
    pub id: String,
    pub project_id: String,
    pub title: String,
    pub branch: Option<String>,
    pub worktree: Option<PathBuf>,
    pub model: Option<String>,
    pub archived: bool,
    pub deleted: bool,
    pub native: Option<NativeRef>,
    pub messages: u32,
}

/// What [`read`] found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Catalog {
    pub projects: Vec<T3Project>,
    pub threads: Vec<T3Thread>,
    /// Tables present that are never read (auth, peers), for the plan's "not carried" list.
    pub skipped_tables: Vec<String>,
    /// Tables cut at `MAX_ROWS`: the plan says so instead of moving part of them silently.
    pub truncated: Vec<String>,
}

#[derive(Debug)]
pub enum ReadError {
    Missing(PathBuf),
    Open(String),
    Schema(String),
}

impl fmt::Display for ReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Missing(p) => write!(f, "no T3 Code database at {}", p.display()),
            Self::Open(e) => write!(f, "T3 Code's database could not be opened read-only: {e}"),
            Self::Schema(e) => {
                write!(f, "T3 Code's database is a shape this reader does not know: {e}")
            }
        }
    }
}

impl std::error::Error for ReadError {}

fn columns(conn: &Connection, table: &str) -> Result<Vec<String>, ReadError> {
    let mut stmt = conn
        .prepare("SELECT name FROM pragma_table_info(?1)")
        .map_err(|e| ReadError::Schema(e.to_string()))?;
    let names = stmt
        .query_map([table], |r| r.get::<_, String>(0))
        .map_err(|e| ReadError::Schema(e.to_string()))?
        .filter_map(Result::ok)
        .collect();
    Ok(names)
}

fn tables(conn: &Connection) -> Result<BTreeSet<String>, ReadError> {
    let mut stmt = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map_err(|e| ReadError::Schema(e.to_string()))?;
    let names = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|e| ReadError::Schema(e.to_string()))?
        .filter_map(Result::ok)
        .collect();
    Ok(names)
}

/// `SELECT` the wanted columns that exist (a missing one reads as NULL), one map per row.
fn rows(
    conn: &Connection,
    table: &str,
    wanted: &[&str],
    truncated: &mut Vec<String>,
) -> Result<Vec<BTreeMap<String, Option<String>>>, ReadError> {
    let have = columns(conn, table)?;
    let present: Vec<&str> =
        wanted.iter().copied().filter(|w| have.iter().any(|h| h == w)).collect();
    if present.is_empty() {
        return Ok(Vec::new());
    }
    let sql = format!(
        "SELECT {} FROM \"{table}\" LIMIT {}",
        present.iter().map(|c| format!("\"{c}\"")).collect::<Vec<_>>().join(", "),
        MAX_ROWS + 1
    );
    let mut stmt = conn.prepare(&sql).map_err(|e| ReadError::Schema(e.to_string()))?;
    let mut out: Vec<_> = stmt
        .query_map([], |r| {
            let mut row = BTreeMap::new();
            for (i, name) in present.iter().enumerate() {
                let value: Option<String> = match r.get_ref(i)? {
                    rusqlite::types::ValueRef::Null => None,
                    rusqlite::types::ValueRef::Integer(n) => Some(n.to_string()),
                    rusqlite::types::ValueRef::Real(n) => Some(n.to_string()),
                    rusqlite::types::ValueRef::Text(t) => {
                        Some(String::from_utf8_lossy(t).into_owned())
                    }
                    rusqlite::types::ValueRef::Blob(_) => None,
                };
                row.insert((*name).to_owned(), value);
            }
            Ok(row)
        })
        .map_err(|e| ReadError::Schema(e.to_string()))?
        .filter_map(Result::ok)
        .collect();
    if out.len() > MAX_ROWS {
        out.truncate(MAX_ROWS);
        truncated.push(table.to_owned());
    }
    Ok(out)
}

fn get<'a>(row: &'a BTreeMap<String, Option<String>>, key: &str) -> Option<&'a str> {
    row.get(key).and_then(Option::as_deref).filter(|s| !s.is_empty())
}

fn json(text: Option<&str>) -> Value {
    text.and_then(|t| serde_json::from_str(t).ok()).unwrap_or(Value::Null)
}

fn json_str<'a>(v: &'a Value, path: &[&str]) -> Option<&'a str> {
    let mut at = v;
    for key in path {
        at = at.get(key)?;
    }
    at.as_str().filter(|s| !s.is_empty())
}

fn agent_of(driver: &str) -> Option<Agent> {
    let d = driver.to_ascii_lowercase();
    if d.starts_with("claude") {
        Some(Agent::Claude)
    } else if d.starts_with("codex") {
        Some(Agent::Codex)
    } else {
        None
    }
}

/// Reads T3 Code's database read-only.
pub fn read(database: &Path) -> Result<Catalog, ReadError> {
    if !database.is_file() {
        return Err(ReadError::Missing(database.to_path_buf()));
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn =
        Connection::open_with_flags(database, flags).map_err(|e| ReadError::Open(e.to_string()))?;
    conn.busy_timeout(std::time::Duration::from_millis(500))
        .map_err(|e| ReadError::Open(e.to_string()))?;
    let present = tables(&conn)?;
    if !present.contains("projection_projects") {
        return Err(ReadError::Schema("no projection_projects table".into()));
    }
    let mut catalog = Catalog {
        skipped_tables: present
            .iter()
            .filter(|t| t.starts_with("auth_") || t.starts_with("peer_"))
            .cloned()
            .collect(),
        ..Catalog::default()
    };

    for row in rows(
        &conn,
        "projection_projects",
        &["project_id", "title", "workspace_root", "scripts_json", "archived_at", "deleted_at"],
        &mut catalog.truncated,
    )? {
        let (Some(id), Some(root)) = (get(&row, "project_id"), get(&row, "workspace_root")) else {
            continue;
        };
        let scripts = json(get(&row, "scripts_json"));
        let script_names = scripts
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|s| s.get("name").and_then(Value::as_str))
            .map(str::to_owned)
            .collect();
        catalog.projects.push(T3Project {
            id: id.to_owned(),
            title: get(&row, "title").unwrap_or(id).to_owned(),
            root: PathBuf::from(root),
            archived: get(&row, "archived_at").is_some(),
            deleted: get(&row, "deleted_at").is_some(),
            script_names,
        });
    }

    // The native session behind each provider thread.
    let mut native: BTreeMap<String, NativeRef> = BTreeMap::new();
    if present.contains("orchestration_v2_projection_provider_threads") {
        for row in rows(
            &conn,
            "orchestration_v2_projection_provider_threads",
            &["provider_thread_id", "thread_id", "payload_json"],
            &mut catalog.truncated,
        )? {
            let payload = json(get(&row, "payload_json"));
            let driver = json_str(&payload, &["nativeThreadRef", "driver"])
                .or_else(|| json_str(&payload, &["driver"]));
            let id = json_str(&payload, &["nativeThreadRef", "nativeId"]);
            let (Some(agent), Some(id)) = (driver.and_then(agent_of), id) else { continue };
            let reference = NativeRef { agent, id: id.to_owned() };
            if let Some(key) = get(&row, "provider_thread_id") {
                native.insert(key.to_owned(), reference.clone());
            }
            if let Some(thread) = get(&row, "thread_id") {
                native.entry(format!("thread:{thread}")).or_insert(reference);
            }
        }
    }

    let mut counts: BTreeMap<String, u32> = BTreeMap::new();
    if present.contains("orchestration_v2_projection_messages") {
        let mut stmt = conn
            .prepare("SELECT thread_id, COUNT(*) FROM orchestration_v2_projection_messages GROUP BY thread_id")
            .map_err(|e| ReadError::Schema(e.to_string()))?;
        for (thread, n) in stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
            .map_err(|e| ReadError::Schema(e.to_string()))?
            .filter_map(Result::ok)
        {
            counts.insert(thread, u32::try_from(n).unwrap_or(u32::MAX));
        }
    }

    let mut seen = BTreeSet::new();
    if present.contains("orchestration_v2_projection_threads") {
        for row in rows(
            &conn,
            "orchestration_v2_projection_threads",
            &[
                "thread_id",
                "project_id",
                "title",
                "active_provider_thread_id",
                "archived_at",
                "deleted_at",
                "payload_json",
            ],
            &mut catalog.truncated,
        )? {
            let Some(id) = get(&row, "thread_id") else { continue };
            let payload = json(get(&row, "payload_json"));
            let reference = get(&row, "active_provider_thread_id")
                .and_then(|p| native.get(p))
                .or_else(|| native.get(&format!("thread:{id}")))
                .cloned();
            seen.insert(id.to_owned());
            catalog.threads.push(T3Thread {
                id: id.to_owned(),
                project_id: get(&row, "project_id").unwrap_or_default().to_owned(),
                title: get(&row, "title").unwrap_or(id).to_owned(),
                branch: json_str(&payload, &["branch"]).map(str::to_owned),
                worktree: json_str(&payload, &["worktreePath"]).map(PathBuf::from),
                model: json_str(&payload, &["modelSelection", "model"]).map(str::to_owned),
                archived: get(&row, "archived_at").is_some(),
                deleted: get(&row, "deleted_at").is_some(),
                native: reference,
                messages: counts.get(id).copied().unwrap_or(0),
            });
        }
    }
    // Older T3 Code builds: the first projection's threads table (columns differ by version).
    if present.contains("projection_threads") {
        for row in rows(
            &conn,
            "projection_threads",
            &[
                "thread_id",
                "project_id",
                "title",
                "branch",
                "worktree_path",
                "model",
                "model_selection_json",
                "archived_at",
                "deleted_at",
            ],
            &mut catalog.truncated,
        )? {
            let Some(id) = get(&row, "thread_id") else { continue };
            if !seen.insert(id.to_owned()) {
                continue;
            }
            let selection = json(get(&row, "model_selection_json"));
            catalog.threads.push(T3Thread {
                id: id.to_owned(),
                project_id: get(&row, "project_id").unwrap_or_default().to_owned(),
                title: get(&row, "title").unwrap_or(id).to_owned(),
                branch: get(&row, "branch").map(str::to_owned),
                worktree: get(&row, "worktree_path").map(PathBuf::from),
                model: get(&row, "model")
                    .or_else(|| json_str(&selection, &["model"]))
                    .map(str::to_owned),
                archived: get(&row, "archived_at").is_some(),
                deleted: get(&row, "deleted_at").is_some(),
                native: native.get(&format!("thread:{id}")).cloned(),
                messages: counts.get(id).copied().unwrap_or(0),
            });
        }
    }
    Ok(catalog)
}

/// The native transcript behind a thread on this computer, when it is there.
fn native_chat(home: &Path, thread: &T3Thread) -> Option<ChatRef> {
    let native = thread.native.as_ref()?;
    // A session id is a uuid-like token: never a path.
    if native.id.is_empty() || native.id.contains(['/', '\\']) || native.id.contains("..") {
        return None;
    }
    match native.agent {
        Agent::Claude => {
            let cwd = thread.worktree.as_deref()?;
            let file = home
                .join(".claude/projects")
                .join(laptop::claude_slug(cwd))
                .join(format!("{}.jsonl", native.id));
            file.is_file()
                .then(|| ChatRef { agent: Agent::Claude, path: laptop::tilde(home, &file) })
        }
        Agent::Codex => {
            let mut files = Vec::new();
            walk(&home.join(".codex/sessions"), 4, &mut files);
            files
                .into_iter()
                .find(|f| f.file_name().is_some_and(|n| n.to_string_lossy().contains(&native.id)))
                .map(|f| ChatRef { agent: Agent::Codex, path: laptop::tilde(home, &f) })
        }
        Agent::Cursor => None,
    }
}

fn walk(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth == 0 || out.len() >= MAX_ROWS {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if entry.file_type().is_ok_and(|t| t.is_dir()) {
            walk(&path, depth - 1, out);
        } else {
            out.push(path);
        }
    }
}

/// The plan: one project per T3 project folder, one per live thread worktree (its own machine,
/// so threads keep running side by side), each with the transcripts that ran there.
pub fn plan(home: &Path, t3_home: &Path, catalog: &Catalog, git: &dyn GitFacts) -> Plan {
    let mut plan = Plan::new(Source {
        kind: SourceKind::AgentClient,
        label: "T3 Code".into(),
        id: format!("t3code:{}", laptop::tilde(home, t3_home)),
    });
    let history = History::read(home);
    let titles: BTreeMap<&str, &str> =
        catalog.projects.iter().map(|p| (p.id.as_str(), p.title.as_str())).collect();
    let mut keys = BTreeSet::new();
    let mut names = BTreeSet::new();
    for table in &catalog.truncated {
        plan.warnings.push(format!(
            "T3 table {table} has more than {MAX_ROWS} rows: only the first {MAX_ROWS} are in this plan"
        ));
    }
    let mut push = |plan: &mut Plan, mut project: Project| {
        if !keys.insert(project.key.clone()) {
            plan.warnings
                .push(format!("{}: listed by T3 Code more than once; moved once", project.key));
            return;
        }
        let base = project.name.clone();
        let mut n = 2usize;
        while !names.insert(project.name.clone()) {
            let suffix = format!("-{n}");
            let stem: String = base.chars().take(40usize.saturating_sub(suffix.len())).collect();
            project.name = format!("{}{suffix}", stem.trim_end_matches('-'));
            n = n.saturating_add(1);
        }
        plan.projects.push(project);
    };

    for p in &catalog.projects {
        if p.deleted {
            continue;
        }
        if !p.root.is_dir() {
            plan.warnings.push(format!(
                "T3 project {:?}: its folder {} is gone; skipped",
                p.title,
                p.root.display()
            ));
            continue;
        }
        let mut project = laptop::project(home, &p.root, &history, git, &mut plan.warnings);
        project.name = machine_name(&p.title);
        project.checked = !p.archived;
        project.notes.push(format!("T3 Code project {:?} ({})", p.title, p.id));
        if p.archived {
            project.notes.push("archived in T3 Code: listed unchecked".into());
        }
        if !p.script_names.is_empty() {
            project.notes.push(format!(
                "T3 scripts not carried as setup (review and add to .cmux/machine.toml): {}",
                p.script_names.join(", ")
            ));
        }
        push(&mut plan, project);
    }

    let mut unlinked = 0usize;
    for t in &catalog.threads {
        if t.deleted {
            continue;
        }
        let project_title = titles.get(t.project_id.as_str()).copied().unwrap_or("t3");
        let chat = native_chat(home, t);
        if t.native.is_some() && chat.is_none() {
            unlinked += 1;
        }
        let root = catalog.projects.iter().find(|p| p.id == t.project_id).map(|p| p.root.as_path());
        let Some(worktree) = t.worktree.as_deref().filter(|w| w.is_dir() && Some(*w) != root)
        else {
            // Ran in the project folder (or its worktree is gone): its transcript joins that
            // project.
            if let Some(chat) = chat {
                let key = root.map(|r| laptop::tilde(home, r));
                if let Some(project) =
                    plan.projects.iter_mut().find(|p| Some(&p.key) == key.as_ref())
                    && !carried(&project.chats, &chat)
                {
                    project.chats.push(chat);
                }
            }
            continue;
        };
        let mut project = laptop::project(home, worktree, &history, git, &mut plan.warnings);
        project.name =
            machine_name(&format!("{project_title}-{}", t.branch.as_deref().unwrap_or(&t.title)));
        if let Some(chat) = chat
            && !carried(&project.chats, &chat)
        {
            project.chats.push(chat);
        }
        project.checked = !t.archived;
        project.notes.push(format!(
            "T3 Code thread {:?} in {project_title}: {} messages{}",
            t.title,
            t.messages,
            t.model.as_deref().map(|m| format!(", model {m}")).unwrap_or_default()
        ));
        if let Some(n) = &t.native {
            project.notes.push(format!(
                "resumes {} session {}",
                match n.agent {
                    Agent::Claude => "Claude Code",
                    Agent::Codex => "Codex",
                    Agent::Cursor => "Cursor",
                },
                n.id
            ));
        }
        if t.archived {
            project.notes.push("archived in T3 Code: listed unchecked".into());
        }
        push(&mut plan, project);
    }
    if unlinked > 0 {
        plan.warnings.push(format!(
            "{unlinked} T3 threads name a native session whose transcript is not on this computer"
        ));
    }

    for (what, why) in [
        (
            "T3 Code sign-ins and pairing (auth tables, userdata/secrets)",
            "credentials stay on this computer; sign in on the new machine",
        ),
        (
            "T3 script commands",
            "imported as names only; a command is never run on the new machine unreviewed",
        ),
        (
            "T3's own copy of thread messages",
            "the native Claude Code / Codex transcript is carried instead",
        ),
        ("peer environments", "other T3 servers are not this person's to move"),
        ("attachments and keybindings", "not read"),
    ] {
        plan.unsupported.push(Unsupported { what: what.into(), why: why.into() });
    }
    for table in &catalog.skipped_tables {
        plan.unsupported
            .push(Unsupported { what: format!("table {table}"), why: "never read".into() });
    }
    plan
}

#[cfg(test)]
#[path = "t3code_tests.rs"]
mod tests;

/// Whether `chats` already carries `chat`: the same entry, or a folder of the
/// same agent's sessions that holds it (the laptop reader links a worktree's
/// whole Claude session folder; the thread names one file inside it).
fn carried(chats: &[ChatRef], chat: &ChatRef) -> bool {
    chats.iter().any(|c| {
        c == chat
            || (c.agent == chat.agent
                && chat
                    .path
                    .strip_prefix(c.path.as_str())
                    .is_some_and(|rest| rest.starts_with('/')))
    })
}
