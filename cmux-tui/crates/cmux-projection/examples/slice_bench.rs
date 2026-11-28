//! The first slice's benchmark (RFD 0007): one machine reads a stand-in Mac folder through the
//! projection over TCP, with no copy step, across a modelled Mac-to-machine link.
//!
//!     slice_bench serve FOLDER LISTEN_ADDR
//!     slice_bench link LISTEN_ADDR TARGET_ADDR --rtt-ms N [--mbps M] [--stats FILE]
//!     slice_bench mount ADDR MOUNT STATE
//!
//! `serve` is the origin (the Mac): it walks FOLDER into a manifest, and for each connection sends
//! `u64 LE length + manifest` then answers asks on the stream. `link` is a TCP proxy that holds
//! every chunk N/2 ms in each direction (a delay queue, so throughput is not throttled by it) and
//! optionally caps each direction at M megabits/s; it rewrites FILE with its byte counts every
//! 100 ms. `mount` is the machine (Linux): it fetches the manifest from ADDR, serves the link and
//! mounts the overlay at MOUNT, prints `mounted`, and stays until SIGINT/SIGTERM, then prints the
//! overlay's stats and unmounts. `bench/bench-slice.sh` drives all three.

use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::os::unix::fs::{FileExt as _, MetadataExt as _};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cmux_projection::link::{Source, answer_asks};
use cmux_projection::manifest::{Item, Kind, Manifest};
use cmux_projection::wire::{self, Part};
use cmux_projection::{Fetch, FetchError};

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("serve") => serve(&args[1..]),
        Some("link") => link(&args[1..]),
        Some("mount") => mount(&args[1..]),
        _ => anyhow::bail!(
            "usage: slice_bench serve FOLDER LISTEN_ADDR | link LISTEN_ADDR TARGET_ADDR --rtt-ms N [--mbps M] [--stats FILE] | mount ADDR MOUNT STATE"
        ),
    }
}

fn ms(since: Instant) -> f64 {
    since.elapsed().as_secs_f64() * 1000.0
}

// --- serve: the origin --------------------------------------------------------------------------

struct Served {
    path: PathBuf,
    size: u64,
    mtime_ns: i64,
}

/// The stand-in Mac: serves each file's bytes, refusing a file changed since the manifest (the
/// same source as `conformance_mount`).
struct Folder(Vec<Option<Served>>);

impl Source for Folder {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Part {
        let Some(Some(served)) = self.0.get(entry as usize) else {
            return Part::status(wire::REFUSED);
        };
        let Ok(file) = std::fs::File::open(&served.path) else {
            return Part::status(wire::FAILED);
        };
        let Ok(meta) = file.metadata() else { return Part::status(wire::FAILED) };
        if meta.len() != served.size || mtime_ns(&meta) != served.mtime_ns {
            return Part::status(wire::CHANGED);
        }
        let want = u64::from(len).min(served.size.saturating_sub(offset));
        let mut bytes = vec![0u8; usize::try_from(want).unwrap_or(0)];
        match file.read_exact_at(&mut bytes, offset) {
            Ok(()) => Part::ok(bytes),
            Err(_) => Part::status(wire::FAILED),
        }
    }

    fn whole(&self, entry: u32) -> Part {
        let size =
            self.0.get(entry as usize).and_then(Option::as_ref).map_or(0, |served| served.size);
        match u32::try_from(size) {
            Ok(len) if len <= wire::MAX_READ => self.read(entry, 0, len),
            _ => Part::status(wire::FAILED),
        }
    }
}

fn mtime_ns(meta: &std::fs::Metadata) -> i64 {
    meta.mtime().saturating_mul(1_000_000_000).saturating_add(meta.mtime_nsec())
}

