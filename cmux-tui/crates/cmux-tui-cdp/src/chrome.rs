use std::ffi::OsString;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
#[cfg(test)]
use std::sync::atomic::AtomicBool;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

static PROFILE_SEQ: AtomicU64 = AtomicU64::new(1);
static CHROME_REAPER: OnceLock<Mutex<Option<ChromeReaper>>> = OnceLock::new();
const REAPER_CAPACITY: usize = 4_096;
const REAPER_INITIAL_BACKOFF: Duration = Duration::from_millis(10);
const REAPER_MAX_BACKOFF: Duration = Duration::from_secs(1);

#[cfg(test)]
static FORCE_REAPER_PENDING: AtomicBool = AtomicBool::new(false);
#[cfg(test)]
static FORCE_REAPER_WAIT_ERROR: AtomicBool = AtomicBool::new(false);
#[cfg(test)]
static REAPER_POLL_ATTEMPTS: AtomicUsize = AtomicUsize::new(0);
#[cfg(test)]
static REAPER_TEST_LOCK: Mutex<()> = Mutex::new(());

#[cfg(test)]
thread_local! {
    static FORCE_KILL_TIMEOUT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static FORCE_REAPER_SPAWN_FAILURE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static REAP_CHILD_CALLED_ON_THREAD: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

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
    reaper: Option<ChromeReaperLease>,
}

impl Chrome {
    /// Launch Chrome (headful by default, headless when the launch
    /// options request it) and wait for the browser CDP endpoint printed
    /// on stderr.
    pub fn launch(binary: PathBuf) -> anyhow::Result<Self> {
        Chrome::launch_with(&ChromeLaunchOptions {
            binary,
            mode: BrowserMode::default(),
            user_data_dir: None,
            ephemeral: true,
        })
    }

    pub fn launch_with(options: &ChromeLaunchOptions) -> anyhow::Result<Self> {
        // Browser shutdown must never depend on creating a new thread. Refuse
        // to launch the child until the process-wide reaper owns a worker and
        // has reserved bounded cleanup capacity for this exact process.
        let reaper = chrome_reaper_lease().map_err(|error| {
            anyhow::anyhow!("cannot launch Chrome without bounded cleanup ownership: {error}")
        })?;
        let (profile_dir, profile_ephemeral) = profile_dir_for(options)?;
        std::fs::create_dir_all(&profile_dir)?;
        let mut command = Command::new(&options.binary);
        command
            .args(chrome_args_for(&profile_dir, options.mode))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        let mut child = cmux_tui_process::spawn(&mut command).map_err(|e| {
            anyhow::anyhow!("failed to launch Chrome at {}: {e}", options.binary.display())
        })?;

        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| anyhow::anyhow!("failed to capture Chrome stderr"))?;
        let (tx, rx) = mpsc::channel();
        let stderr_worker = std::thread::Builder::new()
            .name("cmux-tui-cdp-chrome-stderr".into())
            .spawn(move || {
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
            });
        if let Err(error) = stderr_worker {
            if kill_child_until(&mut child, Instant::now() + Duration::from_secs(1)) {
                if profile_ephemeral {
                    let _ = std::fs::remove_dir_all(&profile_dir);
                }
            } else {
                reap_child_detached(reaper, child, profile_ephemeral.then(|| profile_dir.clone()));
            }
            return Err(error.into());
        }

        let web_socket_url = match rx.recv_timeout(Duration::from_secs(10)) {
            Ok(url) => url,
            Err(_) => {
                if kill_child_until(&mut child, Instant::now() + Duration::from_secs(1)) {
                    if profile_ephemeral {
                        let _ = std::fs::remove_dir_all(&profile_dir);
                    }
                } else {
                    reap_child_detached(
                        reaper,
                        child,
                        profile_ephemeral.then(|| profile_dir.clone()),
                    );
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
            reaper: Some(reaper),
        })
    }

    pub fn web_socket_url(&self) -> &str {
        &self.web_socket_url
    }

    pub fn kill(&self) {
        let _ = self.kill_until(Instant::now() + Duration::from_secs(1));
    }

    pub fn kill_until(&self, deadline: Instant) -> bool {
        let mut slot = self.child.lock().unwrap();
        let Some(mut child) = slot.take() else { return true };
        drop(slot);
        if kill_child_until(&mut child, deadline) {
            return true;
        }
        *self.child.lock().unwrap() = Some(child);
        false
    }
}

