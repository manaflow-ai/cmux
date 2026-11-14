//! `acpmux desktop link | unlink | status`: give the Claude desktop app, Claude Code (its own
//! CLI and Claude desktop's Code tab), Codex (its desktop app and CLI), OpenCode, Gemini CLI,
//! Qwen Code and pi this machine's acpmux tools, so a chat there reaches every session, machine
//! and Cloud machine acpmux reaches: list the agents, message one by name, read its reply.
//! Leo, 2026-11-09: "even if somebody say still wants to keep using [the Codex desktop app] and/or claude
//! desktop, to be always saying "yeah i want to keep using cmux-next :) they give a good
//! transport between everybody :)""; and on Claude Code's own cross-session messaging, "we
//! should offer it for codex too! ... ppl care somewhat about pi and opencode and stuff like qwen
//! and deepseek and glm" (Qwen, DeepSeek and GLM models run in OpenCode, pi or Qwen Code).
//!
//! Each app gets one MCP server entry named [`SERVER_KEY`] in its own user-scope config:
//!
//! - Claude desktop: `claude_desktop_config.json` `mcpServers` (macOS `~/Library/Application
//!   Support/Claude`, Linux `$XDG_CONFIG_HOME/Claude`). The app reads it at launch.
//! - Claude Code: `claude mcp add-json --scope user`, its own writer of `~/.claude.json` (which
//!   every running Claude Code rewrites, so acpmux never writes that file itself). Claude
//!   desktop's Code tab runs the same Claude Code with the same user config.
//! - Codex: `[mcp_servers.cmux]` in `$CODEX_HOME/config.toml` (`~/.codex`), which the Codex
//!   desktop app and CLI share, edited with `toml_edit` so comments and order stay, under the
//!   lock every cmux writer of it takes (`cmux_tui_platform::codex_config_lock`).
//! - OpenCode: `mcp.cmux` in `$XDG_CONFIG_HOME/opencode/opencode.json` (`~/.config`, on macOS
//!   too), a `local` server whose `command` is one array and whose env is `environment`.
//!   OpenCode merges that file with an `opencode.jsonc` beside it, so a person's JSONC stays theirs.
//! - Gemini CLI and Qwen Code (a Gemini CLI fork): `mcpServers` in `<GEMINI_CLI_HOME or
//!   ~>/.gemini/settings.json` and
//!   `~/.qwen/settings.json`, without Claude's `type`.
//! - pi, which has no MCP by design: a `cmux` skill (`<PI_CODING_AGENT_DIR or
//!   ~/.pi/agent>/skills/cmux/SKILL.md`) that runs the same requests through this acpmux CLI
//!   (`ls`, `send --no-wait --from pi`, `last`, `wait`), with [`GUEST_ENV`] set so the daemon
//!   takes them for a guest's. The file is ours while it carries the line [`PI_MARK`].
//!
//! The entry runs this acpmux binary as `acpmux acpmux-mcp` with [`GUEST_ENV`] set to the app's
//! id: the server's guest mode (`acpmux_mcp_guest.rs`), which lists the tools that make sense
//! outside an acpmux chat and none inside one (an acpmux session gets its own `cmux` server,
//! which replaces this entry by name anyway). [`GUEST_ENV`] is also what makes an entry ours:
//! unlink removes only an entry that carries it, and link never replaces one that does not.
//! Nothing is linked unless a person runs `link` (or presses the Settings row); no default
//! changes.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

/// The server's name in every app's config: the name the tools show under (`mcp__cmux__ls`).
pub const SERVER_KEY: &str = "cmux";
/// Set in the entry's env to the app's id: the acpmux MCP server's guest mode, and the mark of
/// an entry this command wrote.
pub const GUEST_ENV: &str = "ACPMUX_MCP_GUEST";
/// The server subcommand the entry runs.
const SERVER_ARG: &str = "acpmux-mcp";
/// The longest a `claude mcp` call may take.
// timeout: a local `claude mcp` add/remove call that sets up the desktop link; it carries no message and a hang is reported, not retried silently
const CLAUDE_CLI_WAIT: std::time::Duration = std::time::Duration::from_secs(20);

/// An app this command links.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum App {
    ClaudeDesktop,
    ClaudeCode,
    Codex,
    OpenCode,
    GeminiCli,
    QwenCode,
    Pi,
}

