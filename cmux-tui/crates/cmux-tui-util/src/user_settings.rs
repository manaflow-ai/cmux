//! The few settings-file keys the daemon reads itself. The app owns the
//! file (it writes it, `CmuxConfigFile`); the daemon and the CLI only read
//! it, so every client that talks to this daemon gets the same value
//! (plans/cmux-next/settings-react.md: preferences belong to the config
//! layer of the machine). The managed (MDM) layer is not read here.

use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

use serde_json::Value;

/// Environment variable that names another settings file, as in the app
/// (`CmuxConfigFile.overrideKey`), so test launches never read the user's.
pub const CONFIG_OVERRIDE: &str = "CMUX_NEXT_CONFIG_FILE";

/// The app's settings file (`CmuxConfigFile.defaultURL`), under the home:
/// `.config/cmux/cmux-next.json`, in `.config/cmux-next/` on macOS
/// (`cmux_config::location`).
fn next_file(home: &Path) -> PathBuf {
    home.join(".config").join(cmux_config::NEXT_DIR).join(cmux_config::location::NEXT_FILE_NAME)
}

/// The settings file the app reads and writes: `CMUX_NEXT_CONFIG_FILE`,
/// else `<home>/.config/cmux/cmux-next.json` (`cmux-next/` on macOS). Classic
/// is imported by the app only after the person consents.
pub fn config_path() -> PathBuf {
    let env = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
    if env(CONFIG_OVERRIDE).is_some() {
        return path_from(env);
    }
    cmux_config::location::migrate_legacy_once();
    let home = crate::platform::home_dir().unwrap_or_default();
    next_file(&home)
}

/// `CMUX_NEXT_CONFIG_FILE` (a leading `~` is the home), else the app's file
/// under `HOME`, from the environment `env`.
pub fn path_from(env: impl Fn(&str) -> Option<std::ffi::OsString>) -> PathBuf {
    if let Some(path) = env(CONFIG_OVERRIDE) {
        let path = PathBuf::from(path);
        if let Ok(rest) = path.strip_prefix("~")
            && let Some(home) = env("HOME")
        {
            return PathBuf::from(home).join(rest);
        }
        return path;
    }
    let home = env("HOME").map(PathBuf::from).unwrap_or_default();
    next_file(&home)
}

/// Settings-file `workspaces.newPlacement`: where a new workspace goes in
/// the personal sidebar order when its creator names no place. Same values
/// and default as the app's `NewWorkspacePlacement`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NewWorkspacePlacement {
    /// First, below the home workspace's row, above every group. The default
    /// (Lawrence 2026-11-12: "by default all new workspaces should go to the
    /// top"), for every client and creator.
    #[default]
    Top,
    /// Right after the session's active workspace, in its group (`Top`
    /// when there is none, or it is the home workspace).
    AfterCurrent,
    /// After every row.
    Bottom,
}

thread_local! {
    /// A creation path that names its own place (reopen, Home): every
    /// workspace this thread creates meanwhile goes there. Unit tests set it
    /// too ([`NewWorkspacePlacement::set_for_test`]).
    static SCOPED: Cell<Option<NewWorkspacePlacement>> = const { Cell::new(None) };
}

/// The last value read, with the identity of the file it came from.
struct CachedPlacement {
    path: PathBuf,
    modified: Option<SystemTime>,
    len: u64,
    value: NewWorkspacePlacement,
}

/// So a creation only stats the file while it does not change.
static CACHE: Mutex<Option<CachedPlacement>> = Mutex::new(None);

impl NewWorkspacePlacement {
    /// The value in settings text `text`. A missing key, a value the app does
    /// not know and a file that does not parse give the default, as in the
    /// app (which reports the bad value as a diagnostic).
    pub fn from_config_text(text: &str) -> Self {
        let text = text.trim_start_matches('\u{feff}');
        let Ok(document) = serde_json::from_str::<Value>(&strip_jsonc(text)) else {
            return Self::default();
        };
        match document.pointer("/workspaces/newPlacement").and_then(Value::as_str) {
            Some("top") => Self::Top,
            Some("afterCurrent") => Self::AfterCurrent,
            Some("bottom") => Self::Bottom,
            _ => Self::default(),
        }
    }

    /// The value a `workspace.create {placement}` names (`top`,
    /// `after_current`, `bottom`); `None` for any other text.
    pub fn from_wire(value: &str) -> Option<Self> {
        match value {
            "top" => Some(Self::Top),
            "after_current" => Some(Self::AfterCurrent),
            "bottom" => Some(Self::Bottom),
            _ => None,
        }
    }