fn walk(root: &Path, at: &Path, items: &mut Vec<Item>, paths: &mut Vec<(String, PathBuf)>) {
    let Ok(read) = std::fs::read_dir(at) else { return };
    for entry in read.flatten() {
        let path = entry.path();
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        let Ok(relative) = path.strip_prefix(root) else { continue };
        let Some(relative) = relative.to_str().map(str::to_owned) else { continue };
        let kind = if meta.is_dir() {
            Kind::Dir
        } else if meta.file_type().is_symlink() {
            Kind::Link
        } else if meta.is_file() {
            Kind::File
        } else {
            continue;
        };
        let link = (kind == Kind::Link).then(|| {
            std::fs::read_link(&path).map(|target| target.display().to_string()).unwrap_or_default()
        });
        items.push(Item {
            path: relative.clone(),
            kind,
            mode: meta.mode() & 0o7777,
            size: meta.len(),
            mtime_ns: mtime_ns(&meta),
            link,
        });
        match kind {
            Kind::Dir => walk(root, &path, items, paths),
            Kind::File => paths.push((relative, path)),
            Kind::Link => {}
        }
    }
}

fn serve(args: &[String]) -> anyhow::Result<()> {
    let [folder, listen] = args else {
        anyhow::bail!("usage: slice_bench serve FOLDER LISTEN_ADDR")
    };
    let started = Instant::now();
    let source = std::fs::canonicalize(folder)?;
    let (mut items, mut paths) = (Vec::new(), Vec::new());
    walk(&source, &source, &mut items, &mut paths);
    let (entries, files, bytes) = (
        items.len(),
        items.iter().filter(|item| item.kind == Kind::File).count(),
        items.iter().filter(|item| item.kind == Kind::File).map(|item| item.size).sum::<u64>(),
    );
    let manifest = Manifest::build(mtime_ns(&std::fs::metadata(&source)?), items)?;
    let mut served: Vec<Option<Served>> = Vec::new();
    served.resize_with(manifest.len(), || None);
    for (relative, path) in paths {
        let Ok(meta) = std::fs::metadata(&path) else { continue };
        if let Some(slot) =
            manifest.resolve(&relative).and_then(|index| served.get_mut(index as usize))
        {
            *slot = Some(Served { path, size: meta.len(), mtime_ns: mtime_ns(&meta) });
        }
    }
    let walk_ms = ms(started);
    let encoded = Arc::new(manifest.encode()?);
    let listener = TcpListener::bind(listen)?;
    println!(
        "{{\"entries\":{entries},\"files\":{files},\"bytes\":{bytes},\"walk_ms\":{walk_ms:.1},\"manifest_bytes\":{}}}",
        encoded.len()
    );
    std::io::stdout().flush()?;
    let folder = Arc::new(Folder(served));
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        let (folder, encoded) = (folder.clone(), encoded.clone());
        std::thread::spawn(move || {
            let _ = stream.set_nodelay(true);
            let sent = stream
                .write_all(&(encoded.len() as u64).to_le_bytes())
                .and_then(|()| stream.write_all(&encoded));
            if sent.is_err() {
                return;
            }
            let Ok(reader) = stream.try_clone() else { return };
            if let Err(error) = answer_asks(reader, stream, folder.as_ref()) {
                eprintln!("serve: answering asks ended: {error}");
            }
        });
    }
    Ok(())
}

// --- link: the modelled Mac-to-machine link ----------------------------------------------------

struct Model {
    /// One way: half the round trip.
    delay: Duration,
    /// Bytes a second each direction, if capped.
    rate: Option<f64>,
}