impl App {
    pub const ALL: [App; 7] = [
        App::ClaudeDesktop,
        App::ClaudeCode,
        App::Codex,
        App::OpenCode,
        App::GeminiCli,
        App::QwenCode,
        App::Pi,
    ];

    /// The id the CLI takes and the entry's [`GUEST_ENV`] carries.
    pub fn id(self) -> &'static str {
        match self {
            App::ClaudeDesktop => "claude-desktop",
            App::ClaudeCode => "claude-code",
            App::Codex => "codex",
            App::OpenCode => "opencode",
            App::GeminiCli => "gemini",
            App::QwenCode => "qwen",
            App::Pi => "pi",
        }
    }

    /// What a person calls it.
    pub fn label(self) -> &'static str {
        match self {
            App::ClaudeDesktop => "Claude desktop",
            App::ClaudeCode => "Claude Code",
            App::Codex => "Codex desktop and CLI",
            App::OpenCode => "OpenCode",
            App::GeminiCli => "Gemini CLI",
            App::QwenCode => "Qwen Code",
            App::Pi => "pi",
        }
    }

    pub fn parse(id: &str) -> Option<App> {
        App::ALL.into_iter().find(|a| a.id() == id.trim().to_ascii_lowercase())
    }

    /// When the change reaches the app.
    fn takes_effect(self) -> &'static str {
        match self {
            App::ClaudeDesktop => "quit and reopen Claude desktop",
            App::ClaudeCode => "new Claude Code sessions have it",
            App::Codex => "new Codex threads have it; restart the Codex app if it is open",
            App::OpenCode => "new OpenCode sessions have it",
            App::GeminiCli => "new Gemini CLI sessions have it",
            App::QwenCode => "new Qwen Code sessions have it",
            App::Pi => "new pi sessions have the cmux skill",
        }
    }
}

/// Where the apps keep their config, and what the entry runs. [`Env::current`] for this process;
/// tests build one over a scratch home.
#[derive(Clone, Debug)]
pub struct Env {
    /// The person's home folder.
    pub home: PathBuf,
    /// `CLAUDE_CONFIG_DIR`, when set.
    pub claude_config_dir: Option<PathBuf>,
    /// `CODEX_HOME`, when set.
    pub codex_home: Option<PathBuf>,
    /// `XDG_CONFIG_HOME`, when set (Claude desktop reads it on Linux only, OpenCode everywhere).
    pub xdg_config_home: Option<PathBuf>,
    /// `PI_CODING_AGENT_DIR`, when set.
    pub pi_dir: Option<PathBuf>,
    /// `GEMINI_CLI_HOME`, when set: Gemini CLI's home in place of the person's.
    pub gemini_home: Option<PathBuf>,
    /// The acpmux binary the entry runs.
    pub exe: PathBuf,
    /// Its arguments: the binary's prefix (`acp` in the cmux binary) and `acpmux-mcp`.
    pub args: Vec<String>,
    /// The acpmux home the entry's server must use, when it is not the default one.
    pub acpmux_home: Option<PathBuf>,
    /// The `claude` CLI, when found.
    pub claude_cli: Option<PathBuf>,
}

impl Env {
    /// For this process: this binary as acpmux runs itself (`self_command.rs`), and its home.
    pub fn current() -> Result<Env> {
        let me =
            crate::self_command::SelfCommand::current().context("finding this acpmux binary")?;
        let home = crate::config::home();
        let home = (home != crate::config::default_home()).then_some(home);
        Env::with(me, home)
    }

    /// For the acpmux in binary `me`, whose daemon home is `acpmux_home` (None: the default one).
    pub fn with(me: crate::self_command::SelfCommand, acpmux_home: Option<PathBuf>) -> Result<Env> {
        let home = dirs::home_dir().ok_or_else(|| anyhow!("no home folder"))?;
        let var = |k: &str| std::env::var_os(k).filter(|v| !v.is_empty()).map(PathBuf::from);
        Ok(Env {
            home,
            claude_config_dir: var("CLAUDE_CONFIG_DIR"),
            codex_home: var("CODEX_HOME"),
            xdg_config_home: var("XDG_CONFIG_HOME"),
            pi_dir: var("PI_CODING_AGENT_DIR"),
            gemini_home: var("GEMINI_CLI_HOME"),
            args: me.args_lossy(&[SERVER_ARG]),
            exe: me.exe,
            acpmux_home,
            claude_cli: crate::config::which("claude").map(PathBuf::from),
        })
    }

