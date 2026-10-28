//! `cmux agents doctor`: whether this machine is ready for agents, read-only.
//!
//! It reports, never changes: Claude Code and Codex on PATH, whether each
//! names the cmux-cua MCP server in its own config, and the macOS grants of
//! the cmux Computer Use helper. cmux injects cmux-cua into every chat it
//! starts (acpmux `agent_tools`), so a config without it means computer use
//! only inside cmux chats, not an error. The grants come from the running
//! app (`computer_use.status`, the model behind Computer Use Setup); without
//! the app they are unknown rather than guessed. Nothing here prompts for or
//! grants a permission, and every report exits 0.
//!
//! The MCP tool `agents_doctor` runs the same checks (`mcp_findings`) and
//! reports each row as a finding with a status of ok, warn or fail and a
//! structured fix. Both print paths under HOME as `~/...` and never print
//! the text of a config they could not parse (it may hold a key).

use std::ffi::OsStr;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, wire};
use crate::localization::AgentsDoctorMessages;

const HELP: &str = "Usage: cmux agents doctor [--json]\n\nReports whether this machine is ready for agents: Claude Code and Codex on PATH, their cmux-cua computer use wiring, any older cmux on PATH that a login shell could run instead of this one, and the macOS grants of cmux Computer Use (Accessibility, Screen Recording, capture consent). Read-only: it never changes a config and never asks for a grant. Exits 0 for every report; 2 on a usage error. --json prints {\"schema_version\":1,\"checks\":[...]}; every row has exactly the keys id, status (ok, missing, unknown, not_applicable, cmux_only, outdated), reason, detail, fix and fix_url (null when there is none).\n";

/// The app method that reports Computer Use Setup's grants.
pub(super) const STATUS_METHOD: &str = "computer_use.status";
/// The MCP server name cmux uses for computer use, and its binary.
const CUA_SERVER: &str = "cmux-cua";
pub(super) const ACCESSIBILITY_URL: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
pub(super) const SCREEN_RECORDING_URL: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Status {
    Ok,
    Missing,
    Unknown,
    NotApplicable,
    /// Not configured for the user, but injected into chats cmux starts.
    CmuxOnly,
    /// An older `cmux` that a login shell may find first.
    Outdated,
}

impl Status {
    fn key(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Missing => "missing",
            Self::Unknown => "unknown",
            Self::NotApplicable => "not_applicable",
            Self::CmuxOnly => "cmux_only",
            Self::Outdated => "outdated",
        }
    }

    fn label(self, messages: &AgentsDoctorMessages) -> &'static str {
        match self {
            Self::Ok => messages.status_ok,
            Self::Missing => messages.status_missing,
            Self::Unknown => messages.status_unknown,
            Self::NotApplicable => messages.status_not_applicable,
            Self::CmuxOnly => messages.status_cmux_only,
            Self::Outdated => messages.status_outdated,
        }
    }
}

/// One row of the report.
struct Check {
    id: &'static str,
    label: &'static str,
    status: Status,
    reason: &'static str,
    detail: String,
    fix: Option<String>,
    fix_url: Option<&'static str>,
    /// What an MCP client can do about it (`Fix`); text only when `None`.
    action: Option<FixAction>,
    /// A missing harness while another one is installed: a warning, not a
    /// failure, for the MCP finding.
    other_harness: bool,
}

/// The runnable part of a fix: a command as written in the fix text, or
/// the cmux command palette entry it names.
#[derive(Clone, Copy)]
enum FixAction {
    /// `cmux agents doctor`, run again.
    RunAgain,
    /// `open '<fix_url>'`.
    OpenUrl,
    /// The palette entry Computer Use Setup.
    ComputerUseSetup,
}

/// The palette entry the setup fixes name, as the app titles it.
const COMPUTER_USE_SETUP: &str = "Computer Use Setup";

impl Check {
    fn new(id: &'static str, label: &'static str, status: Status, reason: &'static str) -> Self {
        Self {
            id,
            label,
            status,
            reason,
            detail: String::new(),
            fix: None,
            fix_url: None,
            action: None,
            other_harness: false,
        }
    }

