use super::*;

fn read(kind: NoticeKind, posted_ms: u64, read_ms: Option<u64>) -> NoticeRead {
    NoticeRead { kind, posted_ms, read_ms }
}

#[test]
fn each_notice_lands_in_one_bucket_by_its_time_to_read() {
    let now = 10_000_000;
    let notices = [
        read(NoticeKind::Finished, 1_000, Some(1_000 + 5_000)),
        read(NoticeKind::Finished, 1_000, Some(1_000 + SOON_MS)),
        read(NoticeKind::Finished, 1_000, Some(1_000 + SOON_MS + 1)),
        read(NoticeKind::Finished, 1_000, Some(1_000 + LATE_MS + 1)),
        read(NoticeKind::Finished, 1_000, None),
        read(NoticeKind::Finished, now - 1_000, None),
        read(NoticeKind::NeedsInput, 2_000, Some(2_500)),
    ];
    let stats = notice_stats(&notices, now);
    let finished = &stats["kinds"]["finished"];
    assert_eq!(finished["posted"], 6, "{stats}");
    assert_eq!(finished["read_within_60s"], 2, "{stats}");
    assert_eq!(finished["read_within_10m"], 1, "{stats}");
    assert_eq!(finished["read_later"], 1, "{stats}");
    assert_eq!(finished["never_read"], 1, "{stats}");
    assert_eq!(finished["unread_recent"], 1, "{stats}");
    // 3 of the 5 old enough to say were read within 10 min.
    assert_eq!(finished["acted_rate"], 0.6, "{stats}");
    assert_eq!(finished["read_ms_p50"], SOON_MS, "{stats}");
    assert_eq!(finished["read_ms_p95"], LATE_MS + 1, "{stats}");

    assert_eq!(stats["kinds"]["needs_input"]["posted"], 1, "{stats}");
    assert_eq!(stats["kinds"]["needs_input"]["read_ms_p50"], 500, "{stats}");
    assert_eq!(stats["kinds"]["failed"]["posted"], 0, "{stats}");
    assert_eq!(stats["kinds"]["failed"]["acted_rate"], Value::Null, "{stats}");
    assert_eq!(stats["kinds"]["failed"]["read_ms_p50"], Value::Null, "{stats}");
    assert_eq!(stats["all"]["posted"], 7, "{stats}");
    assert_eq!(stats["window"]["since_ms"], 1_000, "{stats}");
}

#[test]
fn a_read_stamped_before_its_post_counts_as_read_at_once() {
    let stats = notice_stats(&[read(NoticeKind::Failed, 5_000, Some(4_000))], 9_000);
    assert_eq!(stats["kinds"]["failed"]["read_within_60s"], 1, "{stats}");
    assert_eq!(stats["kinds"]["failed"]["read_ms_p50"], 0, "{stats}");
}

#[test]
fn nearest_rank_percentiles() {
    assert_eq!(percentile(&[], 50), None);
    assert_eq!(percentile(&[7], 95), Some(7));
    let hundred = (1..=100).collect::<Vec<u64>>();
    assert_eq!(percentile(&hundred, 50), Some(50));
    assert_eq!(percentile(&hundred, 95), Some(95));
}
