use super::*;
use crate::Sample;
use crate::tests::{calm, incident};
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

#[test]
fn the_meter_keeps_the_readings_of_its_last_sample() {
    let probe = Arc::new(FakeProbe::default());
    let m = meter(&probe);
    assert_eq!(m.last_sample(), None);
    *probe.sample.lock().unwrap() =
        Sample { cpu_busy: Some(0.95), hid_idle_seconds: Some(4.0), ..calm() };
    let t0 = Instant::now();
    m.sample_at(t0).unwrap();
    let kept = m.last_sample().unwrap();
    assert_eq!((kept.cpu_busy, kept.hid_idle_seconds), (Some(0.95), Some(4.0)));
    // A fresh verdict is reused and the readings with it; the next sample replaces them.
    *probe.sample.lock().unwrap() = Sample { cpu_busy: Some(0.10), ..calm() };
    m.sample_at(t0 + Duration::from_secs(1)).unwrap();
    assert_eq!(m.last_sample().unwrap().cpu_busy, Some(0.95));
    m.sample_at(t0 + Duration::from_secs(3)).unwrap();
    assert_eq!(m.last_sample().unwrap().cpu_busy, Some(0.10));
}

#[test]
fn the_verdict_carries_the_cpu_busy_reading_as_a_percent() {
    let probe = Arc::new(FakeProbe::default());
    *probe.sample.lock().unwrap() = Sample { cpu_busy: Some(0.4567), ..calm() };
    let v = meter(&probe).sample_at(Instant::now()).unwrap();
    assert_eq!(v.cpu_busy_pct, Some(45.7));
    assert_eq!(v.cpu_p50_pct, None, "one sample covers no window");
    let json = serde_json::to_value(&v).unwrap();
    assert_eq!(json["cpu_busy_pct"], 45.7);
    assert!(json.get("cpu_p50_pct").is_none(), "absent, not null, until measured");
}

#[test]
fn cpu_p50_is_the_time_weighted_median_of_the_meters_own_samples() {
    let probe = Arc::new(FakeProbe::default());
    let m = meter(&probe);
    let t0 = Instant::now();
    let at = |s: u64| t0 + Duration::from_secs(s);
    let busy = |b: f64| *probe.sample.lock().unwrap() = Sample { cpu_busy: Some(b), ..calm() };
    busy(0.1);
    // The first sample's reading covers no interval the meter knows of.
    assert_eq!(m.sample_at(at(0)).unwrap().cpu_window_s, None);
    busy(0.2);
    assert_eq!(m.sample_at(at(30)).unwrap().cpu_p50_pct, None, "30 s is under the minimum");
    busy(0.9);
    let v = m.sample_at(at(60)).unwrap();
    // 30 s at 20 % and 30 s at 90 %: nearest rank stops on the first half.
    assert_eq!((v.cpu_p50_pct, v.cpu_window_s), (Some(20.0), Some(60.0)));
    busy(0.9);
    let v = m.sample_at(at(120)).unwrap();
    assert_eq!((v.cpu_p50_pct, v.cpu_window_s), (Some(90.0), Some(120.0)));
    assert_eq!(v.cpu_busy_pct, Some(90.0));
}

#[test]
fn the_cpu_window_clips_at_ten_minutes_and_forgets_older_readings() {
    let t0 = Instant::now();
    let at = |s: u64| t0 + Duration::from_secs(s);
    // A long interval at 90 % reaching past the window, then 5 min at 10 %.
    let ring = [(at(0), at(900), 90.0), (at(900), at(1200), 10.0)];
    let (p50, window) = cpu_window_p50(ring, at(1200)).unwrap();
    assert_eq!(window, 600.0, "clipped at the window start");
    assert_eq!(p50, 10.0, "300 s at 10 % is half of 600 s");
    assert_eq!(cpu_window_p50([(at(0), at(10), 50.0)], at(1200)), None, "out of the window");

    let probe = Arc::new(FakeProbe::default());
    *probe.sample.lock().unwrap() = Sample { cpu_busy: Some(0.5), ..calm() };
    let m = meter(&probe);
    m.sample_at(at(0)).unwrap();
    m.sample_at(at(120)).unwrap();
    // Twenty minutes idle: the 0..120 reading is gone; the new one covers the gap, clipped.
    let v = m.sample_at(at(1320)).unwrap();
    assert_eq!(v.cpu_window_s, Some(600.0));
    assert_eq!(m.lock().cpu.len(), 1);
}

#[test]
fn a_host_with_no_cpu_reading_reports_none() {
    let probe = Arc::new(FakeProbe::default());
    *probe.sample.lock().unwrap() = Sample { cpu_busy: None, ..calm() };
    let m = meter(&probe);
    let t0 = Instant::now();
    m.sample_at(t0).unwrap();
    let v = m.sample_at(t0 + Duration::from_secs(120)).unwrap();
    assert_eq!((v.cpu_busy_pct, v.cpu_p50_pct, v.cpu_window_s), (None, None, None));
}
