use std::ffi::OsString;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static PROFILE_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone)]
pub struct ChromeLaunchOptions {
    pub binary: Option<String>,
    pub user_data_dir: Option<PathBuf>,
    pub ephemeral: bool,
}

/// A launched Chrome/Chromium process plus its profile dir.
pub struct Chrome {
    child: Mutex<Option<Child>>,
    profile_dir: PathBuf,
    profile_ephemeral: bool,
    web_socket_url: String,
}

impl Chrome {
    /// Launch Chrome in headless mode and wait for the browser CDP
    /// endpoint printed on stderr.
    pub fn launch(explicit_binary: Option<&str>) -> anyhow::Result<Self> {
        Chrome::launch_with(ChromeLaunchOptions {
            binary: explicit_binary.map(str::to_string),
            user_data_dir: None,
            ephemeral: true,
        })
    }

    pub fn launch_with(options: ChromeLaunchOptions) -> anyhow::Result<Self> {
        let binary = find_chrome_binary(options.binary.as_deref())?;
        let (profile_dir, profile_ephemeral) = profile_dir_for(&options)?;
        std::fs::create_dir_all(&profile_dir)?;
        let mut child = Command::new(&binary)
            .arg("--headless=new")
            .arg("--remote-debugging-port=0")
            .arg("--no-first-run")
            .arg("--no-default-browser-check")
            .arg("--disable-background-timer-throttling")
            .arg("--disable-backgrounding-occluded-windows")
            .arg("--disable-renderer-backgrounding")
            .arg(format!("--user-data-dir={}", profile_dir.display()))
            .arg("about:blank")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| anyhow::anyhow!("failed to launch Chrome at {}: {e}", binary.display()))?;

        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| anyhow::anyhow!("failed to capture Chrome stderr"))?;
        let (tx, rx) = mpsc::channel();
        std::thread::Builder::new().name("mux-cdp-chrome-stderr".into()).spawn(move || {
            let mut reader = BufReader::new(stderr);
            let mut line = String::new();
            let mut sent = false;
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        if !sent {
                            if let Some(url) = parse_devtools_url(&line) {
                                let _ = tx.send(url);
                                sent = true;
                            }
                        }
                    }
                }
            }
        })?;

        let web_socket_url = match rx.recv_timeout(Duration::from_secs(10)) {
            Ok(url) => url,
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                if profile_ephemeral {
                    let _ = std::fs::remove_dir_all(&profile_dir);
                }
                anyhow::bail!(
                    "Chrome did not publish a DevTools endpoint within 10s (binary: {})",
                    binary.display()
                );
            }
        };

        Ok(Chrome {
            child: Mutex::new(Some(child)),
            profile_dir,
            profile_ephemeral,
            web_socket_url,
        })
    }

    pub fn web_socket_url(&self) -> &str {
        &self.web_socket_url
    }

    pub fn kill(&self) {
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl Drop for Chrome {
    fn drop(&mut self) {
        self.kill();
        if self.profile_ephemeral {
            let _ = std::fs::remove_dir_all(&self.profile_dir);
        }
    }
}

/// Locate a Chrome-family binary. The explicit config path wins; then
/// well-known app locations; then PATH.
pub fn find_chrome_binary(explicit: Option<&str>) -> anyhow::Result<PathBuf> {
    if let Some(path) = explicit.filter(|s| !s.trim().is_empty()) {
        let path = PathBuf::from(path);
        if is_executable_file(&path) {
            return Ok(path);
        }
        anyhow::bail!(
            "configured browser.chrome_binary does not point to an executable file: {}",
            path.display()
        );
    }

    for path in known_binary_paths() {
        if is_executable_file(&path) {
            return Ok(path);
        }
    }

    for name in ["google-chrome", "chromium", "chromium-browser", "brave-browser", "microsoft-edge"]
    {
        if let Some(path) = find_on_path(name) {
            return Ok(path);
        }
    }

    anyhow::bail!(
        "no Chrome/Chromium binary found; set browser.chrome_binary in ~/.config/cmux/mux.json"
    )
}

fn known_binary_paths() -> Vec<PathBuf> {
    vec![
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome".into(),
        "/Applications/Chromium.app/Contents/MacOS/Chromium".into(),
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser".into(),
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge".into(),
        "/usr/bin/google-chrome".into(),
        "/usr/bin/chromium".into(),
        "/usr/bin/chromium-browser".into(),
        "/snap/bin/chromium".into(),
        "/usr/bin/brave-browser".into(),
        "/usr/bin/microsoft-edge".into(),
    ]
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|dir| dir.join(name)).find(|p| is_executable_file(p))
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else { return false };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn make_profile_dir() -> anyhow::Result<PathBuf> {
    let seq = PROFILE_SEQ.fetch_add(1, Ordering::Relaxed);
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis();
    let mut name = OsString::from("cmux-mux-cdp-");
    name.push(std::process::id().to_string());
    name.push("-");
    name.push(now.to_string());
    name.push("-");
    name.push(seq.to_string());
    let dir = std::env::temp_dir().join(name);
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn profile_dir_for(options: &ChromeLaunchOptions) -> anyhow::Result<(PathBuf, bool)> {
    if options.ephemeral {
        return Ok((make_profile_dir()?, true));
    }
    if let Some(dir) = options.user_data_dir.clone() {
        return Ok((dir, false));
    }
    Ok((default_user_data_dir()?, false))
}

pub fn default_user_data_dir() -> anyhow::Result<PathBuf> {
    if cfg!(target_os = "macos") {
        let home = std::env::var("HOME")?;
        return Ok(PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("cmux-mux")
            .join("chrome-profile"));
    }
    if let Some(data_home) = std::env::var_os("XDG_DATA_HOME") {
        return Ok(PathBuf::from(data_home).join("cmux-mux").join("chrome-profile"));
    }
    let home = std::env::var("HOME")?;
    Ok(PathBuf::from(home).join(".local/share/cmux-mux/chrome-profile"))
}

fn parse_devtools_url(line: &str) -> Option<String> {
    let marker = "DevTools listening on ";
    let idx = line.find(marker)?;
    Some(line[idx + marker.len()..].trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_devtools_endpoint() {
        assert_eq!(
            parse_devtools_url("DevTools listening on ws://127.0.0.1:1/devtools/browser/x\n"),
            Some("ws://127.0.0.1:1/devtools/browser/x".to_string())
        );
        assert_eq!(parse_devtools_url("other"), None);
    }

    #[test]
    fn ephemeral_profile_ignores_configured_user_data_dir() {
        let explicit_dir =
            std::env::temp_dir().join(format!("cmux-mux-cdp-explicit-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&explicit_dir);
        std::fs::create_dir_all(&explicit_dir).unwrap();
        let sentinel = explicit_dir.join("keep");
        std::fs::write(&sentinel, b"keep").unwrap();

        let options = ChromeLaunchOptions {
            binary: None,
            user_data_dir: Some(explicit_dir.clone()),
            ephemeral: true,
        };
        let (selected, ephemeral) = profile_dir_for(&options).unwrap();
        assert!(ephemeral);
        assert_ne!(selected, explicit_dir);

        let _ = std::fs::remove_dir_all(&selected);
        assert!(sentinel.exists());
        let _ = std::fs::remove_dir_all(&explicit_dir);
    }
}