    fn detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = detail.into();
        self
    }

    fn fix(mut self, fix: impl Into<String>) -> Self {
        self.fix = Some(fix.into());
        self
    }

    /// A fix whose runnable part is `action`.
    fn fix_action(mut self, fix: &str, action: Option<FixAction>) -> Self {
        self.fix = Some(fix.to_owned());
        self.action = action;
        self
    }

    /// The detail and the fix with every path under a `redactions`
    /// directory written by its name (`~/...`, `$CODEX_HOME/...`).
    fn redacted(mut self, redactions: &[(String, &'static str)]) -> Self {
        self.detail = redact_paths(&self.detail, redactions);
        self.fix = self.fix.map(|fix| redact_paths(&fix, redactions));
        self
    }

    /// The MCP finding: `{id, status, reason, summary, fix}`, where `status`
    /// is ok (ok, not applicable), warn (only inside cmux chats, unknown, a
    /// missing harness beside an installed one) or fail (missing) and `fix`
    /// is `{text, command, palette, url}` or null.
    fn finding(&self) -> Value {
        let status = match self.status {
            Status::Ok | Status::NotApplicable => "ok",
            Status::CmuxOnly | Status::Unknown | Status::Outdated => "warn",
            Status::Missing if self.other_harness => "warn",
            Status::Missing => "fail",
        };
        let fix = self.fix.as_ref().map(|text| {
            let (command, palette) = match self.action {
                Some(FixAction::RunAgain) => (Some("cmux agents doctor".to_owned()), None),
                Some(FixAction::OpenUrl) => (self.fix_url.map(|url| format!("open '{url}'")), None),
                Some(FixAction::ComputerUseSetup) => (None, Some(COMPUTER_USE_SETUP)),
                None => (None, None),
            };
            json!({"text": text, "command": command, "palette": palette, "url": self.fix_url})
        });
        json!({
            "id": self.id,
            "status": status,
            "reason": self.reason,
            "summary": format!("{}: {}", self.label, self.detail),
            "fix": fix,
        })
    }

    fn json(&self) -> Value {
        let mut row = Map::new();
        row.insert("id".into(), json!(self.id));
        row.insert("status".into(), json!(self.status.key()));
        row.insert("reason".into(), json!(self.reason));
        row.insert("detail".into(), json!(self.detail));
        row.insert("fix".into(), json!(self.fix));
        row.insert("fix_url".into(), json!(self.fix_url));
        Value::Object(row)
    }
}

/// What the doctor reads from the environment, read once.
struct Environment {
    home: Option<PathBuf>,
    path: Option<std::ffi::OsString>,
    cwd: Option<PathBuf>,
    claude_config_dir: Option<PathBuf>,
    codex_home: Option<PathBuf>,
}

impl Environment {
    /// The directories printed by name: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`
    /// and HOME (`~`), each as set and as resolved (the working directory
    /// is the resolved path, so a symlinked HOME reads both ways), longest
    /// first.
    fn redactions(&self) -> Vec<(String, &'static str)> {
        let mut redactions = Vec::new();
        for (dir, name) in [
            (&self.claude_config_dir, "$CLAUDE_CONFIG_DIR"),
            (&self.codex_home, "$CODEX_HOME"),
            (&self.home, "~"),
        ] {
            let Some(dir) = dir else { continue };
            for dir in
                [Some(dir.clone()), cmux_blocking::fs::canonicalize(dir).ok()].into_iter().flatten()
            {
                if let Some(dir) = dir.to_str().map(|dir| dir.trim_end_matches('/'))
                    && !dir.is_empty()
                    && !redactions.iter().any(|(seen, _): &(String, _)| seen == dir)
                {
                    redactions.push((dir.to_owned(), name));
                }
            }
        }
        redactions.sort_by_key(|(dir, _)| std::cmp::Reverse(dir.len()));
        redactions
    }

    fn current() -> Self {
        let env = super::caller_env::var_os;
        let dir = |key: &str| env(key).filter(|value| !value.is_empty()).map(PathBuf::from);
        Self {
            home: dir("HOME"),
            path: env("PATH"),
            cwd: super::caller_env::current_dir(),
            claude_config_dir: dir("CLAUDE_CONFIG_DIR"),
            codex_home: dir("CODEX_HOME"),
        }
    }
}

/// Runs `cmux agents doctor` with the arguments after `doctor`.
pub(super) fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    if args.iter().any(|arg| matches!(arg.as_str(), "--help" | "-h")) {
        println!("{HELP}");
        return 0;
    }
    if let Some(arg) = args.first() {
        return wire::print_local_error(
            &json!({
                "code": "usage.invalid",
                "message": format!("cmux: agents doctor: unexpected argument {arg:?}"),
                "details": {},
                "retryable": false,
            }),
            global.output,
            2,
        );
    }
    let messages = &crate::localization::catalog().agents_doctor;
    let checks = collect(&Environment::current(), messages, None, || app_status(global));
    match global.output {
        OutputMode::Human => {
            print!("{}", table(&checks, messages));
            0
        }
        OutputMode::Quiet => 0,
        OutputMode::Json | OutputMode::JsonLines => {
            let report = json!({
                "schema_version": 1,
                "checks": checks.iter().map(Check::json).collect::<Vec<_>>(),
            });
            wire::print_local_success(&report, global.output)
        }
    }
}

