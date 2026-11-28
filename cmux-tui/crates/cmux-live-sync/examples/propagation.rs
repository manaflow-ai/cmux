//! Propagation latency, file saved on one side to the same bytes readable on the other.
//!
//! cargo run --release -p cmux-live-sync --example propagation -- [EDITS] [RTT_MS]
//!
//! RTT_MS delays every chunk each way by half of it (the tunnel stand-in). Prints p50/p95/max for
//! Mac to VM and VM to Mac, and the lost-edit count (an edit whose bytes never arrived).

use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use cmux_live_sync::{Event, Follower, Leader};
use crossbeam_channel::unbounded;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let edits: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(200);
    let rtt = Duration::from_millis(args.get(2).and_then(|s| s.parse().ok()).unwrap_or(0));
    let dir = tempfile::tempdir()?;
    let (mac, vm) = (dir.path().join("mac"), dir.path().join("vm"));
    fs::create_dir_all(&mac)?;
    fs::create_dir_all(&vm)?;
    for i in 0..1000 {
        fs::create_dir_all(mac.join(format!("src/{}", i % 20)))?;
        fs::write(mac.join(format!("src/{}/f{i}.rs", i % 20)), format!("// {i}\n"))?;
    }

    let (vm_end, mac_end) = delayed_pair(rtt / 2)?;
    let (vm_root, vm_state) = (vm.clone(), dir.path().join("vm-state"));
    thread::spawn(move || {
        let mut f = Follower::new(vm_root, vm_state).unwrap();
        let r = vm_end.try_clone().unwrap();
        let _ = f.serve(r, vm_end);
    });
    let (ev_tx, ev_rx) = unbounded();
    let (_stop_tx, stop_rx) = unbounded::<()>();
    let (mac_root, mac_state) = (mac.clone(), dir.path().join("mac-state"));
    let mut link = Some(mac_end);
    thread::spawn(move || {
        let mut l = Leader::new(mac_root, mac_state, ev_tx).unwrap();
        l.run(
            || {
                let s = link.take().ok_or_else(|| std::io::Error::other("one link only"))?;
                Ok((s.try_clone()?, s))
            },
            &stop_rx,
        );
    });
    let start = Instant::now();
    loop {
        match ev_rx.recv_timeout(Duration::from_secs(60))? {
            Event::Online { paths, took } => {
                println!("first sync: {paths} files in {took:?} (wall {:?})", start.elapsed());
                break;
            }
            Event::Alert { reason } => println!("ALERT {reason}"),
            _ => {}
        }
    }
    thread::spawn(move || {
        for e in ev_rx {
            if let Event::Alert { reason } | Event::Offline { reason } = e {
                println!("ALERT {reason}");
            }
        }
    });

    let mut lost = 0;
    for (name, from, to) in [("mac->vm", &mac, &vm), ("vm->mac", &vm, &mac)] {
        let mut took = vec![];
        for n in 0..edits {
            let rel = format!("src/{}/f{}.rs", n % 20, (n * 37) % 1000);
            let body = format!("// {name} edit {n}\n");
            let t = Instant::now();
            write_atomic(&from.join(&rel), body.as_bytes())?;
            loop {
                if fs::read(to.join(&rel)).is_ok_and(|b| b == body.as_bytes()) {
                    took.push(t.elapsed());
                    break;
                }
                if t.elapsed() > Duration::from_secs(10) {
                    lost += 1;
                    break;
                }
                thread::sleep(Duration::from_micros(200));
            }
            thread::sleep(Duration::from_millis(5));
        }
        took.sort();
        let at = |q: f64| {
            took.get(((took.len() as f64 - 1.0) * q).round() as usize).copied().unwrap_or_default()
        };
        println!(
            "{name}: n={} p50={:.1}ms p95={:.1}ms max={:.1}ms (rtt {}ms)",
            took.len(),
            at(0.5).as_secs_f64() * 1e3,
            at(0.95).as_secs_f64() * 1e3,
            at(1.0).as_secs_f64() * 1e3,
            rtt.as_millis()
        );
    }
    println!("lost edits: {lost}");
    if lost > 0 {
        std::process::exit(1);
    }
    Ok(())
}

/// Editors save by temp file and rename, as here.
fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("bench-tmp");
    fs::write(&tmp, bytes)?;
    fs::rename(tmp, path)
}

/// A socketpair whose every chunk waits `delay` in each direction.
fn delayed_pair(delay: Duration) -> std::io::Result<(UnixStream, UnixStream)> {
    if delay.is_zero() {
        return UnixStream::pair();
    }
    let (a, a_in) = UnixStream::pair()?;
    let (b, b_in) = UnixStream::pair()?;
    for (mut from, mut to) in [(a_in.try_clone()?, b_in.try_clone()?), (b_in, a_in)] {
        thread::spawn(move || {
            let (tx, rx) = unbounded::<(Instant, Vec<u8>)>();
            thread::spawn(move || {
                for (at, chunk) in rx {
                    thread::sleep(at.saturating_duration_since(Instant::now()));
                    if to.write_all(&chunk).is_err() {
                        return;
                    }
                }
            });
            let mut buf = vec![0u8; 1 << 16];
            while let Ok(n) = from.read(&mut buf) {
                if n == 0 || tx.send((Instant::now() + delay, buf[..n].to_vec())).is_err() {
                    return;
                }
            }
        });
    }
    Ok((a, b))
}
