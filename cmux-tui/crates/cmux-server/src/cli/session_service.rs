//! The session service: `cmux server install` that keeps this machine's cmux
//! session daemon running, for a machine the signed server channel does not
//! serve yet (or with `--binary`). It copies this binary to
//! `~/.local/bin/cmux-tui` (the path every cmux client installs and upgrades
//! over SSH), links `~/.local/bin/cmux` to it when that name is free, and
//! writes the service (`cmux-server.service`, a systemd user unit with
//! linger on Linux; `com.cmux.server`, a LaunchAgent on macOS) that runs
//! `cmux-tui daemon start --session main`. The unit names are the store's,
//! so `up`, `down`, `status` and `uninstall` work the same on both.

use std::io::Read;
use std::path::Path;

use cmux_server_core::InstallMode;
use cmux_server_core::layout::Layout;
use cmux_server_core::units::{
    DEFAULT_SESSION, SESSION_BINARY, SessionUnit, parse_session_unit, valid_session_name,
};
use serde_json::json;
use sha2::{Digest, Sha256};

use super::{Args, Context, Output, lifecycle};
use crate::error::{Error, Result};
use crate::process::Runner;
use crate::service::{Announce, Services, SessionHost, check_private_dir};
use crate::{fsx, host};

/// The session service this layout's unit runs, when it is one.
pub(super) fn installed(svc: &Services<'_>) -> Option<SessionUnit> {
    let text = std::fs::read_to_string(svc.unit_path().ok()?).ok()?;
    parse_session_unit(&text)
}

/// The session of the installed session unit, as the steps that render or
/// run it need it (uninstall renews the unit as cmux renders it, and on
/// macOS runs the binary to end the session's terminals). Its binary is the
/// one install places (`$HOME/SESSION_BINARY`), never the path the file
/// names: a unit cmux renders for another binary still counts as cmux's only
/// through the ownership record, and no other binary runs.
pub(super) fn installed_host(ctx: &Context<'_>, svc: &Services<'_>) -> Option<SessionHost> {
    if svc.layout.mode != InstallMode::User {
        return None;
    }
    let unit = installed(svc)?;
    let binary = Path::new(ctx.env.home.as_deref()?).join(SESSION_BINARY);
    Some(SessionHost { binary: binary.to_str()?.to_owned(), session: unit.session })
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
    let announce = !args.json;
    let binary = target
        .to_str()
        .ok_or_else(|| Error::rejected("the home directory path is not UTF-8"))?
        .to_owned();
    let announcer = Announce(ctx.runner);
    let runner: &dyn Runner = if announce { &announcer } else { ctx.runner };
    let svc = Services {
        session: Some(SessionHost { binary: binary.clone(), session: session.to_owned() }),
        runner,
        linger: !args.has("user"),
        announce,
        ..lifecycle::services(ctx, layout)?
    };
    // One service command at a time, for the whole install (Services::lock).
    let _service_lock = svc.lock()?;
    // Every refusal comes before the first change.
    svc.preflight()?;
    let binary_changed = place_binary(&source, &target, announce)?;
    let mut warnings = Vec::new();
    link_shim(&fsx::local(&layout.cli_shim), &target, &mut warnings)?;
    let service = svc.install(binary_changed)?;
    warnings.extend(service.warnings.iter().cloned());
    let changed = binary_changed || service.changed;
    let keeps = match (cfg!(target_os = "linux"), service.linger, args.has("user")) {
        (true, Some(true), _) => "It starts at boot and keeps running while you are logged out.",
        (true, _, true) => {
            "It starts when you log in and stops when you log out (--user: linger left off)."
        }
        (true, _, false) => "It starts when you log in and stops when you log out (linger is off).",
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

/// Copies `source` to `target` (mode 0755, through a new temporary file
/// with a random name and one rename, so a client probing the path never
/// sees half a binary and a file planted next to it is never written
/// through). Refuses a directory other accounts can write to. `false`:
/// `target` is `source`, or already has its bytes.
fn place_binary(source: &Path, target: &Path, announce: bool) -> Result<bool> {
    let dir = target.parent().ok_or_else(|| Error::rejected("the binary path has no parent"))?;
    fsx::ensure_dir(dir, 0o755)?;
    check_private_dir(dir, "the cmux binary directory")?;
    // Only a regular file at the path is kept: a symlink there (even to
    // this binary) is replaced, so what the service runs cannot change
    // through a file elsewhere.
    let regular = std::fs::symlink_metadata(target).is_ok_and(|m| m.is_file());
    let real = |p: &Path| std::fs::canonicalize(p).ok();
    if regular && real(source).is_some_and(|s| Some(s) == real(target)) {
        return Ok(false);
    }
    let wanted = digest(source)?;
    if regular && digest(target).ok() == Some(wanted) {
        return Ok(false);
    }
    if announce {
        eprintln!("  write {}", target.display());
    }
    fsx::atomic_copy(source, target, 0o755)?;
    Ok(true)
}

fn digest(path: &Path) -> Result<[u8; 32]> {
    let mut file = std::fs::File::open(path).map_err(|e| Error::io(path.display(), e))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = file.read(&mut buf).map_err(|e| Error::io(path.display(), e))?;
        // `read` never returns more than the buffer holds.
        let Some(chunk) = buf.get(..n).filter(|chunk| !chunk.is_empty()) else { break };
        hasher.update(chunk);
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

/// What `cmux server uninstall` leaves of the session service, and the
/// command that removes each: the binary (cmux clients reuse it over SSH)
/// and linger (other services of this user may need it).
pub(super) fn uninstall_notes(svc: &Services<'_>, unit: &SessionUnit) -> Vec<String> {
    let mut notes = Vec::new();
    let binary = Path::new(&unit.binary);
    if binary.is_file() {
        let mut rm = unit.binary.clone();
        let shim = binary.with_file_name("cmux");
        if std::fs::read_link(&shim).is_ok_and(|t| t == Path::new("cmux-tui") || t == binary) {
            rm = format!("{rm} {}", shim.display());
        }
        notes
            .push(format!("kept {} (cmux reuses it over SSH); to remove it: rm {rm}", unit.binary));
    }
    if cfg!(target_os = "linux")
        && crate::service::linger_state(svc.runner, &svc.user) == Some(true)
    {
        notes.push(format!(
            "linger stays on (other services of yours may need it); to turn it off: loginctl disable-linger {}",
            svc.user
        ));
    }
    notes
}