fn link(args: &[String]) -> anyhow::Result<()> {
    let mut places = Vec::new();
    let (mut rtt_ms, mut mbps, mut stats) = (None, None, None);
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--rtt-ms" => rtt_ms = iter.next().map(|value| value.parse::<f64>()).transpose()?,
            "--mbps" => mbps = iter.next().map(|value| value.parse::<f64>()).transpose()?,
            "--stats" => stats = iter.next().cloned(),
            _ => places.push(arg.clone()),
        }
    }
    let ([listen, target], Some(rtt_ms)) = (places.as_slice(), rtt_ms) else {
        anyhow::bail!(
            "usage: slice_bench link LISTEN_ADDR TARGET_ADDR --rtt-ms N [--mbps M] [--stats FILE]"
        );
    };
    let model = Arc::new(Model {
        delay: Duration::from_secs_f64(rtt_ms / 2000.0),
        rate: mbps.filter(|mbps| *mbps > 0.0).map(|mbps| mbps * 1e6 / 8.0),
    });
    // up: client to target (machine to Mac); down: target to client (Mac to machine).
    // The fourth count is writes going up: the machine flushes one ask at a time and waits for
    // nothing else, so it is the number of round trips (asks sent at once can share a write, so
    // it is a floor).
    let counts =
        Arc::new([AtomicU64::new(0), AtomicU64::new(0), AtomicU64::new(0), AtomicU64::new(0)]);
    if let Some(stats) = stats {
        let counts = counts.clone();
        std::thread::spawn(move || {
            let mut last = None;
            loop {
                let now = counts.each_ref().map(|count| count.load(Ordering::Relaxed));
                if last != Some(now) {
                    let [up, down, connections, writes_up] = now;
                    let temp = format!("{stats}.tmp");
                    let line = format!(
                        "{{\"bytes_up\":{up},\"bytes_down\":{down},\"connections\":{connections},\"writes_up\":{writes_up}}}\n"
                    );
                    if std::fs::write(&temp, line)
                        .and_then(|()| std::fs::rename(&temp, &stats))
                        .is_ok()
                    {
                        last = Some(now);
                    }
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        });
    }
    let listener = TcpListener::bind(listen)?;
    eprintln!("link: {listen} -> {target}, rtt {rtt_ms} ms, mbps {mbps:?}");
    for client in listener.incoming() {
        let Ok(client) = client else { continue };
        let server = match TcpStream::connect(target) {
            Ok(server) => server,
            Err(error) => {
                eprintln!("link: connect {target}: {error}");
                continue;
            }
        };
        counts[2].fetch_add(1, Ordering::Relaxed);
        let _ = client.set_nodelay(true);
        let _ = server.set_nodelay(true);
        let (Ok(client_read), Ok(server_read)) = (client.try_clone(), server.try_clone()) else {
            continue;
        };
        let (up, down) = (counts.clone(), counts.clone());
        let (up_model, down_model) = (model.clone(), model.clone());
        std::thread::spawn(move || relay(client_read, server, &up_model, &up[0], Some(&up[3])));
        std::thread::spawn(move || relay(server_read, client, &down_model, &down[1], None));
    }
    Ok(())
}

/// Moves bytes `from` to `to` as the model says: each chunk leaves once the capped rate has sent
/// it, and lands `delay` later. The reader stamps and queues; the writer releases on time, so
/// chunks in flight overlap and the delay costs latency, not throughput.
fn relay(
    mut from: TcpStream,
    mut to: TcpStream,
    model: &Model,
    count: &AtomicU64,
    writes: Option<&AtomicU64>,
) {
    // A bounded queue: at most this many chunks in flight, so a slow side pushes back.
    let (send, receive) = mpsc::sync_channel::<(Instant, Vec<u8>)>(1024);
    let writer = std::thread::spawn(move || {
        for (release, bytes) in receive {
            let now = Instant::now();
            if release > now {
                std::thread::sleep(release - now);
            }
            if to.write_all(&bytes).is_err() {
                break;
            }
        }
        let _ = to.shutdown(Shutdown::Write);
    });
    // A chunk is at most 5 ms of the capped rate (a coarse chunk would add its own latency).
    let chunk =
        model.rate.map_or(64 * 1024, |rate| ((rate * 0.005) as usize).clamp(1500, 64 * 1024));
    let mut buffer = vec![0u8; chunk];
    let mut sent_by = Instant::now();
    loop {
        let read = match from.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(read) => read,
        };
        count.fetch_add(read as u64, Ordering::Relaxed);
        if let Some(writes) = writes {
            writes.fetch_add(1, Ordering::Relaxed);
        }
        let now = Instant::now();
        let leaves = match model.rate {
            Some(rate) => {
                sent_by = sent_by.max(now) + Duration::from_secs_f64(read as f64 / rate);
                sent_by
            }
            None => now,
        };
        if send.send((leaves + model.delay, buffer[..read].to_vec())).is_err() {
            break;
        }
        // Read no faster than the cap sends.
        let now = Instant::now();
        if leaves > now {
            std::thread::sleep(leaves - now);
        }
    }
    drop(send);
    let _ = writer.join();
    let _ = from.shutdown(Shutdown::Read);
}

