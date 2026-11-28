use super::*;
use std::sync::atomic::AtomicUsize;

fn gate() -> Arc<DialGate> {
    Arc::new(DialGate::new(3, Duration::from_millis(1500), Duration::from_secs(2)))
}

#[tokio::test(start_paused = true)]
async fn a_single_dial_goes_at_once() {
    let gate = gate();
    let started = Instant::now();
    let slot = gate.enter(false, 0.9).await;
    assert!(slot.is_some());
    assert_eq!(started.elapsed(), Duration::ZERO);
    assert_eq!(gate.in_flight(), 1);
    drop(slot);
    assert_eq!(gate.in_flight(), 0);
    assert_eq!(gate.waited(), 0);
}

/// 40 links dropped together: no more than the slots dial at once, the rest start spread
/// over the window, and every one dials.
#[tokio::test(start_paused = true)]
async fn forty_dials_at_once_go_a_few_at_a_time_and_all_go() {
    let gate = gate();
    let t0 = Instant::now();
    let dialing = Arc::new(AtomicUsize::new(0));
    let most = Arc::new(AtomicUsize::new(0));
    let starts = Arc::new(Mutex::new(Vec::new()));
    let mut dials = Vec::new();
    for i in 0..40u32 {
        let (gate, dialing, most, starts) =
            (gate.clone(), dialing.clone(), most.clone(), starts.clone());
        dials.push(tokio::spawn(async move {
            gate.pass(false, f64::from(i) / 40.0, async {
                let now = dialing.fetch_add(1, Ordering::SeqCst) + 1;
                most.fetch_max(now, Ordering::SeqCst);
                starts.lock().unwrap().push(t0.elapsed());
                // A dial that opens in 50 ms.
                tokio::time::sleep(Duration::from_millis(50)).await;
                dialing.fetch_sub(1, Ordering::SeqCst);
            })
            .await;
        }));
    }
    for dial in dials {
        dial.await.unwrap();
    }
    let starts = starts.lock().unwrap().clone();
    assert_eq!(starts.len(), 40);
    assert!(most.load(Ordering::SeqCst) <= 3, "{}", most.load(Ordering::SeqCst));
    let at_once = starts.iter().filter(|s| s.is_zero()).count();
    assert_eq!(at_once, 3, "{starts:?}");
    let last = starts.iter().max().unwrap();
    assert!(*last < Duration::from_secs(3), "{starts:?}");
    assert_eq!(gate.waited(), 37);
}

/// A peer a client waits on skips the spread: it dials before the burst's spread ones.
#[tokio::test(start_paused = true)]
async fn a_wanted_dial_goes_before_the_spread_ones() {
    let gate = gate();
    let held: Vec<_> = futures::future::join_all((0..3).map(|_| gate.enter(false, 0.0))).await;
    let order = Arc::new(Mutex::new(Vec::new()));
    let spread = {
        let (gate, order) = (gate.clone(), order.clone());
        tokio::spawn(async move {
            gate.pass(false, 0.5, async { order.lock().unwrap().push("spread") }).await;
        })
    };
    let wanted = {
        let (gate, order) = (gate.clone(), order.clone());
        tokio::spawn(async move {
            gate.pass(true, 0.5, async { order.lock().unwrap().push("wanted") }).await;
        })
    };
    tokio::task::yield_now().await;
    drop(held);
    spread.await.unwrap();
    wanted.await.unwrap();
    assert_eq!(*order.lock().unwrap(), vec!["wanted", "spread"]);
}

/// A background dial already queued for a slot does not go before a wanted one that queued
/// after it: the freed slot goes to the wanted dial.
#[tokio::test(start_paused = true)]
async fn a_wanted_dial_goes_before_an_earlier_queued_background_one() {
    let gate = gate();
    let mut held: Vec<_> = futures::future::join_all((0..3).map(|_| gate.enter(false, 0.0))).await;
    let order = Arc::new(Mutex::new(Vec::new()));
    let background = {
        let (gate, order) = (gate.clone(), order.clone());
        tokio::spawn(async move {
            gate.pass(false, 0.0, async { order.lock().unwrap().push("background") }).await;
        })
    };
    // The background dial (spread with jitter 0) is queued for a slot before the wanted one.
    tokio::time::sleep(Duration::from_millis(1)).await;
    let wanted = {
        let (gate, order) = (gate.clone(), order.clone());
        tokio::spawn(async move {
            gate.pass(true, 0.0, async { order.lock().unwrap().push("wanted") }).await;
        })
    };
    tokio::time::sleep(Duration::from_millis(1)).await;
    assert!(order.lock().unwrap().is_empty());
    // One slot comes free: the wanted dial takes it, and the background one goes after.
    held.pop();
    wanted.await.unwrap();
    background.await.unwrap();
    assert_eq!(*order.lock().unwrap(), vec!["wanted", "background"]);
    assert_eq!(gate.in_flight(), 2);
    drop(held);
    assert_eq!(gate.in_flight(), 0);
}

