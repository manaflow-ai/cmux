//! `repos` and `workspaces` from `conductor.db`. The schema is Conductor's
//! (read by getpaseo/import at `user_version` 112 and later): required
//! columns are checked by name, optional ones (the scripts) are read when
//! present, and a cell of the wrong type is no value, never a failure.

use std::path::{Path, PathBuf};

use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags};
use serde::Serialize;

/// The most rows read from one table; more is a refusal, never a cut list.
pub const MAX_ROWS: usize = 10_000;
/// The longest text cell kept (a script can be long; a path cannot).
pub const MAX_CELL_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Catalog {
    pub database: PathBuf,
    pub repos: Vec<Repo>,
    pub workspaces: Vec<Workspace>,
}

/// One repository Conductor knows.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Repo {
    pub id: String,
    pub name: String,
    pub root_path: Option<PathBuf>,
    pub hidden: bool,
    pub setup_script: Option<String>,
    pub archive_script: Option<String>,
    /// `run_scripts_json`: an object of run scripts, kept as JSON text.
    pub run_scripts: Option<String>,
}

/// One workspace (a worktree on its own branch).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Workspace {
    pub id: String,
    pub repo_id: String,
    /// Without `refs/heads/`.
    pub branch: Option<String>,
    /// `ready` or `archived`; anything else is reported as unsupported.
    pub state: String,
    pub path: Option<PathBuf>,
    /// The commit Conductor recorded when it archived the workspace.
    pub archive_commit: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ReadError {
    /// Not a database, or it could not be opened read-only.
    Open(String),
    /// A table or a required column is missing: another Conductor version.
    Schema(String),
    /// More than [`MAX_ROWS`] rows, or a query failed partway.
    Read(String),
}

impl std::fmt::Display for ReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Open(reason) => write!(f, "conductor.db could not be opened: {reason}"),
            Self::Schema(reason) => write!(f, "conductor.db has an unknown layout: {reason}"),
            Self::Read(reason) => write!(f, "conductor.db could not be read: {reason}"),
        }
    }
}

impl std::error::Error for ReadError {}

const REPO_REQUIRED: [&str; 3] = ["id", "root_path", "name"];
const REPO_OPTIONAL: [&str; 4] =
    ["is_hidden", "setup_script", "archive_script", "run_scripts_json"];
const WORKSPACE_REQUIRED: [&str; 6] =
    ["id", "repo_id", "branch", "state", "path", "archive_commit"];

/// Reads the catalog. Conductor may be running: the database is opened
/// read-only and shares its write-ahead log, so a commit Conductor has not
/// checkpointed yet is still read.
pub fn read(database: &Path) -> Result<Catalog, ReadError> {
    if !database.is_file() {
        return Err(ReadError::Open(format!("{} is not a file", database.display())));
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let connection =
        Connection::open_with_flags(database, flags).map_err(|e| ReadError::Open(e.to_string()))?;
    connection
        .busy_timeout(std::time::Duration::from_millis(500))
        .map_err(|e| ReadError::Open(e.to_string()))?;
    let repo_columns = columns(&connection, "repos")?;
    let workspace_columns = columns(&connection, "workspaces")?;
    for (table, have, required) in [
        ("repos", &repo_columns, &REPO_REQUIRED[..]),
        ("workspaces", &workspace_columns, &WORKSPACE_REQUIRED[..]),
    ] {
        if let Some(missing) = required.iter().find(|name| !have.iter().any(|c| c == *name)) {
            return Err(ReadError::Schema(format!("{table} has no {missing} column")));
        }
    }
    let mut selected: Vec<&str> = REPO_REQUIRED.to_vec();
    selected.extend(REPO_OPTIONAL.iter().filter(|name| repo_columns.iter().any(|c| c == *name)));
    let repos = rows(&connection, "repos", &selected, |cell| Repo {
        id: cell("id").unwrap_or_default(),
        name: cell("name").unwrap_or_default(),
        root_path: cell("root_path").map(PathBuf::from),
        hidden: cell("is_hidden").is_some_and(|value| value == "1" || value == "true"),
        setup_script: cell("setup_script"),
        archive_script: cell("archive_script"),
        run_scripts: cell("run_scripts_json"),
    })?;
    let workspaces = rows(&connection, "workspaces", &WORKSPACE_REQUIRED, |cell| Workspace {
        id: cell("id").unwrap_or_default(),
        repo_id: cell("repo_id").unwrap_or_default(),
        branch: cell("branch")
            .map(|branch| branch.strip_prefix("refs/heads/").unwrap_or(&branch).to_string()),
        state: cell("state").unwrap_or_default(),
        path: cell("path").map(PathBuf::from),
        archive_commit: cell("archive_commit"),
    })?;
    Ok(Catalog { database: database.to_path_buf(), repos, workspaces })
}

fn columns(connection: &Connection, table: &str) -> Result<Vec<String>, ReadError> {
    let mut statement = connection
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|e| ReadError::Schema(e.to_string()))?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|e| ReadError::Schema(e.to_string()))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| ReadError::Schema(e.to_string()))?;
    if names.is_empty() {
        return Err(ReadError::Schema(format!("no {table} table")));
    }
    Ok(names)
}

/// Every row of `table`, each turned into a `T` from its cells by name.
/// Integers read as their decimal text; blobs, NULLs, blank and oversized
/// text read as no value.
fn rows<T>(
    connection: &Connection,
    table: &str,
    columns: &[&str],
    make: impl Fn(&dyn Fn(&str) -> Option<String>) -> T,
) -> Result<Vec<T>, ReadError> {
    let sql = format!("SELECT {} FROM {table} LIMIT {}", columns.join(", "), MAX_ROWS + 1);
    let mut statement = connection.prepare(&sql).map_err(|e| ReadError::Read(e.to_string()))?;
    let mut rows = statement.query([]).map_err(|e| ReadError::Read(e.to_string()))?;
    let mut out = Vec::new();
    while let Some(row) = rows.next().map_err(|e| ReadError::Read(e.to_string()))? {
        if out.len() == MAX_ROWS {
            return Err(ReadError::Read(format!("{table} has more than {MAX_ROWS} rows")));
        }
        let mut cells: Vec<Option<String>> = Vec::with_capacity(columns.len());
        for index in 0..columns.len() {
            let value = row.get_ref(index).map_err(|e| ReadError::Read(e.to_string()))?;
            cells.push(text(value));
        }
        let cell = |name: &str| {
            columns
                .iter()
                .position(|c| *c == name)
                .and_then(|index| cells.get(index).cloned().flatten())
        };
        out.push(make(&cell));
    }
    Ok(out)
}

fn text(value: ValueRef<'_>) -> Option<String> {
    let text = match value {
        ValueRef::Text(bytes) if bytes.len() <= MAX_CELL_BYTES => {
            std::str::from_utf8(bytes).ok()?.to_string()
        }
        ValueRef::Integer(number) => number.to_string(),
        _ => return None,
    };
    Some(text).filter(|text| !text.trim().is_empty())
}