    /// The file the app's entry lives in.
    pub fn config_path(&self, app: App) -> PathBuf {
        match app {
            App::ClaudeDesktop => self.claude_desktop_dir().join("claude_desktop_config.json"),
            App::ClaudeCode => match &self.claude_config_dir {
                Some(dir) => dir.join(".claude.json"),
                None => self.home.join(".claude.json"),
            },
            App::Codex => self
                .codex_home
                .clone()
                .unwrap_or_else(|| self.home.join(".codex"))
                .join("config.toml"),
            App::OpenCode => self.xdg_config().join("opencode/opencode.json"),
            App::GeminiCli => {
                self.gemini_home.as_ref().unwrap_or(&self.home).join(".gemini/settings.json")
            }
            App::QwenCode => self.home.join(".qwen/settings.json"),
            App::Pi => self.pi_agent_dir().join("skills/cmux/SKILL.md"),
        }
    }

    fn xdg_config(&self) -> PathBuf {
        self.xdg_config_home.clone().unwrap_or_else(|| self.home.join(".config"))
    }

    fn claude_desktop_dir(&self) -> PathBuf {
        if cfg!(target_os = "macos") {
            self.home.join("Library/Application Support/Claude")
        } else {
            self.xdg_config().join("Claude")
        }
    }

    fn pi_agent_dir(&self) -> PathBuf {
        self.pi_dir.clone().unwrap_or_else(|| self.home.join(".pi/agent"))
    }

    /// Whether the app is on this machine: its config folder is there (Claude Code: its CLI or
    /// its config file).
    pub fn installed(&self, app: App) -> bool {
        match app {
            App::ClaudeDesktop => self.claude_desktop_dir().is_dir(),
            App::ClaudeCode => self.claude_cli.is_some() || self.config_path(app).is_file(),
            App::Codex | App::OpenCode | App::GeminiCli | App::QwenCode => {
                self.config_path(app).parent().is_some_and(Path::is_dir)
            }
            App::Pi => self.pi_agent_dir().is_dir(),
        }
    }

    /// The env of the entry for `app`.
    fn entry_env(&self, app: App) -> Vec<(&'static str, String)> {
        let mut env = vec![(GUEST_ENV, app.id().to_owned())];
        if let Some(home) = &self.acpmux_home {
            env.push(("ACPMUX_HOME", home.to_string_lossy().into_owned()));
        }
        env
    }

    /// The entry for `app`, as the JSON both Claude configs take: the shape every other app's
    /// entry is read back into ([`canonical`]).
    pub fn entry_json(&self, app: App) -> Value {
        let env: serde_json::Map<String, Value> =
            self.entry_env(app).into_iter().map(|(k, v)| (k.to_owned(), json!(v))).collect();
        json!({
            "type": "stdio",
            "command": self.exe.to_string_lossy(),
            "args": self.args,
            "env": env,
        })
    }

    /// The entry as `app`'s own config spells it.
    fn native_entry(&self, app: App) -> Value {
        let entry = self.entry_json(app);
        let field = |key: &str| entry.get(key).cloned().unwrap_or(Value::Null);
        match app {
            App::GeminiCli | App::QwenCode => {
                json!({"command": field("command"), "args": field("args"), "env": field("env")})
            }
            App::OpenCode => {
                let mut command = vec![field("command")];
                command.extend(field("args").as_array().cloned().unwrap_or_default());
                json!({
                    "type": "local",
                    "command": command,
                    "environment": field("env"),
                    "enabled": true,
                })
            }
            _ => entry,
        }
    }

    /// pi's `cmux` skill: the acpmux CLI, as a guest, for what the MCP tools do elsewhere.
    pub fn pi_skill(&self) -> String {
        use crate::harness_health::channel::quote;
        let mut cli: Vec<String> = self
            .entry_env(App::Pi)
            .into_iter()
            .map(|(k, v)| format!("{k}={}", quote(&v)))
            .collect();
        cli.push(quote(&self.exe.to_string_lossy()));
        cli.extend(self.args.iter().filter(|a| *a != SERVER_ARG).map(|a| quote(a)));
        let cli = cli.join(" ");
        [
            "---",
            "name: cmux",
            "description: Reach other coding agents through cmux (Claude Code, Codex, OpenCode, Gemini CLI, pi and the rest, on this machine and its paired and Cloud machines) - list them, message one by name, read its reply, wait until it is done. Use when the task names another agent or session, or needs one to answer or do something.",
            "---",
            PI_MARK,
            "",
            "# Reaching other agents through cmux",
            "",
            "cmux wrote this skill (`acpmux desktop link`; `acpmux desktop unlink --app pi` removes it).",
            "Run these in a shell, where `cmux-agents` stands for:",
            "",
            &format!("    {cli}"),
            "",
            "- List the agent sessions, newest first: `cmux-agents ls` (add words to filter by name or title).",
            "- Message one by name, id or host/name: `cmux-agents send --no-wait --from pi -- NAME 'TEXT'`.",
            "  It arrives in that chat as pi's message, never as the person's, and does not wait. Make the",
            "  text self-contained and say how to answer you.",
            "- Read its last reply: `cmux-agents last NAME`.",
            "- Learn when it is done instead of polling: `cmux-agents wait NAME --timeout 1800` returns when",
            "  its turn ends or it asks for permission (exit 0 done, 2 permission, 3 timeout).",
            "",
        ]
        .join("\n")
    }
}

