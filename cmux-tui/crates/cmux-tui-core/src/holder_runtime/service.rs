//! The daemon's holder for one terminal host root: start or reach it, spawn
//! terminals on it, and hand every live terminal to a new holder after a
//! holder crash.

use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use cmux_holder::link::{HolderLink, TerminalSink};
use cmux_holder::{Listed, SpawnRequest};

use super::{HolderSink, HolderTerminal};
use crate::panic_free::RecoverPoison;

/// The holder of one terminal host root (one daemon session).
pub(crate) struct HolderService {
    socket: PathBuf,
    token: [u8; 32],
    link: Mutex<Option<Arc<HolderLink>>>,
    next_chan: AtomicU32,
    /// Terminals this daemon runs on the holder, for a re-adoption after a
    /// holder crash.
    live: Mutex<HashMap<u32, Weak<HolderTerminal>>>,
    /// What the holder ran when this daemon first reached it: the
    /// terminals a restarted daemon re-attaches, by terminal id.
    listed: Mutex<HashMap<[u8; 16], Listed>>,
}

impl HolderService {
    /// The service of `host_root`, made on first use. One per root in the
    /// process: every surface of a session reaches the same holder.
    pub(crate) fn for_root(host_root: &Path) -> io::Result<Arc<Self>> {
        static SERVICES: OnceLock<Mutex<HashMap<PathBuf, Arc<HolderService>>>> = OnceLock::new();
        let services = SERVICES.get_or_init(Mutex::default);
        let mut services = services.lock().recover_poison();
        if let Some(service) = services.get(host_root) {
            return Ok(service.clone());
        }
        let service = Arc::new(Self {
            socket: socket_path(host_root)?,
            token: load_or_create_token(host_root)?,
            link: Mutex::new(None),
            next_chan: AtomicU32::new(1),
            live: Mutex::default(),
            listed: Mutex::default(),
        });
        services.insert(host_root.to_path_buf(), service.clone());
        Ok(service)
    }

    /// Whether a holder of `host_root` may run: its socket exists. Asking
    /// costs no file, process or token when none does.
    pub(crate) fn may_run(host_root: &Path) -> bool {
        socket_path(host_root).is_ok_and(|socket| socket.exists())
    }

    /// The live link: connects to a running holder, else starts one. A link
    /// made after a lost one hands every live terminal to the new holder.
    pub(crate) fn link(self: &Arc<Self>) -> io::Result<Arc<HolderLink>> {
        self.link_or_launch(true)
    }

    /// [`Self::link`]; with `launch` false a holder that does not run is not
    /// started (a restart only asks whether one kept terminals).
    fn link_or_launch(self: &Arc<Self>, launch: bool) -> io::Result<Arc<HolderLink>> {
        let mut slot = self.link.lock().recover_poison();
        if let Some(link) = slot.as_ref()
            && link.is_open()
        {
            return Ok(link.clone());
        }
        let had_link = slot.is_some();
        let (link, listed) = match self.connect() {
            Ok(connected) => connected,
            Err(_) if launch => {
                self.launch()?;
                self.connect()?
            }
            Err(error) => return Err(error),
        };
        {
            let mut known = self.listed.lock().recover_poison();
            for entry in listed {
                self.next_chan.fetch_max(entry.chan + 1, Ordering::AcqRel);
                known.entry(entry.id).or_insert(entry);
            }
        }
        *slot = Some(link.clone());
        drop(slot);
        if had_link {
            self.readopt(&link);
        }
        Ok(link)
    }

    /// Start `request` on the holder. Returns the terminal (its custody
    /// master, pid and output sink); `seed` reaches the parser before the
    /// shell's first byte.
    pub(crate) fn spawn(
        self: &Arc<Self>,
        request: &SpawnRequest,
        seed: &[u8],
    ) -> io::Result<Arc<HolderTerminal>> {
        let link = self.link()?;
        let chan = self.next_chan.fetch_add(1, Ordering::AcqRel);
        let sink = HolderSink::new(0);
        sink.prepend(seed);
        let (pid, custody) = link.spawn(chan, request, sink.clone() as Arc<dyn TerminalSink>)?;
        Ok(self.track(chan, request.id, pid, custody, sink))
    }

    /// The terminal `id` a previous daemon left running on the holder, now
    /// streaming its kept output from the oldest byte, with the custody dup
    /// of its master the holder passed in its WELCOME. `None` when the
    /// holder does not run it.
    pub(crate) fn reattach(
        self: &Arc<Self>,
        id: &[u8; 16],
    ) -> io::Result<Option<Arc<HolderTerminal>>> {
        let link = self.link()?;
        let Some(entry) = self.listed.lock().recover_poison().remove(id) else { return Ok(None) };
        let Some(custody) = entry.master.filter(|_| !entry.exited) else { return Ok(None) };
        let sink = HolderSink::new(entry.oldest);
        link.attach(entry.chan, entry.oldest, sink.clone() as Arc<dyn TerminalSink>)?;
        Ok(Some(self.track(entry.chan, *id, entry.pid, custody, sink)))
    }

    /// Whether the holder ran terminal `id` when this daemon reached it.
    pub(crate) fn lists(self: &Arc<Self>, id: &[u8; 16]) -> bool {
        self.link_or_launch(false).is_ok()
            && self.listed.lock().recover_poison().get(id).is_some_and(|e| !e.exited)
    }

    /// Hang up `chan`'s terminal; SIGKILL its group after `grace_ms`.
    pub(crate) fn close(self: &Arc<Self>, chan: u32, grace_ms: u32) -> io::Result<()> {
        self.link()?.close(chan, grace_ms)
    }

