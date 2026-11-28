use super::*;

#[test]
fn slower_links_get_higher_levels() {
    let p = Params::default();
    let lan = Link { bytes_per_sec: 1.25e9, rtt: 0.0005, cores: 8 };
    let wifi = Link { bytes_per_sec: 6e6, rtt: 0.02, cores: 8 };
    assert!(level_for(&wifi, &p) > level_for(&lan, &p));
    assert!(level_for(&lan, &p) <= 3);
}
