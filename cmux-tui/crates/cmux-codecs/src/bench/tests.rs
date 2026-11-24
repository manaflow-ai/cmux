use super::Link;

/// Loss rate and mean run of consecutive losses over `n` datagrams.
fn loss_stats(burst_len: f64, n: usize) -> (f64, f64) {
    let mut link = Link::new(0, 2.0, burst_len, 0.0, 7);
    let (mut runs, mut was_lost) = (0usize, false);
    for _ in 0..n {
        let before = link.dropped;
        link.send(0, vec![0; 100]);
        let lost = link.dropped > before;
        runs += usize::from(lost && !was_lost);
        was_lost = lost;
    }
    (link.dropped as f64 / n as f64 * 100.0, link.dropped as f64 / runs.max(1) as f64)
}

#[test]
fn burst_loss_keeps_the_average_rate() {
    let (iid_pct, iid_run) = loss_stats(0.0, 200_000);
    let (burst_pct, burst_run) = loss_stats(8.0, 200_000);
    assert!((iid_pct - 2.0).abs() < 0.2, "i.i.d. loss {iid_pct:.2}%");
    assert!(iid_run < 1.2, "i.i.d. runs {iid_run:.2}");
    assert!((burst_pct - 2.0).abs() < 0.3, "burst loss {burst_pct:.2}%");
    assert!((burst_run - 8.0).abs() < 1.0, "burst runs {burst_run:.2}");
}
