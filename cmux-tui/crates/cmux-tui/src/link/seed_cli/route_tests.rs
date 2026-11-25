//! The RFD 0066 table: 102 MB, 2 GB and 50 GB at 0.55 MB/s and 28.5 MB/s.

use super::*;

const SLOW: u64 = 550_000;
const FAST: u64 = 28_500_000;
const MB: u64 = 1_000_000;
const GB: u64 = 1_000 * MB;

#[test]
fn the_rfd_table_routes_each_size_over_each_uplink() {
    assert_eq!(choose(102 * MB, 1_000, SLOW), Route::ListingFirstSnapshotBehind);
    assert_eq!(choose(102 * MB, 1_000, FAST), Route::WholeSnapshot);
    assert_eq!(choose(2 * GB, 10_000, SLOW), Route::ListingFirstSnapshotBehind);
    assert_eq!(choose(2 * GB, 10_000, FAST), Route::ListingFirstSnapshotBehind);
    assert_eq!(choose(50 * GB, 10_000, SLOW), Route::ListingOnly);
    assert_eq!(choose(50 * GB, 10_000, FAST), Route::ListingOnly);
}

#[test]
fn a_minute_of_sending_is_the_edge_and_33_mb_fits_the_slow_uplink() {
    assert_eq!(choose(33 * MB, 10, SLOW), Route::WholeSnapshot);
    assert_eq!(choose(60 * SLOW, 10, SLOW), Route::ListingFirstSnapshotBehind);
    assert_eq!(choose(60 * SLOW - 1, 10, SLOW), Route::WholeSnapshot);
    assert_eq!(choose(1_700 * MB, 10, FAST), Route::WholeSnapshot);
}

#[test]
fn the_size_and_file_limits_send_listing_only() {
    assert_eq!(choose(SNAPSHOT_MAX_BYTES, 10, FAST * 100), Route::WholeSnapshot);
    assert_eq!(choose(SNAPSHOT_MAX_BYTES + 1, 10, FAST), Route::ListingOnly);
    assert_eq!(choose(MB, SNAPSHOT_MAX_FILES - 1, FAST), Route::WholeSnapshot);
    assert_eq!(choose(MB, SNAPSHOT_MAX_FILES, FAST), Route::ListingOnly);
}

#[test]
fn a_zero_rate_uses_the_conservative_default() {
    assert_eq!(choose(33 * MB, 10, 0), Route::WholeSnapshot);
    assert_eq!(choose(102 * MB, 10, 0), Route::ListingFirstSnapshotBehind);
}

#[test]
fn the_sleep_figure_rounds_up_to_whole_minutes() {
    assert_eq!(sleep_minutes(2 * GB, FAST), 2);
    assert_eq!(sleep_minutes(102 * MB, SLOW), 4);
    assert_eq!(sleep_minutes(1, FAST), 1);
}
