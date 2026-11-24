//! The Cloud actions' argument checks. The app sends the invocation's
//! arguments as JSON (`string`, `int`, `bool`; a CLI flag given with no value
//! arrives as `true`) and gets the checked value or the refusal.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::Said;

/// An invocation's arguments.
pub type Args = Map<String, Value>;

/// A checked value, or why the run is refused.
pub type Checked<T> = Result<T, Said>;

fn text<'a>(args: &'a Args, name: &str) -> Option<&'a str> {
    args.get(name).and_then(Value::as_str)
}

fn int(args: &Args, name: &str) -> Option<i64> {
    args.get(name).and_then(|value| if value.is_f64() { None } else { value.as_i64() })
}

fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Trimmed of spaces and tabs only (newlines kept), as `.whitespaces` trims.
fn trim_spaces(value: &str) -> &str {
    value.trim_matches(|c: char| c.is_whitespace() && !is_newline(c))
}

/// Trimmed of all white space and newlines.
fn trimmed<'a>(args: &'a Args, name: &str) -> Option<&'a str> {
    text(args, name).map(str::trim)
}

/// A trimmed, non-empty text argument, else `missing`.
fn required(args: &Args, name: &str, missing: Said) -> Checked<String> {
    match trimmed(args, name) {
        Some(value) if !value.is_empty() => Ok(value.to_owned()),
        _ => Err(missing),
    }
}

/// `~` and `~/…` under `home`: a quoted `~/boot.sh` reaches the app unexpanded.
pub fn expanding_home(path: &str, home: &str) -> String {
    match path.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => format!("{home}{rest}"),
        _ => path.to_owned(),
    }
}

/// `cloud exec`'s `--command`.
pub fn command(args: &Args) -> Checked<String> {
    required(args, "command", Said::key("commandRequired"))
}

/// `--path` of the file verbs: absolute, no NUL, no `..` part, at most 4096 bytes.
pub fn file_path(args: &Args) -> Checked<String> {
    let path = trimmed(args, "path").unwrap_or("");
    let ok = path.starts_with('/')
        && !path.contains('\0')
        && !path.split('/').any(|part| part == "..")
        && path.len() <= 4096;
    if ok { Ok(path.to_owned()) } else { Err(Said::key("filePathRequired")) }
}

/// `--port`: 1 through 65535.
pub fn port(args: &Args) -> Checked<u16> {
    int(args, "port")
        .and_then(|port| u16::try_from(port).ok())
        .filter(|&port| port >= 1)
        .ok_or_else(|| Said::key("invalidPort"))
}

/// The machine and port a Cloud port message names: the machine's name for the reader, its id
/// for the next command (`--target machine:<id>`), and the port (`<port>` when none was given).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PortNames {
    pub name: String,
    pub id: String,
    pub port: Option<u16>,
}

impl PortNames {
    /// The message's values in order: name, id, port.
    pub fn values(&self) -> [String; 3] {
        let port = self.port.map_or_else(|| "<port>".to_owned(), |port| port.to_string());
        [self.name.clone(), self.id.clone(), port]
    }

    /// `key` with name, id, port and then `more`.
    pub fn said(&self, key: &'static str, more: &[&str]) -> Said {
        let values = self.values().into_iter().chain(more.iter().map(|&value| value.to_owned()));
        Said::with(key, values.collect::<Vec<_>>())
    }
}

/// `--port` of the port verbs, refused with the machine named and the command to run
/// (`portInvalid`: name, id, verb).
pub fn named_port(args: &Args, verb: &str, names: &PortNames) -> Checked<u16> {
    port(args).map_err(|_| Said::with("portInvalid", [names.name.as_str(), &names.id, verb]))
}

/// `cloud set-idle-pause --minutes`: `off` (0) or one of `choices`, as text or a number.
pub fn idle_pause_minutes(args: &Args, choices: &[i64]) -> Checked<i64> {
    let given = match args.get("minutes") {
        Some(Value::String(text)) => Some(trim_spaces(text).to_lowercase()),
        Some(value) if !value.is_f64() => value.as_i64().map(|minutes| minutes.to_string()),
        _ => None,
    };
    let minutes =
        given.and_then(|text| if text == "off" { Some(0) } else { text.parse::<i64>().ok() });
    match minutes {
        Some(minutes) if choices.contains(&minutes) => Ok(minutes),
        _ => {
            let listed: Vec<String> = std::iter::once("off".to_owned())
                .chain(choices.iter().filter(|&&minutes| minutes > 0).map(i64::to_string))
                .collect();
            Err(Said::with("idlePauseMustBeOneOf", [listed.join(", ")]))
        }
    }
}

/// `new-terminal-on-machine --workspace <id>`: none without one; a bare or blank flag refuses.
pub fn machine_workspace(args: &Args, machine: &str) -> Checked<Option<String>> {
    if !args.contains_key("workspace") {
        return Ok(None);
    }
    required(args, "workspace", Said::with("machineWorkspaceRequired", [machine])).map(Some)
}

/// The publication id an action takes in `--path`; `missing` names it.
pub fn id_argument(args: &Args, missing: &'static str) -> Checked<String> {
    required(args, "path", Said::key(missing))
}