/// Every check id, in report order.
const CHECK_IDS: [&str; 8] = [
    "harness.claude",
    "harness.codex",
    "mcp.claude",
    "mcp.codex",
    "cli.shadow",
    "grant.accessibility",
    "grant.screen_recording",
    "grant.capture_consent",
];

/// The app's `computer_use.status` reply as the CLI reads it.
#[cfg_attr(not(target_os = "macos"), allow(unused_variables))]
fn app_status(global: &GlobalArgs) -> Result<Value, Value> {
    #[cfg(target_os = "macos")]
    {
        super::mcp::agent_app(global, STATUS_METHOD, json!({}), super::app::READ_TIMEOUT, None)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(json!({"code": "app.not_found"}))
    }
}

/// The rows `wanted` names (all when `None`), in report order. The app is
/// asked for its grants only on macOS and only when a grant row is wanted.
fn collect(
    environment: &Environment,
    messages: &AgentsDoctorMessages,
    wanted: Option<&[String]>,
    app_status: impl FnOnce() -> Result<Value, Value>,
) -> Vec<Check> {
    let wants = |id: &str| wanted.is_none_or(|wanted| wanted.iter().any(|w| w == id));
    let mut checks = checks_without_grants(environment, messages);
    let redactions = environment.redactions();
    let harness = |check: &Check| check.id.starts_with("harness.");
    if checks.iter().any(|check| harness(check) && check.status == Status::Ok) {
        for check in checks.iter_mut().filter(|check| harness(check)) {
            check.other_harness = check.status == Status::Missing;
        }
    }
    if GRANT_ROWS.into_iter().any(wants) {
        checks.extend(grant_checks(app_status, messages));
    }
    checks
        .into_iter()
        .filter(|check| wants(check.id))
        .map(|check| check.redacted(&redactions))
        .collect()
}

/// The MCP tool's name.
pub(super) const MCP_TOOL: &str = "agents_doctor";

/// The `agents_doctor` tool descriptor: read-only, one optional argument.
pub(super) fn mcp_tool() -> Value {
    json!({
        "name": MCP_TOOL,
        "title": "Agents doctor",
        "description": "Check whether this machine is ready for agents, as `cmux agents doctor` \
            does: Claude Code and Codex on PATH, their cmux-cua computer use wiring, an older \
            cmux on PATH, and the macOS grants of cmux Computer Use. Read-only: it runs no fix and changes no \
            setting. Answers {schema_version, findings}; each finding is {id, status (ok, \
            warn, fail), reason, summary, fix}, where fix is null or {text, command, palette, \
            url}: a command to run as written, a cmux command palette entry, or a System \
            Settings url to open. Paths under the home directory read ~/...",
        "inputSchema": {
            "type": "object",
            "properties": {
                "checks": {
                    "type": "array",
                    "minItems": 1,
                    "uniqueItems": true,
                    "items": {"type": "string", "enum": CHECK_IDS},
                    "description": "Only these checks, by id; default all.",
                },
            },
            "required": [],
            "additionalProperties": false,
        },
        "annotations": {
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": false,
        },
    })
}