/// An entry as `app`'s config holds it, in the shape of [`Env::entry_json`].
fn canonical(app: App, entry: &Value) -> Value {
    match app {
        App::OpenCode => {
            let command =
                entry.get("command").and_then(Value::as_array).cloned().unwrap_or_default();
            let mut v = json!({
                "command": command.first().cloned().unwrap_or(Value::Null),
                "args": command.get(1..).unwrap_or_default(),
            });
            if let Some(env) = entry.get("environment") {
                v.set("env", env.clone());
            }
            v
        }
        _ => entry.clone(),
    }
}

/// The key of `app`'s MCP servers in its JSON config.
fn servers_key(app: App) -> &'static str {
    match app {
        App::OpenCode => "mcp",
        _ => SERVERS_KEY,
    }
}

/// The line that marks pi's skill as one cmux wrote: a whole line of its own, so a person's skill
/// that only mentions [`GUEST_ENV`] is never taken for cmux's.
const PI_MARK: &str = "<!-- cmux: written by acpmux desktop link (ACPMUX_MCP_GUEST=pi) -->";

/// Whether a skill's text is one cmux wrote: it has [`PI_MARK`] as a line.
fn pi_ours(text: &str) -> bool {
    text.lines().any(|line| line == PI_MARK)
}

/// An app's entry as found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    /// The app is not on this machine.
    NotInstalled,
    /// No entry named [`SERVER_KEY`].
    NotLinked,
    /// Our entry, running this binary.
    Linked,
    /// Our entry, running another acpmux (an older app's, a moved binary) or for another
    /// acpmux home.
    Stale,
    /// An entry named [`SERVER_KEY`] this command did not write: left alone.
    Foreign,
}

impl State {
    pub fn id(self) -> &'static str {
        match self {
            State::NotInstalled => "not-installed",
            State::NotLinked => "not-linked",
            State::Linked => "linked",
            State::Stale => "stale",
            State::Foreign => "foreign",
        }
    }
}

/// One app's row of `status`, and of `link` and `unlink` after they ran.
#[derive(Clone, Debug)]
pub struct Row {
    pub app: App,
    pub state: State,
    pub config: PathBuf,
    /// What this run did, or why it did nothing.
    pub note: Option<String>,
}

impl Row {
    pub fn to_json(&self) -> Value {
        let mut v = json!({
            "app": self.app.id(),
            "label": self.app.label(),
            "state": self.state.id(),
            "linked": self.state == State::Linked,
            "config": self.config.to_string_lossy(),
        });
        if let Some(note) = &self.note {
            v.set("note", json!(note));
        }
        v
    }
}

/// The state of `app`'s entry, read only.
pub fn status(env: &Env, app: App) -> Row {
    let config = env.config_path(app);
    let state = if !env.installed(app) {
        State::NotInstalled
    } else if app == App::Pi {
        match std::fs::read_to_string(&config) {
            Ok(text) if text == env.pi_skill() => State::Linked,
            Ok(text) if pi_ours(&text) => State::Stale,
            Ok(_) => State::Foreign,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => State::NotLinked,
            Err(e) => {
                let note = Some(format!("reading {}: {e}", config.display()));
                return Row { app, state: State::NotLinked, config, note };
            }
        }
    } else {
        match read_entry(env, app) {
            Ok(entry) => classify(env, app, entry.as_ref()),
            Err(e) => {
                return Row { app, state: State::NotLinked, config, note: Some(format!("{e:#}")) };
            }
        }
    };
    Row { app, state, config, note: None }
}

