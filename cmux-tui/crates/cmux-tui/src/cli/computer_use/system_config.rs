//! `cmux computer-use setup` on Linux and Windows: the box owner's mode in a
//! config the agent's user cannot write (docs/computer-use-approvals.md,
//! "Modes"), which cmux Remote's host reads (`cmux-remote-host` `config.rs`).
//!
//! | OS | Config | Manifest (`bounded`) | Owner |
//! | --- | --- | --- | --- |
//! | Linux | `/etc/cmux/computer-use.toml` | `/etc/cmux/computer-use.manifest.yaml` | root, 0644 in a root 0755 folder |
//! | Windows | `%ProgramData%\cmux\computer-use.toml` | `…\computer-use.manifest.yaml` | Administrators; the folder's ACL is SYSTEM and Administrators full, Users read |
//!
//! One file, one schema: the TOML the host parses (`mode`, `manifest` as the
//! path of the owner's capability manifest next to it, `[environment]` with
//! upstream's two-part opt-in for `unrestricted`, `[device_hub]` and the
//! pinned `[[approvers]]`). `schemas/computer-use/setup-config` holds what
//! this writes; the CLI's and the host's tests both check it.
//!
//! Device hub approvers are pinned here, never taken from the hub alone:
//! `--approver ID` reads the account's devices through the hub as this
//! machine's device, shows each chosen device's name, platform and approval
//! key fingerprint, and writes `{device_id, approval_key_fingerprint}` only after
//! the owner types `yes` on the terminal. The host then accepts an Allow only
//! from a pinned device whose registered approval key still has that
//! fingerprint, signed with that key (a deny needs only the decider's signing key).
//!
//! A non-root run elevates with `sudo` (Linux) or UAC (Windows) and needs a
//! terminal for that; it never falls back to a file the user owns. Root or an
//! elevated administrator (a VM's provisioning) writes directly, and may pin
//! with `--approver-pin JSON` without a terminal.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{ELEVATED_FLAG, Mode, Setup, UNRESTRICTED_ENV};

/// The config file.
pub(super) fn path() -> PathBuf {
    dir().join("computer-use.toml")
}

/// The owner's capability manifest of `bounded`, next to the config.
pub(super) fn manifest_path() -> PathBuf {
    dir().join("computer-use.manifest.yaml")
}

fn dir() -> PathBuf {
    #[cfg(windows)]
    {
        let base = std::env::var_os("ProgramData")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"));
        base.join("cmux")
    }
    #[cfg(not(windows))]
    {
        PathBuf::from("/etc/cmux")
    }
}

/// The host's TOML schema (`cmux-remote-host` `config.rs`), as setup writes it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct SystemConfig {
    pub mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manifest: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub allow_terminals: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub environment: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_hub: Option<DeviceHub>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub approvers: Vec<Pin>,
}

/// `[device_hub]`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct DeviceHub {
    pub url: String,
    pub token_command: String,
    #[serde(default)]
    pub allow_always: bool,
}

/// One pinned approver.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Pin {
    pub device_id: String,
    pub approval_key_fingerprint: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub platform: String,
}

impl Pin {
    /// A pin given on the command line (`--approver-pin JSON`), checked.
    pub(crate) fn parse(text: &str) -> Result<Pin, String> {
        let pin: Pin = serde_json::from_str(text)
            .map_err(|e| format!("--approver-pin takes a JSON object: {e}"))?;
        let fingerprint = &pin.approval_key_fingerprint;
        if fingerprint.len() != 64 || !fingerprint.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
            return Err("an approver's approval_key_fingerprint is 64 lowercase hex digits".into());
        }
        if pin.device_id.is_empty() {
            return Err("an approver needs its device_id".into());
        }
        Ok(pin)
    }
}

const HEADER: &str = "# cmux Computer Use: this machine's mode (docs/computer-use-approvals.md, \"Modes\").\n\
# Written by `cmux computer-use setup`; owned by root (Linux) or SYSTEM/Administrators (Windows).\n";

/// The config for `mode`, `manifest` (its path once written), the hub and the
/// pinned approvers.
pub(super) fn config(
    mode: Mode,
    manifest: Option<&Path>,
    device_hub: Option<DeviceHub>,
    approvers: Vec<Pin>,
) -> SystemConfig {
    let environment = if mode == Mode::Unrestricted {
        UNRESTRICTED_ENV.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
    } else {
        BTreeMap::new()
    };
    SystemConfig {
        mode: mode.name().to_owned(),
        manifest: manifest.map(|path| path.display().to_string()),
        allow_terminals: Vec::new(),
        environment,
        device_hub,
        approvers,
    }
}

/// The file's text.
pub(super) fn render(config: &SystemConfig) -> Result<String, String> {
    let body = toml::to_string(config).map_err(|e| format!("cannot write the config: {e}"))?;
    Ok(format!("{HEADER}{body}"))
}

