use super::*;

const LEASE: Duration = Duration::from_secs(60);

fn held(heard: Now) -> Held {
    Held { socket: PathBuf::new(), job: "j".into(), lease: LEASE, heard: Some(heard), lost: None }
}

fn running() -> (anyhow::Result<Value>, Now) {
    (Ok(json!({"state": "running"})), (Instant::now(), SystemTime::now()))
}

/// An answer `json` that came at `came`.
fn said(json: Value, came: Now) -> impl FnOnce() -> (anyhow::Result<Value>, Now) {
    move || (Ok(json), came)
}

fn code(result: anyhow::Result<()>) -> String {
    result.unwrap_err().downcast::<FsRefusal>().unwrap().code
}

#[test]
fn a_write_within_half_the_lease_reads_nothing() {
    let now = (Instant::now(), SystemTime::now());
    let mut fence = held(now);
    fence.allows(now, || panic!("no read within half the lease")).unwrap();
}

#[test]
fn a_copy_that_slept_past_its_lease_writes_nothing_more() {
    let then = (Instant::now(), SystemTime::now());
    let mut fence = held(then);
    // A Mac asleep: the monotonic clock stood still, the wall clock did not.
    let woke = (then.0, then.1 + LEASE * 2);
    let expired = said(json!({"state": "failed", "error_code": "seed.hold_expired"}), woke);
    assert_eq!(code(fence.allows(woke, expired)), "seed.hold_expired");
    // Ended for good: no later write goes either.
    assert_eq!(code(fence.allows(woke, running)), "seed.hold_expired");
}

#[test]
fn a_stopped_copy_whose_hold_still_runs_goes_on() {
    let then = (Instant::now(), SystemTime::now());
    let mut fence = held(then);
    let later = (then.0 + LEASE, then.1 + LEASE);
    fence.allows(later, said(json!({"state": "running"}), later)).unwrap();
    fence.allows(later, || panic!("just heard")).unwrap();
}

#[test]
fn a_running_answer_that_came_back_past_the_lease_lets_nothing_through() {
    let then = (Instant::now(), SystemTime::now());
    let mut fence = held(then);
    let asked = (then.0 + LEASE, then.1 + LEASE);
    // The Mac slept while the answer waited: it came a lease later.
    let came = (asked.0, asked.1 + LEASE * 2);
    let late = said(json!({"state": "running"}), came);
    assert_eq!(code(fence.allows(asked, late)), "seed.hold_expired");
}

#[test]
fn a_fence_raised_unheard_reads_the_job_before_its_first_write() {
    let now = (Instant::now(), SystemTime::now());
    let mut fence = Held { heard: None, ..held(now) };
    let expired = said(json!({"state": "failed", "error_code": "seed.hold_expired"}), now);
    assert_eq!(code(fence.allows(now, expired)), "seed.hold_expired");
    let mut fence = Held { heard: None, ..held(now) };
    fence.allows(now, said(json!({"state": "running"}), now)).unwrap();
}

#[test]
fn a_job_the_machine_forgot_or_cannot_say_stops_the_writes() {
    let then = (Instant::now(), SystemTime::now());
    let later = (then.0 + LEASE, then.1 + LEASE);
    let unreachable = move || (Err(anyhow::anyhow!("connection refused")), later);
    assert_eq!(code(held(then).allows(later, unreachable)), "seed.hold_expired");
    let forgot = move || {
        let refusal = FsRefusal { code: "seed.job_unknown".into(), message: "no such job".into() };
        (Err(refusal.into()), later)
    };
    assert_eq!(code(held(then).allows(later, forgot)), "seed.hold_expired");
}

#[test]
fn only_writes_are_fenced() {
    check("fs.stat").unwrap();
    check("blob.fetch.status").unwrap();
    // No fence up: a store fetch goes.
    check("blob.fetch.start").unwrap();
}
