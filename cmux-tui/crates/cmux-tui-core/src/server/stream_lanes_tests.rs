use super::*;
use std::sync::mpsc;

fn lane(raw: u16) -> ClientStreamId {
    ClientStreamId::new(raw).unwrap()
}

/// A job: its name, and an optional gate it waits on before it reports.
struct Job {
    name: &'static str,
    gate: Option<mpsc::Receiver<()>>,
    started: Option<mpsc::Sender<()>>,
}

fn job(name: &'static str) -> Job {
    Job { name, gate: None, started: None }
}

fn gated(name: &'static str, gate: mpsc::Receiver<()>) -> Job {
    Job { name, gate: Some(gate), started: None }
}

fn lanes(max_jobs: usize) -> (StreamLanes<Job>, mpsc::Receiver<&'static str>) {
    let (done_tx, done_rx) = mpsc::channel();
    let done_tx = Mutex::new(done_tx);
    let lanes = StreamLanes::new(max_jobs, 1 << 20, move |job: Job| {
        if let Some(started) = job.started {
            let _ = started.send(());
        }
        if let Some(gate) = job.gate {
            let _ = gate.recv();
        }
        let _ = done_tx.lock().unwrap().send(job.name);
        true
    });
    (lanes, done_rx)
}

const WAIT: Duration = Duration::from_secs(10);

#[test]
fn a_blocked_request_of_one_stream_never_delays_another_stream() {
    let (lanes, done) = lanes(16);
    let (release, gate) = mpsc::channel();
    lanes.submit(lane(1), gated("slow attach", gate), 10).unwrap();
    lanes.submit(lane(1), job("after the attach"), 10).unwrap();
    lanes.submit(lane(2), job("key"), 10).unwrap();
    // Lane 2's key runs while lane 1 is still blocked.
    assert_eq!(done.recv_timeout(WAIT), Ok("key"));
    release.send(()).unwrap();
    assert_eq!(done.recv_timeout(WAIT), Ok("slow attach"));
    assert_eq!(done.recv_timeout(WAIT), Ok("after the attach"));
    lanes.finish_and_wait();
    assert_eq!(lanes.peak_workers(), 2);
}

#[test]
fn one_lane_runs_in_submit_order_on_one_worker() {
    let (lanes, done) = lanes(64);
    let (release, gate) = mpsc::channel();
    lanes.submit(lane(7), gated("0", gate), 1).unwrap();
    for name in ["1", "2", "3", "4"] {
        lanes.submit(lane(7), job(name), 1).unwrap();
    }
    release.send(()).unwrap();
    let order: Vec<_> = (0..5).map(|_| done.recv_timeout(WAIT).unwrap()).collect();
    assert_eq!(order, ["0", "1", "2", "3", "4"]);
    lanes.finish_and_wait();
    assert_eq!(lanes.peak_workers(), 1, "one lane never needs a second worker");
}

#[test]
fn a_full_lane_refuses_without_touching_other_lanes() {
    let (lanes, done) = lanes(2);
    let (release, gate) = mpsc::channel();
    lanes.submit(lane(1), gated("running", gate), 1).unwrap();
    // The running job left the queue; two more fill it.
    let mut queued = 0;
    while lanes.submit(lane(1), job("queued"), 1).is_ok() {
        queued += 1;
        assert!(queued <= 3, "the lane must stop taking jobs at its bound");
    }
    assert_eq!(lanes.submit(lane(1), job("over"), 1), Err(LaneRefusal::Full));
    lanes.submit(lane(2), job("other lane"), 1).unwrap();
    assert_eq!(done.recv_timeout(WAIT), Ok("other lane"));
    release.send(()).unwrap();
    lanes.finish_and_wait();
}

#[test]
fn closing_drops_queued_jobs_waits_for_the_running_one_and_refuses_new_ones() {
    let (lanes, done) = lanes(16);
    let (release, gate) = mpsc::channel();
    let (started_tx, started) = mpsc::channel();
    lanes
        .submit(lane(1), Job { name: "running", gate: Some(gate), started: Some(started_tx) }, 1)
        .unwrap();
    lanes.submit(lane(1), job("dropped"), 1).unwrap();
    started.recv_timeout(WAIT).unwrap();
    assert!(
        !lanes.close_and_wait(Duration::from_millis(1)),
        "the running job still holds its worker"
    );
    assert_eq!(lanes.submit(lane(1), job("late"), 1), Err(LaneRefusal::Closed));
    release.send(()).unwrap();
    lanes.finish_and_wait();
    assert_eq!(done.try_iter().collect::<Vec<_>>(), ["running"]);
}
