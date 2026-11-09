//! `acpmux desktop link | unlink | status`: give the Claude desktop app, Claude Code (its own
//! CLI and Claude desktop's Code tab) and Codex (its desktop app and CLI) this machine's acpmux
//! MCP server, so a chat there reaches every session, machine and Cloud machine acpmux reaches.
//! Leo, 2026-11-09: "even if somebody say still wants to keep using [the Codex desktop app] and/or claude
//! desktop, to be always saying "yeah i want to keep using cmux-next :) they give a good
//! transport between everybody :)"".
//!
//! Each app gets one MCP server entry named [`SERVER_KEY`] in its own user-scope config:
//!
//! - Claude desktop: `claude_desktop_config.json` `mcpServers` (macOS `~/Library/Application
//!   Support/Claude`, Linux `$XDG_CONFIG_HOME/Claude`). The app reads it at launch.
//! - Claude Code: `claude mcp add-json --scope user`, its own writer of `~/.claude.json` (which
//!   every running Claude Code rewrites, so acpmux never writes that file itself). Claude
//!   desktop's Code tab runs the same Claude Code with the same user config.
//! - Codex: `[mcp_servers.cmux]` in `$CODEX_HOME/config.toml` (`~/.codex`), which the Codex
//!   desktop app and CLI share, edited with `toml_edit` so comments and order stay.
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
use serde_json::{Value, json};

/// The server's name in every app's config: the name the tools show under (`mcp__cmux__ls`).
pub const SERVER_KEY: &str = "cmux";
/// Set in the entry's env to the app's id: the acpmux MCP server's guest mode, and the mark of
/// an entry this command wrote.
pub const GUEST_ENV: &str = "ACPMUX_MCP_GUEST";
/// The server subcommand the entry runs.
const SERVER_ARG: &str = "acpmux-mcp";
/// The longest a `claude mcp` call may take.
const CLAUDE_CLI_WAIT: std::time::Duration = std::time::Duration::from_secs(20);

/// An app this command links.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum App {
    ClaudeDesktop,
    ClaudeCode,
    Codex,
}

impl App {
    pub const ALL: [App; 3] = [App::ClaudeDesktop, App::ClaudeCode, App::Codex];

    /// The id the CLI takes and the entry's [`GUEST_ENV`] carries.
    pub fn id(self) -> &'static str {
        match self {
            App::ClaudeDesktop => "claude-desktop",
            App::ClaudeCode => "claude-code",
            App::Codex => "codex",
        }
    }

    /// What a person calls it.
    pub fn label(self) -> &'static str {
        match self {
            App::ClaudeDesktop => "Claude desktop",
            App::ClaudeCode => "Claude Code",
            App::Codex => "Codex desktop and CLI",
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
    /// `XDG_CONFIG_HOME`, when set (Linux only).
    pub xdg_config_home: Option<PathBuf>,
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
        }
    }

    fn claude_desktop_dir(&self) -> PathBuf {
        if cfg!(target_os = "macos") {
            self.home.join("Library/Application Support/Claude")
        } else {
            self.xdg_config_home.clone().unwrap_or_else(|| self.home.join(".config")).join("Claude")
        }
    }

    /// Whether the app is on this machine: its config folder is there (Claude Code: its CLI or
    /// its config file).
    pub fn installed(&self, app: App) -> bool {
        match app {
            App::ClaudeDesktop => self.claude_desktop_dir().is_dir(),
            App::ClaudeCode => self.claude_cli.is_some() || self.config_path(app).is_file(),
            App::Codex => self.config_path(app).parent().is_some_and(Path::is_dir),
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

    /// The entry for `app`, as the JSON both Claude configs take.
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
    /// Our entry, running another acpmux (an older app's, a moved binary).
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
            v["note"] = json!(note);
        }
        v
    }
}

/// The state of `app`'s entry, read only.
pub fn status(env: &Env, app: App) -> Row {
    let config = env.config_path(app);
    let state = if !env.installed(app) {
        State::NotInstalled
    } else {
        match read_entry(env, app) {
            Ok(entry) => classify(env, entry.as_ref()),
            Err(e) => {
                return Row { app, state: State::NotLinked, config, note: Some(format!("{e:#}")) };
            }
        }
    };
    Row { app, state, config, note: None }
}

fn classify(env: &Env, entry: Option<&Value>) -> State {
    let Some(entry) = entry else { return State::NotLinked };
    if entry.pointer(&format!("/env/{GUEST_ENV}")).and_then(Value::as_str).is_none() {
        return State::Foreign;
    }
    let ours = env.exe.to_string_lossy();
    let same_args = entry["args"] == json!(env.args);
    if entry["command"].as_str() == Some(ours.as_ref()) && same_args {
        State::Linked
    } else {
        State::Stale
    }
}