/// The `agents_doctor` result for these tool arguments, or why they are
/// refused. `app_status` reads the app's `computer_use.status`.
pub(super) fn mcp_findings(
    arguments: &Map<String, Value>,
    app_status: impl FnOnce() -> Result<Value, Value>,
) -> Result<Value, String> {
    if let Some(name) = arguments.keys().find(|name| *name != "checks") {
        return Err(format!("{MCP_TOOL} has no argument {name:?}"));
    }
    let wanted = match arguments.get("checks") {
        None => None,
        Some(Value::Array(items)) if !items.is_empty() => Some(
            items
                .iter()
                .map(|item| match item.as_str() {
                    Some(id) if CHECK_IDS.contains(&id) => Ok(id.to_owned()),
                    _ => Err(format!(
                        "{MCP_TOOL}: unknown check {item}; the checks are {}",
                        CHECK_IDS.join(", ")
                    )),
                })
                .collect::<Result<Vec<_>, _>>()?,
        ),
        Some(_) => return Err(format!("{MCP_TOOL}: checks must be a nonempty array of ids")),
    };
    if let Some(wanted) = &wanted
        && let Some(duplicate) =
            wanted.iter().enumerate().find_map(|(i, id)| wanted[..i].contains(id).then_some(id))
    {
        return Err(format!("{MCP_TOOL}: checks names {duplicate} twice"));
    }
    let messages = &crate::localization::catalog().agents_doctor;
    let checks = collect(&Environment::current(), messages, wanted.as_deref(), app_status);
    Ok(json!({
        "schema_version": 1,
        "findings": checks.iter().map(Check::finding).collect::<Vec<_>>(),
    }))
}

