use super::*;

#[test]
fn the_head_follows_the_pointer_between_steps() {
    let mut s = TrailState::default();
    s.moved(0.0, 0.0, 1.0);
    s.moved(10.0, 0.0, 1.01);
    assert_eq!(s.len, 2);
    // Within a step of points[1]: the head moves, nothing shifts.
    s.moved(20.0, 5.0, 1.03);
    s.moved(30.0, 6.0, 1.045);
    assert_eq!(s.len, 2);
    assert_eq!(s.points[0], TrailPoint { x: 30.0, y: 6.0, t: 1.045 });
    // A step after points[1]: the head is committed and a new one shifts in.
    s.moved(40.0, 7.0, 1.05);
    assert_eq!(s.len, 3);
    assert_eq!(s.points[1], TrailPoint { x: 30.0, y: 6.0, t: 1.045 });
    assert_eq!(s.points[2], TrailPoint { x: 0.0, y: 0.0, t: 1.0 });
}

#[test]
fn a_move_a_step_after_the_committed_point_shifts_in() {
    let mut s = TrailState::default();
    s.moved(0.0, 0.0, 0.0);
    s.moved(1.0, 0.0, 0.01);
    s.moved(2.0, 0.0, 0.05);
    assert_eq!(s.len, 3);
    assert_eq!(s.points[0].x, 2.0);
    assert_eq!(s.points[1].x, 1.0);
    assert_eq!(s.points[2].x, 0.0);
    // At 120 Hz for 2 s the ring stays full; a committed point is the last head before the
    // step, so committed points are within one sample under a step apart.
    for i in 0..240 {
        s.moved(f32::from(u8::try_from(i % 200).unwrap()), 0.0, 1.0 + f64::from(i) / 120.0);
    }
    assert_eq!(s.len, TRAIL_POINTS);
    for w in s.points[1..].windows(2) {
        let gap = w[0].t - w[1].t;
        assert!((TRAIL_STEP_S - 1.0 / 120.0 - 1e-9..TRAIL_STEP_S + 1e-9).contains(&gap), "{gap}");
    }
}

#[test]
fn rows_carry_scaled_positions_and_ages_and_expire() {
    let mut s = TrailState::default();
    s.moved(100.0, 50.0, 10.0);
    s.moved(200.0, 60.0, 10.5);
    let rows = s.rows(10.6, 0.5);
    assert_eq!(rows[0][0..2], [100.0, 30.0]);
    assert!((rows[0][2] - 0.1).abs() < 1e-5);
    assert_eq!(rows[0][3], 1.0);
    assert_eq!(rows[1][0..2], [50.0, 25.0]);
    assert!((rows[1][2] - 0.6).abs() < 1e-5);
    assert_eq!(rows[1][3], 1.0);
    assert_eq!(rows[2], [0.0; 4]);
    // Past TRAIL_LIFE_S the older point expires, then the head.
    let rows = s.rows(11.2, 1.0);
    assert_eq!(rows[1], [0.0; 4]);
    assert_eq!(rows[0][3], 1.0);
    assert!(s.rows(11.6, 1.0).iter().all(|r| *r == [0.0; 4]));
    // A sample from after `now` is age 0, not negative.
    assert_eq!(s.rows(9.0, 1.0)[0][2], 0.0);
    assert!(TrailState::default().rows(0.0, 1.0).iter().all(|r| *r == [0.0; 4]));
}

#[test]
fn bad_input_is_ignored() {
    let mut s = TrailState::default();
    s.moved(f32::NAN, 0.0, 0.0);
    s.moved(0.0, f32::INFINITY, 0.0);
    s.moved(0.0, 0.0, f64::NAN);
    assert_eq!(s, TrailState::default());
    s.moved(1.0, 2.0, 3.0);
    assert!(s.rows(f64::NAN, 1.0).iter().all(|r| *r == [0.0; 4]));
    assert!(s.rows(3.0, f32::NAN).iter().flatten().all(|v| v.is_finite()));
    // A len past the ring (a C caller's struct) is read as a full ring.
    s.len = 99;
    s.moved(4.0, 5.0, 4.0);
    assert_eq!(s.len, TRAIL_POINTS);
    assert_eq!(s.rows(4.0, 1.0)[0], [4.0, 5.0, 0.0, 1.0]);
}
