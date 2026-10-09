//! The project list's table (`project-list-v1`, plans/cmux-next/projects.md):
//! one row per project, keyed by canonical path, the project as JSON. The
//! reducer is [`super::projects`]; this module loads and stores it.

use rusqlite::{Connection, Transaction};
use serde_json::{Value, json};

use super::projects::{Project, Projects, Refusals};

/// `project.list|observe|add|update|remove|sync`.
pub const CAPABILITY: &str = "project-list-v1";
/// The resource kind of a project on `session.events`.
pub(crate) const RESOURCE: &str = "project";
/// The most projects a list returns at once.
pub(crate) const MAX_LIST: usize = 500;

pub(crate) fn create_projects_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS projects (
           path TEXT PRIMARY KEY NOT NULL,
           project_json TEXT NOT NULL
         );",
    )?;
    Ok(())
}

/// Every stored project. A row that no longer parses (a damaged row, or a
/// newer build's shape this one cannot read) is skipped, not fatal.
pub(crate) fn load(connection: &Connection) -> anyhow::Result<Projects> {
    let mut statement = connection.prepare("SELECT path, project_json FROM projects")?;
    let rows =
        statement.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?;
    let mut projects = Vec::new();
    for row in rows {
        let (path, json) = row?;
        match serde_json::from_str::<Project>(&json) {
            Ok(project) if project.path == path => projects.push(project),
            Ok(_) => {
                eprintln!("cmux-tui: a project row names another path; skipped");
            }
            Err(error) => {
                eprintln!("cmux-tui: a project row does not parse ({error}); skipped");
            }
        }
    }
    Ok(Projects::from_projects(projects))
}

/// Writes `paths` of `projects`: their current rows, or a delete for a path
/// the reducer removed.
pub(crate) fn write(
    transaction: &Transaction<'_>,
    projects: &Projects,
    paths: &[String],
) -> anyhow::Result<()> {
    for path in paths {
        match projects.get(path) {
            Some(project) => {
                transaction.execute(
                    "INSERT INTO projects(path, project_json) VALUES(?1, ?2)
                     ON CONFLICT(path) DO UPDATE SET project_json = excluded.project_json",
                    rusqlite::params![path, serde_json::to_string(project)?],
                )?;
            }
            None => {
                transaction.execute("DELETE FROM projects WHERE path = ?1", [path])?;
            }
        }
    }
    Ok(())
}

/// A project as `project.list` and the `state_upsert` value carry it.
/// Times are decimal strings, as every `*_ms` on the wire (spec `decimal`).
pub(crate) fn project_value(project: &Project) -> Value {
    let sources: serde_json::Map<String, Value> = project
        .sources
        .iter()
        .map(|(source, seen)| {
            let value = json!({
                "first_seen_ms": seen.first_seen_ms.to_string(),
                "last_used_ms": seen.last_used_ms.to_string(),
            });
            (source.clone(), value)
        })
        .collect();
    json!({
        "path": project.path,
        "name": project.name(),
        "last_used_ms": project.last_used_ms().to_string(),
        "sources": sources,
        "overlay": project.overlay,
        "state": project.state,
    })
}

/// `project.list`: pinned first, then the most recently used; `query`
/// matches the name or the path, case-insensitively.
pub(crate) fn list_value(
    connection: &Connection,
    include_hidden: bool,
    query: Option<&str>,
    limit: Option<usize>,
) -> anyhow::Result<Value> {
    let projects = load(connection)?;
    let needle = query.map(str::to_lowercase).filter(|needle| !needle.trim().is_empty());
    let limit = limit.unwrap_or(MAX_LIST).min(MAX_LIST);
    let listed: Vec<Value> = projects
        .list(include_hidden)
        .into_iter()
        .filter(|project| {
            needle.as_ref().is_none_or(|needle| {
                project.path.to_lowercase().contains(needle)
                    || project.name().to_lowercase().contains(needle)
            })
        })
        .take(limit)
        .map(project_value)
        .collect();
    Ok(json!({"projects": listed}))
}

/// The refusals of this daemon: the user's home, and the agent homes no
/// project lives in (cmux's agent-home, each harness's own config folder).
pub(crate) fn refusals() -> Refusals {
    let home = std::env::var("HOME").unwrap_or_default();
    // The home folder itself is not privacy-protected; resolving it reads nothing inside.
    let home = std::fs::canonicalize(&home)
        .map_or(home, |resolved| resolved.to_string_lossy().into_owned());
    let roots = [
        "Library/Application Support/cmux/agent-home",
        ".claude",
        ".codex",
        ".pi",
        ".gemini",
        ".cursor",
        ".local/share/opencode",
    ]
    .iter()
    .map(|relative| format!("{}/{relative}", home.trim_end_matches('/')))
    .collect();
    Refusals { home, roots }
}