/// `text` with each redaction directory, and every path under it, written
/// by its name. `redactions` is longest first, so `$CODEX_HOME` inside HOME
/// keeps its name.
fn redact_paths(text: &str, redactions: &[(String, &'static str)]) -> String {
    let mut text = text.to_owned();
    for (dir, name) in redactions {
        if text == *dir {
            return (*name).to_owned();
        }
        text = text.replace(&format!("{dir}/"), &format!("{name}/"));
    }
    text
}

fn checks_without_grants(environment: &Environment, messages: &AgentsDoctorMessages) -> Vec<Check> {
    let claude = on_path(environment.path.as_deref(), "claude");
    let codex = on_path(environment.path.as_deref(), "codex");
    vec![
        harness_check(
            "harness.claude",
            messages.check_harness_claude,
            "Claude Code",
            claude.as_deref(),
            messages,
        ),
        harness_check(
            "harness.codex",
            messages.check_harness_codex,
            "Codex",
            codex.as_deref(),
            messages,
        ),
        mcp_check(
            "mcp.claude",
            messages.check_mcp_claude,
            "Claude Code",
            claude.is_some(),
            || claude_cua(environment),
            messages,
        ),
        mcp_check(
            "mcp.codex",
            messages.check_mcp_codex,
            "Codex",
            codex.is_some(),
            || codex_cua(environment),
            messages,
        ),
        cli_shadow_check(environment.path.as_deref(), messages),
    ]
}

// MARK: Older cmux on PATH

/// How long one `cmux --version` may take.
const VERSION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);

/// Every `cmux` on `path` that is not this CLI and is older than it: a login
/// shell (Codex runs each command in `zsh -lc`) that lists one first runs it
/// instead of this CLI. The PyPI `cmux` (cmux-tui) in `~/.local/bin` is the
/// usual one. App-bundled CLIs (`*.app/Contents/Resources/bin/cmux`) are left
/// out: each belongs to its own app. Runs only `--version` of each.
fn cli_shadow_check(path: Option<&OsStr>, messages: &AgentsDoctorMessages) -> Check {
    let label = messages.check_cli_shadow;
    let own_version = env!("CARGO_PKG_VERSION");
    let own = parse_version(own_version);
    let this = std::env::current_exe().and_then(cmux_blocking::fs::canonicalize).ok();
    let mut seen: Vec<PathBuf> = Vec::new();
    let mut older: Vec<(PathBuf, String)> = Vec::new();
    for dir in path.map(std::env::split_paths).into_iter().flatten() {
        let candidate = dir.join("cmux");
        let Ok(meta) = cmux_blocking::fs::metadata(&candidate) else { continue };
        if !meta.is_file() || meta.permissions().mode() & 0o111 == 0 {
            continue;
        }
        let real =
            cmux_blocking::fs::canonicalize(&candidate).unwrap_or_else(|_| candidate.clone());
        if this.as_ref() == Some(&real) || seen.contains(&real) || in_app_bundle(&real) {
            continue;
        }
        seen.push(real);
        let Some(version) = version_of(&candidate) else { continue };
        if let (Some(theirs), Some(own)) = (parse_version(&version), own)
            && theirs < own
        {
            older.push((candidate, version));
        }
    }
    if older.is_empty() {
        return Check::new("cli.shadow", label, Status::Ok, "no_older_cli")
            .detail(messages.no_older_cli);
    }
    let list = older
        .iter()
        .map(|(path, version)| format!("{} ({version})", path.display()))
        .collect::<Vec<_>>()
        .join(", ");
    let paths =
        older.iter().map(|(path, _)| path.display().to_string()).collect::<Vec<_>>().join(", ");
    Check::new("cli.shadow", label, Status::Outdated, "older_cli_on_path")
        .detail(messages.older_cli_on_path.replace("{list}", &list).replace("{own}", own_version))
        .fix(messages.remove_older_cli.replace("{paths}", &paths))
}

/// Whether `path` is inside `<name>.app/Contents/Resources/bin/`.
fn in_app_bundle(path: &Path) -> bool {
    path.parent().is_some_and(|bin| {
        bin.ends_with("Contents/Resources/bin")
            && bin
                .ancestors()
                .nth(3)
                .is_some_and(|app| app.extension().is_some_and(|extension| extension == "app"))
    })
}

/// The first `X.Y.Z` that `<cli> --version` prints, within
/// [`VERSION_TIMEOUT`]; `None` when it fails, hangs or prints none.
fn version_of(cli: &Path) -> Option<String> {
    use cmux_process::{Command, Stdio};
    use std::io::Read;
    let mut child = Command::new(cli)
        .arg("--version")
        // The MCP server's proxied servers and their tokens stay with it.
        .env_remove("CMUX_MCP_UPSTREAMS")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    // wakeup-allow: cli-only `cmux agents doctor`'s one bound on an agent's --version; its exit ends the wait first
    if !matches!(child.wait_timeout(VERSION_TIMEOUT), Ok(Some(_))) {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    }
    let mut text = String::new();
    child.stdout.take()?.take(4096).read_to_string(&mut text).ok()?;
    text.split(|c: char| !(c.is_ascii_digit() || c == '.'))
        .find(|word| parse_version(word).is_some())
        .map(str::to_owned)
}

/// `X.Y.Z` (ignoring anything after a third number) as a comparable triple.
fn parse_version(text: &str) -> Option<(u64, u64, u64)> {
    let mut parts = text.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    Some((major, minor, patch))
}

// MARK: Harnesses

/// The first executable `name` in `path` (the `PATH` value), as a shell finds it.
pub(super) fn on_path(path: Option<&OsStr>, name: &str) -> Option<PathBuf> {
    std::env::split_paths(path?)
        .filter(|dir| !dir.as_os_str().is_empty())
        .map(|dir| dir.join(name))
        .find(|candidate| {
            cmux_blocking::fs::metadata(candidate)
                .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        })
}

fn harness_check(
    id: &'static str,
    label: &'static str,
    harness: &str,
    found: Option<&Path>,
    messages: &AgentsDoctorMessages,
) -> Check {
    match found {
        Some(path) => {
            Check::new(id, label, Status::Ok, "on_path").detail(path.display().to_string())
        }
        None => Check::new(id, label, Status::Missing, "not_on_path")
            .detail(messages.not_on_path)
            .fix(messages.install_harness.replace("{harness}", harness)),
    }
}

// MARK: cmux-cua wiring

/// Where a harness config names cmux-cua.
enum Wiring {
    Configured {
        location: PathBuf,
    },
    /// Claude Code's project `.mcp.json` names it, but this project has not
    /// approved it (`projects.<cwd>.enabledMcpjsonServers`).
    PendingApproval {
        location: PathBuf,
    },
    Absent,
    Unreadable {
        location: PathBuf,
        error: String,
    },
}

fn mcp_check(
    id: &'static str,
    label: &'static str,
    harness: &str,
    installed: bool,
    wiring: impl FnOnce() -> Wiring,
    messages: &AgentsDoctorMessages,
) -> Check {
    if !installed {
        return Check::new(id, label, Status::NotApplicable, "harness_missing")
            .detail(messages.harness_missing.replace("{harness}", harness));
    }
    match wiring() {
        Wiring::Configured { location } => Check::new(id, label, Status::Ok, "configured")
            .detail(messages.configured.replace("{location}", &location.display().to_string())),
        Wiring::PendingApproval { location } => {
            Check::new(id, label, Status::CmuxOnly, "pending_approval")
                .detail(
                    messages
                        .pending_approval
                        .replace("{location}", &location.display().to_string()),
                )
                .fix(messages.approve_in_claude)
        }
        Wiring::Absent => Check::new(id, label, Status::CmuxOnly, "injected_in_cmux_chats")
            .detail(messages.injected_in_cmux_chats)
            .fix(messages.start_from_cmux_chat),
        Wiring::Unreadable { location, error } => {
            let shown = location.display().to_string();
            Check::new(id, label, Status::Unknown, "config_unreadable")
                .detail(
                    messages
                        .config_unreadable
                        .replace("{location}", &shown)
                        .replace("{error}", &error),
                )
                .fix(messages.fix_config.replace("{location}", &shown))
        }
    }
}

/// Whether a server entry is cmux-cua: by its name or by its command.
fn is_cua(name: &str, command: Option<&str>) -> bool {
    name == CUA_SERVER
        || command.is_some_and(|command| {
            Path::new(command).file_name().and_then(OsStr::to_str) == Some(CUA_SERVER)
        })
}

pub(super) fn read_text(path: &Path) -> Result<Option<String>, String> {
    match cmux_blocking::fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.to_string()),
    }
}