/// A dial cancelled while it waits for a slot (its peer stopped) costs the gate nothing:
/// the slot it would have had goes to the next dial, or back to free.
#[tokio::test(start_paused = true)]
async fn a_cancelled_waiting_dial_does_not_keep_a_slot() {
    let gate = gate();
    let held: Vec<_> = futures::future::join_all((0..3).map(|_| gate.enter(true, 0.0))).await;
    let gave_up = tokio::time::timeout(Duration::from_millis(100), gate.enter(true, 0.0)).await;
    assert!(gave_up.is_err());
    let next = tokio::spawn({
        let gate = gate.clone();
        async move { gate.enter(true, 0.0).await.is_some() }
    });
    tokio::task::yield_now().await;
    drop(held);
    assert!(next.await.unwrap());
    assert_eq!(gate.in_flight(), 0);
    let started = Instant::now();
    let slots: Vec<_> = futures::future::join_all((0..3).map(|_| gate.enter(true, 0.0))).await;
    assert_eq!(started.elapsed(), Duration::ZERO);
    assert_eq!(gate.in_flight(), 3);
    drop(slots);
}

/// A dial that hangs gives its slot back after the hold, and still runs to its end.
#[tokio::test(start_paused = true)]
async fn a_hung_dial_frees_its_slot_after_the_hold() {
    let gate = gate();
    let hung: Vec<_> = (0..3)
        .map(|_| {
            let gate = gate.clone();
            tokio::spawn(async move {
                gate.pass(false, 0.0, tokio::time::sleep(Duration::from_secs(30))).await;
            })
        })
        .collect();
    tokio::task::yield_now().await;
    assert_eq!(gate.in_flight(), 3);
    let started = Instant::now();
    gate.pass(true, 0.0, async {}).await;
    assert_eq!(started.elapsed(), Duration::from_secs(2));
    for dial in hung {
        dial.await.unwrap();
    }
    assert_eq!(gate.in_flight(), 0);
}

/// Dials one after another, each done before the next, are no burst however quick: the 7th
/// quick cold connect in a second waited up to the whole spread (2026-11-24).
#[tokio::test(start_paused = true)]
async fn dials_one_after_another_in_a_second_all_go_at_once() {
    let gate = gate();
    let started = Instant::now();
    for _ in 0..20 {
        gate.pass(false, 0.9, tokio::time::sleep(Duration::from_millis(10))).await;
    }
    assert_eq!(started.elapsed(), Duration::from_millis(200));
    assert_eq!(gate.waited(), 0);
}

/// A dial still in flight counts in its burst: past the slots, the next ones spread.
#[tokio::test(start_paused = true)]
async fn dials_still_in_flight_count_in_the_burst() {
    let gate = gate();
    let held: Vec<_> = futures::future::join_all((0..3).map(|_| gate.enter(false, 0.0))).await;
    let started = Instant::now();
    let fourth = tokio::spawn({
        let gate = gate.clone();
        async move { gate.enter(false, 0.5).await.is_some() }
    });
    tokio::task::yield_now().await;
    // The slots come free at once, but the fourth entered behind three in flight: it spreads.
    drop(held);
    assert!(fourth.await.unwrap());
    assert_eq!(started.elapsed(), Duration::from_millis(750));
    assert_eq!(gate.waited(), 1);
}

/// A burst ends: a dial a while later is one link dropping on its own, and goes at once.
#[tokio::test(start_paused = true)]
async fn a_dial_after_the_burst_goes_at_once() {
    let gate = gate();
    for _ in 0..10 {
        drop(gate.enter(false, 0.0).await);
    }
    tokio::time::sleep(BURST).await;
    let started = Instant::now();
    drop(gate.enter(false, 0.9).await);
    assert_eq!(started.elapsed(), Duration::ZERO);
}
