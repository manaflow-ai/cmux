use super::*;

#[test]
fn ninety_percent_of_the_cores_rounded_up() {
    assert_eq!(cpu_loops(1), 1);
    assert_eq!(cpu_loops(10), 9);
    assert_eq!(cpu_loops(15), 14);
    assert_eq!(cpu_loops(64), 58);
}

#[test]
fn busy_share_between_readings() {
    assert_eq!(busy_pct(Some((10, 100)), Some((100, 200))), Some(90.0));
    assert_eq!(busy_pct(Some((10, 100)), Some((10, 100))), None);
}
