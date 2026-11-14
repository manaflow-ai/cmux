//! The macOS launchd agent that keeps `cmux link serve` running for the
//! user (`~/Library/LaunchAgents/com.cmuxterm.link.plist`). Linux gets a
//! systemd user unit in a later slice.

use std::io;
use std::path::{Path, PathBuf};

/// The launchd label.
pub(super) const LABEL: &str = "com.cmuxterm.link";

/// The agent plist for `program` with `arguments` (after the program).
pub(super) fn plist(program: &Path, arguments: &[String]) -> io::Result<Vec<u8>> {
    let mut command = vec![plist::Value::String(program.to_string_lossy().into_owned())];
    command.extend(arguments.iter().cloned().map(plist::Value::String));
    let mut dictionary = plist::Dictionary::new();
    dictionary.insert("Label".into(), plist::Value::String(LABEL.into()));
    dictionary.insert("ProgramArguments".into(), plist::Value::Array(command));
    dictionary.insert("RunAtLoad".into(), plist::Value::Boolean(true));
    dictionary.insert("KeepAlive".into(), plist::Value::Boolean(true));
    dictionary.insert("ProcessType".into(), plist::Value::String("Background".into()));
    // Tells `serve` which job launchd runs it for (`launchd_refresh.rs`).
    let mut environment = plist::Dictionary::new();
    environment
        .insert(crate::launchd_refresh::AGENT_ENV.into(), plist::Value::String(LABEL.into()));
    dictionary.insert("EnvironmentVariables".into(), plist::Value::Dictionary(environment));
    let mut bytes = Vec::new();
    plist::Value::Dictionary(dictionary).to_writer_xml(&mut bytes).map_err(io::Error::other)?;
    Ok(bytes)
}

/// `~/Library/LaunchAgents/com.cmuxterm.link.plist`.
pub(super) fn plist_path() -> io::Result<PathBuf> {
    let home = std::env::var_os("HOME")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not set"))?;
    Ok(PathBuf::from(home).join("Library/LaunchAgents").join(format!("{LABEL}.plist")))
}

/// Write the plist and (re)load it in the user's GUI domain.
pub(super) fn install(program: &Path, arguments: &[String]) -> io::Result<PathBuf> {
    let path = plist_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, plist(program, arguments)?)?;
    reload(&path)?;
    Ok(path)
}

fn reload(path: &Path) -> io::Result<()> {
    let domain = gui_domain();
    let _ = launchctl(&["bootout", &format!("{domain}/{LABEL}")]);
    launchctl(&["bootstrap", &domain, &path.to_string_lossy()])
}

/// An agent installed before `serve` took `--key-lock-dir` runs with the
/// lock directory guessed in launchd's empty environment; an update restarts
/// it but never rewrites its plist. When the installed agent serves
/// `state_dir`'s link and its `flag` is missing or names another directory
/// than `lock_dir`, the plist gets it and the agent is reloaded once; true
/// then. An agent that already has it, another state directory's agent, or
/// no agent is left alone.
pub(super) fn refresh_key_lock_dir(
    state_dir: &Path,
    flag: &str,
    lock_dir: &Path,
) -> io::Result<bool> {
    let path = plist_path()?;
    if !rewrite_key_lock_dir(&path, state_dir, flag, lock_dir)? {
        return Ok(false);
    }
    reload(&path)?;
    Ok(true)
}

/// The plist part of [`refresh_key_lock_dir`]: rewrites the plist at `path`
/// when it needs `flag`; true when it did.
fn rewrite_key_lock_dir(
    path: &Path,
    state_dir: &Path,
    flag: &str,
    lock_dir: &Path,
) -> io::Result<bool> {
    let value = match plist::Value::from_file(path) {
        Ok(value) => value,
        Err(error) if error.as_io().is_some_and(|io| io.kind() == io::ErrorKind::NotFound) => {
            return Ok(false);
        }
        Err(error) => return Err(io::Error::other(error)),
    };
    let command: Vec<String> = value
        .as_dictionary()
        .and_then(|dictionary| dictionary.get("ProgramArguments"))
        .and_then(plist::Value::as_array)
        .map(|items| items.iter().filter_map(plist::Value::as_string).map(str::to_owned).collect())
        .unwrap_or_default();
    let Some((program, arguments)) = command.split_first() else { return Ok(false) };
    let Some(arguments) = with_key_lock_dir(arguments, state_dir, flag, lock_dir) else {
        return Ok(false);
    };
    std::fs::write(path, plist(Path::new(program), &arguments)?)?;
    Ok(true)
}

/// `arguments` with `flag lock_dir`, or `None` when they already have it or
/// serve another state directory than `state_dir`.
fn with_key_lock_dir(
    arguments: &[String],
    state_dir: &Path,
    flag: &str,
    lock_dir: &Path,
) -> Option<Vec<String>> {
    let value = |name: &str| {
        arguments.iter().position(|argument| argument == name).and_then(|at| arguments.get(at + 1))
    };
    if value("--state-dir").map(Path::new) != Some(state_dir) {
        return None;
    }
    if value(flag).map(Path::new) == Some(lock_dir) {
        return None;
    }
    let mut rewritten = Vec::with_capacity(arguments.len() + 2);
    let mut rest = arguments.iter();
    while let Some(argument) = rest.next() {
        if argument == flag {
            rest.next();
        } else {
            rewritten.push(argument.clone());
        }
    }
    rewritten.extend([flag.to_owned(), lock_dir.to_string_lossy().into_owned()]);
    Some(rewritten)
}

/// Unload the agent and remove its plist.
pub(super) fn uninstall() -> io::Result<()> {
    let _ = launchctl(&["bootout", &format!("{}/{LABEL}", gui_domain())]);
    match std::fs::remove_file(plist_path()?) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

fn gui_domain() -> String {
    // SAFETY: getuid has no preconditions.
    format!("gui/{}", unsafe { libc::getuid() })
}

fn launchctl(arguments: &[&str]) -> io::Result<()> {
    let status = std::process::Command::new("/bin/launchctl").args(arguments).status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("launchctl {} failed: {status}", arguments[0])))
    }
}

#[cfg(test)]
mod tests;