// --- mount: the machine -------------------------------------------------------------------------

/// Bench only: a [`Fetch`] that times each ask (one `read` or `batch` call of the overlay) and
/// appends one JSON line per ask: its start and answer times (seconds since the epoch, the clock
/// the bench script reads), its kind and the paths it asked for.
struct Timed {
    link: Arc<cmux_projection::link::Link>,
    manifest: Arc<Manifest>,
    log: std::fs::File,
}

fn epoch() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0.0, |since| since.as_secs_f64())
}

impl Timed {
    fn record(&self, kind: &str, entries: &[u32], start: f64) {
        let paths: Vec<String> =
            entries.iter().map(|entry| self.manifest.path_of(*entry)).collect();
        let line = format!(
            "{{\"kind\":\"{kind}\",\"start\":{start:.6},\"end\":{:.6},\"n\":{},\"paths\":{paths:?}}}\n",
            epoch(),
            entries.len()
        );
        let _ = (&self.log).write_all(line.as_bytes());
    }
}

impl Fetch for Timed {
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError> {
        let start = epoch();
        let answer = self.link.read(entry, offset, len);
        self.record("read", &[entry], start);
        answer
    }

    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>> {
        let start = epoch();
        let answers = self.link.batch(entries);
        self.record("batch", entries, start);
        answers
    }

    fn cache(&self) -> bool {
        self.link.cache()
    }
}

#[cfg(not(target_os = "linux"))]
fn mount(_args: &[String]) -> anyhow::Result<()> {
    anyhow::bail!("projected folders mount on Linux only")
}

