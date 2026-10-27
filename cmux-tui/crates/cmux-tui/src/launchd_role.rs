//! Brings an installed launchd agent's `ProcessType` up to the process-roles
//! table (`cmux_server_core::units::LaunchdJob`, threading-model.md "Process
//! roles"). launchd reads a plist only at bootstrap, and only `cmux host
//! enable` or `cmux link install-agent` write a fresh one, so an agent an
//! older cmux installed keeps the role it was written with (`Background`
//! before p02-threads-234). The callers run this before they bootstrap the
//! agent and when its `serve` starts, the way cmux-server's launchd install
//! rewrites a changed plist before its bootstrap (cmux-server
//! service/launchd.rs). Every other key, the program and its arguments
//! included, stays as installed.

use std::io::{self, Write as _};
use std::path::Path;

use cmux_server_core::units::LaunchdJob;

/// Sets `ProcessType` in the plist at `path` to `job`'s table value when it
/// differs, by an atomic rename that keeps the file's mode. Returns whether
/// it rewrote the file; a missing file is no agent and is left missing.
pub(crate) fn upgrade_process_type(path: &Path, job: LaunchdJob) -> io::Result<bool> {
    let bytes = match cmux_blocking::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    let mut value = plist::Value::from_reader(io::Cursor::new(bytes))
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let dictionary = value.as_dictionary_mut().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "the launchd plist is not a dictionary")
    })?;
    let wanted = job.process_type();
    if dictionary.get("ProcessType").and_then(plist::Value::as_string) == Some(wanted) {
        return Ok(false);
    }
    dictionary.insert("ProcessType".into(), plist::Value::String(wanted.into()));
    let mut out = Vec::new();
    value.to_writer_xml(&mut out).map_err(io::Error::other)?;
    replace(path, &out)?;
    Ok(true)
}

/// Writes `bytes` beside `path` and renames it over `path`, with `path`'s mode.
fn replace(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let permissions = cmux_blocking::fs::metadata(path)?.permissions();
    let name = path.file_name().ok_or_else(|| io::Error::other("the plist path has no name"))?;
    let mut temporary_name = std::ffi::OsString::from(".");
    temporary_name.push(name);
    temporary_name.push(format!(".{}.tmp", std::process::id()));
    let temporary = path.with_file_name(temporary_name);
    let result = (|| {
        let mut file = crate::blocking::fs::open_with(
            std::fs::OpenOptions::new().write(true).create(true).truncate(true),
            &temporary,
        )?;
        file.write_all(bytes)?;
        crate::blocking::fs::sync_all(&file)?;
        crate::blocking::fs::set_permissions(&temporary, permissions)?;
        cmux_blocking::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = cmux_blocking::fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The `com.cmuxterm.host-remote` plist `cmux host enable` wrote before
    /// p02-threads-234.
    const OLD_HOST_REMOTE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.cmuxterm.host-remote</string>
  <key>ProgramArguments</key>
  <array><string>/Applications/cmux.app/Contents/Resources/bin/cmux</string><string>host</string><string>serve</string><string>--dir</string><string>/Users/ana/.cmux/host</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/Users/ana/.cmux/host/serve.log</string>
  <key>StandardErrorPath</key><string>/Users/ana/.cmux/host/serve.log</string>
</dict>
</plist>
"#;

    fn dictionary(path: &Path) -> plist::Dictionary {
        plist::Value::from_file(path).unwrap().into_dictionary().unwrap()
    }

    #[test]
    fn an_old_background_agent_becomes_interactive_and_keeps_everything_else() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("com.cmuxterm.host-remote.plist");
        std::fs::write(&path, OLD_HOST_REMOTE).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).unwrap();
        }
        let before = dictionary(&path);

        assert!(upgrade_process_type(&path, LaunchdJob::RemoteHost).unwrap());

        let after = dictionary(&path);
        assert_eq!(after["ProcessType"].as_string(), Some("Interactive"));
        for (key, value) in &before {
            if key != "ProcessType" {
                assert_eq!(after.get(key), Some(value), "{key}");
            }
        }
        assert_eq!(after.len(), before.len());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o640);
        }
        let names: Vec<_> =
            std::fs::read_dir(dir.path()).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(names.len(), 1, "no temporary file is left: {names:?}");
    }

    #[test]
    fn an_agent_already_at_the_table_value_is_not_rewritten() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("com.cmuxterm.host-remote.plist");
        let current = OLD_HOST_REMOTE.replace("Background", "Interactive");
        std::fs::write(&path, &current).unwrap();

        assert!(!upgrade_process_type(&path, LaunchdJob::RemoteHost).unwrap());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), current);
    }

    #[test]
    fn an_agent_with_no_process_type_gets_the_table_value() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("agent.plist");
        let old =
            OLD_HOST_REMOTE.replace("  <key>ProcessType</key><string>Background</string>\n", "");
        std::fs::write(&path, old).unwrap();

        assert!(upgrade_process_type(&path, LaunchdJob::RemoteHost).unwrap());
        assert_eq!(dictionary(&path)["ProcessType"].as_string(), Some("Interactive"));
    }

    #[test]
    fn no_installed_agent_is_left_uninstalled() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("missing.plist");
        assert!(!upgrade_process_type(&path, LaunchdJob::Link).unwrap());
        assert!(!path.exists());
    }

    #[test]
    fn a_plist_that_does_not_parse_is_an_error_and_stays_as_it_was() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("broken.plist");
        std::fs::write(&path, "not a plist").unwrap();
        let error = upgrade_process_type(&path, LaunchdJob::Link).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "not a plist");
    }
}
