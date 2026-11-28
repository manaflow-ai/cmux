//! Custom slash commands (saved prompts) a person makes from cmux (`cmux agent-config commands`,
//! Settings > Claude Code & Codex > Skills > New Command), each written where its agent reads it:
//!
//! - Claude Code: `~/.claude/commands/NAME.md` (`$CLAUDE_CONFIG_DIR/commands`), which Claude Code
//!   loads as `/NAME` and reports over ACP, so the composer's `/` menu lists it in a new chat.
//! - Codex: `~/.codex/prompts/NAME.md` (`$CODEX_HOME/prompts`), Codex's custom prompts, which it
//!   runs as `/prompts:NAME`.
//! - cmux: `~/.config/cmux-next/commands/NAME.md` ([`crate::paths::cmux_commands_dir`]), cmux's own
//!   saved prompts: the daemon's `apps.composer.list` answers them beside the extensions' commands,
//!   so `/NAME` is in every chat's `/` menu whatever the agent, and picking it writes the prompt
//!   into the draft.
//!
//! Each file is the agents' own format: a YAML frontmatter `description`, then the prompt. A write
//! takes the file's edit lock and goes through [`crate::write::Store`] (atomic, prior file backed
//! up in cmux's private folder); a name already taken is refused unless the caller replaces it.

use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::frontmatter;
use crate::paths::Homes;

/// The longest command name cmux writes.
const MAX_NAME: usize = 64;
/// The longest prompt cmux writes or the composer is handed.
pub const MAX_PROMPT_BYTES: usize = 64 * 1024;

/// Whose `/` menu a command is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Target {
    Claude,
    Codex,
    Cmux,
}

impl Target {
    pub const ALL: [Target; 3] = [Target::Claude, Target::Codex, Target::Cmux];

    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "claude" | "claude-code" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            "cmux" => Some(Self::Cmux),
            _ => None,
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Cmux => "cmux",
        }
    }

    /// The product's own name.
    pub fn display(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
            Self::Cmux => "cmux",
        }
    }

    /// The folder its command files live in.
    pub fn dir(self, homes: &Homes) -> PathBuf {
        match self {
            Self::Claude => homes.claude.join("commands"),
            Self::Codex => homes.codex.join("prompts"),
            Self::Cmux => homes.cmux_commands.clone(),
        }
    }

    /// What the person types for `name`: `/name`, or `/prompts:name` for Codex.
    pub fn invocation(self, name: &str) -> String {
        match self {
            Self::Codex => format!("/prompts:{name}"),
            _ => format!("/{name}"),
        }
    }
}

/// One saved command as its file holds it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedCommand {
    pub agent: Target,
    pub name: String,
    /// What the person types in the composer.
    pub invocation: String,
    pub description: String,
    pub prompt: String,
    pub path: PathBuf,
}

/// A command to write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewCommand {
    pub agent: Target,
    pub name: String,
    /// Empty: the prompt's first line.
    pub description: String,
    pub prompt: String,
    /// Write over a command of that name instead of refusing.
    pub replace: bool,
}

#[derive(Debug)]
pub enum CommandError {
    BadName(String),
    EmptyPrompt,
    TooLong,
    Exists(PathBuf),
    Missing(PathBuf),
    Io(PathBuf, std::io::Error),
}

impl CommandError {
    /// The refusal's code (`--json` errors).
    pub fn code(&self) -> &'static str {
        match self {
            Self::BadName(_) => "command.bad_name",
            Self::EmptyPrompt => "command.empty_prompt",
            Self::TooLong => "command.too_long",
            Self::Exists(_) => "command.exists",
            Self::Missing(_) => "command.missing",
            Self::Io(..) => "command.io",
        }
    }
}

impl std::fmt::Display for CommandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadName(name) => write!(
                f,
                "{name:?} is not a command name: letters, digits, '-', '_' and '.', starting with a letter or digit, at most {MAX_NAME}"
            ),
            Self::EmptyPrompt => write!(f, "the prompt is empty"),
            Self::TooLong => write!(f, "the prompt is longer than {MAX_PROMPT_BYTES} bytes"),
            Self::Exists(path) => {
                write!(f, "{} already exists (--replace writes over it)", path.display())
            }
            Self::Missing(path) => write!(f, "{} does not exist", path.display()),
            Self::Io(path, error) => write!(f, "{}: {error}", path.display()),
        }
    }
}

impl std::error::Error for CommandError {}

/// Whether `name` is one cmux writes: a single file name every agent reads as one word.
pub fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    name.len() <= MAX_NAME
        && chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        && !name.ends_with(".md")
        && !name.contains("..")
}

