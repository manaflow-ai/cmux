use super::*;
use tokio::sync::mpsc;

fn peer() -> std::sync::Arc<Peer> {
    let (tx, _notices) = mpsc::channel(64);
    Peer::new("huge-blue", "ws://127.0.0.1:9", None, None, tx)
}

/// remote-ssh-reconnect probe: a chat started as the network comes back after a 150 s drop
/// waits for the link (`new_on_peer`); one for a machine gone for longer is refused at once.
#[test]
fn a_new_chat_waits_on_a_young_outage_only() {
    let peer = peer();
    let now = crate::store::now_ms();
    peer.with_link(|l| {
        l.down(now - 150_000, Duration::from_secs(1));
    });
    assert!(peer.reconnects_soon(), "a 150 s outage still reconnects within a second");
    peer.login_refused.store(true, std::sync::atomic::Ordering::SeqCst);
    assert!(!peer.reconnects_soon(), "a refused login holds its attempts back");
    let gone = self::peer();
    gone.with_link(|l| {
        l.down(now - 2 * WANTED_OUTAGE_FOR.as_millis() as u64, Duration::from_secs(60));
    });
    assert!(!gone.reconnects_soon(), "a machine gone for long is refused at once");
}

/// cosmic-gray, 2026-11-21: reads that kept asking about swarm VMs long gone re-dialed each
/// one's ssh about once a second. Past `WANTED_OUTAGE_FOR` an ask no longer cuts the wait;
/// a message still does.
#[tokio::test(start_paused = true)]
async fn an_ask_about_a_peer_down_for_minutes_waits_its_backoff_but_a_message_cuts_it() {
    let peer = peer();
    let long_ago = crate::store::now_ms() - 2 * WANTED_OUTAGE_FOR.as_millis() as u64;
    peer.with_link(|l| {
        l.down(long_ago, Duration::from_secs(60));
    });
    assert!(!peer.asks_shorten(crate::store::now_ms()));
    let delay = Duration::from_secs(20);
    let waiting = peer.clone();
    let started = Instant::now();
    let wait = tokio::spawn(async move { waiting.wait_backoff(delay).await });
    for _ in 0..30 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        peer.want();
    }
    assert!(!wait.is_finished(), "asks every half second for 15 s cut nothing");
    assert!(started.elapsed() < delay);
    peer.wake();
    assert_eq!(wait.await.unwrap(), BackoffWait::Done);
    assert!(started.elapsed() < delay, "a message cuts it: {:?}", started.elapsed());

    let young = self::peer();
    young.with_link(|l| {
        l.down(crate::store::now_ms(), Duration::from_secs(60));
    });
    assert!(young.asks_shorten(crate::store::now_ms()), "an outage just begun still heeds asks");
}

