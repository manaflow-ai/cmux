use super::*;
use tokio::sync::mpsc;

fn peer() -> std::sync::Arc<Peer> {
    let (tx, _notices) = mpsc::channel(64);
    Peer::new("huge-blue", "ws://127.0.0.1:9", None, None, tx)
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