fn classify(env: &Env, app: App, entry: Option<&Value>) -> State {
    let Some(entry) = entry else { return State::NotLinked };
    if !ours_json(entry) {
        return State::Foreign;
    }
    let ours = env.exe.to_string_lossy();
    let same_args = entry["args"] == json!(env.args);
    // The env too: an entry for another acpmux home reaches another daemon.
    let same_env = entry.get("env") == env.entry_json(app).get("env");
    if entry["command"].as_str() == Some(ours.as_ref()) && same_args && same_env {
        State::Linked
    } else {
        State::Stale
    }
}

/// Whether an entry named [`SERVER_KEY`] (as JSON) is one this command wrote: it carries
/// [`GUEST_ENV`].
fn ours_json(entry: &Value) -> bool {
    entry.pointer(&format!("/env/{GUEST_ENV}")).and_then(Value::as_str).is_some()
}

/// The same for Codex's TOML entry, its `env` an inline table or a table of its own.
fn ours_toml(entry: &toml_edit::Item) -> bool {
    entry.get("env").and_then(|env| env.get(GUEST_ENV)).and_then(toml_edit::Item::as_str).is_some()
}

/// The refusal of an edit that found, in the text it was built on, an entry named
/// [`SERVER_KEY`] this command did not write: it is left as it is. Checked on every round of
/// the edit (`desktop_link_write.rs`), so one that appeared after `status` read the file, while
/// the edit waited for the lock or raced another writer, is never replaced or removed.
#[derive(Debug)]
struct ForeignEntry;

impl std::fmt::Display for ForeignEntry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "a server named {SERVER_KEY} that cmux did not write is there")
    }
}

impl std::error::Error for ForeignEntry {}

/// The note of a row whose entry is not ours.
fn foreign_note(config: &Path) -> String {
    let what = if config.ends_with("SKILL.md") { "a skill" } else { "a server" };
    format!(
        "{what} named {SERVER_KEY} that cmux did not write is in {}; left alone",
        config.display()
    )
}

/// Give `app` the entry. An entry of ours that runs another binary is replaced; one we did not
/// write is left alone and named in the row, also one that appears while the edit runs.
pub fn link(env: &Env, app: App, dry_run: bool) -> Row {
    let mut row = status(env, app);
    row.note = match row.state {
        State::NotInstalled => Some(format!("{} is not on this machine", app.label())),
        State::Linked => Some("already linked".to_owned()),
        State::Foreign => Some(foreign_note(&row.config)),
        State::NotLinked | State::Stale if dry_run => Some("would link".to_owned()),
        State::NotLinked | State::Stale => match write_entry(env, app, row.state == State::Stale) {
            Ok(()) => {
                row.state = State::Linked;
                Some(format!("linked; {}", app.takes_effect()))
            }
            Err(e) if e.downcast_ref::<ForeignEntry>().is_some() => {
                row.state = State::Foreign;
                Some(foreign_note(&row.config))
            }
            Err(e) => Some(format!("{e:#}")),
        },
    };
    row
}

/// Remove `app`'s entry, only when this command wrote it.
pub fn unlink(env: &Env, app: App, dry_run: bool) -> Row {
    let mut row = status(env, app);
    row.note = match row.state {
        // A config it could not read keeps the reason `status` gave.
        State::NotInstalled | State::NotLinked => row.note.take(),
        State::Foreign => Some(foreign_note(&row.config)),
        State::Linked | State::Stale if dry_run => Some("would unlink".to_owned()),
        State::Linked | State::Stale => match remove_entry(env, app) {
            Ok(()) => {
                row.state = State::NotLinked;
                Some(format!("unlinked; {}", app.takes_effect()))
            }
            Err(e) if e.downcast_ref::<ForeignEntry>().is_some() => {
                row.state = State::Foreign;
                Some(foreign_note(&row.config))
            }
            Err(e) => Some(format!("{e:#}")),
        },
    };
    row
}