/// `cloud open-browser --path`: where the tab opens on the port, `/` when absent; refused as
/// `portPathInvalid` with the machine and port named.
pub fn browser_path(args: &Args, names: &PortNames) -> Checked<String> {
    let path = text(args, "path").map(trim_spaces).unwrap_or("");
    if path.is_empty() {
        return Ok("/".to_owned());
    }
    let ok = path.starts_with('/')
        && path.len() <= 2048
        && !path.chars().any(|c| c.is_whitespace() || c.is_control());
    if ok { Ok(path.to_owned()) } else { Err(names.said("portPathInvalid", &[])) }
}

/// One text argument the action needs, by `check`: `publicKey` (scp), `contents` (file-write),
/// `snapshot`, `linkId` (preview-revoke), `key` (api-key-revoke).
/// A missing `linkId` is refused as `portFailed` with the machine and port in `names`.
pub fn needed(args: &Args, check: &str, names: &PortNames) -> Checked<String> {
    let raw = |name: &str, missing: Said| text(args, name).map(str::to_owned).ok_or(missing);
    match check {
        // Sent as given; only a blank one refuses.
        "publicKey" => match text(args, "publicKey") {
            Some(key) if !key.trim().is_empty() => Ok(key.to_owned()),
            _ => Err(Said::key("publicKeyRequired")),
        },
        "contents" => raw("contents", Said::key("fileContentsRequired")),
        "snapshot" => match text(args, "snapshot") {
            Some(id) if !id.is_empty() => Ok(id.to_owned()),
            _ => Err(Said::key("snapshotRequired")),
        },
        "linkId" => match text(args, "linkId") {
            Some(id) if !id.is_empty() => Ok(id.to_owned()),
            _ => Err(names.said("portFailed", &["linkId is required"])),
        },
        "key" => required(args, "key", Said::key("apiKeyRequired")),
        _ => Err(Said::text(format!("unknown argument check {check}"))),
    }
}

/// `cloud provision-api --port N [--name KEY]`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProvisionAPI {
    pub port: u16,
    pub name: Option<String>,
}

pub fn provision_api(args: &Args) -> Checked<ProvisionAPI> {
    let port = port(args)?;
    let name = trimmed(args, "name").filter(|name| !name.is_empty()).map(str::to_owned);
    Ok(ProvisionAPI { port, name })
}

/// `cloud apply-machine-config [--machine-config FILE]`: the file, else none (the automatic
/// source). A bare flag (no value) arrives as `true` and is refused, never read as none.
pub fn apply_machine_config(args: &Args, home: &str) -> Checked<Option<String>> {
    if !args.contains_key("machineConfig") {
        return Ok(None);
    }
    match text(args, "machineConfig") {
        Some(path) if !path.is_empty() => Ok(Some(expanding_home(path, home))),
        _ => Err(Said::with("machineConfigUnreadable", ["--machine-config"])),
    }
}

/// `cloud new-machine --size` -> (vCPUs, MiB) as the server's size ladder makes them from the
/// memory a create sends (the smallest row with that memory), so the answer says what the machine
/// gets. `resize-machine` sets vCPUs itself.
pub const CREATE_SIZES: [(&str, i64, i64); 4] =
    [("large", 8, 16_384), ("medium", 4, 8_192), ("small", 2, 4_096), ("xlarge", 12, 24_576)];

/// The create size named `size`: (vCPUs, MiB).
pub fn create_size(size: &str) -> Option<(i64, i64)> {
    CREATE_SIZES.iter().find(|(name, ..)| *name == size).map(|&(_, cpu, memory)| (cpu, memory))
}

fn size_choices() -> Said {
    let names: Vec<&str> = CREATE_SIZES.iter().map(|(name, ..)| *name).collect();
    Said::with("sizeMustBeOneOf", [names.join(", ")])
}

/// `cloud resize-machine`'s sizes, name -> (vCPUs, MiB); Pro allows up to 24 GiB.
pub const RESIZE_SIZES: [(&str, i64, i64); 4] =
    [("large", 8, 16_384), ("medium", 4, 8_192), ("small", 2, 4_096), ("xlarge", 16, 24_576)];

/// `--disk` bounds in GiB (the route's `VM_DISK_MB_MAX`); it takes 4 GiB steps.
pub const DISK_GIB: std::ops::RangeInclusive<i64> = 4..=256;

/// A checked `cloud resize-machine`: the size (with its vCPUs and MiB) and the disk, at least one.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Resize {
    pub size: Option<String>,
    pub cpu: Option<i64>,
    pub memory_mb: Option<i64>,
    pub disk_gib: Option<i64>,
    pub storage_mb: Option<i64>,
}

