use super::*;

/// A luma plane of `w` x `h` with the marker for `v` painted at cell size `cell` (video range).
fn plane(v: u16, w: usize, h: usize, cell: usize) -> Vec<u8> {
    let mut y = vec![16u8; w * h];
    for (i, white) in crate::marker::cells(u32::from(v)).iter().enumerate() {
        for row in 0..cell.min(h) {
            for x in i * cell..((i + 1) * cell).min(w) {
                y[row * w + x] = if *white { 235 } else { 16 };
            }
        }
    }
    y
}

#[test]
fn a_half_size_stream_reads_its_marker_at_half_scale() {
    // A 960x1080 screen fitted into 480 wide: the 32 px cells arrive as 16 px.
    let y = plane(0xbeef, 480, 540, 16);
    assert_eq!(read_marker(None, &y, 480, (0, 0), (1, 1)), None, "the 640 px marker overruns 480");
    assert_eq!(read_marker(None, &y, 480, (0, 0), (1, 2)), Some(0xbeef));
    let full = plane(0x1234, 960, 64, 32);
    assert_eq!(read_marker(None, &full, 960, (0, 0), (1, 1)), Some(0x1234));
}

#[test]
fn marker_scale_takes_a_ratio_of_at_most_one() {
    assert_eq!(parse_marker_scale("1/2").unwrap(), (1, 2));
    assert_eq!(parse_marker_scale("480/960").unwrap(), (480, 960));
    assert_eq!(parse_marker_scale("1").unwrap(), (1, 1));
    for bad in ["0/2", "3/2", "x", "1/"] {
        assert!(parse_marker_scale(bad).is_err(), "{bad}");
    }
}