    /// The value in the settings file at `path`; the default without one.
    /// Only a regular file is read (never a FIFO or a device).
    pub fn from_config_file(path: &Path) -> Self {
        let Ok(metadata) = std::fs::metadata(path) else { return Self::default() };
        if !metadata.is_file() {
            return Self::default();
        }
        let (modified, len) = (metadata.modified().ok(), metadata.len());
        let mut cache = CACHE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(cached) = cache.as_ref()
            && cached.path == path
            && (cached.modified, cached.len) == (modified, len)
        {
            return cached.value;
        }
        let value = std::fs::read_to_string(path)
            .map(|text| Self::from_config_text(&text))
            .unwrap_or_default();
        *cache = Some(CachedPlacement { path: path.to_path_buf(), modified, len, value });
        value
    }

    /// The value a workspace this daemon creates now uses: a scoped place
    /// ([`Self::scoped`]), else the settings file, read at each creation (a
    /// change applies to the next workspace with no reload). Unit tests
    /// never read the developer's file: they get the default.
    pub fn current() -> Self {
        if let Some(scoped) = SCOPED.with(Cell::get) {
            return scoped;
        }
        if cfg!(test) { Self::default() } else { Self::from_config_file(&config_path()) }
    }

    /// Runs `body` with every workspace this thread creates placed at
    /// `self`: a creation path that names its own place.
    pub fn scoped<T>(self, body: impl FnOnce() -> T) -> T {
        let _guard = ScopedPlacement(SCOPED.with(|cell| cell.replace(Some(self))));
        body()
    }

    /// The value [`Self::current`] gives on this thread until the guard drops.
    #[cfg(any(test, feature = "test-support"))]
    pub fn set_for_test(self) -> ScopedPlacement {
        ScopedPlacement(SCOPED.with(|cell| cell.replace(Some(self))))
    }
}

/// Restores the scoped placement that was set before.
pub struct ScopedPlacement(Option<NewWorkspacePlacement>);

impl Drop for ScopedPlacement {
    fn drop(&mut self) {
        SCOPED.with(|cell| cell.set(self.0));
    }
}

/// Settings-file `sessions.resumeAgents` ("Resume Agents After Restart"):
/// whether a terminal respawned after its host died (a crash or reboot)
/// runs its agent's resume (`claude --resume <id>`, `codex resume <id>`).
/// On by default. A file that does not parse, or a value that is not a
/// boolean, gives `false`: the person's choice is unknown, so the resume is
/// only shown, never run.
pub fn resume_agents_from_config_text(text: &str) -> bool {
    if text.trim().is_empty() {
        return true;
    }
    let Ok(document) = serde_json::from_str::<Value>(&strip_jsonc(text)) else { return false };
    match document.pointer("/sessions/resumeAgents") {
        None | Some(Value::Null) => true,
        Some(Value::Bool(on)) => *on,
        Some(_) => false,
    }
}

/// [`resume_agents_from_config_text`] of the settings file, read at each
/// respawn (a change applies with no reload); on without a file.
pub fn resume_agents() -> bool {
    let path = config_path();
    match std::fs::metadata(&path) {
        Ok(metadata) if metadata.is_file() => std::fs::read_to_string(&path)
            .map(|text| resume_agents_from_config_text(&text))
            .unwrap_or(false),
        Ok(_) => false,
        Err(error) => error.kind() == std::io::ErrorKind::NotFound,
    }
}

/// Settings' Ultra Connection Mode (`remote.ultra`) for the WireGuard
/// tunnels this Mac starts (Cloud, `wg hub`, the terminal client).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum UltraConnection {
    /// No repair data.
    Off,
    /// The default: no extra data on a clean link; repair data within
    /// about one round trip once packets are lost (cmux-wg `UltraChoice::Auto`).
    #[default]
    Auto,
    /// Repair data on every connection, about 2-3x the bytes
    /// (cmux-wg `UltraMode::SETTING`).
    Always,
}

/// Settings' Tailscale carrier policy (`transport.tailnetCarrier`). The
/// default is direct-only (ask-3c089caeef): the tailnet address joins the race
/// only when tailscaled's LocalAPI reports a direct path, and must win it on
/// round trip; without Tailscale it adds nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TailnetCarrier {
    /// Do not add Tailscale addresses to races.
    Off,
    /// Add only paths tailscaled currently reports as direct.
    #[default]
    DirectOnly,
    /// Accepted for forward compatibility. Relayed paths remain excluded by
    /// the race helper until their cost is measured.
    On,
}

