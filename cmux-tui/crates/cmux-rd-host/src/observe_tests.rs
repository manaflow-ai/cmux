use super::*;

#[test]
fn observe_requires_exact_next_counter_and_post_input_timestamp() {
    assert_eq!(response(7, 1000, 8, 999), Ok(None));
    assert_eq!(response(7, 1000, 8, 1000), Ok(None));
    assert_eq!(response(7, 1000, 7, 1100), Ok(None));
    assert_eq!(response(7, 1000, 8, 3500), Ok(Some(2500)));
    assert_eq!(response(u16::MAX, 1000, 0, 3500), Ok(Some(2500)));
    assert!(response(7, 1000, 9, 3500).is_err());
}

#[test]
fn observe_rejects_other_connection_and_occlusion() {
    let target = Window { id: 2, pid: 40, rect: [0.0, 0.0, 100.0, 100.0] };
    let cover = Window { id: 3, pid: 40, rect: [50.0, 0.0, 50.0, 100.0] };
    assert!(unobscured(&[target], 2, 40, &[(10.0, 10.0), (90.0, 10.0)]));
    assert!(!unobscured(&[cover, target], 2, 40, &[(10.0, 10.0), (90.0, 10.0)]));
    assert!(!unobscured(&[target], 2, 41, &[(10.0, 10.0)]));
    assert!(!unobscured(&[target], 2, 40, &[(100.0, 10.0)]));
    assert!(!unobscured(&[target], 2, 40, &[]));
}

#[test]
fn observe_marker_guards_bounds_and_scaled_cells() {
    let stride = 100;
    let mut plane = vec![16; stride * 8];
    for (i, on) in crate::marker::cells(257).iter().enumerate() {
        plane[4 * stride + 3 + i * 4 + 2] = if *on { 235 } else { 16 };
    }
    assert_eq!(read_marker(&plane, stride, (3, 2), 4), Some(257));
    plane[4 * stride + 3 + 18 * 4 + 2] = 128;
    assert_eq!(read_marker(&plane, stride, (3, 2), 4), None);
    assert_eq!(read_marker(&plane, stride, (usize::MAX, 2), 4), None);
    assert_eq!(read_marker(&plane, stride, (90, 2), 4), None);
}

#[test]
fn observe_reports_nearest_rank_over_all_samples() {
    assert_eq!(percentiles(&[]), None);
    assert_eq!(percentiles(&[9000, 1000, 3000, 2000]), Some((2.0, 9.0)));
    assert_eq!(percentiles(&[3500]), Some((3.5, 3.5)));
}
