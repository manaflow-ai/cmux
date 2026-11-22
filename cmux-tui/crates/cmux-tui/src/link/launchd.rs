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
    let domain = gui_domain();
    let _ = launchctl(&["bootout", &format!("{domain}/{LABEL}")]);
    launchctl(&["bootstrap", &domain, &path.to_string_lossy()])?;
    Ok(path)
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
mod tests {
    use super::*;

    #[test]
    fn the_agent_plist_runs_link_serve_and_keeps_it_alive() {
        let arguments = vec![
            "link".to_string(),
            "serve".to_string(),
            "--state-dir".to_string(),
            "/a b/<x>".to_string(),
        ];
        let bytes =
            plist(Path::new("/Applications/cmux.app/Contents/MacOS/cmux"), &arguments).unwrap();
        let value = plist::Value::from_reader_xml(bytes.as_slice()).unwrap();
        let dictionary = value.as_dictionary().unwrap();
        assert_eq!(dictionary["Label"].as_string(), Some(LABEL));
        let command: Vec<&str> = dictionary["ProgramArguments"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item.as_string().unwrap())
            .collect();
        assert_eq!(
            command,
            [
                "/Applications/cmux.app/Contents/MacOS/cmux",
                "link",
                "serve",
                "--state-dir",
                "/a b/<x>"
            ]
        );
        assert_eq!(dictionary["KeepAlive"].as_boolean(), Some(true));
        assert_eq!(dictionary["RunAtLoad"].as_boolean(), Some(true));
    }
}