#[tokio::test(start_paused = true)]
async fn a_refusal_cuts_a_long_backoff_wait_to_the_wanted_bound() {
    let peer = peer();
    let waiting = peer.clone();
    let started = Instant::now();
    let wait = tokio::spawn(async move { waiting.wait_backoff(Backoff::CAP).await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(!wait.is_finished());
    // A client opens a chat on the peer while its link is down.
    peer.want();
    assert_eq!(wait.await.unwrap(), BackoffWait::Done);
    assert!(started.elapsed() <= Backoff::WANTED_CAP, "{:?}", started.elapsed());
}

/// A client that asks while the link is down gets the next attempt at once, not after
/// the wanted bound; asks that keep coming get one cut per `WANTED_CAP`.
#[tokio::test(start_paused = true)]
async fn an_ask_starts_the_next_attempt_at_once_once_per_cap() {
    let peer = peer();
    let waiting = peer.clone();
    let started = Instant::now();
    let wait = tokio::spawn(async move { waiting.wait_backoff(Backoff::CAP).await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    peer.want();
    assert_eq!(wait.await.unwrap(), BackoffWait::Done);
    assert!(started.elapsed() < Duration::from_millis(150), "{:?}", started.elapsed());

    let waiting = peer.clone();
    let again = Instant::now();
    let wait = tokio::spawn(async move { waiting.wait_backoff(Backoff::CAP).await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    peer.want();
    assert_eq!(wait.await.unwrap(), BackoffWait::Done);
    assert!(again.elapsed() >= Backoff::WANTED_CAP / 2, "{:?}", again.elapsed());
}

/// Review of #38015 (F1): an ask made while the attempt was still opening its tunnel, before
/// anything listened for it, restarts the attempt all the same; one before the mark does not.
#[tokio::test(start_paused = true)]
async fn an_ask_before_the_listener_still_counts_when_it_came_after_the_mark() {
    let peer = peer();
    let after = Instant::now() + Duration::from_millis(100);
    tokio::time::advance(Duration::from_millis(200)).await;
    peer.want();
    tokio::time::timeout(Duration::from_millis(10), peer.next_ask_after(after))
        .await
        .expect("an ask after the mark counts, though nothing listened yet");
    let later = Instant::now() + Duration::from_millis(100);
    peer.want();
    let early = tokio::time::timeout(Duration::from_millis(50), peer.next_ask_after(later));
    assert!(early.await.is_err(), "an ask before the mark is not counted");
}

#[tokio::test(start_paused = true)]
async fn an_unwanted_peer_waits_its_whole_delay_and_a_stop_ends_any_wait() {
    let peer = peer();
    let started = Instant::now();
    assert_eq!(peer.wait_backoff(Duration::from_secs(20)).await, BackoffWait::Done);
    assert!(started.elapsed() >= Duration::from_secs(20));

    peer.want();
    tokio::time::advance(WANTED_FOR).await;
    assert!(!peer.is_wanted(), "an ask lapses by itself");

    let waiting = peer.clone();
    let wait = tokio::spawn(async move { waiting.wait_backoff(Duration::from_secs(3_600)).await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    peer.stop();
    assert_eq!(wait.await.unwrap(), BackoffWait::Stopped);
}

/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
/// faster". A peer that failed while the network was down waited out its backoff (up to
/// `Backoff::CAP`) after the network came back; a change of this computer's network now ends
/// the wait at once, one change one attempt.
#[tokio::test(start_paused = true)]
async fn a_network_change_ends_a_backoff_wait_at_once() {
    use crate::no_panic::LockExt as _;
    let peer = peer();
    let (changes, seen) = tokio::sync::watch::channel(0);
    *peer.network.lock_or_recover() = seen;
    for _ in 0..2 {
        let waiting = peer.clone();
        let wait = tokio::spawn(async move { waiting.wait_backoff(Backoff::CAP).await });
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(!wait.is_finished());
        let changed = Instant::now();
        changes.send_modify(|n| *n += 1);
        assert_eq!(wait.await.unwrap(), BackoffWait::Done);
        assert!(changed.elapsed() < Duration::from_millis(10), "{:?}", changed.elapsed());
    }
    // A change already acted on does not end the next wait.
    let waiting = peer.clone();
    let wait = tokio::spawn(async move { waiting.wait_backoff(Duration::from_secs(20)).await });
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert!(!wait.is_finished(), "one change, one attempt");
    peer.stop();
    assert_eq!(wait.await.unwrap(), BackoffWait::Stopped);
}

/// ask-3c089caeef: the next ready link logs how long the reconnect a network change sent took
/// (`reconnect_ms`), once; NOW's paths row reads it in place of "duration unmeasured".
#[tokio::test(start_paused = true)]
async fn a_network_change_starts_the_reconnect_clock_read_once() {
    use crate::no_panic::LockExt as _;
    let peer = peer();
    assert_eq!(peer.reconnect_took(), None, "no trigger, no duration");
    let (changes, seen) = tokio::sync::watch::channel(0);
    *peer.network.lock_or_recover() = seen;
    let waiting = peer.clone();
    let wait = tokio::spawn(async move { waiting.wait_backoff(Backoff::CAP).await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    changes.send_modify(|n| *n += 1);
    assert_eq!(wait.await.unwrap(), BackoffWait::Done);
    tokio::time::advance(Duration::from_millis(250)).await;
    let (took, cause) = peer.reconnect_took().expect("the change is remembered");
    assert_eq!(cause, "network");
    assert!(took >= Duration::from_millis(250), "{took:?}");
    assert_eq!(peer.reconnect_took(), None, "read once");
}

fn wake_env(peer: &Peer) -> Option<String> {
    let ssh = peer.ssh_command();
    ssh.as_std()
        .get_envs()
        .find(|(k, _)| *k == WAKE_ENV)
        .and_then(|(_, v)| v.map(|v| v.to_string_lossy().into_owned()))
}

#[tokio::test(start_paused = true)]
async fn a_message_marks_the_peer_to_wake_for_a_window_and_wants_it() {
    let peer = peer();
    assert!(!peer.waking());
    assert_eq!(wake_env(&peer), None, "a background reconnect asks no route to wake");
    peer.want();
    assert_eq!(wake_env(&peer), None, "a chat opened on the peer is no message");
    peer.wake();
    assert!(peer.waking() && peer.is_wanted());
    assert_eq!(wake_env(&peer).as_deref(), Some("1"));
    tokio::time::advance(WANTED_FOR + Duration::from_secs(1)).await;
    assert!(peer.is_wanted(), "wanted while it wakes, past an ordinary ask's window");
    tokio::time::advance(WAKE_FOR).await;
    assert!(!peer.waking() && !peer.is_wanted(), "the mark lapses by itself");
    assert_eq!(wake_env(&peer), None);
}

#[tokio::test]
async fn a_message_runs_peer_wake_once_per_window_with_the_peer_name() {
    let peer = peer();
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("woken");
    let script = format!("printf '%s %s\\n' \"$ACPMUX_PEER_WAKE\" \"$1\" >> {}", log.display());
    assert_eq!(peer.wake_argv(), None, "no hook handed over: nothing runs");
    let hook: WakeHook = Arc::new(StdMutex::new(None));
    peer.set_wake_hook(hook.clone());
    assert_eq!(peer.wake_argv(), None, "no peerWake configured: nothing runs");
    *hook.lock().unwrap() = Some(vec!["sh".into(), "-c".into(), script, "wake".into()]);
    assert_eq!(peer.wake_argv().unwrap().last().map(String::as_str), Some("huge-blue"));
    peer.wake();
    peer.wake(); // the same window: no second run
    let read = || std::fs::read_to_string(&log).unwrap_or_default();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while read().is_empty() {
        assert!(std::time::Instant::now() < deadline, "peerWake never ran");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(read(), "1 huge-blue\n");
    // A window that lapsed opens again on the next message.
    *peer.wanted.wake_until.lock().unwrap() = Some(Instant::now());
    *peer.wanted.hook_at.lock().unwrap() = Instant::now().checked_sub(WAKE_FOR);
    peer.wake();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while read().lines().count() < 2 {
        assert!(std::time::Instant::now() < deadline, "the next window ran no peerWake");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // A reload that removes the key stops it at once (`catalog_reload.rs`).
    *hook.lock().unwrap() = None;
    assert_eq!(peer.wake_argv(), None);
}

/// cmuxterm-hq#17784: a message whose machine was resumed, then parked again before it went
/// in, is tried by its outbox at 0, 2, 7, 17, 47, 107, 227 and 527 s (its retry delays, 2, 5,
/// 10, 30, 60, 120, 300 s, added up), and each attempt marks the peer again. Before, those
/// marks kept the window open from 0 s to 407 s and `peerWake` ran at 0 s, then not until
/// 527 s; now it runs again at 227 s, the first attempt `WAKE_FOR` after the last run. The
/// clock is tokio's, paused.
#[tokio::test(start_paused = true)]
async fn a_message_still_waiting_runs_peer_wake_again_each_window() {
    let peer = peer();
    let dir = tempfile::tempdir().unwrap();
    let log = dir.path().join("woken");
    let script = format!("printf '%s\\n' \"$1\" >> {}", log.display());
    let hook: WakeHook =
        Arc::new(StdMutex::new(Some(vec!["sh".into(), "-c".into(), script, "wake".into()])));
    peer.set_wake_hook(hook);
    let runs = || std::fs::read_to_string(&log).unwrap_or_default().lines().count();
    // Polls on the real clock, so the paused one moves only by `advance`: the hook's task
    // gets the thread between polls.
    async fn settle(runs: &dyn Fn() -> usize, want: usize) {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while runs() < want && std::time::Instant::now() < deadline {
            tokio::task::yield_now().await;
            std::thread::sleep(Duration::from_millis(20));
        }
        for _ in 0..10 {
            tokio::task::yield_now().await;
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    let started = Instant::now();
    let mut at = Duration::ZERO;
    let mut seen = Vec::new();
    let want = [(0u64, 1usize), (2, 1), (7, 1), (17, 1), (47, 1), (107, 1), (227, 2), (527, 3)];
    for (attempt, runs_by_then) in want {
        let to = Duration::from_secs(attempt);
        tokio::time::advance(to - at).await;
        at = to;
        peer.wake();
        settle(&runs, runs_by_then).await;
        assert!(peer.waking(), "marked to wake while the message waits");
        seen.push((attempt, runs()));
    }
    assert_eq!(Instant::now() - started, Duration::from_secs(527));
    assert_eq!(seen, want, "peerWake runs once per WAKE_FOR while the message waits");
}

#[tokio::test(start_paused = true)]
async fn a_message_cuts_a_long_backoff_wait_to_the_wanted_bound() {
    let peer = peer();
    let waiting = peer.clone();
    let started = Instant::now();
    let wait = tokio::spawn(async move { waiting.wait_backoff(Backoff::CAP).await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    peer.wake();
    assert_eq!(wait.await.unwrap(), BackoffWait::Done);
    assert!(started.elapsed() <= Backoff::WANTED_CAP, "{:?}", started.elapsed());
}

#[test]
fn a_ready_link_that_ends_is_wanted_unless_it_died_right_after_its_handshake() {
    let now = crate::store::now_ms();
    let ended = |ready_ms_ago: Option<u64>, restarting: bool| {
        let peer = peer();
        if let Some(ago) = ready_ms_ago {
            peer.with_link(|l| {
                l.opened(now - ago);
                l.ready(now - ago);
            });
        }
        peer.link_ending(restarting);
        peer.is_wanted()
    };
    assert!(ended(Some(20_000), false), "a link up 20 s drops: its chats wait on it");
    let outage = peer();
    outage.with_link(|l| {
        l.opened(now - 20_000);
        l.ready(now - 20_000);
    });
    outage.link_ending(false);
    let until = outage.wanted.until.lock().unwrap().unwrap();
    assert!(
        until > Instant::now() + WANTED_FOR,
        "a stable outage keeps fast reconnects longer than one ask"
    );
    let restarted = peer();
    restarted.with_link(|l| {
        l.opened(now);
        l.ready(now);
    });
    restarted.link_ending(true);
    restarted.want();
    let until = restarted.wanted.until.lock().unwrap().unwrap();
    assert!(until > Instant::now() + WANTED_FOR, "an ask never shortens a restart's window");
    assert!(ended(Some(1_000), true), "a restart (Close 1012), however short the link");
    assert!(!ended(Some(1_000), false), "a crash loop keeps its backoff");
    assert!(!ended(None, false), "a handshake that failed is no open chat");
}
