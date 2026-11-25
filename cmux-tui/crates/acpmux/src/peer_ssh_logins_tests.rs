use super::*;
use crate::peer_dial_gate::{DialGate, HOLD, SLOTS, SPREAD};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::time::Instant;

/// ssh children of a fake daemon: how many are logging in now, the most at once in the first
/// 60 s, and how many links opened.
#[derive(Default)]
struct Spawner {
    logging_in: AtomicUsize,
    most: AtomicUsize,
    opened: AtomicUsize,
}

impl Spawner {
    /// One ssh process that takes `login` to log in, counted while it does.
    async fn ssh(&self, t0: Instant, login: Duration) {
        let now = self.logging_in.fetch_add(1, Ordering::SeqCst) + 1;
        if t0.elapsed() < Duration::from_secs(60) {
            self.most.fetch_max(now, Ordering::SeqCst);
        }
        tokio::time::sleep(login).await;
        self.logging_in.fetch_sub(1, Ordering::SeqCst);
    }

    /// A peer link's first ssh dial: the tunnel and the token read beside it
    /// (`Peer::open_ssh`), both logging in at once.
    async fn first_dial(&self, t0: Instant, login: Duration) {
        tokio::join!(self.ssh(t0, login), self.ssh(t0, login));
        self.opened.fetch_add(1, Ordering::SeqCst);
    }
}

/// A daemon starting with `peers` ssh peers whose logins each take `login`: every link dials
/// at once through the dial gate, and through the login gate when `bounded`. The most ssh
/// children logging in at once in the first 60 s, and when the last link opened.
async fn boot(peers: usize, login: Duration, bounded: bool) -> (usize, Duration) {
    let dials = Arc::new(DialGate::new(SLOTS, SPREAD, HOLD));
    let logins = Arc::new(DialGate::new(LOGINS, Duration::ZERO, LOGIN_HOLD));
    let spawner = Arc::new(Spawner::default());
    let t0 = Instant::now();
    let links: Vec<_> = (0..peers)
        .map(|i| {
            let (dials, logins, spawner) = (dials.clone(), logins.clone(), spawner.clone());
            let jitter = i as f64 / peers as f64;
            tokio::spawn(async move {
                let dial = spawner.first_dial(t0, login);
                if bounded {
                    dials.pass(false, jitter, login_through(&logins, false, dial)).await;
                } else {
                    dials.pass(false, jitter, dial).await;
                }
            })
        })
        .collect();
    for link in links {
        link.await.unwrap();
    }
    assert_eq!(spawner.opened.load(Ordering::SeqCst), peers, "every link opens");
    (spawner.most.load(Ordering::SeqCst), t0.elapsed())
}

/// A daemon starting with 130 peers on a loaded host (a 15 s ssh login, right after a reboot)
/// had every peer's ssh logging in at once within seconds (2026-11-24); through the login gate
/// no more than two per login slot are, and every link still opens.
#[tokio::test(start_paused = true)]
async fn a_daemon_with_130_peers_logs_in_a_few_at_a_time_on_a_loaded_host() {
    let login = Duration::from_secs(15);
    let (before, _) = boot(130, login, false).await;
    let (after, all_open) = boot(130, login, true).await;
    eprintln!("130 peers, 15 s logins: most ssh logging in at once in 60 s: {before} -> {after}");
    assert!(before > 2 * LOGINS * 2, "the dial gate alone let {before} through");
    assert!(after <= 2 * LOGINS, "{after} ssh logging in at once");
    // 130 logins, LOGINS at a time, each slot held its 15 s.
    assert!(all_open <= Duration::from_secs(15 * 130 / LOGINS as u64 + 30), "{all_open:?}");
}

/// On a host that is not loaded (a 300 ms login) the bound costs the boot a few seconds.
#[tokio::test(start_paused = true)]
async fn a_daemon_with_130_peers_on_a_quiet_host_has_every_link_open_within_seconds() {
    let login = Duration::from_millis(300);
    let (before, before_open) = boot(130, login, false).await;
    let (after, all_open) = boot(130, login, true).await;
    eprintln!(
        "130 peers, 300 ms logins: most ssh logging in at once {before} -> {after}, \
         all open {before_open:?} -> {all_open:?}"
    );
    assert!(after <= 2 * LOGINS, "{after} ssh logging in at once");
    assert!(all_open <= Duration::from_secs(10), "{all_open:?}");
}

/// A login a client waits on goes before background logins already queued.
#[tokio::test(start_paused = true)]
async fn a_wanted_login_goes_before_queued_background_ones() {
    let gate = Arc::new(DialGate::new(1, Duration::ZERO, LOGIN_HOLD));
    let order = Arc::new(std::sync::Mutex::new(Vec::new()));
    let busy: Vec<_> = (0..1)
        .map(|_| {
            let gate = gate.clone();
            tokio::spawn(async move {
                login_through(&gate, false, tokio::time::sleep(Duration::from_secs(1))).await;
            })
        })
        .collect();
    tokio::task::yield_now().await;
    let background = {
        let (gate, order) = (gate.clone(), order.clone());
        tokio::spawn(async move {
            login_through(&gate, false, async { order.lock().unwrap().push("background") }).await;
        })
    };
    tokio::time::sleep(Duration::from_millis(1)).await;
    let wanted = {
        let (gate, order) = (gate.clone(), order.clone());
        tokio::spawn(async move {
            login_through(&gate, true, async { order.lock().unwrap().push("wanted") }).await;
        })
    };
    tokio::time::sleep(Duration::from_millis(1)).await;
    for task in busy {
        task.await.unwrap();
    }
    wanted.await.unwrap();
    background.await.unwrap();
    assert_eq!(*order.lock().unwrap(), vec!["wanted", "background"]);
}

/// A token read inside the link's ssh dial shares the dial's slot: with every slot held by
/// such dials, none waits on itself.
#[tokio::test(start_paused = true)]
async fn a_login_inside_a_login_shares_its_slot() {
    let gate = Arc::new(DialGate::new(1, Duration::ZERO, LOGIN_HOLD));
    let started = Instant::now();
    let inner = login_through(&gate, false, async {
        login_through(&gate, false, async { gate.in_flight() }).await
    })
    .await;
    assert_eq!(inner, 1);
    assert_eq!(started.elapsed(), Duration::ZERO);
    assert_eq!(gate.in_flight(), 0);
}

/// A login that hangs gives its slot back after the hold.
#[tokio::test(start_paused = true)]
async fn a_hung_login_frees_its_slot_after_the_hold() {
    let gate = Arc::new(DialGate::new(1, Duration::ZERO, LOGIN_HOLD));
    let hung = {
        let gate = gate.clone();
        tokio::spawn(async move {
            login_through(&gate, false, tokio::time::sleep(Duration::from_secs(120))).await;
        })
    };
    tokio::task::yield_now().await;
    let started = Instant::now();
    login_through(&gate, false, async {}).await;
    assert_eq!(started.elapsed(), LOGIN_HOLD);
    hung.await.unwrap();
}
