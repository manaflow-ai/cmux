//! `cmux computer-use setup` on Linux and Windows: the box owner's mode in a
//! config the agent's user cannot write (docs/computer-use-approvals.md,
//! "Modes"), which the host reads when it starts the Computer Use worker.
//!
//! | OS | File | Owner |
//! | --- | --- | --- |
//! | Linux | `/etc/cmux/computer-use.json` | root, 0644 in a root 0755 folder |
//! | Windows | `%ProgramData%\cmux\computer-use.json` | Administrators; the folder's ACL is SYSTEM and Administrators full, Users read |
//!
//! The document is `{"version": 1, "mode", "manifest"?, "env"?}`: `manifest`
//! is the owner's upstream capability manifest for `bounded`, `env` holds
//! upstream's two-part opt-in for `unrestricted`. A non-root run elevates
//! with `sudo` (Linux) or UAC (Windows) and needs a terminal for that; it
//! never falls back to a file the user owns. Root or an elevated
//! administrator (a VM's provisioning) writes directly.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::{ELEVATED_FLAG, Mode, Setup, UNRESTRICTED_ENV};

/// The config file.
pub(super) fn path() -> PathBuf {
    #[cfg(windows)]
    {
        let base = std::env::var_os("ProgramData")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"));
        base.join("cmux").join("computer-use.json")
    }
    #[cfg(not(windows))]
    {
        PathBuf::from("/etc/cmux/computer-use.json")
    }
}

/// The manifest file of `bounded`: a JSON object of upstream's version 3.
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

/// The config document for `mode`.
pub(super) fn document(mode: Mode, manifest: Option<Value>) -> Value {
    let mut document = json!({"version": 1, "mode": mode.name()});
    if let (Some(object), Some(manifest)) = (document.as_object_mut(), manifest) {
        object.insert("manifest".into(), manifest);
    }
    if mode == Mode::Unrestricted
        && let Some(object) = document.as_object_mut()
    {
        let env: serde_json::Map<String, Value> =
            UNRESTRICTED_ENV.iter().map(|(k, v)| ((*k).to_owned(), json!(v))).collect();
        object.insert("env".into(), Value::Object(env));
    }
    document
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
    let document = document(setup.mode, manifest);
    if elevated() {
        write(&path(), &document).map_err(|m| failure("computer_use.write_failed", m))?;
        return Ok(json!({"path": path().display().to_string(), "config": document}));
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
    let code = elevate(setup).map_err(|m| failure("computer_use.elevation_failed", m))?;
    if code != 0 {
        return Err(failure(
            "computer_use.elevation_failed",
            format!("the elevated setup exited with {code}; nothing changed"),
        ));
    }
    Ok(json!({"path": path().display().to_string(), "config": document, "elevated": true}))
}

fn interactive() -> bool {
    use std::io::IsTerminal as _;
    std::io::stdin().is_terminal() && std::io::stderr().is_terminal()
}

/// The words of the elevated run: the same setup, plus [`ELEVATED_FLAG`].
pub(super) fn elevated_args(setup: &Setup) -> Result<Vec<String>, String> {
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
    args.push(ELEVATED_FLAG.into());
    Ok(args)
}

#[cfg(unix)]
fn elevated() -> bool {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() == 0 }
}

#[cfg(unix)]
fn elevate(setup: &Setup) -> Result<i32, String> {
    let exe = std::env::current_exe().map_err(|e| format!("cannot find this cmux: {e}"))?;
    let status = cmux_process::Command::new("sudo")
        .arg("--")
        .arg(exe)
        .args(elevated_args(setup)?)
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
fn elevate(setup: &Setup) -> Result<i32, String> {
    let exe = std::env::current_exe().map_err(|e| format!("cannot find this cmux: {e}"))?;
    let quote = |s: &str| format!("'{}'", s.replace('\'', "''"));
    let list: Vec<String> = elevated_args(setup)?.iter().map(|a| quote(a)).collect();
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

/// Writes `document` to `path` through a temporary file in the same folder.
fn write(path: &Path, document: &Value) -> Result<(), String> {
    let dir = path.parent().ok_or("the config has no folder")?;
    prepare_dir(dir)?;
    let mut text = serde_json::to_string_pretty(document).map_err(|e| e.to_string())?;
    text.push('\n');
    let tmp = dir.join(".computer-use.json.tmp");
    let _ = std::fs::remove_file(&tmp);
    write_new(&tmp, text.as_bytes())?;
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