/// Parse `transport.tailnetCarrier`, with an environment override for tests.
pub fn tailnet_carrier_from_config_text(text: &str) -> TailnetCarrier {
    let Ok(document) = serde_json::from_str::<Value>(&strip_jsonc(text)) else {
        return TailnetCarrier::default();
    };
    let value = document
        .pointer("/transport/tailnetCarrier")
        .or_else(|| document.get("transport.tailnetCarrier"));
    match value {
        None | Some(Value::Null) => TailnetCarrier::default(),
        Some(Value::String(text)) if text == "direct-only" || text == "direct_only" => {
            TailnetCarrier::DirectOnly
        }
        Some(Value::String(text)) if text == "on" => TailnetCarrier::On,
        // "off", and anything not understood.
        Some(_) => TailnetCarrier::Off,
    }
}

/// Current Tailscale carrier policy. `CMUX_TAILNET_CARRIER` wins for hermetic
/// tests and development runs.
pub fn tailnet_carrier() -> TailnetCarrier {
    if let Ok(value) = std::env::var("CMUX_TAILNET_CARRIER") {
        return match value.trim() {
            "direct-only" | "direct_only" => TailnetCarrier::DirectOnly,
            "on" => TailnetCarrier::On,
            _ => TailnetCarrier::Off,
        };
    }
    if cfg!(test) {
        return TailnetCarrier::Off;
    }
    let path = config_path();
    match std::fs::metadata(&path) {
        Ok(metadata) if metadata.is_file() => std::fs::read_to_string(&path)
            .map(|text| tailnet_carrier_from_config_text(&text))
            .unwrap_or_default(),
        _ => TailnetCarrier::default(),
    }
}

/// [`UltraConnection`] of a settings file: `remote.ultra` (`"off"`,
/// `"auto"`, `"always"`); without it, the retired toggle `remote.ultraMode`
/// set to `true` is Always. Anything else, and a file that does not parse,
/// is the default, Auto.
pub fn ultra_from_config_text(text: &str) -> UltraConnection {
    let Ok(document) = serde_json::from_str::<Value>(&strip_jsonc(text)) else {
        return UltraConnection::default();
    };
    match document.pointer("/remote/ultra").and_then(Value::as_str) {
        Some("off") => UltraConnection::Off,
        Some("always") => UltraConnection::Always,
        Some("auto") => UltraConnection::Auto,
        _ if document.pointer("/remote/ultraMode").and_then(Value::as_bool) == Some(true) => {
            UltraConnection::Always
        }
        _ => UltraConnection::default(),
    }
}

/// [`ultra_from_config_text`] of the settings file, read when a tunnel
/// starts (a change applies to the next connection with no reload); Auto
/// without a file, and always Auto in unit tests.
pub fn ultra() -> UltraConnection {
    if cfg!(test) {
        return UltraConnection::default();
    }
    let path = config_path();
    match std::fs::metadata(&path) {
        Ok(metadata) if metadata.is_file() => std::fs::read_to_string(&path)
            .map(|text| ultra_from_config_text(&text))
            .unwrap_or_default(),
        _ => UltraConnection::default(),
    }
}

/// The default of `remote.agentShareIdleMinutes`: sharing an owner's agent turned on turns
/// itself off after this many minutes with no viewer.
pub const AGENT_SHARE_IDLE_MINUTES_DEFAULT: u64 = 15;
/// The schema's range of `remote.agentShareIdleMinutes` (schemas/settings/source/machines.json).
pub const AGENT_SHARE_IDLE_MINUTES_RANGE: std::ops::RangeInclusive<u64> = 1..=240;

/// `remote.agentShareIdleMinutes` of a settings file: a whole number in the schema's range;
/// anything else, and a file that does not parse, is the default (15).
pub fn agent_share_idle_minutes_from_config_text(text: &str) -> u64 {
    serde_json::from_str::<Value>(&strip_jsonc(text))
        .ok()
        .and_then(|document| {
            document.pointer("/remote/agentShareIdleMinutes").and_then(Value::as_u64)
        })
        .filter(|minutes| AGENT_SHARE_IDLE_MINUTES_RANGE.contains(minutes))
        .unwrap_or(AGENT_SHARE_IDLE_MINUTES_DEFAULT)
}