/// The entry named [`SERVER_KEY`] in `app`'s config, as JSON (Codex's TOML converted).
fn read_entry(env: &Env, app: App) -> Result<Option<Value>> {
    let path = env.config_path(app);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
    };
    match app {
        App::ClaudeDesktop | App::ClaudeCode | App::OpenCode | App::GeminiCli | App::QwenCode => {
            if text.trim().is_empty() {
                return Ok(None);
            }
            let doc: Value = serde_json::from_str(&text)
                .with_context(|| format!("{} is not JSON", path.display()))?;
            let entry = doc.pointer(&format!("/{}/{SERVER_KEY}", servers_key(app)));
            Ok(entry.map(|e| canonical(app, e)))
        }
        // `status` reads pi's skill itself; it has no entry.
        App::Pi => Ok(None),
        App::Codex => {
            let doc: toml::Table =
                toml::from_str(&text).with_context(|| format!("{} is not TOML", path.display()))?;
            let entry = doc
                .get("mcp_servers")
                .and_then(|s| s.get(SERVER_KEY))
                .map(|e| serde_json::to_value(e).unwrap_or(Value::Null));
            Ok(entry)
        }
    }
}

fn write_entry(env: &Env, app: App, replace: bool) -> Result<()> {
    match app {
        App::ClaudeDesktop | App::OpenCode | App::GeminiCli | App::QwenCode => {
            edit_json(&env.config_path(app), servers_key(app), link_json(env, app))
        }
        App::Pi => edit_file(&env.config_path(app), None, |text| {
            if !text.is_empty() && !pi_ours(text) {
                return Err(ForeignEntry.into());
            }
            Ok(env.pi_skill())
        }),
        App::ClaudeCode => {
            // `claude mcp` edits the file itself, so this is checked just before it runs.
            refuse_foreign_claude_code(env)?;
            if replace {
                claude_cli(env, &["mcp", "remove", "--scope", "user", SERVER_KEY])?;
            }
            let entry = env.entry_json(app).to_string();
            claude_cli(env, &["mcp", "add-json", "--scope", "user", SERVER_KEY, &entry])
        }
        App::Codex => edit_toml(&env.config_path(app), link_toml(env, app)),
    }
}

fn remove_entry(env: &Env, app: App) -> Result<()> {
    match app {
        App::ClaudeDesktop | App::OpenCode | App::GeminiCli | App::QwenCode => {
            edit_json(&env.config_path(app), servers_key(app), unlink_json(app))
        }
        App::Pi => {
            let path = env.config_path(app);
            // Move the skill aside first and judge the file that moved, so a skill another writer
            // puts there while this runs is the one judged, never one deleted unread.
            let aside = path.with_file_name(format!("SKILL.md.cmux-unlink-{}", std::process::id()));
            match std::fs::rename(&path, &aside) {
                Ok(()) => {}
                // Already gone: nothing to remove.
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
                Err(e) => return Err(e).with_context(|| format!("moving {}", path.display())),
            }
            let ours = std::fs::read_to_string(&aside).is_ok_and(|text| pi_ours(&text));
            if !ours {
                // Put it back without replacing a file written there since: a hard link fails
                // when the name is taken, and then the moved file stays beside it, named.
                return match std::fs::hard_link(&aside, &path) {
                    Ok(()) => {
                        let _ = std::fs::remove_file(&aside);
                        Err(ForeignEntry.into())
                    }
                    Err(e) => Err(anyhow!(
                        "{} is not cmux's and a new one took its place; it is kept as {}: {e}",
                        path.display(),
                        aside.display()
                    )),
                };
            }
            std::fs::remove_file(&aside)
                .with_context(|| format!("removing {}", aside.display()))?;
            // The skill's own folder, when nothing else is in it.
            if let Some(dir) = path.parent() {
                let _ = std::fs::remove_dir(dir);
            }
            Ok(())
        }
        App::ClaudeCode => {
            refuse_foreign_claude_code(env)?;
            claude_cli(env, &["mcp", "remove", "--scope", "user", SERVER_KEY])
        }
        App::Codex => edit_toml(&env.config_path(app), unlink_toml),
    }
}

/// [`ForeignEntry`] when Claude Code's config has an entry named [`SERVER_KEY`] that is not ours.
fn refuse_foreign_claude_code(env: &Env) -> Result<()> {
    match read_entry(env, App::ClaudeCode)? {
        Some(entry) if !ours_json(&entry) => Err(ForeignEntry.into()),
        _ => Ok(()),
    }
}

/// Link's change of a JSON config's servers (`mcpServers`, OpenCode's `mcp`), as found in the
/// text of this round: our entry in, unless one named [`SERVER_KEY`] there is not ours.
fn link_json(env: &Env, app: App) -> impl Fn(&mut Ordered<Value>) -> Result<()> + '_ {
    move |servers: &mut Ordered<Value>| {
        if servers.get(SERVER_KEY).is_some_and(|entry| !ours_json(&canonical(app, entry))) {
            return Err(ForeignEntry.into());
        }
        servers.insert(SERVER_KEY, env.native_entry(app));
        Ok(())
    }
}