/// The file `name` is for `agent`.
pub fn file(homes: &Homes, agent: Target, name: &str) -> Result<PathBuf, CommandError> {
    if !valid_name(name) {
        return Err(CommandError::BadName(name.to_owned()));
    }
    Ok(agent.dir(homes).join(format!("{name}.md")))
}

/// The file's text: a frontmatter `description` (a YAML double-quoted string, which JSON's
/// quoting is), then the prompt.
pub fn render(description: &str, prompt: &str) -> String {
    let quoted = serde_json::to_string(description).unwrap_or_else(|_| "\"\"".into());
    let mut text = format!("---\ndescription: {quoted}\n---\n{prompt}");
    if !text.ends_with('\n') {
        text.push('\n');
    }
    text
}

/// The description a command gets when none is given: its prompt's first line, cut at 100 chars.
fn first_line(prompt: &str) -> String {
    let line = prompt.lines().map(str::trim).find(|line| !line.is_empty()).unwrap_or_default();
    if line.chars().count() > 100 {
        format!("{}…", line.chars().take(99).collect::<String>())
    } else {
        line.to_owned()
    }
}

/// Writes `command` and returns it as its file now holds it.
pub fn add(homes: &Homes, command: &NewCommand) -> Result<SavedCommand, CommandError> {
    let path = file(homes, command.agent, &command.name)?;
    let prompt = command.prompt.trim_end();
    if prompt.trim().is_empty() {
        return Err(CommandError::EmptyPrompt);
    }
    if prompt.len() > MAX_PROMPT_BYTES {
        return Err(CommandError::TooLong);
    }
    let description = match command.description.trim() {
        "" => first_line(prompt),
        given => given.to_owned(),
    };
    let io = |error| CommandError::Io(path.clone(), error);
    let _lock = homes.edits.lock(&path).map_err(io)?;
    if !command.replace && fs::symlink_metadata(&path).is_ok() {
        return Err(CommandError::Exists(path));
    }
    homes.edits.replace(&path, &render(&description, prompt)).map_err(io)?;
    read(command.agent, &path).ok_or_else(|| CommandError::Missing(path.clone()))
}

/// Removes `name`'s file for `agent`, keeping its text as the file's last backup in cmux's
/// private folder. Returns the file it removed.
pub fn remove(homes: &Homes, agent: Target, name: &str) -> Result<PathBuf, CommandError> {
    let path = file(homes, agent, name)?;
    let io = |error| CommandError::Io(path.clone(), error);
    let _lock = homes.edits.lock(&path).map_err(io)?;
    let Ok(text) = fs::read(&path) else { return Err(CommandError::Missing(path)) };
    let backup = homes.edits.last_backup_path(&path);
    if let Some(dir) = backup.parent() {
        fs::create_dir_all(dir).map_err(io)?;
    }
    fs::write(&backup, text).map_err(io)?;
    fs::remove_file(&path).map_err(io)?;
    Ok(path)
}

/// One command file, or `None` when it cannot be read or is not a command name.
pub fn read(agent: Target, path: &Path) -> Option<SavedCommand> {
    let name = path.file_name()?.to_str()?.strip_suffix(".md")?.to_owned();
    if !valid_name(&name) {
        return None;
    }
    let meta = fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() > (MAX_PROMPT_BYTES as u64) * 2 {
        return None;
    }
    let text = fs::read_to_string(path).ok()?;
    let front = frontmatter::parse(&text).unwrap_or_default();
    let prompt = frontmatter::body(&text).trim_end().to_owned();
    Some(SavedCommand {
        agent,
        invocation: agent.invocation(&name),
        description: front.description.unwrap_or_else(|| first_line(&prompt)),
        prompt,
        name,
        path: path.to_path_buf(),
    })
}

/// The commands directly in `agent`'s folder (cmux makes no subfolders), in name order.
pub fn list_in(agent: Target, dir: &Path) -> Vec<SavedCommand> {
    let Ok(entries) = fs::read_dir(dir) else { return Vec::new() };
    let mut out: Vec<SavedCommand> =
        entries.flatten().filter_map(|entry| read(agent, &entry.path())).collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// Every saved command of `agent` (all three when `None`): Claude Code's, Codex's, then cmux's.
pub fn list(homes: &Homes, agent: Option<Target>) -> Vec<SavedCommand> {
    Target::ALL
        .into_iter()
        .filter(|target| agent.is_none_or(|want| want == *target))
        .flat_map(|target| list_in(target, &target.dir(homes)))
        .collect()
}

#[cfg(test)]
#[path = "commands_tests.rs"]
mod tests;