/// [`agent_share_idle_minutes_from_config_text`] of the settings file, read each time an agent's
/// share arms its timer; the default without a file, and always the default in unit tests.
pub fn agent_share_idle_minutes() -> u64 {
    if cfg!(test) {
        return AGENT_SHARE_IDLE_MINUTES_DEFAULT;
    }
    let path = config_path();
    match std::fs::metadata(&path) {
        Ok(metadata) if metadata.is_file() => std::fs::read_to_string(&path)
            .map(|text| agent_share_idle_minutes_from_config_text(&text))
            .unwrap_or(AGENT_SHARE_IDLE_MINUTES_DEFAULT),
        _ => AGENT_SHARE_IDLE_MINUTES_DEFAULT,
    }
}

/// The dotted settings key of AutoCloud (schemas/settings/source/machines.json, a hidden toggle,
/// default off): Auto may start a chat on a Cloud machine, and the hybrid chat start is on
/// (`cmux-tui` `feature_flags::hybrid_chat_start_flag`).
pub const AUTO_CLOUD_KEY: &str = "cloud.autoCloud";

/// `cloud.autoCloud` of a settings file, flat (`"cloud.autoCloud"`) or nested
/// (`{"cloud": {"autoCloud": …}}`), under what an administrator set
/// ([`cmux_config::managed::applied_to`]): `Some` of a boolean, a `false` in either form winning
/// over a `true` in the other; None when no form holds a boolean or the file does not parse.
pub fn auto_cloud_from_config_text(text: &str) -> Option<bool> {
    auto_cloud_applied(auto_cloud_file_value(text))
}

fn auto_cloud_file_value(text: &str) -> Option<Value> {
    let text = text.trim_start_matches('\u{feff}');
    let document = serde_json::from_str::<Value>(&strip_jsonc(text)).ok()?;
    let flat = document.get(AUTO_CLOUD_KEY).and_then(Value::as_bool);
    let nested = document.pointer("/cloud/autoCloud").and_then(Value::as_bool);
    match (flat, nested) {
        (Some(false), _) | (_, Some(false)) => Some(Value::Bool(false)),
        (flat, nested) => flat.or(nested).map(Value::Bool),
    }
}

fn auto_cloud_applied(file: Option<Value>) -> Option<bool> {
    cmux_config::managed::applied_to(AUTO_CLOUD_KEY, file).as_ref().and_then(Value::as_bool)
}

/// [`auto_cloud_from_config_text`] of the settings file at `path`; without a readable file, only
/// what an administrator set.
pub fn auto_cloud_from_config_file(path: &Path) -> Option<bool> {
    match std::fs::read_to_string(path) {
        Ok(text) => auto_cloud_from_config_text(&text),
        Err(_) => auto_cloud_applied(None),
    }
}

/// [`auto_cloud_from_config_file`] of the app's settings file ([`config_path`]), read at each call
/// so a change applies to the next chat start with no reload; always None in unit tests.
pub fn auto_cloud() -> Option<bool> {
    if cfg!(test) {
        return None;
    }
    auto_cloud_from_config_file(&config_path())
}

/// Settings-file `agents.cmuxMcp` ("Give Agents cmux’s Tools"): whether
/// agents cmux starts get its `cmux` MCP server (which carries cmux Computer
/// Use): a Claude Code or Codex typed into a cmux terminal (the `claude` and
/// `codex` shims, each launch) and the app's agent chats (acpmux, which reads
/// the same key: `acpmux::agent_tools::agents_get_cmux`). Only through the
/// launch: cmux never writes an agent's own config. On by default (cmux's
/// tools come with the app); Settings > Agents turns it off.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AgentsCmuxMcp {
    /// The default (no value, `"on"`, or anything but `"off"`): agents cmux
    /// starts get the server, and it serves them (as `"mcp": {"enabled":
    /// true}` does, unless that key says otherwise).
    #[default]
    On,
    /// The person turned it off: agents cmux starts get no `cmux` server.
    Off,
}

impl AgentsCmuxMcp {
    /// The dotted settings key.
    pub const KEY: &'static str = "agents.cmuxMcp";

    /// The value in the settings text, flat (`"agents.cmuxMcp"`) or nested
    /// (`{"agents": {"cmuxMcp": …}}`), as the app's settings owner writes
    /// either, under what an administrator set ([`cmux_config::managed::applied_to`]).
    /// Only `"off"` is `Off`, and an `"off"` in either form wins over the
    /// other; a file that does not parse is `On`.
    pub fn from_config_text(text: &str) -> Self {
        Self::applied(Self::file_value(text))
    }

    fn file_value(text: &str) -> Option<Value> {
        let text = text.trim_start_matches('\u{feff}');
        let document = serde_json::from_str::<Value>(&strip_jsonc(text)).ok()?;
        let flat = document.get(Self::KEY).cloned();
        let nested = document.pointer("/agents/cmuxMcp").cloned();
        let off = Value::String("off".into());
        if flat.as_ref() == Some(&off) || nested.as_ref() == Some(&off) {
            return Some(off);
        }
        flat.or(nested)
    }

