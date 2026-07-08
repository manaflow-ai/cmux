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
    pub binary: PathBuf,
    pub mode: BrowserMode,
    pub user_data_dir: Option<PathBuf>,
    pub ephemeral: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum BrowserMode {
    #[default]
    Headful,
    Headless,
}

/// A launched Chrome/Chromium process plus its profile dir.
pub struct Chrome {
    child: Mutex<Option<Child>>,
    profile_dir: PathBuf,
    profile_ephemeral: bool,
    web_socket_url: String,
}

impl Chrome {
    /// Launch Chrome (headful by default, headless when the launch
    /// options request it) and wait for the browser CDP endpoint printed
    /// on stderr.
    pub fn launch(binary: PathBuf) -> anyhow::Result<Self> {
        Chrome::launch_with(ChromeLaunchOptions {
            binary,
            mode: BrowserMode::default(),
            user_data_dir: None,
            ephemeral: true,
        })
    }

    pub fn launch_with(options: ChromeLaunchOptions) -> anyhow::Result<Self> {
        let (profile_dir, profile_ephemeral) = profile_dir_for(&options)?;
        std::fs::create_dir_all(&profile_dir)?;
        let mut command = Command::new(&options.binary);
        command.args(chrome_args_for(&profile_dir, options.mode));
        let mut child = command
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

fn chrome_args_for(profile_dir: &Path, mode: BrowserMode) -> Vec<String> {
    let mut args = Vec::new();
    if mode == BrowserMode::Headless {
        args.push("--headless=new".to_string());
    }
    args.extend([
        "--remote-debugging-port=0".to_string(),
        "--no-first-run".to_string(),
        "--no-default-browser-check".to_string(),
        "--disable-background-timer-throttling".to_string(),
        "--disable-backgrounding-occluded-windows".to_string(),
        "--disable-renderer-backgrounding".to_string(),
        "--disable-blink-features=AutomationControlled".to_string(),
        format!("--user-data-dir={}", profile_dir.display()),
    ]);
    if mode == BrowserMode::Headful {
        args.push("--window-size=1280,900".to_string());
    }
    args.push("about:blank".to_string());
    args
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
            mode: BrowserMode::Headful,
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
            mode: BrowserMode::Headful,
            user_data_dir: Some(explicit_dir.clone()),
            ephemeral: false,
        };
        let (selected, ephemeral) = profile_dir_for(&options).unwrap();

        assert!(!ephemeral);
        assert_eq!(selected, explicit_dir);
    }

    #[test]
    fn headful_args_omit_headless_and_keep_stealth_throttle_profile_window() {
        let profile = PathBuf::from("/tmp/cmux profile");
        let args = chrome_args_for(&profile, BrowserMode::Headful);

        assert!(!args.iter().any(|arg| arg == "--headless=new"));
        assert!(args.iter().any(|arg| arg == "--remote-debugging-port=0"));
        assert!(args.iter().any(|arg| arg == "--no-first-run"));
        assert!(args.iter().any(|arg| arg == "--no-default-browser-check"));
        assert!(args.iter().any(|arg| arg == "--disable-background-timer-throttling"));
        assert!(args.iter().any(|arg| arg == "--disable-backgrounding-occluded-windows"));
        assert!(args.iter().any(|arg| arg == "--disable-renderer-backgrounding"));
        assert!(args.iter().any(|arg| arg == "--disable-blink-features=AutomationControlled"));
        assert!(args.iter().any(|arg| arg == "--user-data-dir=/tmp/cmux profile"));
        assert!(args.iter().any(|arg| arg == "--window-size=1280,900"));
        assert_eq!(args.last().map(String::as_str), Some("about:blank"));
    }

    #[test]
    fn headless_args_add_headless_and_omit_window_size() {
        let profile = PathBuf::from("/tmp/cmux-profile");
        let args = chrome_args_for(&profile, BrowserMode::Headless);

        assert!(args.iter().any(|arg| arg == "--headless=new"));
        assert!(args.iter().any(|arg| arg == "--disable-blink-features=AutomationControlled"));
        assert!(args.iter().any(|arg| arg == "--user-data-dir=/tmp/cmux-profile"));
        assert!(!args.iter().any(|arg| arg == "--window-size=1280,900"));
        assert_eq!(args.last().map(String::as_str), Some("about:blank"));
    }
}
