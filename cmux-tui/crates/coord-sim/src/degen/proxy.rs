//! A slow link: a unix-socket proxy whose daemon-to-client direction runs at `rate` bytes/s with
//! `latency` added to every chunk. It holds at most a few chunks itself, so a slow reader's backlog
//! stays in the daemon (what the slow-link case measures), not here. Client-to-daemon is unthrottled.
//!
//! Every thread runs in the caller's scope; dropping the proxy stops its accept loop and shuts every
//! socket it holds, so each of them ends and the scope joins it.
//!
//! Standalone: `coord-sim degen --proxy --listen SOCK --upstream SOCK [--rate-bps 65536 --latency-ms 300]`.

use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::sync_channel;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Copy)]
pub struct Link {
    pub rate_bps: u64,
    pub latency: Duration,
}

pub struct Proxy {
    pub listen: PathBuf,
    stop: Arc<AtomicBool>,
    /// Every socket it opened or accepted, to shut on drop.
    socks: Arc<Mutex<Vec<UnixStream>>>,
    /// Bytes this proxy moved daemon-to-client.
    pub down_bytes: Arc<AtomicU64>,
}

impl Proxy {
    pub fn start<'s>(
        sc: &'s std::thread::Scope<'s, '_>,
        listen: &Path,
        upstream: &Path,
        link: Link,
    ) -> Result<Proxy, String> {
        let _ = std::fs::remove_file(listen);
        let l = UnixListener::bind(listen)
            .map_err(|e| format!("proxy bind {}: {e}", listen.display()))?;
        l.set_nonblocking(true).map_err(|e| e.to_string())?;
        let stop = Arc::new(AtomicBool::new(false));
        let down = Arc::new(AtomicU64::new(0));
        let socks = Arc::new(Mutex::new(Vec::new()));
        let (s, d, up, held) = (stop.clone(), down.clone(), upstream.to_path_buf(), socks.clone());
        sc.spawn(move || {
            while !s.load(Ordering::SeqCst) {
                match l.accept() {
                    Ok((client, _)) => {
                        let _ = client.set_nonblocking(false);
                        if let Ok(server) = UnixStream::connect(&up) {
                            if let (Ok(c), Ok(sv)) = (client.try_clone(), server.try_clone()) {
                                held.lock().unwrap_or_else(|e| e.into_inner()).extend([c, sv]);
                            }
                            pipe(sc, client, server, link, s.clone(), d.clone());
                        }
                    }
                    Err(_) => std::thread::sleep(Duration::from_millis(5)),
                }
            }
        });
        Ok(Proxy { listen: listen.to_path_buf(), stop, socks, down_bytes: down })
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        for s in self.socks.lock().unwrap_or_else(|e| e.into_inner()).iter() {
            let _ = s.shutdown(std::net::Shutdown::Both);
        }
        let _ = std::fs::remove_file(&self.listen);
    }
}

fn pipe<'s>(
    sc: &'s std::thread::Scope<'s, '_>,
    client: UnixStream,
    server: UnixStream,
    link: Link,
    stop: Arc<AtomicBool>,
    down: Arc<AtomicU64>,
) {
    let (Ok(mut c_read), Ok(mut s_write)) = (client.try_clone(), server.try_clone()) else {
        return;
    };
    // Client to daemon, as fast as it comes.
    sc.spawn(move || {
        let _ = std::io::copy(&mut c_read, &mut s_write);
        let _ = s_write.shutdown(std::net::Shutdown::Write);
    });
    // Daemon to client: paced reads, each chunk released `latency` after it was read.
    let chunk = (link.rate_bps / 20).clamp(256, 64 << 10) as usize;
    let (tx, rx) = sync_channel::<(Instant, Vec<u8>)>(4);
    let mut s_read = server;
    sc.spawn(move || {
        let start = Instant::now();
        let mut sent = 0u64;
        let mut buf = vec![0u8; chunk];
        while !stop.load(Ordering::SeqCst) {
            let n = match s_read.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            sent += n as u64;
            let due = Duration::from_secs_f64(sent as f64 / link.rate_bps.max(1) as f64);
            if let Some(wait) = due.checked_sub(start.elapsed()) {
                std::thread::sleep(wait);
            }
            let bytes = buf.get(..n).unwrap_or_default().to_vec();
            if tx.send((Instant::now() + link.latency, bytes)).is_err() {
                break;
            }
        }
        let _ = s_read.shutdown(std::net::Shutdown::Both);
    });
    let mut c_write = client;
    sc.spawn(move || {
        while let Ok((due, bytes)) = rx.recv() {
            if let Some(wait) = due.checked_duration_since(Instant::now()) {
                std::thread::sleep(wait);
            }
            if c_write.write_all(&bytes).is_err() {
                break;
            }
            down.fetch_add(bytes.len() as u64, Ordering::Relaxed);
        }
        let _ = c_write.shutdown(std::net::Shutdown::Both);
    });
}

pub fn run_cli(args: &[String]) -> Result<(), String> {
    let listen = crate::flag(args, "--listen").ok_or("--listen SOCK")?;
    let upstream = crate::flag(args, "--upstream").ok_or("--upstream SOCK")?;
    let link = Link {
        rate_bps: crate::flag_or(args, "--rate-bps", 65_536)?,
        latency: Duration::from_millis(crate::flag_or(args, "--latency-ms", 300)?),
    };
    std::thread::scope(|sc| {
        let _p = Proxy::start(sc, Path::new(listen), Path::new(upstream), link)?;
        eprintln!(
            "proxy {listen} -> {upstream} at {} B/s, {} ms",
            link.rate_bps,
            link.latency.as_millis()
        );
        loop {
            std::thread::sleep(Duration::from_secs(3600));
        }
    })
}

#[cfg(test)]
#[path = "proxy_tests.rs"]
mod tests;
