//! The trajectory mirror's thread beside the Cloud worker (`trajectory.rs`,
//! #25584), so a slow upload or an import never stalls the worker's poll
//! loop. The worker hands it a client at each bind; from then on it reads
//! what is kept, imports the restore source's chats once acpmux runs, and
//! sends what acpmux wrote every [`PASS_EVERY`] (at once while more waits).
//! A deployment that keeps no trajectories is asked again every
//! [`DISABLED_EVERY`]. On Linux the thread reads and writes files as the
//! work user (`setfsuid`): the agent's files are that user's, and a link
//! they plant cannot make root read or write another file. Dropping the
//! handle (the worker ending: a stop, a park or a shutdown) makes every
//! later request fail at once and waits up to [`STOP_WAIT`] for the one in
//! flight, so no request is held open into a snapshot.

use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::Duration;

use serde_json::Value;

use super::client::{CloudClient, Http};
use super::sender::{Answer, Backoff};
use super::trajectory::{Api, Importer, Layout, Mirror, Pass};
use crate::json::JsonField;

pub const PASS_EVERY: Duration = Duration::from_secs(5);
pub const DISABLED_EVERY: Duration = Duration::from_secs(30 * 60);
/// A drop waits this long for the request in flight (each is bounded by
/// the API client's 20 s timeout).
pub const STOP_WAIT: Duration = Duration::from_secs(25);

enum Msg<H: Http> {
    Bound(Box<CloudClient<H>>),
}

/// The worker's handle on the mirror thread.
pub struct Trajectories<H: Http> {
    tx: Option<Sender<Msg<H>>>,
    stop: Arc<AtomicBool>,
    done: Receiver<()>,
    thread: Option<JoinHandle<()>>,
}

impl<H: Http> Drop for Trajectories<H> {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self.tx = None;
        if !matches!(self.done.recv_timeout(STOP_WAIT), Err(RecvTimeoutError::Timeout))
            && let Some(thread) = self.thread.take()
        {
            let _ = thread.join();
        }
    }
}

impl<H: Http + Send + 'static> Trajectories<H> {
    /// Starts the thread. `now` is wall-clock milliseconds, `random` in
    /// `[0, 1)` (backoff jitter). `fs_identity` is the `(uid, gid)` the
    /// thread's file access runs as (Linux).
    pub fn spawn(
        layout: Layout,
        importer: Box<dyn Importer + Send>,
        fs_identity: Option<(u32, u32)>,
        now: fn() -> u64,
        random: fn() -> f64,
        log: fn(&str),
    ) -> std::io::Result<Trajectories<H>> {
        let (tx, rx) = mpsc::channel();
        let (done_tx, done) = mpsc::channel::<()>();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = Arc::clone(&stop);
        let thread = std::thread::Builder::new().name("cmux-host-trajectory".to_owned()).spawn(
            move || {
                let _done = done_tx;
                if let Some((uid, gid)) = fs_identity {
                    set_fs_identity(uid, gid, log);
                }
                run(&rx, &stopping, layout, importer, now, random, log);
            },
        )?;
        Ok(Trajectories { tx: Some(tx), stop, done, thread: Some(thread) })
    }

    /// The machine is bound (again): keep its chats from now on.
    pub fn bound(&self, client: CloudClient<H>) {
        if let Some(tx) = self.tx.as_ref() {
            let _ = tx.send(Msg::Bound(Box::new(client)));
        }
    }
}

/// [`Api`] over the bound machine's client.
struct ClientApi<'a, H: Http> {
    client: &'a mut CloudClient<H>,
    stop: &'a AtomicBool,
    now: fn() -> u64,
}

impl<H: Http> Api for ClientApi<'_, H> {
    fn call(&mut self, action: &str, body: &Value) -> Answer {
        if self.stop.load(Ordering::SeqCst) {
            return Answer::Transport;
        }
        let path =
            format!("/v1/cloud/machines/{}/trajectories/{action}", self.client.bound().machine);
        self.client.post_json(&path, body, (self.now)())
    }
}

