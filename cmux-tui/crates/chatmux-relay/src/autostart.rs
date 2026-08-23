//! Per-user autostart integration for the relay.
use std::fs;
use std::path::{Path, PathBuf};

const LABEL: &str = "dev.chatmux.relay";

fn home() -> Result<PathBuf, String> {
    std::env::var_os("HOME").map(PathBuf::from).ok_or_else(|| "HOME is not set".to_owned())
}

fn xml_escape(value: &str) -> String {
    value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

fn write_private(path: &Path, body: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() { fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?; }
    fs::write(path, body).map_err(|e| format!("write {}: {e}", path.display()))?;
    #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|e| format!("chmod {}: {e}", path.display()))?; }
    Ok(())
}

#[cfg(target_os = "macos")]
fn install_impl(exe: &Path) -> Result<String, String> {
    let path = home()?.join("Library/LaunchAgents").join(format!("{LABEL}.plist"));
    let body = format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>Label</key><string>{LABEL}</string><key>ProgramArguments</key><array><string>{}</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>\n", xml_escape(&exe.to_string_lossy()));
    write_private(&path, &body)?;
    Ok(format!("installed {path:?}"))
}

#[cfg(target_os = "linux")]
fn install_impl(exe: &Path) -> Result<String, String> {
    let path = home()?.join(".config/systemd/user/chatmux-relay.service");
    let body = format!("[Unit]\nDescription=chatmux relay\n[Service]\nExecStart={}\nRestart=always\n[Install]\nWantedBy=default.target\n", exe.to_string_lossy().replace('%', "%%"));
    write_private(&path, &body)?;
    Ok(format!("installed {path:?}; run systemctl --user enable --now chatmux-relay.service"))
}

#[cfg(target_os = "windows")]
fn install_impl(_: &Path) -> Result<String, String> { Err("Windows autostart is not supported by this build (schtasks integration is pending).".to_owned()) }

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn install_impl(_: &Path) -> Result<String, String> { Err("autostart is unsupported on this platform".to_owned()) }

pub fn install(exe: &Path) -> Result<String, String> { install_impl(exe) }

pub fn uninstall() -> Result<String, String> {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    { let path = if cfg!(target_os = "macos") { home()?.join("Library/LaunchAgents").join(format!("{LABEL}.plist")) } else { home()?.join(".config/systemd/user/chatmux-relay.service") }; match fs::remove_file(&path) { Ok(()) | Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(format!("removed {}", path.display())), Err(e) => Err(format!("remove {}: {e}", path.display())) } }
    #[cfg(target_os = "windows")] { Err("Windows autostart is not supported by this build (schtasks integration is pending).".to_owned()) }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))] { Err("autostart is unsupported on this platform".to_owned()) }
}

#[cfg(test)]
mod tests { use super::*; #[test] fn escapes_xml() { assert_eq!(xml_escape("a<&\"' >"), "a&lt;&amp;&quot;&apos; &gt;"); } }