/// A JSON config, `None` when the file does not exist.
pub(super) fn read_json(path: &Path) -> Result<Option<Value>, String> {
    read_text(path)?
        .map(|text| serde_json::from_str::<Value>(&text).map_err(|error| error.to_string()))
        .transpose()
}

/// The names of the cmux-cua entries of an `mcpServers` object.
fn cua_server_names(servers: Option<&Value>) -> Vec<&str> {
    servers
        .and_then(Value::as_object)
        .map(|servers| {
            servers
                .iter()
                .filter(|(name, server)| {
                    is_cua(name, server.get("command").and_then(Value::as_str))
                })
                .map(|(name, _)| name.as_str())
                .collect()
        })
        .unwrap_or_default()
}

/// Claude Code: user scope (`mcpServers` of `~/.claude.json`, or of
/// `$CLAUDE_CONFIG_DIR/.claude.json`), local scope (its `projects.<cwd>`),
/// and project scope (`.mcp.json` in the working directory), which counts
/// only once `projects.<cwd>.enabledMcpjsonServers` approves it.
fn claude_cua(environment: &Environment) -> Wiring {
    let user_file = environment
        .claude_config_dir
        .as_ref()
        .or(environment.home.as_ref())
        .map(|dir| dir.join(".claude.json"));
    let mut project_entry: Option<Value> = None;
    if let Some(file) = user_file {
        match read_json(&file) {
            Ok(Some(config)) => {
                if !cua_server_names(config.get("mcpServers")).is_empty() {
                    return Wiring::Configured { location: file };
                }
                let project = environment
                    .cwd
                    .as_ref()
                    .and_then(|cwd| config.get("projects")?.get(cwd.to_str()?))
                    .cloned();
                if !cua_server_names(project.as_ref().and_then(|entry| entry.get("mcpServers")))
                    .is_empty()
                {
                    return Wiring::Configured { location: file };
                }
                project_entry = project;
            }
            Ok(None) => {}
            Err(error) => return Wiring::Unreadable { location: file, error },
        }
    }
    let Some(project) = environment.cwd.as_ref().map(|cwd| cwd.join(".mcp.json")) else {
        return Wiring::Absent;
    };
    let config = match read_json(&project) {
        Ok(Some(config)) => config,
        Ok(None) => return Wiring::Absent,
        Err(error) => return Wiring::Unreadable { location: project, error },
    };
    let names = cua_server_names(config.get("mcpServers"));
    if names.is_empty() {
        return Wiring::Absent;
    }
    let approved = project_entry
        .as_ref()
        .and_then(|entry| entry.get("enabledMcpjsonServers"))
        .and_then(Value::as_array)
        .is_some_and(|enabled| {
            enabled.iter().filter_map(Value::as_str).any(|name| names.contains(&name))
        });
    if approved {
        Wiring::Configured { location: project }
    } else {
        Wiring::PendingApproval { location: project }
    }
}