impl Drop for Chrome {
    fn drop(&mut self) {
        if self.kill_until(Instant::now() + Duration::from_secs(1)) {
            if self.profile_ephemeral {
                let _ = std::fs::remove_dir_all(&self.profile_dir);
            }
            return;
        }
        let child = self.child.get_mut().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
        if let Some(child) = child {
            reap_child_detached(
                self.reaper.take().expect("live Chrome retains its reaper lease"),
                child,
                self.profile_ephemeral.then(|| self.profile_dir.clone()),
            );
        } else if self.profile_ephemeral {
            let _ = std::fs::remove_dir_all(&self.profile_dir);
        }
    }
}

struct ReapRequest {
    child: Child,
    profile_dir: Option<PathBuf>,
    _lease: ChromeReaperLease,
    next_attempt: Instant,
    retry_delay: Duration,
}

struct ChromeReaperLease {
    sender: mpsc::Sender<ReapRequest>,
    active: Arc<AtomicUsize>,
}

impl Drop for ChromeReaperLease {
    fn drop(&mut self) {
        self.active.fetch_sub(1, Ordering::AcqRel);
    }
}

struct ChromeReaper {
    sender: mpsc::Sender<ReapRequest>,
    active: Arc<AtomicUsize>,
    _worker: JoinHandle<()>,
}

impl ChromeReaper {
    fn start() -> std::io::Result<Self> {
        let (sender, receiver) = mpsc::channel();
        let worker = spawn_reaper_worker(receiver)?;
        Ok(Self { sender, active: Arc::new(AtomicUsize::new(0)), _worker: worker })
    }

    fn lease(&self) -> std::io::Result<ChromeReaperLease> {
        reserve_reaper_lease(self.sender.clone(), self.active.clone(), REAPER_CAPACITY)
    }
}

fn spawn_reaper_worker(receiver: mpsc::Receiver<ReapRequest>) -> std::io::Result<JoinHandle<()>> {
    #[cfg(test)]
    let force_spawn_failure = FORCE_REAPER_SPAWN_FAILURE.get();
    #[cfg(not(test))]
    let force_spawn_failure = false;
    if force_spawn_failure {
        return Err(std::io::Error::other("forced Chrome reaper spawn failure"));
    }
    std::thread::Builder::new()
        .name("cmux-tui-cdp-chrome-reaper".into())
        .spawn(move || run_reaper(receiver))
}

fn reserve_reaper_lease(
    sender: mpsc::Sender<ReapRequest>,
    active: Arc<AtomicUsize>,
    capacity: usize,
) -> std::io::Result<ChromeReaperLease> {
    active
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |current| {
            (current < capacity).then_some(current + 1)
        })
        .map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::WouldBlock, "Chrome reaper capacity exhausted")
        })?;
    Ok(ChromeReaperLease { sender, active })
}

fn chrome_reaper_lease() -> std::io::Result<ChromeReaperLease> {
    let mut slot = CHROME_REAPER.get_or_init(|| Mutex::new(None)).lock().unwrap();
    if slot.is_none() {
        *slot = Some(ChromeReaper::start()?);
    }
    slot.as_ref().expect("Chrome reaper initialized").lease()
}

fn reap_child_detached(reaper: ChromeReaperLease, child: Child, profile_dir: Option<PathBuf>) {
    let sender = reaper.sender.clone();
    sender
        .send(ReapRequest {
            child,
            profile_dir,
            _lease: reaper,
            next_attempt: Instant::now(),
            retry_delay: REAPER_INITIAL_BACKOFF,
        })
        .expect("Chrome reaper worker remains alive while its service is registered");
}

fn run_reaper(receiver: mpsc::Receiver<ReapRequest>) {
    let mut pending: Vec<ReapRequest> = Vec::new();
    loop {
        let received = if pending.is_empty() {
            receiver.recv().map_err(|_| mpsc::RecvTimeoutError::Disconnected)
        } else {
            let now = Instant::now();
            let wait = pending
                .iter()
                .map(|request| request.next_attempt.saturating_duration_since(now))
                .min()
                .unwrap_or(REAPER_MAX_BACKOFF);
            receiver.recv_timeout(wait)
        };
        match received {
            Ok(request) => pending.push(request),
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) if pending.is_empty() => return,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                std::thread::sleep(REAPER_MAX_BACKOFF);
            }
        }
        while let Ok(request) = receiver.try_recv() {
            pending.push(request);
        }
        let now = Instant::now();
        pending.retain_mut(|request| {
            if request.next_attempt > now {
                return true;
            }
            if poll_reap_request(request) {
                return false;
            }
            request.next_attempt = now + request.retry_delay;
            request.retry_delay = (request.retry_delay * 2).min(REAPER_MAX_BACKOFF);
            true
        });
    }
}

