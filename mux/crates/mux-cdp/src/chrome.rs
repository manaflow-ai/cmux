use std::ffi::OsString;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static PROFILE_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone)]
pub struct ChromeLaunchOptions {
    pub binary: PathBuf,
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
    pub fn launch(binary: PathBuf) -> anyhow::Result<Self> {
        Chrome::launch_with(&ChromeLaunchOptions { binary, user_data_dir: None, ephemeral: true })
    }

    pub fn launch_with(options: &ChromeLaunchOptions) -> anyhow::Result<Self> {
        let (profile_dir, profile_ephemeral) = profile_dir_for(options)?;
        std::fs::create_dir_all(&profile_dir)?;
        let mut child = Command::new(&options.binary)
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
            .map_err(|e| {
                anyhow::anyhow!("failed to launch Chrome at {}: {e}", options.binary.display())
            })?;

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
                        if !sent && let Some(url) = parse_devtools_url(&line) {
                            let _ = tx.send(url);
                            sent = true;
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
                    options.binary.display()
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
    anyhow::bail!("ChromeLaunchOptions.user_data_dir is required when ephemeral is false")
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
            binary: PathBuf::from("chrome"),
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

    #[test]
    fn explicit_profile_dir_is_used_verbatim() {
        let explicit_dir =
            std::env::temp_dir().join(format!("cmux-mux-cdp-verbatim-{}", std::process::id()));
        let options = ChromeLaunchOptions {
            binary: PathBuf::from("chrome"),
            user_data_dir: Some(explicit_dir.clone()),
            ephemeral: false,
        };
        let (selected, ephemeral) = profile_dir_for(&options).unwrap();

        assert!(!ephemeral);
        assert_eq!(selected, explicit_dir);
    }
}
