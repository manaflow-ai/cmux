use super::*;

/// Before: a reaper that panicked left the flag set, so no reaper ever ran again and idle
/// pooled harnesses were never ended. After: the claim clears it as the task unwinds.
#[tokio::test]
async fn a_reaper_that_panics_gives_its_claim_back() {
    let flag: &'static AtomicBool = Box::leak(Box::new(AtomicBool::new(true)));
    let died = tokio::spawn(async move {
        let _claim = ReaperClaim { flag, held: true };
        panic!("reaper died");
    })
    .await;
    assert!(died.is_err());
    assert!(!flag.load(Ordering::SeqCst), "a dead reaper still holds the pool's claim");
}

/// A reaper that released its claim on the normal exit never clears a successor's.
#[test]
fn a_released_claim_leaves_a_successors_claim_alone() {
    let flag = AtomicBool::new(true);
    let mut claim = ReaperClaim { flag: &flag, held: true };
    claim.release();
    flag.store(true, Ordering::SeqCst);
    drop(claim);
    assert!(flag.load(Ordering::SeqCst));
}