fn poll_reap_request(request: &mut ReapRequest) -> bool {
    #[cfg(test)]
    REAP_CHILD_CALLED_ON_THREAD.set(true);
    #[cfg(test)]
    {
        REAPER_POLL_ATTEMPTS.fetch_add(1, Ordering::Relaxed);
        if FORCE_REAPER_WAIT_ERROR.load(Ordering::Acquire) {
            let _ = request.child.kill();
            return false;
        }
        if FORCE_REAPER_PENDING.load(Ordering::Acquire) {
            return false;
        }
    }
    let _ = request.child.kill();
    match request.child.try_wait() {
        Ok(Some(_)) => {}
        Ok(None) | Err(_) => return false,
    }
    if let Some(profile_dir) = request.profile_dir.take() {
        let _ = std::fs::remove_dir_all(profile_dir);
    }
    true
}

fn kill_child_until(child: &mut Child, deadline: Instant) -> bool {
    let _ = child.kill();
    #[cfg(test)]
    if FORCE_KILL_TIMEOUT.get() {
        return false;
    }
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return true,
            Ok(None) => {}
            Err(_) => return false,
        }
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            return false;
        };
        std::thread::sleep(remaining.min(Duration::from_millis(10)));
    }
}

fn make_profile_dir() -> anyhow::Result<PathBuf> {
    let seq = PROFILE_SEQ.fetch_add(1, Ordering::Relaxed);
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis();
    let mut name = OsString::from("cmux-tui-cdp-");
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
            std::env::temp_dir().join(format!("cmux-tui-cdp-explicit-{}", std::process::id()));
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
            std::env::temp_dir().join(format!("cmux-tui-cdp-verbatim-{}", std::process::id()));
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

    #[test]
    fn kill_until_confirms_the_owned_process_within_its_deadline() {
        let child = Command::new("sleep")
            .arg("60")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let profile_dir = make_profile_dir().unwrap();
        let chrome = Chrome {
            child: Mutex::new(Some(child)),
            profile_dir,
            profile_ephemeral: true,
            web_socket_url: "ws://127.0.0.1/unused".to_string(),
            reaper: Some(chrome_reaper_lease().unwrap()),
        };

        assert!(chrome.kill_until(Instant::now() + Duration::from_secs(1)));
        assert!(chrome.child.lock().unwrap().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn drop_transfers_an_unconfirmed_child_to_a_reaper() {
        let _guard = REAPER_TEST_LOCK.lock().unwrap();
        unsafe extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
            fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
        }

        let child = Command::new("sleep")
            .arg("60")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let pid = i32::try_from(child.id()).unwrap();
        let chrome = Chrome {
            child: Mutex::new(Some(child)),
            profile_dir: make_profile_dir().unwrap(),
            profile_ephemeral: true,
            web_socket_url: "ws://127.0.0.1/unused".to_string(),
            reaper: Some(chrome_reaper_lease().unwrap()),
        };

        FORCE_KILL_TIMEOUT.set(true);
        drop(chrome);
        FORCE_KILL_TIMEOUT.set(false);
        let deadline = Instant::now() + Duration::from_secs(1);
        let reaped = loop {
            if unsafe { kill(pid, 0) } != 0 {
                break true;
            }
            if Instant::now() >= deadline {
                break false;
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        if !reaped {
            let mut status = 0;
            unsafe {
                waitpid(pid, &mut status, 0);
            }
        }

        assert!(reaped, "dropping Chrome discarded an unconfirmed child without reaping it");
    }

    #[cfg(unix)]
    #[test]
    fn reaper_spawn_failure_never_waits_on_the_caller_thread() {
        let _guard = REAPER_TEST_LOCK.lock().unwrap();
        let child = Command::new("sleep")
            .arg("60")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let reaper = chrome_reaper_lease().unwrap();
        let chrome = Chrome {
            child: Mutex::new(Some(child)),
            profile_dir: make_profile_dir().unwrap(),
            profile_ephemeral: true,
            web_socket_url: "ws://127.0.0.1/unused".to_string(),
            reaper: Some(reaper),
        };

        REAP_CHILD_CALLED_ON_THREAD.set(false);
        FORCE_KILL_TIMEOUT.set(true);
        FORCE_REAPER_SPAWN_FAILURE.set(true);
        drop(chrome);
        FORCE_REAPER_SPAWN_FAILURE.set(false);
        FORCE_KILL_TIMEOUT.set(false);
        let reaped_inline = REAP_CHILD_CALLED_ON_THREAD.get();

        let cleanup = Command::new("true").spawn().unwrap();
        reap_child_detached(chrome_reaper_lease().unwrap(), cleanup, None);

        assert!(!reaped_inline, "reaper spawn failure fell back to an unbounded caller wait");
    }

    #[cfg(unix)]
    #[test]
    fn final_reaper_request_survives_a_shutdown_thread_spawn_failure() {
        let _guard = REAPER_TEST_LOCK.lock().unwrap();
        unsafe extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
            fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
        }

        let warmup = Command::new("true").spawn().unwrap();
        reap_child_detached(chrome_reaper_lease().unwrap(), warmup, None);

        let child = Command::new("sleep")
            .arg("60")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let pid = i32::try_from(child.id()).unwrap();
        let profile_dir = make_profile_dir().unwrap();

        FORCE_REAPER_SPAWN_FAILURE.set(true);
        reap_child_detached(chrome_reaper_lease().unwrap(), child, Some(profile_dir.clone()));
        FORCE_REAPER_SPAWN_FAILURE.set(false);

        let deadline = Instant::now() + Duration::from_secs(1);
        let cleaned = loop {
            if unsafe { kill(pid, 0) } != 0 && !profile_dir.exists() {
                break true;
            }
            if Instant::now() >= deadline {
                break false;
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        if !cleaned {
            let mut status = 0;
            unsafe {
                kill(pid, 9);
                waitpid(pid, &mut status, 0);
            }
            let _ = std::fs::remove_dir_all(&profile_dir);
        }

        assert!(cleaned, "the final Chrome cleanup remained parked until another browser shutdown");
    }

    #[cfg(unix)]
    #[test]
    fn persistent_reaper_backs_off_unconfirmed_children() {
        let _guard = REAPER_TEST_LOCK.lock().unwrap();
        unsafe extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
            fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
        }

        let child = Command::new("sleep")
            .arg("60")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let pid = i32::try_from(child.id()).unwrap();
        FORCE_REAPER_PENDING.store(true, Ordering::Release);
        REAPER_POLL_ATTEMPTS.store(0, Ordering::Release);
        reap_child_detached(chrome_reaper_lease().unwrap(), child, None);
        std::thread::sleep(Duration::from_millis(160));
        let attempts = REAPER_POLL_ATTEMPTS.load(Ordering::Acquire);
        FORCE_REAPER_PENDING.store(false, Ordering::Release);

        let deadline = Instant::now() + Duration::from_secs(1);
        while unsafe { kill(pid, 0) } == 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        if unsafe { kill(pid, 0) } == 0 {
            let mut status = 0;
            unsafe {
                kill(pid, 9);
                waitpid(pid, &mut status, 0);
            }
        }

        assert!(attempts <= 6, "unconfirmed child was polled {attempts} times in 160ms");
    }

    #[cfg(unix)]
    #[test]
    fn terminal_reaper_wait_error_retains_ownership_for_retry() {
        let _guard = REAPER_TEST_LOCK.lock().unwrap();
        unsafe extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
            fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
        }

        let child = Command::new("sleep")
            .arg("60")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let pid = i32::try_from(child.id()).unwrap();
        let profile_dir = make_profile_dir().unwrap();
        FORCE_REAPER_WAIT_ERROR.store(true, Ordering::Release);
        REAPER_POLL_ATTEMPTS.store(0, Ordering::Release);
        reap_child_detached(chrome_reaper_lease().unwrap(), child, Some(profile_dir.clone()));
        let deadline = Instant::now() + Duration::from_millis(200);
        while REAPER_POLL_ATTEMPTS.load(Ordering::Acquire) == 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let retained = profile_dir.exists();
        FORCE_REAPER_WAIT_ERROR.store(false, Ordering::Release);

        let cleanup_deadline = Instant::now() + Duration::from_secs(1);
        while profile_dir.exists() && Instant::now() < cleanup_deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let mut status = 0;
        unsafe {
            kill(pid, 9);
            waitpid(pid, &mut status, 0);
        }
        let _ = std::fs::remove_dir_all(&profile_dir);

        assert!(retained, "terminal wait error discarded Chrome cleanup ownership");
    }

    #[test]
    fn reaper_admission_is_bounded_by_live_leases() {
        let (sender, _receiver) = mpsc::channel::<ReapRequest>();
        let active = Arc::new(AtomicUsize::new(0));
        let first = reserve_reaper_lease(sender.clone(), active.clone(), 2).unwrap();
        let second = reserve_reaper_lease(sender.clone(), active.clone(), 2).unwrap();

        assert_eq!(active.load(Ordering::Acquire), 2);
        assert!(reserve_reaper_lease(sender.clone(), active.clone(), 2).is_err());

        drop(first);
        let replacement = reserve_reaper_lease(sender, active.clone(), 2).unwrap();
        assert_eq!(active.load(Ordering::Acquire), 2);
        drop(second);
        drop(replacement);
        assert_eq!(active.load(Ordering::Acquire), 0);
    }
}