/// Codex: `[mcp_servers.*]` of `$CODEX_HOME/config.toml` (default
/// `~/.codex/config.toml`), then the project's `.codex/config.toml`.
fn codex_cua(environment: &Environment) -> Wiring {
    let user_file = environment
        .codex_home
        .clone()
        .or_else(|| environment.home.as_ref().map(|home| home.join(".codex")))
        .map(|dir| dir.join("config.toml"));
    let project_file = environment.cwd.as_ref().map(|cwd| cwd.join(".codex").join("config.toml"));
    for file in [user_file, project_file] {
        let Some(file) = file else { continue };
        let config = match read_text(&file).and_then(|text| {
            text.map(|text| text.parse::<toml::Table>().map_err(|error| toml_error(&text, &error)))
                .transpose()
        }) {
            Ok(Some(config)) => config,
            Ok(None) => continue,
            Err(error) => return Wiring::Unreadable { location: file, error },
        };
        let configured =
            config.get("mcp_servers").and_then(toml::Value::as_table).is_some_and(|servers| {
                servers.iter().any(|(name, server)| {
                    is_cua(name, server.get("command").and_then(toml::Value::as_str))
                })
            });
        if configured {
            return Wiring::Configured { location: file };
        }
    }
    Wiring::Absent
}

/// A TOML parse error without the excerpt of the file that `Display`
/// prints: that line may hold a key. Its message and line only.
pub(super) fn toml_error(text: &str, error: &toml::de::Error) -> String {
    let message = error.message().trim();
    match error.span() {
        Some(span) => {
            let line = text.get(..span.start).map_or(1, |head| head.matches('\n').count() + 1);
            format!("line {line}: {message}")
        }
        None => message.to_owned(),
    }
}

// MARK: macOS grants

const GRANT_ROWS: [&str; 3] =
    ["grant.accessibility", "grant.screen_recording", "grant.capture_consent"];

fn grant_label(id: &str, messages: &AgentsDoctorMessages) -> &'static str {
    match id {
        "grant.accessibility" => messages.check_accessibility,
        "grant.screen_recording" => messages.check_screen_recording,
        _ => messages.check_capture_consent,
    }
}

/// The same reason for all three grant rows (the app is not there, the
/// helper does not run, ...).
fn grants_unknown(
    status: Status,
    reason: &'static str,
    detail: &str,
    fix: Option<&str>,
    messages: &AgentsDoctorMessages,
) -> Vec<Check> {
    GRANT_ROWS
        .into_iter()
        .map(|id| {
            let check = Check::new(id, grant_label(id, messages), status, reason).detail(detail);
            match fix {
                Some(fix) => check.fix_action(fix, grant_fix_action(fix, messages)),
                None => check,
            }
        })
        .collect()
}

/// The runnable part of a grant row's fix: rerunning the doctor, or the
/// Computer Use Setup palette entry; opening cmux is text only.
fn grant_fix_action(fix: &str, messages: &AgentsDoctorMessages) -> Option<FixAction> {
    if fix == messages.run_again {
        Some(FixAction::RunAgain)
    } else if fix == messages.setup_command || fix == messages.open_setup {
        Some(FixAction::ComputerUseSetup)
    } else {
        None
    }
}

#[cfg(not(target_os = "macos"))]
fn grant_checks(
    _app_status: impl FnOnce() -> Result<Value, Value>,
    messages: &AgentsDoctorMessages,
) -> Vec<Check> {
    grants_unknown(Status::NotApplicable, "not_macos", messages.not_macos, None, messages)
}

#[cfg(target_os = "macos")]
fn grant_checks(
    app_status: impl FnOnce() -> Result<Value, Value>,
    messages: &AgentsDoctorMessages,
) -> Vec<Check> {
    grants_from_app(app_status(), messages)
}