/// Give `app` the entry. An entry of ours that runs another binary is replaced; one we did not
/// write is left alone and named in the row.
pub fn link(env: &Env, app: App, dry_run: bool) -> Row {
    let mut row = status(env, app);
    row.note = match row.state {
        State::NotInstalled => Some(format!("{} is not on this machine", app.label())),
        State::Linked => Some("already linked".to_owned()),
        State::Foreign => Some(format!(
            "a server named {SERVER_KEY} that cmux did not write is in {}; left alone",
            row.config.display()
        )),
        State::NotLinked | State::Stale if dry_run => Some("would link".to_owned()),
        State::NotLinked | State::Stale => match write_entry(env, app, row.state == State::Stale) {
            Ok(()) => {
                row.state = State::Linked;
                Some(format!("linked; {}", app.takes_effect()))
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
        State::Foreign => {
            Some(format!("a server named {SERVER_KEY} that cmux did not write; left alone"))
        }
        State::Linked | State::Stale if dry_run => Some("would unlink".to_owned()),
        State::Linked | State::Stale => match remove_entry(env, app) {
            Ok(()) => {
                row.state = State::NotLinked;
                Some(format!("unlinked; {}", app.takes_effect()))
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
        App::ClaudeDesktop | App::ClaudeCode => {
            if text.trim().is_empty() {
                return Ok(None);
            }
            let doc: Value = serde_json::from_str(&text)
                .with_context(|| format!("{} is not JSON", path.display()))?;
            Ok(doc.pointer(&format!("/{SERVERS_KEY}/{SERVER_KEY}")).cloned())
        }
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
        App::ClaudeDesktop => {
            let path = env.config_path(app);
            edit_json(&path, |servers| servers.insert(SERVER_KEY, env.entry_json(app)))
        }
        App::ClaudeCode => {
            if replace {
                claude_cli(env, &["mcp", "remove", "--scope", "user", SERVER_KEY])?;
            }
            let entry = env.entry_json(app).to_string();
            claude_cli(env, &["mcp", "add-json", "--scope", "user", SERVER_KEY, &entry])
        }
        App::Codex => {
            let path = env.config_path(app);
            edit_toml(&path, |servers| {
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
            })
        }
    }
}

fn remove_entry(env: &Env, app: App) -> Result<()> {
    match app {
        App::ClaudeDesktop => {
            edit_json(&env.config_path(app), |servers| servers.remove(SERVER_KEY))
        }
        App::ClaudeCode => claude_cli(env, &["mcp", "remove", "--scope", "user", SERVER_KEY]),
        App::Codex => edit_toml(&env.config_path(app), |servers| {
            servers.remove(SERVER_KEY);
        }),
    }
}

/// Read `path` as JSON (none or empty: `{}`), change its `mcpServers`, and write it back whole
/// through a temp file and a rename, so the app never reads half a file. The top level and
/// `mcpServers` keep the person's key order (serde_json's own map would sort them).
fn edit_json(path: &Path, change: impl FnOnce(&mut Ordered<Value>)) -> Result<()> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
    };
    let text = if text.trim().is_empty() { "{}" } else { text.as_str() };
    let doc: Value =
        serde_json::from_str(text).with_context(|| format!("{} is not JSON", path.display()))?;
    let Some(top) = doc.as_object() else {
        bail!("{} is not a JSON object", path.display());
    };
    if top.get(SERVERS_KEY).is_some_and(|s| !s.is_object()) {
        bail!("{SERVERS_KEY} in {} is not an object", path.display());
    }
    let top: Ordered<Value> = serde_json::from_str(text)?;
    #[derive(serde::Deserialize)]
    struct Servers {
        #[serde(rename = "mcpServers")]
        servers: Option<Ordered<Value>>,
    }
    let mut servers = serde_json::from_str::<Servers>(text)?.servers.unwrap_or(Ordered(Vec::new()));
    change(&mut servers);
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
            let node = match servers.take_if(|_| k == SERVERS_KEY) {
                Some(s) => Node::Servers(s),
                None => Node::Plain(v),
            };
            (k, node)
        })
        .collect();
    if let Some(s) = servers {
        out.push((SERVERS_KEY.to_owned(), Node::Servers(s)));
    }
    let mut out = serde_json::to_string_pretty(&Ordered(out))?;
    out.push('\n');
    write_atomic(path, &out)
}

/// The key of Claude's MCP servers.
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

/// The same for Codex's TOML, through `toml_edit` so the person's comments and order stay.
fn edit_toml(path: &Path, change: impl FnOnce(&mut toml_edit::Table)) -> Result<()> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
    };
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
    change(servers);
    write_atomic(path, &doc.to_string())
}

fn write_atomic(path: &Path, text: &str) -> Result<()> {
    let dir = path.parent().ok_or_else(|| anyhow!("{} has no folder", path.display()))?;
    std::fs::create_dir_all(dir).with_context(|| format!("making {}", dir.display()))?;
    let mut tmp = tempfile::NamedTempFile::new_in(dir)
        .with_context(|| format!("writing beside {}", path.display()))?;
    std::io::Write::write_all(&mut tmp, text.as_bytes())?;
    // Keep the file's mode (a person may have made it 0600).
    #[cfg(unix)]
    if let Ok(meta) = std::fs::metadata(path) {
        let _ = std::fs::set_permissions(tmp.path(), meta.permissions());
    }
    tmp.persist(path).map_err(|e| anyhow!("replacing {}: {}", path.display(), e.error))?;
    Ok(())
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
    let deadline = tokio::time::Instant::now() + CLAUDE_CLI_WAIT;
    let done =
        crate::cli::bounded_child::wait(command.spawn()?, None, Some(deadline), "claude mcp")?;
    if !done.status.success() {
        let err = String::from_utf8_lossy(&done.stderr);
        let out = String::from_utf8_lossy(&done.stdout);
        let why = err.lines().chain(out.lines()).rfind(|l| !l.trim().is_empty()).unwrap_or("");
        bail!("claude {} failed ({}): {why}", args[..2].join(" "), done.status);
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

#[cfg(test)]
#[path = "desktop_link_tests.rs"]
mod tests;