#[cfg(target_os = "linux")]
fn mount(args: &[String]) -> anyhow::Result<()> {
    use cmux_projection::link::Link;
    use cmux_projection::mount::Options;
    use cmux_projection::overlay::Overlay;

    // Blocked before any thread starts: every thread inherits the mask, so only sigwait sees them.
    let signals = linux::block_signals();
    let [addr, at, state] = args else {
        anyhow::bail!("usage: slice_bench mount ADDR MOUNT STATE")
    };
    let started = Instant::now();
    let mut stream = TcpStream::connect(addr.as_str())?;
    stream.set_nodelay(true)?;
    let connect_ms = ms(started);
    let fetching = Instant::now();
    let mut length = [0u8; 8];
    stream.read_exact(&mut length)?;
    let mut encoded = vec![0u8; usize::try_from(u64::from_le_bytes(length))?];
    stream.read_exact(&mut encoded)?;
    let manifest_fetch_ms = ms(fetching);
    let decoding = Instant::now();
    let manifest = Manifest::decode(&encoded)?;
    let decode_ms = ms(decoding);
    let entries = manifest.len();
    let mounting = Instant::now();
    let manifest = Arc::new(manifest);
    let link = Arc::new(Link::default());
    let serving = link.clone();
    let reader = stream.try_clone()?;
    std::thread::spawn(move || serving.serve(reader, stream));
    // Bench only: with SLICE_ASK_LOG set, every ask the overlay makes is timed into that file.
    let fetch: Arc<dyn Fetch> = match std::env::var_os("SLICE_ASK_LOG") {
        Some(path) => Arc::new(Timed {
            link,
            manifest: manifest.clone(),
            log: std::fs::OpenOptions::new().create(true).append(true).open(path)?,
        }),
        None => link,
    };
    let owner = (linux::uid(), linux::gid());
    let overlay = Overlay::open(manifest, Path::new(state), fetch, owner)?;
    // Bench only: with SLICE_REPLAY=KEY the mount records its access list under KEY and fetches
    // the last one ahead in the background (RFD 0065 piece 8).
    let overlay = Arc::new(match std::env::var("SLICE_REPLAY") {
        Ok(key) if !key.is_empty() => overlay.with_replay(&key),
        _ => overlay,
    });
    if !overlay.replay_list().is_empty() {
        let replaying = overlay.clone();
        std::thread::spawn(move || {
            let report = replaying.replay_prefetch();
            eprintln!("replay: {report:?}");
        });
    }
    // Bench only: SLICE_BULK=1 copies the rest of the tree behind the mount (RFD 0065 piece 11).
    if std::env::var_os("SLICE_BULK").is_some_and(|value| value == "1") {
        let copying = overlay.clone();
        std::thread::spawn(move || {
            let started = Instant::now();
            let report = copying.bulk_copy(
                &cmux_projection::overlay::bulk::BulkOptions::default(),
                &std::sync::atomic::AtomicBool::new(false),
            );
            eprintln!("bulk: {report:?} in {:.1} s", started.elapsed().as_secs_f64());
        });
    }
    let at = std::fs::canonicalize(at)?;
    let mounted = cmux_projection::mount::mount_with(overlay.clone(), &at, Options::default())?;
    std::fs::metadata(&at)?;
    let mount_ms = ms(mounting);
    println!(
        "{{\"connect_ms\":{connect_ms:.1},\"manifest_fetch_ms\":{manifest_fetch_ms:.1},\"manifest_bytes\":{},\"decode_ms\":{decode_ms:.1},\"mount_ms\":{mount_ms:.1},\"entries\":{entries}}}",
        encoded.len()
    );
    println!("mounted");
    std::io::stdout().flush()?;
    linux::wait_for(&signals, &at);
    let stats = overlay.stats();
    println!(
        "{{\"remote_reads\":{},\"remote_bytes\":{},\"cache_hits\":{}}}",
        stats.remote_reads, stats.remote_bytes, stats.cache_hits
    );
    std::io::stdout().flush()?;
    mounted.unmount();
    Ok(())
}

#[cfg(target_os = "linux")]
mod linux {
    use std::path::Path;

    pub fn uid() -> u32 {
        // SAFETY: getuid has no preconditions and cannot fail.
        unsafe { libc::getuid() }
    }

    pub fn gid() -> u32 {
        // SAFETY: getgid has no preconditions and cannot fail.
        unsafe { libc::getgid() }
    }

    pub fn block_signals() -> libc::sigset_t {
        // SAFETY: a zeroed sigset is a valid argument to sigemptyset; the mask only blocks.
        unsafe {
            let mut set: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut set);
            libc::sigaddset(&mut set, libc::SIGINT);
            libc::sigaddset(&mut set, libc::SIGTERM);
            libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
            set
        }
    }

    /// Waits for SIGINT/SIGTERM, or for the mount at `at` to go (an `umount` from outside).
    pub fn wait_for(set: &libc::sigset_t, at: &Path) {
        let at = at.display().to_string();
        let mounted = || {
            std::fs::read_to_string("/proc/self/mountinfo").is_ok_and(|info| {
                info.lines().any(|line| line.split(' ').nth(4) == Some(at.as_str()))
            })
        };
        let second = libc::timespec { tv_sec: 1, tv_nsec: 0 };
        loop {
            // SAFETY: `set` was filled by block_signals and is blocked on every thread.
            let got = unsafe { libc::sigtimedwait(set, std::ptr::null_mut(), &second) };
            if got > 0 || !mounted() {
                return;
            }
        }
    }
}
