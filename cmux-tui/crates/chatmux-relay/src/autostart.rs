//! Per-user autostart integration for the relay.
use std::{fs, path::{Path, PathBuf}, process::Command as ProcessCommand};
const LABEL: &str = "dev.chatmux.relay";
fn home() -> Result<PathBuf,String> { std::env::var_os("HOME").map(PathBuf::from).ok_or_else(|| "HOME is not set".into()) }
fn xml_escape(v:&str)->String { v.replace('&',"&amp;").replace('<',"&lt;").replace('>',"&gt;").replace('"',"&quot;").replace('\'',"&apos;") }
fn atomic_write(path:&Path, body:&str)->Result<(),String> { let p=path.parent().ok_or("autostart path has no parent")?; fs::create_dir_all(p).map_err(|e|e.to_string())?; let t=path.with_extension("tmp"); fs::write(&t,body).map_err(|e|e.to_string())?; #[cfg(unix)] { use std::os::unix::fs::PermissionsExt; fs::set_permissions(&t,fs::Permissions::from_mode(0o600)).map_err(|e|e.to_string())?; } fs::rename(t,path).map_err(|e|e.to_string()) }
fn run(p:&str,a:&[&str])->Result<(),String>{let s=ProcessCommand::new(p).args(a).status().map_err(|e|format!("run {p}: {e}"))?; if s.success(){Ok(())}else{Err(format!("{p} failed with {s}"))}}
#[cfg(target_os="macos")]
fn install_impl(exe:&Path)->Result<String,String>{let path=home()?.join("Library/LaunchAgents").join(format!("{LABEL}.plist"));let body=format!("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>{LABEL}</string><key>ProgramArguments</key><array><string>{}</string><string>--no-onboard</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>\n",xml_escape(&exe.to_string_lossy()));atomic_write(&path,&body)?;let d=format!("gui/{}",unsafe{libc::getuid()});run("launchctl",&["bootout",&d,path.to_str().unwrap_or("")]).ok();run("launchctl",&["bootstrap",&d,path.to_str().unwrap_or("")])?;Ok(format!("installed {}",path.display()))}
#[cfg(target_os="linux")]
fn install_impl(exe:&Path)->Result<String,String>{let path=home()?.join(".config/systemd/user/chatmux-relay.service");let body=format!("[Unit]\nDescription=chatmux relay\n[Service]\nExecStart={} --no-onboard\nRestart=always\n[Install]\nWantedBy=default.target\n",exe.to_string_lossy().replace('%',"%%"));atomic_write(&path,&body)?;run("systemctl",&["--user","daemon-reload"])?;run("systemctl",&["--user","enable","--now","chatmux-relay.service"])?;Ok(format!("installed {}",path.display()))}
#[cfg(target_os="windows")] fn install_impl(_: &Path)->Result<String,String>{Err("Windows autostart is unsupported by this build.".into())}
#[cfg(not(any(target_os="macos",target_os="linux",target_os="windows")))] fn install_impl(_: &Path)->Result<String,String>{Err("autostart is unsupported on this platform".into())}
pub fn install(exe:&Path)->Result<String,String>{install_impl(exe)}
pub fn uninstall()->Result<String,String>{
    #[cfg(target_os="macos")] {let p=home()?.join("Library/LaunchAgents").join(format!("{LABEL}.plist"));let d=format!("gui/{}",unsafe{libc::getuid()});run("launchctl",&["bootout",&d,p.to_str().unwrap_or("")]).ok();if let Err(e)=fs::remove_file(&p){if e.kind()!=std::io::ErrorKind::NotFound{return Err(e.to_string())}}return Ok(format!("removed {}",p.display()));}
    #[cfg(target_os="linux")] {let p=home()?.join(".config/systemd/user/chatmux-relay.service");run("systemctl",&["--user","disable","--now","chatmux-relay.service"]).ok();if let Err(e)=fs::remove_file(&p){if e.kind()!=std::io::ErrorKind::NotFound{return Err(e.to_string())}}run("systemctl",&["--user","daemon-reload"]).ok();return Ok(format!("removed {}",p.display()));}
    #[cfg(target_os="windows")] {Err("Windows autostart is unsupported by this build.".into())}
    #[cfg(not(any(target_os="macos",target_os="linux",target_os="windows")))] {Err("autostart is unsupported on this platform".into())}
}
#[cfg(test)] mod tests {use super::*;#[test]fn escapes(){assert_eq!(xml_escape("a<&\"' >"),"a&lt;&amp;&quot;&apos; &gt;");}}