/// The manifest file of `bounded`: a JSON object of upstream's version 3
/// (JSON is YAML, which the host and upstream read).
pub(super) fn read_manifest(path: &Path) -> Result<Value, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let manifest: Value =
        serde_json::from_str(&text).map_err(|e| format!("{} is not JSON: {e}", path.display()))?;
    if !manifest.is_object() {
        return Err(format!("{} is not a JSON object", path.display()));
    }
    if manifest["version"] != json!(3) {
        return Err(format!("{} is not a version 3 capability manifest", path.display()));
    }
    Ok(manifest)
}

/// Writes the config, elevating first when needed.
pub(super) fn apply(setup: &Setup) -> Result<Value, Value> {
    let failure = |code: &str, message: String| json!({"code": code, "message": message});
    let manifest = match (&setup.manifest, setup.mode) {
        (Some(path), _) => {
            Some(read_manifest(path).map_err(|m| failure("computer_use.manifest_invalid", m))?)
        }
        (None, Mode::Bounded) => {
            return Err(failure(
                "usage.invalid",
                "bounded needs --manifest FILE: the apps and tools agents may use without asking"
                    .into(),
            ));
        }
        (None, _) => None,
    };
    let as_root = elevated();
    if !setup.approver_pins.is_empty() && !as_root {
        return Err(failure(
            "computer_use.not_elevated",
            "--approver-pin is for provisioning as root or an elevated administrator; pin with \
             --approver ID, which shows each device for you to confirm"
                .into(),
        ));
    }
    if as_root {
        // The interactive pins were confirmed by the person before elevating
        // (`--approver`), or come from provisioning (`--approver-pin`).
        let mut pins = setup.approver_pins.clone();
        if !setup.approvers.is_empty() {
            pins.extend(confirmed_pins(setup).map_err(|m| failure("computer_use.approver_failed", m))?);
        }
        let config = write_all(setup, manifest.as_ref(), pins)
            .map_err(|m| failure("computer_use.write_failed", m))?;
        return Ok(json!({"path": path().display().to_string(), "config": config}));
    }
    if setup.elevated {
        return Err(failure(
            "computer_use.not_elevated",
            format!("{ELEVATED_FLAG} runs only as root or an elevated administrator"),
        ));
    }
    if !interactive() {
        return Err(failure(
            "computer_use.needs_terminal",
            "setting the mode needs root or an administrator: run it in a terminal, where sudo \
             (Linux) or Windows asks you, or as root on the box"
                .into(),
        ));
    }
    // Pinning reads the hub as this user's device (the one cmux Remote uses), then elevates.
    let pins = confirmed_pins(setup).map_err(|m| failure("computer_use.approver_failed", m))?;
    let code = elevate(setup, &pins).map_err(|m| failure("computer_use.elevation_failed", m))?;
    if code != 0 {
        return Err(failure(
            "computer_use.elevation_failed",
            format!("the elevated setup exited with {code}; nothing changed"),
        ));
    }
    Ok(json!({"path": path().display().to_string(), "elevated": true}))
}

/// Writes the manifest (bounded) and the config. Without new pins, the hub and
/// the approvers of the current config stay.
fn write_all(setup: &Setup, manifest: Option<&Value>, pins: Vec<Pin>) -> Result<SystemConfig, String> {
    let dir = dir();
    prepare_dir(&dir)?;
    let manifest_file = match manifest {
        Some(manifest) => {
            let mut text = serde_json::to_string_pretty(manifest).map_err(|e| e.to_string())?;
            text.push('\n');
            write_file(&manifest_path(), text.as_bytes())?;
            Some(manifest_path())
        }
        None => None,
    };
    let (device_hub, approvers) = if pins.is_empty() && setup.device_hub.is_none() {
        let current = std::fs::read_to_string(path())
            .ok()
            .and_then(|text| toml::from_str::<SystemConfig>(&text).ok())
            .unwrap_or_default();
        (current.device_hub, current.approvers)
    } else {
        (hub_section(setup), pins)
    };
    if !approvers.is_empty() && device_hub.is_none() {
        return Err("pinned approvers need --device-hub URL and --hub-token-command PROGRAM".into());
    }
    let config = config(setup.mode, manifest_file.as_deref(), device_hub, approvers);
    write_file(&path(), render(&config)?.as_bytes())?;
    Ok(config)
}

fn hub_section(setup: &Setup) -> Option<DeviceHub> {
    Some(DeviceHub {
        url: setup.device_hub.clone()?,
        token_command: setup.hub_token_command.as_ref()?.display().to_string(),
        allow_always: setup.hub_allow_always,
    })
}

fn interactive() -> bool {
    use std::io::IsTerminal as _;
    std::io::stdin().is_terminal() && std::io::stderr().is_terminal()
}

