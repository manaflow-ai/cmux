#[test]
fn reads_itself() {
    assert!(super::self_rss_kb() > 0);
    assert!(super::self_stat().len() > 20);
    let _ = (super::self_ticks(), super::reaped_children_ticks());
}
