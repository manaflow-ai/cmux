//! RFD 0127 cut 4, the `kill acpmux` with held ssh fault (cmux-fault): an ssh session through
//! the carrier lives through the dialer's acpmux dying. A holds a pipe to B's stand-in sshd
//! (`CircuitService::CmuxTuiResume`, `cmux_remote::resume_hold::hold`, as ssh's ProxyCommand
//! holds it). Mid-transfer, A's acpmux is killed: its kept circuits close, and a new carrier on
//! the same key takes its place, as the service manager's restart starts one. B keeps the sshd
//! connection parked (`hub_carrier_resume.rs`). The hold reconnects through the new carrier and
//! resumes, and the session's bytes come back whole: the banner, then every byte echoed once,
//! none lost or doubled.
//!
//! ```text
//! cargo test -p acpmux --features hub-carrier --test hub_carrier held_ssh -- --nocapture   # CMUX_FAULT_RUNS (20)
//! CMUX_FAULT_SEED=3 cargo test -p acpmux --features hub-carrier --test hub_carrier held_ssh -- --nocapture
//! ```

use super::*;
use cmux_fault::{Failed, Rng, Runs, Trace};
use cmux_remote::resume_hold::{Held, hold};
use std::sync::Mutex;

/// The bound on one run, setup included.
const RUN_BOUND: Duration = Duration::from_secs(60);

fn pattern(seed: u64, len: usize) -> Vec<u8> {
    let mut rng = Rng::new(seed);
    (0..len).map(|_| rng.next_u64() as u8).collect()
}

#[test]
fn hub_carrier_a_held_ssh_lives_through_kill_acpmux() -> Result<(), Failed> {
    let _ = HERMETIC;
    let replay = "cargo test -p acpmux --features hub-carrier --test hub_carrier held_ssh";
    Runs::new("kill acpmux with a held ssh", replay).at_most_parallel(4).run(|seed, trace| {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        runtime.block_on(async {
            tokio::time::timeout(RUN_BOUND, kill_acpmux_mid_ssh(seed, trace))
                .await
                .map_err(|_| format!("the run did not end within {RUN_BOUND:?}"))?
        })
    })
}

async fn kill_acpmux_mid_ssh(seed: u64, trace: &Trace) -> Result<(), String> {
    let mut rng = Rng::new(seed);
    let total = rng.range(1 << 20, 6 << 20) as usize;
    let kills = rng.range(1, 4) as usize;
    // Each kill lands once the session has read this much back: its transport is up.
    let mut at: Vec<usize> = (0..kills).map(|_| rng.range(1, total as u64 - 1) as usize).collect();
    at.sort_unstable();
    trace.note(format!("{total} bytes through the held ssh; kill acpmux at {at:?} read"));

    let fixture = kept_fixture(Duration::ZERO, true, true).await;
    let service = CircuitService::CmuxTuiResume { port: fixture.sshd_port };
    let dialer = Mutex::new(fixture.a.clone());
    let connects = AtomicU64::new(0);
    // Transports that came up: a kill waits for the one before it to have been replaced.
    let (up, mut up_rx) = watch::channel(0usize);
    let connect = || {
        let carrier = dialer.lock().unwrap().clone();
        let b_key = fixture.b_key.clone();
        connects.fetch_add(1, Ordering::SeqCst);
        let up = up.clone();
        async move {
            let transport = carrier.dial_service(&b_key, service).await?;
            up.send_modify(|up| *up += 1);
            Ok(transport)
        }
    };

    // The ssh client: writes the session's bytes, reads the banner and their echo.
    let (app, local) = tokio::io::duplex(64 * 1024);
    let (read_so_far, mut read_rx) = watch::channel(0usize);
    let sending = pattern(seed, total);
    let mut expected = BANNER.to_vec();
    expected.extend_from_slice(&sending);
    let client = tokio::spawn(async move {
        let (mut read, mut write) = tokio::io::split(app);
        let writing = async move {
            for piece in sending.chunks(16 * 1024) {
                write.write_all(piece).await.map_err(|e| e.to_string())?;
            }
            write.shutdown().await.map_err(|e| e.to_string())
        };
        let reading = async move {
            let mut got = Vec::new();
            let mut piece = vec![0u8; 16 * 1024];
            loop {
                match read.read(&mut piece).await.map_err(|e| e.to_string())? {
                    0 => return Ok(got),
                    n => got.extend_from_slice(&piece[..n]),
                }
                read_so_far.send_replace(got.len());
            }
        };
        let (wrote, got) = tokio::join!(writing, reading);
        wrote.and(got)
    });

    let killing = async {
        for (n, point) in at.iter().enumerate() {
            // A kill after the first waits for the hold to come back over the new carrier.
            if up_rx.wait_for(|up| *up > n).await.is_err()
                || read_rx.wait_for(|read| read >= point).await.is_err()
            {
                return Ok(());
            }
            let old = dialer.lock().unwrap().clone();
            let last = *read_rx.borrow();
            let cut = old.cut_kept(&fixture.b_key).await;
            *dialer.lock().unwrap() = fixture.restarted_a();
            drop(old);
            trace.note(format!("kill {n}: acpmux killed at {last} read (cut {cut})"));
            if !cut {
                return Err(format!("kill {n} found no circuit to close"));
            }
        }
        Ok::<(), String>(())
    };
    let (held, killed) = tokio::join!(hold(local, connect, Duration::from_secs(20)), killing);
    trace.note(format!("hold ended {held:?} after {} connects", connects.load(Ordering::SeqCst)));
    if held != Held::Finished {
        return Err(format!("the held ssh ended {held:?}"));
    }
    killed?;
    let got = within("the ssh client", client).await.map_err(|e| e.to_string())??;
    if got != expected {
        let first_off = got.iter().zip(&expected).position(|(a, b)| a != b);
        return Err(format!(
            "the session read {} bytes, {} expected (first difference at {first_off:?})",
            got.len(),
            expected.len()
        ));
    }
    if connects.load(Ordering::SeqCst) < 2 {
        return Err("no kill landed inside the session: it never resumed".into());
    }
    Ok(())
}
