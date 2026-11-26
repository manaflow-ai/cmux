use super::{Mint, MintDown, MintMode};
use crate::clock::WallClock;
use crate::trace::Trace;
use std::time::{Duration, UNIX_EPOCH};

#[tokio::test(start_paused = true)]
async fn the_mint_issues_refuses_and_hangs() {
    let trace = Trace::new();
    let clock = WallClock::starting_at(UNIX_EPOCH + Duration::from_millis(5_400), &trace);
    let mint = Mint::new(Duration::from_secs(1), clock, &trace, |issued, expires| {
        format!("{issued}-{expires}")
    });
    assert_eq!(mint.fetch().await, Ok("6-7".to_owned()));
    mint.set(MintMode::Down);
    assert_eq!(mint.fetch().await, Err(MintDown));
    mint.set(MintMode::Hang);
    let waiting = tokio::spawn({
        let mint = mint.clone();
        async move { mint.fetch().await }
    });
    tokio::time::sleep(Duration::from_secs(60)).await;
    assert!(!waiting.is_finished(), "a hung mint answered");
    mint.set(MintMode::Up);
    assert_eq!(waiting.await.unwrap(), Ok("66-67".to_owned()));
    assert_eq!((mint.minted(), mint.refused()), (2, 1));
}
