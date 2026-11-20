//! The session service: `cmux server install` that keeps this machine's cmux
//! session daemon running, for a machine the signed server channel does not
//! serve yet (or with `--binary`). It copies this binary to
//! `~/.local/bin/cmux-tui` (the path every cmux client installs and upgrades
//! over SSH), links `~/.local/bin/cmux` to it when that name is free, and
//! writes the service (`cmux-server.service`, a systemd user unit with
//! linger on Linux; `com.cmux.server`, a LaunchAgent on macOS) that runs
//! `cmux-tui daemon start --session main`. The unit names are the store's,
//! so `up`, `down`, `status` and `uninstall` work the same on both.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use cmux_server_core::InstallMode;
use cmux_server_core::layout::Layout;
use cmux_server_core::units::{
    DEFAULT_SESSION, SESSION_BINARY, SessionUnit, parse_session_unit, valid_session_name,
};
use serde_json::json;
use sha2::{Digest, Sha256};

use super::{Args, Context, Output, lifecycle};
use crate::error::{Error, Result};
use crate::service::{Services, SessionHost};
use crate::{fsx, host};

/// The session service this layout's unit runs, when it is one.
pub(super) fn installed(svc: &Services<'_>) -> Option<SessionUnit> {
    let text = std::fs::read_to_string(svc.unit_path().ok()?).ok()?;
    parse_session_unit(&text)
}

pub(super) fn install(
    ctx: &Context<'_>,
    args: &Args,
    layout: &Layout,
    note: Option<&str>,
) -> Result<Output> {
    if layout.mode == InstallMode::System {
        return Err(Error::rejected(
            "the session service runs as your own user; run `cmux server install` without --system or sudo",
        ));
    }
    let session = args.value("session-name").unwrap_or(DEFAULT_SESSION);
    if !valid_session_name(session) {
        return Err(Error::usage(format!(
            "invalid session {session:?}: use 1 to 64 letters, digits, '.', '_' or '-'"
        )));
    }
    let home = ctx
        .env
        .home
        .as_deref()
        .ok_or_else(|| Error::rejected("HOME is not set; cannot place the cmux binary"))?;
    let target = Path::new(home).join(SESSION_BINARY);
    let source = match &ctx.self_exe {
        Some(path) => path.clone(),
        None => std::env::current_exe().map_err(|e| Error::io("this binary's path", e))?,
    };
    let binary_changed = place_binary(&source, &target)?;
    let mut warnings = Vec::new();
    link_shim(&fsx::local(&layout.cli_shim), &target, &mut warnings)?;
    let binary = target
        .to_str()
        .ok_or_else(|| Error::rejected("the home directory path is not UTF-8"))?
        .to_owned();
    let svc = Services {
        session: Some(SessionHost { binary: binary.clone(), session: session.to_owned() }),
        ..lifecycle::services(ctx, layout)?
    };
    let service = svc.install(binary_changed)?;
    warnings.extend(service.warnings.iter().cloned());
    let changed = binary_changed || service.changed;
    let keeps = match (cfg!(target_os = "linux"), service.linger) {
        (true, Some(true)) => "It starts at boot and keeps running while you are logged out.",
        (true, _) => "It starts when you log in and stops when you log out (linger is off).",
        _ => "It starts when you log in.",
    };
    let json = json!({
        "installed": true, "source": "binary", "binary": binary, "session": session,
        "unit": service.unit, "changed": changed, "binary_changed": binary_changed,
        "mode": host::mode_str(layout.mode), "linger": service.linger,
        "restarted": service.restarted, "note": note, "warnings": warnings,
    });
    let mut human = format!(
        "cmux server: session \"{session}\" runs as a service ({}), unit {}{}\n  binary: {binary}\n  {keeps}\n",
        if changed { "changed" } else { "no change" },
        service.unit.display(),
        if service.restarted { ", restarted" } else { "" },
    );
    if let Some(note) = note {
        human.push_str(&format!("  note: {note}\n"));
    }
    for w in &warnings {
        human.push_str(&format!("warning: {w}\n"));
    }
    Ok(Output::new(json, human))
}

/// Copies `source` to `target` (mode 0755, through a temporary file and one
/// rename, so a client probing the path never sees half a binary). `false`:
/// `target` is `source`, or already has its bytes.
fn place_binary(source: &Path, target: &Path) -> Result<bool> {
    let real = |p: &Path| std::fs::canonicalize(p).ok();
    if real(source).is_some_and(|s| Some(s) == real(target)) {
        return Ok(false);
    }
    let wanted = digest(source)?;
    if target.is_file() && digest(target).ok() == Some(wanted) {
        return Ok(false);
    }
    let dir = target.parent().ok_or_else(|| Error::rejected("the binary path has no parent"))?;
    fsx::ensure_dir(dir, 0o755)?;
    let tmp: PathBuf = dir.join(format!(".cmux-tui.{}.tmp", std::process::id()));
    let copied = (|| -> std::io::Result<()> {
        let mut from = std::fs::File::open(source)?;
        let mut to = std::fs::File::create(&tmp)?;
        std::io::copy(&mut from, &mut to)?;
        to.flush()?;
        to.sync_all()?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
        }
        std::fs::rename(&tmp, target)
    })();
    if let Err(e) = copied {
        let _ = std::fs::remove_file(&tmp);
        return Err(Error::io(format!("copy this binary to {}", target.display()), e));
    }
    Ok(true)
}

fn digest(path: &Path) -> Result<[u8; 32]> {
    let mut file = std::fs::File::open(path).map_err(|e| Error::io(path.display(), e))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = file.read(&mut buf).map_err(|e| Error::io(path.display(), e))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().into())
}

/// `~/.local/bin/cmux` -> `cmux-tui` when the name is free, so `cmux` works
/// in an SSH session. Something else there (the store's shim, a person's own
/// file) is left alone.
fn link_shim(shim: &Path, target: &Path, warnings: &mut Vec<String>) -> Result<()> {
    if shim == target {
        return Ok(());
    }
    match std::fs::read_link(shim) {
        Ok(existing) if existing == Path::new("cmux-tui") || existing == target => return Ok(()),
        Ok(_) => return Ok(()),
        Err(_) if fsx::exists_no_follow(shim) => {
            warnings.push(format!("{} exists and is not a link; left as is", shim.display()));
            return Ok(());
        }
        Err(_) => {}
    }
    if let Some(dir) = shim.parent() {
        fsx::ensure_dir(dir, 0o755)?;
    }
    fsx::swap_symlink(shim, Path::new("cmux-tui"))
}
