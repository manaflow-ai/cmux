//! The trajectory mirror's thread beside the Cloud worker (`trajectory.rs`,
//! #25584), so a slow upload or an import never stalls the worker's poll
//! loop. The worker hands it a client at each bind; from then on it
//! restores the chats this machine lacks once, then sends what acpmux
//! wrote every [`PASS_EVERY`] (at once while more waits). A deployment
//! that keeps no trajectories is asked again every [`DISABLED_EVERY`].
//! Dropping the handle (the worker ending: a stop, a park or a shutdown)
//! stops the thread after its current request; the drop waits for that
//! up to [`STOP_WAIT`], so no request is held open into a snapshot.

use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
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
    done: Receiver<()>,
    thread: Option<JoinHandle<()>>,
}

impl<H: Http> Drop for Trajectories<H> {
    fn drop(&mut self) {
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
    /// `[0, 1)` (backoff jitter).
    pub fn spawn(
        layout: Layout,
        importer: Box<dyn Importer + Send>,
        now: fn() -> u64,
        random: fn() -> f64,
        log: fn(&str),
    ) -> std::io::Result<Trajectories<H>> {
        let (tx, rx) = mpsc::channel();
        let (done_tx, done) = mpsc::channel::<()>();
        let thread = std::thread::Builder::new().name("cmux-host-trajectory".to_owned()).spawn(
            move || {
                let _done = done_tx;
                run(&rx, layout, importer, now, random, log);
            },
        )?;
        Ok(Trajectories { tx: Some(tx), done, thread: Some(thread) })
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
    now: fn() -> u64,
}

impl<H: Http> Api for ClientApi<'_, H> {
    fn call(&mut self, action: &str, body: &Value) -> Answer {
        let path =
            format!("/v1/cloud/machines/{}/trajectories/{action}", self.client.bound().machine);
        self.client.post_json(&path, body, (self.now)())
    }
}

fn run<H: Http>(
    rx: &Receiver<Msg<H>>,
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
        let Some(c) = client.as_deref_mut() else {
            wait = None;
            continue;
        };
        let mut api = ClientApi { client: c, now };
        if !primed {
            match mirror.prime(&mut api) {
                Ok(remotes) => {
                    primed = true;
                    let restored = mirror.restore(&mut api, importer.as_mut(), &remotes);
                    if restored > 0 {
                        log(&format!("trajectory: restored {restored} chats into acpmux"));
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

/// Imports a bundle with the machine's own acpmux, as the user its session
/// host runs as (`acp session import`; the CLI starts acpmux when it is not
/// running). A chat's folder under that user's home that is gone (a new
/// machine without the checkout) is made empty first, so the chat opens.
pub struct AcpmuxImporter {
    pub bin: PathBuf,
    pub user: String,
    pub uid: u32,
    pub gid: u32,
    pub home: PathBuf,
}

impl AcpmuxImporter {
    fn command(&self, program: &Path) -> Command {
        let mut command = Command::new(program);
        command
            .uid(self.uid)
            .gid(self.gid)
            .env_clear()
            .env("HOME", &self.home)
            .env("USER", &self.user)
            .env("LOGNAME", &self.user)
            .env("PATH", std::env::var("PATH").unwrap_or_else(|_| crate::daemon_spec::DEFAULT_PATH.to_owned()))
            .current_dir(&self.home)
            .stdin(Stdio::null());
        command
    }
}

impl Importer for AcpmuxImporter {
    fn import(&mut self, bundle: &Path, meta: &Value) -> Result<(), String> {
        chown_tree(bundle, self.uid, self.gid).map_err(|e| format!("chown bundle: {e}"))?;
        std::fs::set_permissions(bundle, std::os::unix::fs::PermissionsExt::from_mode(0o700))
            .map_err(|e| format!("bundle mode: {e}"))?;
        if let Some(cwd) = meta.field("cwd").as_str().map(Path::new)
            && cwd.is_absolute()
            && cwd.starts_with(&self.home)
            && !cwd.exists()
        {
            let made = self.command(Path::new("mkdir")).arg("-p").arg(cwd).status();
            if !made.is_ok_and(|s| s.success()) {
                return Err(format!("could not make {}", cwd.display()));
            }
        }
        let out = self
            .command(&self.bin)
            .args(["acp", "--json", "session", "import"])
            .arg(bundle)
            .output()
            .map_err(|e| format!("run {}: {e}", self.bin.display()))?;
        if out.status.success() {
            return Ok(());
        }
        let err = String::from_utf8_lossy(&out.stderr);
        Err(err.trim().chars().take(300).collect())
    }
}

fn chown_tree(path: &Path, uid: u32, gid: u32) -> std::io::Result<()> {
    std::os::unix::fs::lchown(path, Some(uid), Some(gid))?;
    if std::fs::symlink_metadata(path)?.is_dir() {
        for entry in std::fs::read_dir(path)? {
            chown_tree(&entry?.path(), uid, gid)?;
        }
    }
    Ok(())
}