    fn applied(file: Option<Value>) -> Self {
        match cmux_config::managed::applied_to(Self::KEY, file).as_ref().and_then(Value::as_str) {
            Some("off") => Self::Off,
            _ => Self::On,
        }
    }

    /// The value in the settings file at `path`; `On` without one.
    pub fn from_config_file(path: &Path) -> Self {
        match std::fs::read_to_string(path) {
            Ok(text) => Self::from_config_text(&text),
            Err(_) => Self::applied(None),
        }
    }

    /// The value in the app's settings file ([`config_path`]), read at each
    /// call so a change applies to the next agent launch with no reload.
    pub fn current() -> Self {
        Self::from_config_file(&config_path())
    }

    /// The per-agent switch under the answer (cmux#49395): `agents.cmuxMcpClaude`
    /// for `claude`, `agents.cmuxMcpCodex` for `codex` (a `cmux setup mcp`
    /// client id); `None` for any other agent, which follows the answer alone.
    /// acpmux reads the same keys (`acpmux::agent_tools::agent_switch_key`).
    pub fn agent_key(agent: &str) -> Option<&'static str> {
        match agent {
            "claude" => Some("agents.cmuxMcpClaude"),
            "codex" => Some("agents.cmuxMcpCodex"),
            _ => None,
        }
    }

    /// The answer for one agent: `Off` when the answer is off or the person
    /// switched that agent off (`false` at [`Self::agent_key`]); no value,
    /// `true` or anything else keeps the answer.
    pub fn from_config_text_for(text: &str, agent: &str) -> Self {
        let choice = Self::from_config_text(text);
        if choice != Self::On {
            return choice;
        }
        let Some(key) = Self::agent_key(agent) else { return choice };
        let text = text.trim_start_matches('\u{feff}');
        let Ok(document) = serde_json::from_str::<Value>(&strip_jsonc(text)) else {
            return choice;
        };
        let pointer = format!("/{}", key.replace('.', "/"));
        let value = document.get(key).or_else(|| document.pointer(&pointer));
        if value.and_then(Value::as_bool) == Some(false) { Self::Off } else { choice }
    }

    /// [`Self::from_config_text_for`] over the settings file at `path`.
    pub fn from_config_file_for(path: &Path, agent: &str) -> Self {
        std::fs::read_to_string(path)
            .map(|text| Self::from_config_text_for(&text, agent))
            .unwrap_or_default()
    }

    /// [`Self::current`] for one agent (the `claude` and `codex` shims).
    pub fn current_for(agent: &str) -> Self {
        Self::from_config_file_for(&config_path(), agent)
    }

    /// Whether the shims pass the cmux server to an agent launched in a cmux
    /// terminal: unless the person turned it off.
    pub fn injects(self) -> bool {
        self == Self::On
    }

    /// The settings value (`on`, `off`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::On => "on",
            Self::Off => "off",
        }
    }
}

/// JSONC to JSON: drops `//` and `/* */` comments, then trailing commas,
/// outside strings (the dialect the app's `JSONC` parser reads).
pub fn strip_jsonc(text: &str) -> String {
    drop_trailing_commas(&drop_comments(text))
}

/// The text without comments; strings are copied unchanged.
fn drop_comments(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let (mut index, mut start, mut in_string) = (0, 0, false);
    while index < bytes.len() {
        let byte = bytes[index];
        if in_string {
            match byte {
                b'\\' => index += 2,
                b'"' => {
                    in_string = false;
                    index += 1;
                }
                _ => index += 1,
            }
            continue;
        }
        match (byte, bytes.get(index + 1)) {
            (b'"', _) => {
                in_string = true;
                index += 1;
            }
            (b'/', Some(b'/')) => {
                output.push_str(&text[start..index]);
                while index < bytes.len() && bytes[index] != b'\n' {
                    index += 1;
                }
                start = index;
            }
            (b'/', Some(b'*')) => {
                output.push_str(&text[start..index]);
                index += 2;
                while index < bytes.len()
                    && !(bytes[index] == b'*' && bytes.get(index + 1) == Some(&b'/'))
                {
                    index += 1;
                }
                index = (index + 2).min(bytes.len());
                start = index;
            }
            _ => index += 1,
        }
    }
    output.push_str(&text[start.min(bytes.len())..]);
    output
}