fn run<H: Http>(
    rx: &Receiver<Msg<H>>,
    stop: &AtomicBool,
    layout: Layout,
    mut importer: Box<dyn Importer + Send>,
    now: fn() -> u64,
    random: fn() -> f64,
    log: fn(&str),
) {
    let mut client: Option<Box<CloudClient<H>>> = None;
    let mut mirror = Mirror::new(layout.clone(), log);
    let mut primed = false;
    let mut backoff = Backoff::new(5_000, 300_000);
    let mut wait: Option<Duration> = None;
    loop {
        let msg = match wait {
            None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
            Some(w) => rx.recv_timeout(w),
        };
        match msg {
            Ok(Msg::Bound(next)) => {
                client = Some(next);
                mirror = Mirror::new(layout.clone(), log);
                primed = false;
                backoff.reset();
            }
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {}
        }
        if stop.load(Ordering::SeqCst) {
            return;
        }
        let Some(c) = client.as_deref_mut() else {
            wait = None;
            continue;
        };
        let mut api = ClientApi { client: c, stop, now };
        if !primed {
            match mirror.prime(&mut api) {
                Ok(waiting) => {
                    primed = true;
                    if waiting > 0 {
                        log(&format!(
                            "trajectory: {waiting} chats of the restore source to import"
                        ));
                    }
                }
                Err(Pass::Disabled) => {
                    wait = Some(DISABLED_EVERY);
                    continue;
                }
                Err(other) => {
                    log(&format!("trajectory: list failed: {other:?}"));
                    wait = Some(Duration::from_millis(backoff.next(0, random())));
                    continue;
                }
            }
        }
        // Imports wait for acpmux to run (the person opens a chat); each pass tries again.
        mirror.restore(&mut api, importer.as_mut());
        wait = Some(match mirror.sync(&mut api, now()) {
            Pass::Idle => {
                backoff.reset();
                PASS_EVERY
            }
            Pass::More => {
                backoff.reset();
                Duration::ZERO
            }
            Pass::Disabled => {
                primed = false;
                DISABLED_EVERY
            }
            Pass::Failed(why) => {
                log(&format!("trajectory: send failed: {why}"));
                Duration::from_millis(backoff.next(0, random()))
            }
        });
    }
}

/// File access of this thread as `uid`/`gid` (Linux `setfsgid`/`setfsuid`
/// are per thread; network calls are unaffected). On other systems the
/// thread keeps the process's identity.
fn set_fs_identity(uid: u32, gid: u32, log: fn(&str)) {
    #[cfg(target_os = "linux")]
    {
        // SAFETY: plain syscalls on the calling thread; they take integers and touch no memory.
        unsafe {
            libc::setfsgid(gid);
            libc::setfsuid(uid);
        }
        // A second call answers the identity now in force.
        // SAFETY: as above.
        let (now_gid, now_uid) = unsafe { (libc::setfsgid(gid), libc::setfsuid(uid)) };
        if now_uid != uid as i32 || now_gid != gid as i32 {
            log(&format!("trajectory: file identity is {now_uid}:{now_gid}, not {uid}:{gid}"));
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (uid, gid, log);
    }
}

/// Imports a bundle with the machine's own acpmux, as the user its session
/// host runs as (`acp session import`), only while acpmux runs: an import
/// never starts it, so it keeps the environment the machine starts it with.
/// A chat's folder under that user's home that is gone (a new machine
/// without the checkout) is made empty first, so the chat opens.
pub struct AcpmuxImporter {
    pub bin: PathBuf,
    pub user: String,
    pub uid: u32,
    pub gid: u32,
    pub home: PathBuf,
    /// acpmux's socket (`acpmux.sock` beside `sessions/`).
    pub socket: PathBuf,
}

impl Importer for AcpmuxImporter {
    fn ready(&self) -> bool {
        UnixStream::connect(&self.socket).is_ok()
    }

    fn import(&mut self, bundle: &Path, meta: &Value) -> Result<(), String> {
        if let Some(cwd) = meta.field("cwd").as_str().map(Path::new)
            && let Ok(rest) = cwd.strip_prefix(&self.home)
            && rest.components().all(|c| matches!(c, Component::Normal(_)))
            && !cwd.exists()
        {
            // This thread's file access is the work user's (`set_fs_identity`).
            std::fs::create_dir_all(cwd).map_err(|e| format!("make {}: {e}", cwd.display()))?;
        }
        let out = Command::new(&self.bin)
            .args(["acp", "--json", "session", "import"])
            .arg(bundle)
            .uid(self.uid)
            .gid(self.gid)
            .env_clear()
            .env("HOME", &self.home)
            .env("USER", &self.user)
            .env("LOGNAME", &self.user)
            .env(
                "PATH",
                std::env::var("PATH")
                    .unwrap_or_else(|_| crate::daemon_spec::DEFAULT_PATH.to_owned()),
            )
            .current_dir(&self.home)
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("run {}: {e}", self.bin.display()))?;
        if out.status.success() {
            return Ok(());
        }
        let err = String::from_utf8_lossy(&out.stderr);
        Err(err.trim().chars().take(300).collect())
    }
}