/// Unlink's: our entry out; one that is not ours stays, refused.
fn unlink_json(app: App) -> impl Fn(&mut Ordered<Value>) -> Result<()> {
    move |servers: &mut Ordered<Value>| {
        if servers.get(SERVER_KEY).is_some_and(|entry| !ours_json(&canonical(app, entry))) {
            return Err(ForeignEntry.into());
        }
        servers.remove(SERVER_KEY);
        Ok(())
    }
}

/// The same for Codex's `[mcp_servers]`.
fn link_toml(env: &Env, app: App) -> impl Fn(&mut toml_edit::Table) -> Result<()> + '_ {
    move |servers: &mut toml_edit::Table| {
        if servers.get(SERVER_KEY).is_some_and(|entry| !ours_toml(entry)) {
            return Err(ForeignEntry.into());
        }
        let mut table = toml_edit::Table::new();
        table.insert("command", toml_edit::value(env.exe.to_string_lossy().as_ref()));
        let mut args = toml_edit::Array::new();
        for arg in &env.args {
            args.push(arg.as_str());
        }
        table.insert("args", toml_edit::value(args));
        let mut vars = toml_edit::InlineTable::new();
        for (k, v) in env.entry_env(app) {
            vars.insert(k, v.into());
        }
        table.insert("env", toml_edit::value(vars));
        servers.insert(SERVER_KEY, toml_edit::Item::Table(table));
        Ok(())
    }
}

fn unlink_toml(servers: &mut toml_edit::Table) -> Result<()> {
    if servers.get(SERVER_KEY).is_some_and(|entry| !ours_toml(entry)) {
        return Err(ForeignEntry.into());
    }
    servers.remove(SERVER_KEY);
    Ok(())
}

/// Read `path` as JSON (none or empty: `{}`), change its servers under `key`, and write it back
/// whole ([`edit_file`]). The top level and the servers keep the person's key order (serde_json's
/// own map would sort them).
fn edit_json(
    path: &Path,
    key: &str,
    change: impl Fn(&mut Ordered<Value>) -> Result<()>,
) -> Result<()> {
    edit_file(path, None, |text| render_json(path, key, text, &change))
}

/// `text` with `change` made to its servers under `key`; `change` refuses what it must not touch.
fn render_json(
    path: &Path,
    key: &str,
    text: &str,
    change: &impl Fn(&mut Ordered<Value>) -> Result<()>,
) -> Result<String> {
    let text = if text.trim().is_empty() { "{}" } else { text };
    let doc: Value =
        serde_json::from_str(text).with_context(|| format!("{} is not JSON", path.display()))?;
    let Some(top) = doc.as_object() else {
        bail!("{} is not a JSON object", path.display());
    };
    if top.get(key).is_some_and(|s| !s.is_object()) {
        bail!("{key} in {} is not an object", path.display());
    }
    let top: Ordered<Box<serde_json::value::RawValue>> = serde_json::from_str(text)?;
    let mut servers = match top.get(key) {
        Some(raw) => serde_json::from_str::<Ordered<Value>>(raw.get())?,
        None => Ordered(Vec::new()),
    };
    change(&mut servers)?;
    #[derive(serde::Serialize)]
    #[serde(untagged)]
    enum Node {
        Plain(Value),
        Servers(Ordered<Value>),
    }
    let mut servers = Some(servers);
    let mut out: Vec<(String, Node)> = top
        .0
        .into_iter()
        .map(|(k, v)| {
            let node = match servers.take_if(|_| k == key) {
                Some(s) => Node::Servers(s),
                None => Node::Plain(serde_json::from_str(v.get())?),
            };
            Ok((k, node))
        })
        .collect::<Result<_>>()?;
    if let Some(s) = servers {
        out.push((key.to_owned(), Node::Servers(s)));
    }
    let mut out = serde_json::to_string_pretty(&Ordered(out))?;
    out.push('\n');
    Ok(out)
}

/// The key of the MCP servers of Claude's, Gemini CLI's and Qwen Code's configs.
const SERVERS_KEY: &str = "mcpServers";

/// A JSON object read and written in its own key order.
struct Ordered<T>(Vec<(String, T)>);