/// Removes a comma whose next non-space byte closes an object or array.
fn drop_trailing_commas(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let (mut index, mut start, mut in_string) = (0, 0, false);
    while index < bytes.len() {
        let byte = bytes[index];
        if in_string {
            match byte {
                b'\\' => index += 2,
                b'"' => {
                    in_string = false;
                    index += 1;
                }
                _ => index += 1,
            }
            continue;
        }
        if byte == b'"' {
            in_string = true;
        } else if byte == b','
            && matches!(
                bytes[index + 1..].iter().find(|byte| !byte.is_ascii_whitespace()),
                Some(b'}' | b']')
            )
        {
            output.push_str(&text[start..index]);
            start = index + 1;
        }
        index += 1;
    }
    output.push_str(&text[start.min(bytes.len())..]);
    output
}

#[cfg(test)]
mod tests {
    use super::NewWorkspacePlacement as Placement;
    use super::resume_agents_from_config_text as resume_agents;

    #[test]
    fn agents_resume_after_restart_unless_the_file_says_no() {
        assert!(resume_agents(""));
        assert!(resume_agents("{}"));
        assert!(resume_agents(r#"{"sessions": {"resumeAgents": true}}"#));
        assert!(!resume_agents("{\n  // off\n  \"sessions\": {\"resumeAgents\": false,},\n}"));
        assert!(!resume_agents(r#"{"sessions": {"resumeAgents": "yes"}}"#), "not a boolean");
        assert!(!resume_agents("{not json"), "an unreadable file never runs a resume");
    }

    #[test]
    fn agents_cmux_mcp_is_on_unless_the_file_says_off() {
        use super::AgentsCmuxMcp as Choice;
        assert_eq!(Choice::from_config_text(""), Choice::On);
        assert_eq!(Choice::from_config_text("{}"), Choice::On);
        assert_eq!(Choice::from_config_text(r#"{"agents": {"cmuxMcp": "ask"}}"#), Choice::On);
        assert_eq!(Choice::from_config_text(r#"{"agents": {"cmuxMcp": "on"}}"#), Choice::On);
        assert_eq!(Choice::from_config_text(r#"{"agents.cmuxMcp": "off"}"#), Choice::Off);
        assert_eq!(
            Choice::from_config_text("{\n  // no\n  \"agents\": {\"cmuxMcp\": \"off\",},\n}"),
            Choice::Off
        );
        assert_eq!(Choice::from_config_text(r#"{"agents": {"cmuxMcp": true}}"#), Choice::On);
        // Settings writes the nested key; an older flat value never outvotes its `off`.
        assert_eq!(
            Choice::from_config_text(r#"{"agents.cmuxMcp": "ask", "agents": {"cmuxMcp": "off"}}"#),
            Choice::Off
        );
        assert_eq!(
            Choice::from_config_text("\u{feff}{\"agents\": {\"cmuxMcp\": \"off\"}}"),
            Choice::Off,
            "a BOM reads as the settings owner reads it"
        );
        assert_eq!(
            Choice::from_config_text("{not json"),
            Choice::On,
            "only an explicit off turns it off"
        );
        assert!(Choice::On.injects() && !Choice::Off.injects());
        assert_eq!(
            Choice::from_config_file(std::path::Path::new("/nonexistent/cmux-next.json")),
            Choice::On
        );
    }

    #[test]
    fn an_agent_switched_off_gets_no_cmux_tools_under_a_yes() {
        use super::AgentsCmuxMcp as Choice;
        let on = r#"{"agents": {"cmuxMcp": "on"}}"#;
        assert_eq!(Choice::from_config_text_for(on, "claude"), Choice::On, "no switch: on");
        let codex_off = r#"{"agents": {"cmuxMcp": "on", "cmuxMcpCodex": false}}"#;
        assert_eq!(Choice::from_config_text_for(codex_off, "codex"), Choice::Off);
        assert_eq!(Choice::from_config_text_for(codex_off, "claude"), Choice::On);
        let flat = r#"{"agents.cmuxMcp": "on", "agents.cmuxMcpClaude": false}"#;
        assert_eq!(Choice::from_config_text_for(flat, "claude"), Choice::Off, "flat key");
        let kept = r#"{"agents": {"cmuxMcp": "on", "cmuxMcpClaude": true}}"#;
        assert_eq!(Choice::from_config_text_for(kept, "claude"), Choice::On);
        let not_bool = r#"{"agents": {"cmuxMcp": "on", "cmuxMcpClaude": "no"}}"#;
        assert_eq!(Choice::from_config_text_for(not_bool, "claude"), Choice::On, "only false");
        let unset = r#"{"agents": {"cmuxMcpClaude": false}}"#;
        assert_eq!(Choice::from_config_text_for(unset, "claude"), Choice::Off, "on by default");
        assert_eq!(Choice::from_config_text_for(unset, "codex"), Choice::On, "on by default");
        let no = r#"{"agents": {"cmuxMcp": "off", "cmuxMcpClaude": true}}"#;
        assert_eq!(Choice::from_config_text_for(no, "claude"), Choice::Off);
        assert_eq!(Choice::from_config_text_for(codex_off, "gemini"), Choice::On, "no switch");
    }

    #[test]
    fn ultra_is_auto_unless_the_file_says_otherwise() {
        use super::UltraConnection::{Always, Auto, Off};
        use super::ultra_from_config_text as ultra;
        assert_eq!(ultra(""), Auto);
        assert_eq!(ultra("{}"), Auto);
        assert_eq!(ultra(r#"{"remote": {"endSharingOnQuit": true}}"#), Auto);
        assert_eq!(ultra(r#"{"remote": {"ultra": "off"}}"#), Off);
        assert_eq!(ultra(r#"{"remote": {"ultra": "always"}}"#), Always);
        assert_eq!(
            ultra("{\n  // lossy hotel Wi-Fi\n  \"remote\": {\"ultra\": \"always\",},\n}"),
            Always
        );
        assert_eq!(ultra(r#"{"remote": {"ultra": "auto", "ultraMode": true}}"#), Auto);
        assert_eq!(ultra(r#"{"remote": {"ultraMode": true}}"#), Always, "the retired toggle on");
        assert_eq!(ultra(r#"{"remote": {"ultraMode": false}}"#), Auto, "and off: Auto");
        assert_eq!(ultra(r#"{"remote": {"ultra": true}}"#), Auto, "not a choice");
        assert_eq!(ultra("{not json"), Auto);
        assert_eq!(super::ultra(), Auto, "unit tests never read the developer's file");
    }

    #[test]
    fn tailnet_carrier_is_direct_only_unless_the_file_names_off_or_on() {
        use super::TailnetCarrier::{DirectOnly, Off, On};
        use super::tailnet_carrier_from_config_text as carrier;
        assert_eq!(carrier(""), DirectOnly, "no file: the default");
        assert_eq!(carrier("{}"), DirectOnly, "no key: the default");
        assert_eq!(carrier(r#"{"transport":{"tailnetCarrier":"direct-only"}}"#), DirectOnly);
        assert_eq!(carrier(r#"{"transport.tailnetCarrier":"on"}"#), On, "the flat key");
        assert_eq!(carrier(r#"{"transport":{"tailnetCarrier":"on"}}"#), On);
        assert_eq!(carrier(r#"{"transport":{"tailnetCarrier":"off"}}"#), Off);
        assert_eq!(carrier(r#"{"transport":{"tailnetCarrier":"bogus"}}"#), Off, "not understood");
        assert_eq!(carrier("{not json"), DirectOnly);
        assert_eq!(super::tailnet_carrier(), Off, "unit tests never read the developer's file");
    }

    #[test]
    fn invalid_tailnet_setting_types_do_not_enable_the_default() {
        use serde_json::json;
        for value in [json!(false), json!(true), json!(0), json!(1), json!([]), json!({})] {
            for doc in [
                json!({"transport.tailnetCarrier": value}),
                json!({"transport": {"tailnetCarrier": value}}),
            ] {
                assert_eq!(
                    super::tailnet_carrier_from_config_text(&doc.to_string()),
                    super::TailnetCarrier::Off,
                    "{doc}",
                );
            }
        }
    }

    #[test]
    fn agent_share_idle_minutes_is_fifteen_unless_the_file_names_a_value_in_range() {
        use super::agent_share_idle_minutes_from_config_text as minutes;
        assert_eq!(minutes(""), 15);
        assert_eq!(minutes("{}"), 15);
        assert_eq!(minutes(r#"{"remote": {"agentShareIdleMinutes": 5}}"#), 5);
        assert_eq!(
            minutes("{\n  // short\n  \"remote\": {\"agentShareIdleMinutes\": 240,},\n}"),
            240
        );
        assert_eq!(minutes(r#"{"remote": {"agentShareIdleMinutes": 0}}"#), 15, "below the range");
        assert_eq!(minutes(r#"{"remote": {"agentShareIdleMinutes": 241}}"#), 15, "above it");
        assert_eq!(minutes(r#"{"remote": {"agentShareIdleMinutes": "5"}}"#), 15, "not a number");
        assert_eq!(minutes("{not json"), 15);
        assert_eq!(
            super::agent_share_idle_minutes(),
            15,
            "unit tests never read the developer's file"
        );
    }

    #[test]
    fn auto_cloud_is_the_files_boolean_flat_or_nested_and_false_wins() {
        use super::auto_cloud_from_config_text as auto_cloud;
        assert_eq!(auto_cloud(""), None);
        assert_eq!(auto_cloud("{}"), None);
        assert_eq!(auto_cloud(r#"{"cloud": {"autoCloud": true}}"#), Some(true));
        assert_eq!(auto_cloud(r#"{"cloud": {"autoCloud": false}}"#), Some(false));
        assert_eq!(auto_cloud(r#"{"cloud.autoCloud": true}"#), Some(true), "flat key");
        assert_eq!(
            auto_cloud("{\n  // AutoCloud\n  \"cloud\": {\"autoCloud\": true,},\n}"),
            Some(true)
        );
        assert_eq!(auto_cloud("\u{feff}{\"cloud\": {\"autoCloud\": true}}"), Some(true), "a BOM");
        assert_eq!(
            auto_cloud(r#"{"cloud.autoCloud": true, "cloud": {"autoCloud": false}}"#),
            Some(false),
            "a false in either form wins"
        );
        assert_eq!(auto_cloud(r#"{"cloud": {"autoCloud": "yes"}}"#), None, "not a boolean");
        assert_eq!(auto_cloud(r#"{"cloud": {"plan": "pro"}}"#), None);
        assert_eq!(auto_cloud("{not json"), None);
        assert_eq!(super::auto_cloud(), None, "unit tests never read the developer's file");
    }

    #[test]
    fn auto_cloud_reads_the_file_again_at_each_call() {
        use super::auto_cloud_from_config_file as read;
        let path =
            std::env::temp_dir().join(format!("cmux-auto-cloud-{}.json", std::process::id()));
        std::fs::write(&path, r#"{"cloud": {"autoCloud": true}}"#).unwrap();
        assert_eq!(read(&path), Some(true));
        std::fs::write(&path, r#"{"cloud": {"autoCloud": false}}"#).unwrap();
        assert_eq!(read(&path), Some(false));
        std::fs::remove_file(&path).unwrap();
        assert_eq!(read(&path), None, "no file: no value");
    }

    #[test]
    fn new_placement_reads_cmux_json_with_the_app_default() {
        assert_eq!(Placement::from_config_text(""), Placement::Top);
        assert_eq!(Placement::from_config_text("{}"), Placement::Top);
        assert_eq!(
            Placement::from_config_text(r#"{"workspaces": {"newPlacement": "top"}}"#),
            Placement::Top
        );
        assert_eq!(
            Placement::from_config_text(
                "{\n  // order\n  \"workspaces\": {\"newPlacement\": \"bottom\",},\n}"
            ),
            Placement::Bottom
        );
        assert_eq!(
            Placement::from_config_text(r#"{"workspaces": {"newPlacement": "afterCurrent"}}"#),
            Placement::AfterCurrent
        );
        assert_eq!(
            Placement::from_config_text(r#"{"workspaces": {"newPlacement": "sideways"}}"#),
            Placement::Top
        );
        assert_eq!(Placement::from_config_text("{not json"), Placement::Top);
    }

    #[test]
    fn a_scoped_placement_wins_and_nests() {
        assert_eq!(Placement::current(), Placement::Top);
        let outer = Placement::Bottom.set_for_test();
        Placement::AfterCurrent
            .scoped(|| assert_eq!(Placement::current(), Placement::AfterCurrent));
        assert_eq!(Placement::current(), Placement::Bottom);
        drop(outer);
        assert_eq!(Placement::current(), Placement::Top);
    }

    #[test]
    fn a_changed_settings_file_is_read_again() {
        let path =
            std::env::temp_dir().join(format!("cmux-new-placement-{}.json", std::process::id()));
        std::fs::write(&path, r#"{"workspaces": {"newPlacement": "bottom"}}"#).unwrap();
        assert_eq!(Placement::from_config_file(&path), Placement::Bottom);
        std::fs::write(&path, r#"{"workspaces": {"newPlacement": "afterCurrent", "x": 1}}"#)
            .unwrap();
        assert_eq!(Placement::from_config_file(&path), Placement::AfterCurrent);
        std::fs::remove_file(&path).unwrap();
        assert_eq!(Placement::from_config_file(&path), Placement::Top);
        assert_eq!(
            Placement::from_config_file(&std::env::temp_dir()),
            Placement::Top,
            "a directory is not read"
        );
    }
}
