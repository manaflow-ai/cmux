use cmux_link::elapsed::Elapsed;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[test]
fn receiver_elapsed_clones_share_clock_failure_and_rollback_fences() {
    for unavailable in [false, true] {
        let value = Arc::new(Mutex::new(Some(Duration::from_secs(10))));
        let source = value.clone();
        let elapsed = Elapsed::capture(move || *source.lock().unwrap()).unwrap();
        let retained = elapsed.clone();
        *value.lock().unwrap() = Some(Duration::from_secs(12));
        assert_eq!(elapsed.elapsed(), Some(Duration::from_secs(2)));
        *value.lock().unwrap() = if unavailable { None } else { Some(Duration::from_secs(11)) };
        assert_eq!(retained.elapsed(), None);
        *value.lock().unwrap() = Some(Duration::from_secs(15));
        assert_eq!(elapsed.elapsed(), None, "the original clock owner reopened");
    }
}