/// The approvers `--approver` names, read from the hub and confirmed by the
/// person on this terminal; none when no `--approver` was given.
fn confirmed_pins(setup: &Setup) -> Result<Vec<Pin>, String> {
    if setup.approvers.is_empty() {
        return Ok(Vec::new());
    }
    if !interactive() {
        return Err("pinning an approver needs a terminal to confirm it on".into());
    }
    let (Some(url), Some(program)) = (&setup.device_hub, &setup.hub_token_command) else {
        return Err("--approver needs --device-hub URL and --hub-token-command PROGRAM".into());
    };
    let pins = hub_pins(url, program, &setup.approvers)?;
    eprintln!(
        "These devices will answer Computer Use questions for this machine. Check that each \
         fingerprint is the approval key fingerprint the device shows in cmux:"
    );
    for pin in &pins {
        eprintln!("  {} ({}), device {}", pin.name, pin.platform, pin.device_id);
        eprintln!("    approval key {}", cmux_device_hub_client::display_fingerprint(&pin.approval_key_fingerprint));
    }
    eprint!("Pin them? Type yes to confirm: ");
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer).map_err(|e| format!("cannot read the answer: {e}"))?;
    if answer.trim() != "yes" {
        return Err("not confirmed; nothing changed".into());
    }
    Ok(pins)
}

/// Reads the chosen devices from the hub as this user's device.
fn hub_pins(url: &str, program: &Path, ids: &[String]) -> Result<Vec<Pin>, String> {
    use cmux_device_hub_client as hub;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| format!("no runtime: {e}"))?;
    runtime.block_on(async {
        let base = url::Url::parse(url).map_err(|e| format!("--device-hub: {e}"))?;
        let dir = hub::default_identity_dir().ok_or("no directory for this machine's device identity")?;
        let identity = hub::default_key_store(&dir).load_or_create().map_err(|e| e.to_string())?;
        let own = identity.id().to_owned();
        let tokens = Arc::new(hub::CommandToken::new(program));
        let client = hub::HubClient::new(hub::HubClientConfig::new(base, identity, tokens))
            .map_err(|e| e.to_string())?;
        client.register_device(&machine_name()).await.map_err(|e| format!("device hub: {e}"))?;
        let devices = client.devices().await.map_err(|e| format!("device hub: {e}"))?;
        pins_of(&devices, &own, ids)
    })
}

/// The pins for `ids` among the account's `devices`: Macs and iPhones only, never this machine.
pub(super) fn pins_of(
    devices: &[cmux_device_hub_client::HubDevice],
    own: &str,
    ids: &[String],
) -> Result<Vec<Pin>, String> {
    ids.iter()
        .map(|id| {
            let device = devices
                .iter()
                .find(|device| device.id.eq_ignore_ascii_case(id))
                .ok_or_else(|| format!("{id} is not a device of this account"))?;
            if device.id.eq_ignore_ascii_case(own) {
                return Err("this machine cannot approve its own questions".into());
            }
            if !device.platform.is_approver() {
                return Err(format!(
                    "{} is a {} device; only a Mac or an iPhone can approve",
                    device.name,
                    device.platform.as_str()
                ));
            }
            // The approval key (Secure Enclave, Face ID per Allow) is what signs an Allow.
            let key = device.approval_key.as_deref().ok_or_else(|| {
                format!(
                    "{} has no approval key yet: update cmux on it and open it once, then run setup again",
                    device.name
                )
            })?;
            let fingerprint = cmux_device_hub_client::key_fingerprint(key)
                .ok_or_else(|| format!("{} has no valid approval key", device.name))?;
            Ok(Pin {
                device_id: device.id.clone(),
                approval_key_fingerprint: fingerprint,
                name: device.name.clone(),
                platform: device.platform.as_str().to_owned(),
            })
        })
        .collect()
}

fn machine_name() -> String {
    #[cfg(windows)]
    {
        std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows".into())
    }
    #[cfg(not(windows))]
    {
        std::fs::read_to_string("/etc/hostname")
            .ok()
            .map(|name| name.trim().to_owned())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| "Linux".into())
    }
}

