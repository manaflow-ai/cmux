//! A project's worktree recipe: what a new worktree copies from the main
//! checkout and runs before it is used, and what runs before it is removed.
//!
//! The repository says it in two files at its root:
//!
//! - `.worktreeinclude`: the files to copy ([`super::worktree_include`]).
//! - `.cmux/worktree.toml`: `setup`, `run` and `teardown`, each a shell
//!   command, and `include`, more `.worktreeinclude` lines.
//!
//! ```toml
//! setup = "npm install && cp .env.example .env.local"
//! run = "npm run dev -- --port $CMUX_PORT"
//! teardown = "docker compose down"
//! include = [".env", "config/*.local.json"]
//! ```
//!
//! The user's saved recipe (`project.update` `worktree`, on the main
//! checkout's project) wins command by command (an empty command there
//! turns the repository's off), and its include lines come after the
//! repository's, so a `!` line takes one back. Both are read from the main
//! checkout, as it is now.

use std::io::Read as _;
use std::path::Path;

use serde::Serialize;
use serde_json::{Value, json};

use super::worktree_include;
use crate::Mux;
use crate::state::projects::WorktreeRecipe;

/// The repository's recipe file, relative to its root.
pub(crate) const PROJECT_FILE: &str = ".cmux/worktree.toml";
/// The largest recipe or include file read.
const MAX_FILE_BYTES: u64 = 256 * 1024;

/// The recipe a worktree runs with.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub(crate) struct Recipe {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub setup: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub teardown: Option<String>,
    pub include: Vec<String>,
}

impl Recipe {
    /// Nothing to copy and nothing to run.
    pub(crate) fn is_empty(&self) -> bool {
        self.setup.is_none() && self.include.is_empty()
    }
}

/// The repository's recipe, the user's, and what they make together.
pub(crate) struct Resolved {
    pub recipe: Recipe,
    pub repository: Recipe,
    pub saved: Option<WorktreeRecipe>,
    /// The repository's files that were read, and what was wrong with them.
    pub files: Vec<&'static str>,
    pub problems: Vec<String>,
}

impl Resolved {
    pub(crate) fn value(&self) -> Value {
        let mut value = json!({
            "setup": self.recipe.setup,
            "run": self.recipe.run,
            "teardown": self.recipe.teardown,
            "include": self.recipe.include,
            "repository": self.repository,
            "files": self.files,
        });
        if let Some(saved) = &self.saved {
            super::worktree_setup::put(&mut value, "saved", json!(saved));
        }
        if !self.problems.is_empty() {
            super::worktree_setup::put(&mut value, "problems", json!(self.problems));
        }
        value
    }
}

/// The recipe of the main checkout at `main_root` (`None` for a bare
/// repository: only the saved recipe, keyed by `project`, applies).
pub(crate) fn resolve(mux: &Mux, main_root: Option<&Path>, project: &Path) -> Resolved {
    let mut resolved = Resolved {
        recipe: Recipe::default(),
        repository: Recipe::default(),
        saved: saved(mux, project),
        files: Vec::new(),
        problems: Vec::new(),
    };
    if let Some(root) = main_root {
        read_repository(root, &mut resolved);
    }
    let saved = resolved.saved.clone().unwrap_or_default();
    let command = |saved: Option<String>, repository: &Option<String>| {
        saved.or_else(|| repository.clone()).filter(|text| !text.trim().is_empty())
    };
    resolved.recipe = Recipe {
        setup: command(saved.setup, &resolved.repository.setup),
        run: command(saved.run, &resolved.repository.run),
        teardown: command(saved.teardown, &resolved.repository.teardown),
        include: resolved
            .repository
            .include
            .iter()
            .chain(saved.include.iter().flatten())
            .cloned()
            .collect(),
    };
    resolved
}