    /// Stop tracking `chan` (its terminal ended or its surface left).
    pub(crate) fn untrack(&self, chan: u32) {
        self.live.lock().recover_poison().remove(&chan);
        if let Some(link) = self.link.lock().recover_poison().as_ref() {
            link.forget(chan);
        }
    }

    fn track(
        self: &Arc<Self>,
        chan: u32,
        id: [u8; 16],
        pid: i32,
        custody: OwnedFd,
        sink: Arc<HolderSink>,
    ) -> Arc<HolderTerminal> {
        let terminal =
            Arc::new(HolderTerminal { chan, id, pid, custody, sink, service: self.clone() });
        self.live.lock().recover_poison().insert(chan, Arc::downgrade(&terminal));
        terminal
    }

    /// End every live terminal as lost: no holder can stream it.
    fn lose_all(&self) {
        let live: Vec<_> =
            self.live.lock().recover_poison().values().filter_map(Weak::upgrade).collect();
        for terminal in live {
            terminal.sink.lose();
        }
    }

    /// Hand every live terminal to the new holder `link` after a holder
    /// crash: its custody master, pid, and the offset its output continues
    /// from. Output the shells wrote meanwhile waited in their PTYs.
    fn readopt(&self, link: &HolderLink) {
        let live: Vec<_> =
            self.live.lock().recover_poison().values().filter_map(Weak::upgrade).collect();
        for terminal in live {
            let base = terminal.sink.received();
            let sink = terminal.sink.clone() as Arc<dyn TerminalSink>;
            if let Err(error) = link.adopt(
                terminal.chan,
                &terminal.id,
                (terminal.pid, base),
                &terminal.custody,
                sink,
            ) {
                eprintln!("cmux-tui: hand terminal {} to the new holder: {error}", terminal.chan);
            }
        }
    }

    fn connect(self: &Arc<Self>) -> io::Result<(Arc<HolderLink>, Vec<Listed>)> {
        let weak = Arc::downgrade(self);
        HolderLink::connect(
            &self.socket,
            &self.token,
            Box::new(move || {
                // The holder died: start a new one and hand it every master.
                let Some(service) = weak.upgrade() else { return };
                let _ =
                    std::thread::Builder::new().name("holder-restart".into()).spawn(move || {
                        if let Err(error) = service.link() {
                            // No holder streams their output any more: their
                            // terminals end as lost (the shells may still run).
                            eprintln!("cmux-tui: restart the terminal holder: {error}");
                            service.lose_all();
                        }
                    });
            }),
        )
    }

    /// Start the holder from the host executable (the slim, content-addressed
    /// `cmux-tui-host` on macOS) and wait until it listens.
    fn launch(&self) -> io::Result<()> {
        let mut child = crate::host_exe::spawn_host(|command| {
            command
                .args(["__holder", "--socket"])
                .arg(&self.socket)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null());
        })?;
        let hex: String = self.token.iter().map(|byte| format!("{byte:02x}")).collect();
        let mut stdin = child.stdin.take().ok_or_else(|| io::Error::other("no holder stdin"))?;
        stdin.write_all(format!("{hex}\n").as_bytes())?;
        drop(stdin);
        let stdout = child.stdout.take().ok_or_else(|| io::Error::other("no holder stdout"))?;
        let mut line = String::new();
        BufReader::new(stdout).read_line(&mut line)?;
        // Reap the holder if it ever exits while this daemon runs.
        let _ = std::thread::Builder::new().name("holder-reaper".into()).spawn(move || {
            let _ = child.wait();
        });
        if line.trim() != "ready" {
            return Err(io::Error::other(format!("the terminal holder did not start: {line:?}")));
        }
        Ok(())
    }
}

/// `/tmp/cmux-hd-<uid>/<hash of the host root>.sock`: short enough for
/// `sun_path`, one per session, in a 0700 directory of this user.
fn socket_path(host_root: &Path) -> io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    // SAFETY: getuid cannot fail.
    let uid = unsafe { libc::getuid() };
    let dir = PathBuf::from(format!("/tmp/cmux-hd-{uid}"));
    match std::fs::DirBuilder::new().mode(0o700).create(&dir) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let meta = std::fs::symlink_metadata(&dir)?;
    if !meta.is_dir() || meta.uid() != uid || meta.permissions().mode() & 0o077 != 0 {
        return Err(io::Error::other(format!("{} is not a private directory", dir.display())));
    }
    Ok(dir.join(format!("{:016x}.sock", fnv1a(host_root.as_os_str().as_encoded_bytes()))))
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x100_0000_01b3)
    })
}

/// The owner token in `<host root>/holder.token` (0600), made on first use.
/// A restarted daemon of the session reads it to reach the same holder.
fn load_or_create_token(host_root: &Path) -> io::Result<[u8; 32]> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::create_dir_all(host_root)?;
    let path = host_root.join("holder.token");
    if let Ok(text) = std::fs::read_to_string(&path)
        && let Some(token) = parse_hex(text.trim())
    {
        return Ok(token);
    }
    let token = *crate::terminal_host::CapabilityToken::random()
        .map_err(|error| io::Error::other(error.to_string()))?
        .as_bytes();
    let hex: String = token.iter().map(|byte| format!("{byte:02x}")).collect();
    let temporary = path.with_extension("tmp");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(hex.as_bytes())?;
    file.sync_all()?;
    std::fs::rename(&temporary, &path)?;
    Ok(token)
}

fn parse_hex(hex: &str) -> Option<[u8; 32]> {
    if hex.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (index, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(hex.get(index * 2..index * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}