/// `cloud resize-machine --size`, `--disk`: a size from [`RESIZE_SIZES`] (else
/// `sizeMustBeOneOf`), a disk in [`DISK_GIB`] in 4 GiB steps, as a number or text (else
/// `resizeNeedsSizeOrDisk`, as is neither given). A bare flag arrives as `true` and is refused.
pub fn resize(args: &Args) -> Checked<Resize> {
    let names = RESIZE_SIZES.iter().map(|(name, ..)| *name).collect::<Vec<_>>().join(", ");
    let mut request = Resize::default();
    if args.contains_key("size") {
        let (size, cpu, memory) = text(args, "size")
            .and_then(|size| RESIZE_SIZES.iter().find(|(name, ..)| *name == size))
            .ok_or_else(|| Said::with("sizeMustBeOneOf", [names.clone()]))?;
        request.size = Some((*size).to_owned());
        request.cpu = Some(*cpu);
        request.memory_mb = Some(*memory);
    }
    if args.contains_key("disk") {
        let disk = int(args, "disk")
            .or_else(|| text(args, "disk").and_then(|disk| trim_spaces(disk).parse::<i64>().ok()))
            .filter(|disk| DISK_GIB.contains(disk) && disk % 4 == 0)
            .ok_or_else(|| Said::with("resizeNeedsSizeOrDisk", [names.clone()]))?;
        request.disk_gib = Some(disk);
        request.storage_mb = disk.checked_mul(1024);
    }
    if request.size.is_none() && request.disk_gib.is_none() {
        return Err(Said::with("resizeNeedsSizeOrDisk", [names]));
    }
    Ok(request)
}

/// A machine name the create sends as given: 1 to 64 of `A-Z a-z 0-9 . _ -`, not starting
/// with `-`, and not `true` (a bare `--name`).
pub fn is_plain_name(name: &str) -> bool {
    name != "true"
        && (1..=64).contains(&name.chars().count())
        && !name.starts_with('-')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// The bootstrap a new machine runs: a plain script, or a lane host's.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BootstrapKind {
    #[default]
    Plain,
    Lane,
}

/// `cloud new-machine`'s options, checked. Reads no file: the app loads the script and the
/// machine config off the main thread before the create, and parses `repo` (its spec may
/// carry a token, so it is never echoed).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NewMachine {
    pub name: Option<String>,
    pub size: Option<String>,
    pub memory_mb: Option<i64>,
    pub persistent: bool,
    pub bootstrap_path: Option<String>,
    pub bootstrap_kind: BootstrapKind,
    pub machine_config_path: Option<String>,
    /// `--repo`, parsed: never the raw spec, so no login or token passes.
    pub repo: Option<crate::repo::MachineRepo>,
}

/// The invocation's `name`, `size`, `persistent`, `bootstrap`, `bootstrapScript`,
/// `machineConfig` and `repo`, with `~` under `home`.
pub fn new_machine(args: &Args, home: &str) -> Checked<NewMachine> {
    // A text flag given with no value (`--bootstrap-script` last on the line) arrives as `true`:
    // refuse it rather than make a machine without what was asked.
    for name in ["name", "size", "bootstrap", "bootstrapScript", "machineConfig", "repo"] {
        if args.contains_key(name) && text(args, name).is_none() {
            return Err(match name {
                "machineConfig" => Said::with("machineConfigUnreadable", ["--machine-config"]),
                "size" => size_choices(),
                "name" => Said::key("laneNeedsName"),
                "repo" => Said::key("repoUnrecognized"),
                _ => Said::key("bootstrapScriptRequired"),
            });
        }
    }
    let mut request = NewMachine::default();
    if let Some(name) = trimmed(args, "name") {
        if !is_plain_name(name) {
            return Err(Said::key("machineNameInvalid"));
        }
        request.name = Some(name.to_owned());
    }
    if let Some(size) = text(args, "size") {
        let (_, memory) = create_size(size).ok_or_else(size_choices)?;
        request.size = Some(size.to_owned());
        request.memory_mb = Some(memory);
    }
    request.persistent = match args.get("persistent") {
        Some(Value::Bool(on)) => *on,
        Some(Value::String(text)) => text == "true",
        _ => false,
    };
    let kind = text(args, "bootstrap").unwrap_or("none");
    let path = text(args, "bootstrapScript");
    if kind != "none" && kind != "lane" {
        return Err(Said::key("bootstrapScriptRequired"));
    }
    if kind == "lane" || path.is_some() {
        // A script alone runs as a plain bootstrap; `lane` also names the lane host.
        let path = path
            .filter(|path| !path.is_empty())
            .ok_or_else(|| Said::key("bootstrapScriptRequired"))?;
        request.bootstrap_path = Some(expanding_home(path, home));
        request.bootstrap_kind =
            if kind == "lane" { BootstrapKind::Lane } else { BootstrapKind::Plain };
    }
    if let Some(config) = text(args, "machineConfig") {
        if config.is_empty() {
            return Err(Said::with("machineConfigUnreadable", [config]));
        }
        request.machine_config_path = Some(expanding_home(config, home));
    }
    if request.bootstrap_kind == BootstrapKind::Lane && request.name.is_none() {
        return Err(Said::key("laneNeedsName"));
    }
    if let Some(spec) = text(args, "repo") {
        request.repo = Some(crate::repo::parse(spec)?);
    }
    Ok(request)
}

#[cfg(test)]
#[path = "args/tests.rs"]
mod tests;
