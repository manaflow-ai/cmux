//! Per-user autostart integration for the relay.
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::Command as ProcessCommand,
    time::{SystemTime, UNIX_EPOCH},
};
#[cfg(any(target_os = "macos", target_os = "windows"))]
const LABEL: &str = "com.chatmux.relay";

/// `npx` installs a package into a cache directory named `_npx`. That cache is
/// allowed to be removed at any time, so a login service that points at a
/// binary below it would silently stop working. Keep this refusal in the
/// relay as well as in the npm launcher: callers can invoke the native binary
/// directly and must get the same safe result.
const EPHEMERAL_NPX_AUTOSTART_MESSAGE: &str = "autostart needs a durable relay executable; this command is running from npx's temporary cache. Install cmux-relay globally (npm install --global cmux-relay) or in a persistent project, then run cmux-relay --autostart.";

fn is_ephemeral_npx_path(path: &Path) -> bool {
    // Split both separators so this check is testable on every host and also
    // handles a Windows path passed through a Unix-side wrapper.
    path.to_string_lossy()
        .split(['/', '\\'])
        .any(|component| component.eq_ignore_ascii_case("_npx"))
}

fn validate_autostart_executable(path: &Path) -> Result<(), String> {
    if !path.is_absolute() {
        return Err("autostart needs an absolute relay executable path".to_owned());
    }
    if is_ephemeral_npx_path(path) {
        return Err(EPHEMERAL_NPX_AUTOSTART_MESSAGE.to_owned());
    }
    Ok(())
}

fn home() -> Result<PathBuf, String> {
    std::env::var_os("HOME").map(PathBuf::from).ok_or_else(|| "HOME is not set".into())
}
#[cfg(target_os = "macos")]
fn xml_escape(v: &str) -> String {
    v.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
#[cfg(target_os = "linux")]
fn systemd_quote(v: &str) -> String {
    // ExecStart is parsed by systemd's unit-file lexer, not a POSIX shell.
    // Double-quoted items preserve whitespace. Escape literal percent signs
    // so systemd does not treat path components as specifiers.
    format!("\"{}\"", v.replace('%', "%%").replace('\\', "\\\\").replace('"', "\\\""))
}
fn atomic_write(p: &Path, b: &str) -> Result<(), String> {
    let d = p.parent().ok_or("autostart path has no parent")?;
    fs::create_dir_all(d).map_err(|e| e.to_string())?;
    let n = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e| e.to_string())?.as_nanos();
    for i in 0..16 {
        let t = d.join(format!(".autostart-{}-{}", std::process::id(), n + i));
        match fs::OpenOptions::new().write(true).create_new(true).open(&t) {
            Ok(mut f) => {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    fs::set_permissions(&t, fs::Permissions::from_mode(0o600))
                        .map_err(|e| e.to_string())?;
                }
                f.write_all(b.as_bytes()).map_err(|e| e.to_string())?;
                f.sync_all().map_err(|e| e.to_string())?;
                drop(f);
                let r = fs::rename(&t, p).map_err(|e| e.to_string());
                if r.is_err() {
                    let _ = fs::remove_file(&t);
                }
                return r;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e.to_string()),
        }
    }
    Err("could not create a unique temporary autostart file".into())
}
fn run(p: &str, a: &[&str]) -> Result<(), String> {
    let s = ProcessCommand::new(p)
        .args(a)
        .status()
        .map_err(|_| "autostart command could not run".to_owned())?;
    s.success().then_some(()).ok_or_else(|| "autostart command failed".to_owned())
}
#[cfg(target_os = "macos")]
fn install_impl(e: &Path, config: &Path) -> Result<String, String> {
    let p = home()?.join("Library/LaunchAgents").join(format!("{LABEL}.plist"));
    let x = e.to_str().ok_or("executable path is not valid UTF-8")?;
    let c = config.to_str().ok_or("config path is not valid UTF-8")?;
    let b = format!(
        "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>{LABEL}</string><key>ProgramArguments</key><array><string>{}</string><string>--no-onboard</string><string>--config</string><string>{}</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>\n",
        xml_escape(x),
        xml_escape(c)
    );
    atomic_write(&p, &b)?;
    let d = format!("gui/{}", unsafe { libc::getuid() });
    let s = p.to_str().ok_or("autostart path is not valid UTF-8")?;
    let _ = run("launchctl", &["bootout", &d, s]);
    run("launchctl", &["bootstrap", &d, s])?;
    Ok(format!("installed {}", p.display()))
}
#[cfg(target_os = "linux")]
fn install_impl(e: &Path, config: &Path) -> Result<String, String> {
    let p = home()?.join(".config/systemd/user/chatmux-relay.service");
    let x = e.to_str().ok_or("executable path is not valid UTF-8")?;
    let c = config.to_str().ok_or("config path is not valid UTF-8")?;
    atomic_write(
        &p,
        &format!(
            "[Unit]\nDescription=chatmux relay\n[Service]\nExecStart={} --no-onboard --config {}\nRestart=on-failure\nRestartSec=5\n[Install]\nWantedBy=default.target\n",
            systemd_quote(x),
            systemd_quote(c)
        ),
    )?;
    run("systemctl", &["--user", "daemon-reload"])?;
    run("systemctl", &["--user", "enable", "--now", "chatmux-relay.service"])?;
    Ok(format!("installed {}", p.display()))
}
#[cfg(target_os = "windows")]
fn install_impl(e: &Path, config: &Path) -> Result<String, String> {
    let x = e.to_str().ok_or("executable path is not valid UTF-8")?;
    let c = config.to_str().ok_or("config path is not valid UTF-8")?;
    run(
        "schtasks",
        &[
            "/Create",
            "/F",
            "/SC",
            "ONLOGON",
            "/TN",
            LABEL,
            "/TR",
            &format!("\"{}\" --no-onboard --config \"{}\"", x, c),
        ],
    )?;
    run("schtasks", &["/Run", "/TN", LABEL])?;
    Ok(format!("installed Windows task {LABEL}"))
}
#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn install_impl(_: &Path, _: &Path) -> Result<String, String> {
    Err("autostart is unsupported on this platform".into())
}
pub fn install(e: &Path, config: &Path) -> Result<String, String> {
    validate_autostart_executable(e)?;
    install_impl(e, config)
}
#[cfg(target_os = "macos")]
fn uninstall_impl() -> Result<String, String> {
    let p = home()?.join("Library/LaunchAgents").join(format!("{LABEL}.plist"));
    let d = format!("gui/{}", unsafe { libc::getuid() });
    if let Some(s) = p.to_str() {
        let _ = run("launchctl", &["bootout", &d, s]);
    }
    if let Err(e) = fs::remove_file(&p)
        && !matches!(e.kind(), std::io::ErrorKind::NotFound)
    {
        return Err(e.to_string());
    }
    Ok(format!("removed {}", p.display()))
}

