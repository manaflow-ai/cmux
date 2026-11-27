use super::*;

#[tokio::test]
async fn a_deadline_is_not_met_early() {
    let at = Instant::now() + Duration::from_micros(1500);
    sleep_until(at).await;
    assert!(Instant::now() >= at);
}