impl<T> Ordered<T> {
    /// Set `key` to `value`, in its place when it is there, else last.
    fn insert(&mut self, key: &str, value: T) {
        match self.0.iter_mut().find(|(k, _)| k == key) {
            Some((_, v)) => *v = value,
            None => self.0.push((key.to_owned(), value)),
        }
    }

    fn remove(&mut self, key: &str) {
        self.0.retain(|(k, _)| k != key);
    }

    fn get(&self, key: &str) -> Option<&T> {
        self.0.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }
}

impl<'de, T: serde::Deserialize<'de>> serde::Deserialize<'de> for Ordered<T> {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Visit<T>(std::marker::PhantomData<T>);
        impl<'de, T: serde::Deserialize<'de>> serde::de::Visitor<'de> for Visit<T> {
            type Value = Ordered<T>;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a JSON object")
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                mut map: A,
            ) -> Result<Ordered<T>, A::Error> {
                let mut out = Vec::new();
                while let Some(entry) = map.next_entry()? {
                    out.push(entry);
                }
                Ok(Ordered(out))
            }
        }
        d.deserialize_map(Visit(std::marker::PhantomData))
    }
}

impl<T: serde::Serialize> serde::Serialize for Ordered<T> {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.collect_map(self.0.iter().map(|(k, v)| (k, v)))
    }
}

/// The same for Codex's TOML, through `toml_edit` so the person's comments and order stay, under
/// the lock every cmux writer of it takes (`cmux_tui_platform::codex_config_lock`: the hook
/// installer's trust state and the Cloud devbox provider merge).
fn edit_toml(path: &Path, change: impl Fn(&mut toml_edit::Table) -> Result<()>) -> Result<()> {
    let lock = path.parent().map(|dir| dir.join(cmux_tui_platform::codex_config_lock::LOCK_FILE));
    edit_file(path, lock.as_deref(), |text| render_toml(path, text, &change))
}

fn render_toml(
    path: &Path,
    text: &str,
    change: &impl Fn(&mut toml_edit::Table) -> Result<()>,
) -> Result<String> {
    let mut doc: toml_edit::DocumentMut =
        text.parse().with_context(|| format!("{} is not TOML", path.display()))?;
    let servers = doc.entry("mcp_servers").or_insert_with(|| {
        let mut t = toml_edit::Table::new();
        t.set_implicit(true);
        toml_edit::Item::Table(t)
    });
    let Some(servers) = servers.as_table_mut() else {
        bail!("mcp_servers in {} is not a table", path.display());
    };
    change(servers)?;
    Ok(doc.to_string())
}

/// Run the `claude` CLI with `args`, bounded; its last stderr line is the error.
fn claude_cli(env: &Env, args: &[&str]) -> Result<()> {
    let Some(cli) = &env.claude_cli else {
        bail!(
            "the claude CLI is not on PATH; run: claude {}",
            args.iter()
                .map(|a| crate::harness_health::channel::quote(a))
                .collect::<Vec<_>>()
                .join(" ")
        );
    };
    let mut command = std::process::Command::new(cli);
    command
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    // Settings runs this from the app, whose PATH is not the login shell's: an npm-installed
    // `claude` needs `node` from there.
    if let Some(path) = crate::login_env::path() {
        command.env("PATH", path);
    }
    let deadline = tokio::time::Instant::now().checked_add(CLAUDE_CLI_WAIT);
    let done = crate::cli::bounded_child::wait(command.spawn()?, None, deadline, "claude mcp")?;
    if !done.status.success() {
        let err = String::from_utf8_lossy(&done.stderr);
        let out = String::from_utf8_lossy(&done.stdout);
        let why = err.lines().chain(out.lines()).rfind(|l| !l.trim().is_empty()).unwrap_or("");
        let verb = args.get(..2).unwrap_or(args).join(" ");
        bail!("claude {verb} failed ({}): {why}", done.status);
    }
    Ok(())
}

/// The apps a command acts on: the one named, or every one.
pub fn apps(named: Option<&str>) -> Result<Vec<App>> {
    match named {
        None | Some("all") => Ok(App::ALL.to_vec()),
        Some(id) => App::parse(id).map(|a| vec![a]).ok_or_else(|| {
            anyhow!("no app {id}: one of {}, or all", App::ALL.map(App::id).join(", "))
        }),
    }
}

// Every edit of an app's config goes through it (`desktop_link_write.rs`).
#[path = "desktop_link_write.rs"]
mod write;
use write::edit_file;

#[cfg(test)]
#[path = "desktop_link_tests.rs"]
mod tests;