#[cfg(target_os = "linux")]
fn uninstall_impl() -> Result<String, String> {
    let p = home()?.join(".config/systemd/user/chatmux-relay.service");
    let _ = run("systemctl", &["--user", "disable", "--now", "chatmux-relay.service"]);
    if let Err(e) = fs::remove_file(&p)
        && e.kind() != std::io::ErrorKind::NotFound
    {
        return Err(e.to_string());
    }
    let _ = run("systemctl", &["--user", "daemon-reload"]);
    Ok(format!("removed {}", p.display()))
}

#[cfg(target_os = "windows")]
fn uninstall_impl() -> Result<String, String> {
    let _ = run("schtasks", &["/Delete", "/F", "/TN", LABEL]);
    Ok(format!("removed Windows task {LABEL}"))
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn uninstall_impl() -> Result<String, String> {
    Err("autostart is unsupported on this platform".into())
}

pub fn uninstall() -> Result<String, String> {
    uninstall_impl()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[cfg(target_os = "macos")]
    fn escapes() {
        assert_eq!(xml_escape("a<&\"' >"), "a&lt;&amp;&quot;&apos; &gt;");
    }
    #[test]
    #[cfg(target_os = "linux")]
    fn quotes_systemd_execstart_arguments() {
        assert_eq!(
            systemd_quote("/tmp/a'b with\\slash\"quote"),
            "\"/tmp/a'b with\\\\slash\\\"quote\""
        );
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn quotes_systemd_percent_specifiers_as_literal_path_bytes() {
        assert_eq!(
            systemd_quote("/tmp/relay%2Fbin/config%name"),
            "\"/tmp/relay%%2Fbin/config%%name\""
        );
    }

    #[test]
    fn rejects_npx_cache_paths_but_allows_persistent_installs() {
        assert!(is_ephemeral_npx_path(Path::new(
            "/Users/example/.npm/_npx/4f3/node_modules/cmux-relay-darwin-arm64/bin/chatmux-relay",
        )));
        assert!(is_ephemeral_npx_path(Path::new(
            r"C:\\Users\\example\\AppData\\Local\\npm-cache\\_npx\\4f3\\node_modules\\cmux-relay-win32-x64\\bin\\chatmux-relay.exe",
        )));
        assert!(!is_ephemeral_npx_path(Path::new(
            "/usr/local/lib/node_modules/cmux-relay-linux-x64/bin/chatmux-relay",
        )));
        assert!(!is_ephemeral_npx_path(Path::new(
            "/work/project/node_modules/cmux-relay-linux-x64/bin/chatmux-relay",
        )));
    }

    #[test]
    fn npx_autostart_refusal_explains_the_durable_install_requirement() {
        let error = validate_autostart_executable(Path::new("/tmp/_npx/abc/bin/chatmux-relay"))
            .expect_err("ephemeral npx path must be refused");
        assert!(error.contains("durable relay executable"));
        assert!(error.contains("npm install --global cmux-relay"));
    }
}