fn read_repository(root: &Path, resolved: &mut Resolved) {
    match read_text(&root.join(worktree_include::FILE_NAME)) {
        Ok(Some(text)) => {
            resolved.files.push(worktree_include::FILE_NAME);
            resolved.repository.include.extend(text.lines().map(str::to_string));
        }
        Ok(None) => {}
        Err(error) => resolved.problems.push(format!("{}: {error}", worktree_include::FILE_NAME)),
    }
    let text = match read_text(&root.join(PROJECT_FILE)) {
        Ok(Some(text)) => text,
        Ok(None) => return,
        Err(error) => return resolved.problems.push(format!("{PROJECT_FILE}: {error}")),
    };
    resolved.files.push(PROJECT_FILE);
    let table = match toml::from_str::<toml::Table>(&text) {
        Ok(table) => table,
        Err(error) => return resolved.problems.push(format!("{PROJECT_FILE}: {error}")),
    };
    for (key, value) in &table {
        match (key.as_str(), value) {
            ("setup", toml::Value::String(text)) => resolved.repository.setup = Some(text.clone()),
            ("run", toml::Value::String(text)) => resolved.repository.run = Some(text.clone()),
            ("teardown", toml::Value::String(text)) => {
                resolved.repository.teardown = Some(text.clone());
            }
            ("include", toml::Value::Array(items)) => {
                for item in items {
                    match item.as_str() {
                        Some(line) => resolved.repository.include.push(line.to_string()),
                        None => resolved
                            .problems
                            .push(format!("{PROJECT_FILE}: include holds a non-string")),
                    }
                }
            }
            _ => resolved.problems.push(format!("{PROJECT_FILE}: {key} is not read")),
        }
    }
}

/// A regular file's text (`None` when there is none). A link is not read:
/// the recipe is the repository's own.
fn read_text(path: &Path) -> Result<Option<String>, String> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_file() => {}
        Ok(_) => return Err("not a regular file".into()),
        Err(_) => return Ok(None),
    }
    let file = std::fs::File::open(path).map_err(|error| error.to_string())?;
    let mut text = String::new();
    file.take(MAX_FILE_BYTES + 1).read_to_string(&mut text).map_err(|error| error.to_string())?;
    if text.len() as u64 > MAX_FILE_BYTES {
        return Err(format!("larger than {MAX_FILE_BYTES} bytes"));
    }
    Ok(Some(text))
}

/// The user's saved recipe of the project at `project` (canonical).
fn saved(mux: &Mux, project: &Path) -> Option<WorktreeRecipe> {
    let path = std::fs::canonicalize(project).unwrap_or_else(|_| project.to_path_buf());
    let path = path.to_string_lossy().into_owned();
    mux.read_registry_state(|connection| {
        let projects = crate::state::projects_store::load(connection)?;
        Ok(projects.get(&path).and_then(|project| project.overlay.worktree.clone()))
    })
    .ok()
    .flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_repository_files() {
        let mut bytes = [0_u8; 6];
        getrandom::fill(&mut bytes).unwrap();
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let root = std::env::temp_dir().join(format!("cmux-recipe-{hex}"));
        std::fs::create_dir_all(root.join(PROJECT_FILE).parent().unwrap()).unwrap();
        std::fs::write(root.join(".worktreeinclude"), ".env\n").unwrap();
        std::fs::write(
            root.join(PROJECT_FILE),
            "setup = \"npm ci\"\nrun = \"npm run dev\"\nteardown = \"make down\"\ninclude = [\"config/local.json\"]\nports = 3\n",
        )
        .unwrap();
        let mut resolved = Resolved {
            recipe: Recipe::default(),
            repository: Recipe::default(),
            saved: None,
            files: Vec::new(),
            problems: Vec::new(),
        };
        read_repository(&root, &mut resolved);
        assert_eq!(resolved.repository.setup.as_deref(), Some("npm ci"));
        assert_eq!(resolved.repository.teardown.as_deref(), Some("make down"));
        assert_eq!(resolved.repository.include, [".env", "config/local.json"]);
        assert_eq!(resolved.files, [".worktreeinclude", PROJECT_FILE]);
        assert_eq!(resolved.repository.run.as_deref(), Some("npm run dev"));
        assert_eq!(resolved.problems, [format!("{PROJECT_FILE}: ports is not read")]);
        std::fs::remove_dir_all(root).unwrap();
    }
}
