use super::*;
use crate::host_pressure::Sample;
use crate::host_pressure::tests::{calm, incident};
use std::sync::Arc;

/// A probe whose readings a test changes between samples, and counts.
#[derive(Default)]
struct FakeProbe {
    sample: Mutex<Sample>,
    reads: Mutex<u32>,
    /// Set: a sample blocks until the test sends (a slow disk, a stuck read).
    gate: Mutex<Option<std::sync::mpsc::Receiver<()>>>,
}

impl Probe for Arc<FakeProbe> {
    fn sample(&self) -> Sample {
        *self.reads.lock().unwrap() += 1;
        if let Some(gate) = self.gate.lock().unwrap().as_ref() {
            let _ = gate.recv();
        }
        self.sample.lock().unwrap().clone()
    }
}

fn defaults(_host: &str) -> Budget {
    Budget::default()
}

fn meter(probe: &Arc<FakeProbe>) -> Meter {
    Meter::new("h".into(), Box::new(probe.clone()), Box::new(defaults))
}

#[test]
fn the_meter_samples_at_most_once_per_sample_seconds() {
    let probe = Arc::new(FakeProbe::default());
    *probe.sample.lock().unwrap() = calm();
    let m = meter(&probe);
    let t0 = Instant::now();
    m.sample_at(t0).unwrap();
    m.sample_at(t0 + Duration::from_millis(2_900)).unwrap();
    assert_eq!(*probe.reads.lock().unwrap(), 1);
    m.sample_at(t0 + Duration::from_secs(3)).unwrap();
    assert_eq!(*probe.reads.lock().unwrap(), 2);
}

#[test]
fn swap_growth_is_the_rate_between_two_samples() {
    let probe = Arc::new(FakeProbe::default());
    let set_swap = |bytes: u64| {
        *probe.sample.lock().unwrap() = Sample { swapout_bytes: Some(bytes), ..calm() }
    };
    let m = meter(&probe);
    let t0 = Instant::now();
    set_swap(1 << 30);
    // One sample has no rate yet.
    assert_eq!(m.sample_at(t0).unwrap().swap_mb_per_min, None);
    // 100 MiB in 30 s is 200 MB/min: over.
    set_swap((1 << 30) + (100 << 20));
    let v = m.sample_at(t0 + Duration::from_secs(30)).unwrap();
    assert_eq!((v.swap_mb_per_min, v.ok), (Some(200.0), false));
    // Then flat: back within budget.
    let v = m.sample_at(t0 + Duration::from_secs(60)).unwrap();
    assert_eq!((v.swap_mb_per_min, v.ok), (Some(0.0), true));
    // A baseline older than the window gives no rate, and starts a new one.
    set_swap(5 << 30);
    assert_eq!(m.sample_at(t0 + Duration::from_secs(60 + 601)).unwrap().swap_mb_per_min, None);
    assert_eq!(m.sample_at(t0 + Duration::from_secs(60 + 661)).unwrap().swap_mb_per_min, Some(0.0));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stalled_sample_never_holds_a_turn_or_status() {
    let probe = Arc::new(FakeProbe::default());
    *probe.sample.lock().unwrap() = incident();
    let (release, gate) = std::sync::mpsc::channel();
    *probe.gate.lock().unwrap() = Some(gate);
    let m = Arc::new(meter(&probe));
    // A turn's acceptance never waits: no verdict yet, and one sample starts.
    let start = Instant::now();
    assert_eq!(m.peek(), None);
    // Status does not wait behind a sample in flight: it answers with what it has.
    assert_eq!(m.current().await, None);
    assert_eq!(m.current().await, None);
    assert!(start.elapsed() < SAMPLE_WAIT, "{:?}", start.elapsed());
    // One sample at a time: the stalled one is the only read, and no other
    // blocking job queues behind it.
    for _ in 0..200 {
        if *probe.reads.lock().unwrap() > 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(*probe.reads.lock().unwrap(), 1);
    assert!(m.start_sample().is_none());
    release.send(()).unwrap();
    let mut v = None;
    for _ in 0..200 {
        v = m.last();
        if v.is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(!v.expect("the released sample ends").ok);
    // Fresh now: both paths answer from it without another read.
    assert!(m.peek().is_some_and(|v| !v.ok));
    assert!(m.current().await.is_some());
    assert_eq!(*probe.reads.lock().unwrap(), 1);
}

#[tokio::test]
async fn peek_repeats_a_verdict_for_a_minute_only() {
    let probe = Arc::new(FakeProbe::default());
    *probe.sample.lock().unwrap() = incident();
    let m = Arc::new(meter(&probe));
    let Some(old) = Instant::now().checked_sub(Duration::from_secs(30)) else { return };
    m.sample_at(old).unwrap();
    assert!(m.peek().is_some(), "a 30 s old verdict is repeated");
    let m = Arc::new(meter(&probe));
    let Some(older) = Instant::now().checked_sub(Duration::from_secs(61)) else { return };
    m.sample_at(older).unwrap();
    assert_eq!(m.peek(), None, "a 61 s old verdict is not");
}
