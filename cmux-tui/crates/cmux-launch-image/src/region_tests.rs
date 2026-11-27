use super::*;

fn fresh() -> PageRegion {
    PageRegion {
        image_taken_ms: Some(10_000),
        image_version: Some(4),
        page_version: 4,
        page_changed_ms: Some(9_000),
        composite_ms: 12_000,
    }
}

#[test]
fn a_current_image_is_painted() {
    assert_eq!(page_region(&fresh()), RegionReason::Image);
    assert_eq!(page_region(&PageRegion { page_changed_ms: None, ..fresh() }), RegionReason::Image);
    // Taken in the same millisecond as the change it shows.
    assert_eq!(
        page_region(&PageRegion { page_changed_ms: Some(10_000), ..fresh() }),
        RegionReason::Image
    );
    // At the lag limit exactly.
    assert_eq!(
        page_region(&PageRegion { composite_ms: 10_000 + MAX_PAGE_IMAGE_LAG_MS, ..fresh() }),
        RegionReason::Image
    );
}

#[test]
fn a_stale_page_image_is_replaced_by_plain_fill() {
    let cases = [
        (PageRegion { image_taken_ms: None, ..fresh() }, RegionReason::NoImage),
        (PageRegion { page_version: 5, ..fresh() }, RegionReason::VersionDiffers),
        (PageRegion { image_version: None, ..fresh() }, RegionReason::VersionDiffers),
        (PageRegion { page_changed_ms: Some(10_001), ..fresh() }, RegionReason::TakenBeforeChange),
        (
            PageRegion { composite_ms: 10_001 + MAX_PAGE_IMAGE_LAG_MS, ..fresh() },
            RegionReason::TooOld,
        ),
        (PageRegion { composite_ms: 9_999, ..fresh() }, RegionReason::TakenAfterComposite),
    ];
    for (region, reason) in cases {
        assert_eq!(page_region(&region), reason, "{region:?}");
        assert!(!reason.paints_image(), "{region:?} must paint plain");
    }
}

#[test]
fn a_version_change_wins_over_a_fresh_time() {
    // Navigated a moment ago, image taken after (of the old page's last frame): still stale.
    let region = PageRegion { page_version: 5, page_changed_ms: Some(9_500), ..fresh() };
    assert_eq!(page_region(&region), RegionReason::VersionDiffers);
}