/// The grant rows from the app's `computer_use.status` reply (or its failure).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn grants_from_app(reply: Result<Value, Value>, messages: &AgentsDoctorMessages) -> Vec<Check> {
    let status = match reply {
        Ok(status) => status,
        Err(error) => {
            return match error.get("code").and_then(Value::as_str) {
                Some("app.not_found" | "app.unreachable") => grants_unknown(
                    Status::Unknown,
                    "app_not_running",
                    messages.app_not_running,
                    Some(messages.open_cmux),
                    messages,
                ),
                Some("app.transport") => grants_unknown(
                    Status::Unknown,
                    "app_unresponsive",
                    messages.app_unresponsive,
                    Some(messages.run_again),
                    messages,
                ),
                _ => grants_unknown(
                    Status::Unknown,
                    "app_no_report",
                    messages.app_no_report,
                    Some(messages.setup_command),
                    messages,
                ),
            };
        }
    };
    let phase = status.get("phase").and_then(Value::as_str).unwrap_or_default();
    let (reason, detail, fix) = match phase {
        "ready" => return ready_grants(&status, messages),
        "off" => ("computer_use_off", messages.computer_use_off, Some(messages.open_setup)),
        "disabled_by_policy" => ("disabled_by_policy", messages.disabled_by_policy, None),
        "unavailable" => {
            ("helper_unavailable", messages.helper_unavailable, Some(messages.setup_command))
        }
        "starting" => ("helper_starting", messages.helper_starting, Some(messages.run_again)),
        "version_mismatch" => (
            "helper_version_mismatch",
            messages.helper_version_mismatch,
            Some(messages.setup_command),
        ),
        _ => ("app_no_report", messages.app_no_report, Some(messages.setup_command)),
    };
    grants_unknown(Status::Unknown, reason, detail, fix, messages)
}

/// The helper answered: each grant is held or missing (with its System
/// Settings pane); capture consent is not reported yet.
fn ready_grants(status: &Value, messages: &AgentsDoctorMessages) -> Vec<Check> {
    let grant = |id: &'static str, key: &str, url: &'static str| {
        let label = grant_label(id, messages);
        match status.get(key).and_then(Value::as_bool) {
            Some(true) => Check::new(id, label, Status::Ok, "granted").detail(messages.granted),
            Some(false) => {
                let mut check = Check::new(id, label, Status::Missing, "not_granted")
                    .detail(messages.not_granted)
                    .fix_action(
                        &messages.open_settings.replace("{url}", url),
                        Some(FixAction::OpenUrl),
                    );
                check.fix_url = Some(url);
                check
            }
            None => Check::new(id, label, Status::Unknown, "app_no_report")
                .detail(messages.app_no_report)
                .fix_action(messages.setup_command, Some(FixAction::ComputerUseSetup)),
        }
    };
    vec![
        grant("grant.accessibility", "accessibility", ACCESSIBILITY_URL),
        grant("grant.screen_recording", "screen_recording", SCREEN_RECORDING_URL),
        Check::new(
            "grant.capture_consent",
            messages.check_capture_consent,
            Status::Unknown,
            "not_reported",
        )
        .detail(messages.capture_consent_not_reported)
        .fix(messages.allow_capture_prompt),
    ]
}

// MARK: Human table

fn table(checks: &[Check], messages: &AgentsDoctorMessages) -> String {
    let width = |text: &str| text.chars().count();
    let check_width = checks
        .iter()
        .map(|check| width(check.label))
        .chain([width(messages.header_check)])
        .max()
        .unwrap_or_default();
    let status_width = checks
        .iter()
        .map(|check| width(check.status.label(messages)))
        .chain([width(messages.header_status)])
        .max()
        .unwrap_or_default();
    let pad = |text: &str, to: usize| {
        let mut padded = text.to_owned();
        padded.push_str(&" ".repeat(to.saturating_sub(width(text))));
        padded
    };
    let mut out = format!("{}\n\n", messages.title);
    out.push_str(&format!(
        "{}  {}  {}\n",
        pad(messages.header_check, check_width),
        pad(messages.header_status, status_width),
        messages.header_detail
    ));
    for check in checks {
        out.push_str(&format!(
            "{}  {}  {}\n",
            pad(check.label, check_width),
            pad(check.status.label(messages), status_width),
            check.detail
        ));
        if let Some(fix) = &check.fix {
            out.push_str(&format!("{}  {} {fix}\n", pad("", check_width), messages.fix_prefix));
        }
    }
    out
}