/// The words of the elevated run: the same setup, the confirmed pins, plus [`ELEVATED_FLAG`].
pub(super) fn elevated_args(setup: &Setup, pins: &[Pin]) -> Result<Vec<String>, String> {
    let mut args =
        vec!["computer-use".into(), "setup".into(), "--mode".into(), setup.mode.name().into()];
    if let Some(manifest) = &setup.manifest {
        // The elevated run starts elsewhere: name the file absolutely.
        let absolute = std::path::absolute(manifest)
            .map_err(|e| format!("cannot resolve {}: {e}", manifest.display()))?;
        args.push("--manifest".into());
        args.push(absolute.to_string_lossy().into_owned());
    }
    if setup.understand_unrestricted {
        args.push("--i-understand-unrestricted".into());
    }
    if let Some(url) = &setup.device_hub {
        args.push("--device-hub".into());
        args.push(url.clone());
    }
    if let Some(program) = &setup.hub_token_command {
        args.push("--hub-token-command".into());
        args.push(program.to_string_lossy().into_owned());
    }
    if setup.hub_allow_always {
        args.push("--hub-allow-always".into());
    }
    for pin in pins {
        args.push("--approver-pin".into());
        args.push(serde_json::to_string(pin).map_err(|e| e.to_string())?);
    }
    args.push(ELEVATED_FLAG.into());
    Ok(args)
}

#[cfg(unix)]
fn elevated() -> bool {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() == 0 }
}

#[cfg(unix)]
fn elevate(setup: &Setup, pins: &[Pin]) -> Result<i32, String> {
    let exe = std::env::current_exe().map_err(|e| format!("cannot find this cmux: {e}"))?;
    let status = cmux_process::Command::new("sudo")
        .arg("--")
        .arg(exe)
        .args(elevated_args(setup, pins)?)
        .status()
        .map_err(|e| format!("cannot run sudo: {e}"))?;
    Ok(status.code().unwrap_or(1))
}

/// A High or System integrity token: an elevated administrator or SYSTEM.
#[cfg(windows)]
fn elevated() -> bool {
    cmux_process::Command::new("whoami")
        .arg("/groups")
        .output()
        .ok()
        .map(|out| String::from_utf8_lossy(&out.stdout).into_owned())
        .is_some_and(|groups| groups.contains("S-1-16-12288") || groups.contains("S-1-16-16384"))
}

/// Runs the elevated setup through UAC and waits for it.
#[cfg(windows)]
fn elevate(setup: &Setup, pins: &[Pin]) -> Result<i32, String> {
    let exe = std::env::current_exe().map_err(|e| format!("cannot find this cmux: {e}"))?;
    let quote = |s: &str| format!("'{}'", s.replace('\'', "''"));
    let list: Vec<String> = elevated_args(setup, pins)?.iter().map(|a| quote(a)).collect();
    let script = format!(
        "$p = Start-Process -FilePath {} -ArgumentList @({}) -Verb RunAs -Wait -PassThru; exit $p.ExitCode",
        quote(&exe.to_string_lossy()),
        list.join(",")
    );
    let status = cmux_process::Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .status()
        .map_err(|e| format!("cannot ask Windows to elevate: {e}"))?;
    Ok(status.code().unwrap_or(1))
}

/// Writes `bytes` to `path` through a temporary file in the same folder.
fn write_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let dir = path.parent().ok_or("the config has no folder")?;
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.tmp"));
    let _ = std::fs::remove_file(&tmp);
    write_new(&tmp, bytes)?;
    std::fs::rename(&tmp, path).map_err(|e| format!("cannot replace {}: {e}", path.display()))
}

/// The folder exists, is root's and only root writes it.
#[cfg(unix)]
fn prepare_dir(dir: &Path) -> Result<(), String> {
    use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _};
    if let Err(e) = std::fs::DirBuilder::new().recursive(true).mode(0o755).create(dir) {
        return Err(format!("cannot create {}: {e}", dir.display()));
    }
    let meta = std::fs::symlink_metadata(dir)
        .map_err(|e| format!("cannot read {}: {e}", dir.display()))?;
    if !meta.is_dir() || meta.uid() != 0 || meta.mode() & 0o022 != 0 {
        return Err(format!(
            "{} must be a folder owned by root that only root writes; fix or remove it first",
            dir.display()
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn write_new(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o644)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    file.write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))
}

/// The folder exists and its ACL is SYSTEM and Administrators full, Users
/// read, owned by Administrators (well-known SIDs, any Windows language).
#[cfg(windows)]
fn prepare_dir(dir: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    let dir_text = dir.to_string_lossy().into_owned();
    for args in [
        vec![dir_text.as_str(), "/setowner", "*S-1-5-32-544", "/T", "/C"],
        vec![
            dir_text.as_str(),
            "/inheritance:r",
            "/grant:r",
            "*S-1-5-18:(OI)(CI)F",
            "*S-1-5-32-544:(OI)(CI)F",
            "*S-1-5-32-545:(OI)(CI)RX",
            "/T",
            "/C",
        ],
    ] {
        let status = cmux_process::Command::new("icacls")
            .args(&args)
            .status()
            .map_err(|e| format!("cannot run icacls: {e}"))?;
        if !status.success() {
            return Err(format!("icacls could not secure {}", dir.display()));
        }
    }
    Ok(())
}

#[cfg(windows)]
fn write_new(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write as _;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    file.write_all(bytes)
        .and_then(|()| file.sync_all())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))
}
