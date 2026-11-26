use super::*;

#[test]
fn a_stamp_reads_as_its_time() {
    assert_eq!(stamp_ms("19700101T000000Z-1"), Some(0));
    assert_eq!(stamp_ms("20261112T081500Z-4242"), Some(1_794_471_300_000));
    assert_eq!(stamp_ms("2026-11-12"), None);
    assert_eq!(stamp_ms("20261340T000000Z"), None);
}

#[test]
fn ages_read_plainly() {
    assert_eq!(age(10 * 60_000), "under an hour");
    assert_eq!(age(5 * 3_600_000), "5 hours");
    assert_eq!(age(3 * 86_400_000 + 3_600_000), "3 days");
}
