use super::Scale;

#[test]
fn a_full_size_picture_reads_each_pixel_as_it_is() {
    let plane: Vec<u8> = (0..16).collect();
    let scale = Scale::new((4, 4), (4, 4));
    assert!(scale.is_identity());
    assert_eq!(scale.luma_rect(&plane, 4, (1, 1, 2, 2)), Some(vec![5, 6, 9, 10]));
}

#[test]
fn a_half_size_picture_shows_each_pixel_over_four_stream_pixels() {
    // A 2x2 picture of flat cells, shown at 8x8: the stream pixels inside each cell
    // away from the edge between cells read that cell's value.
    let plane = [0u8, 200, 100, 50];
    let scale = Scale::new((2, 2), (8, 8));
    assert_eq!(scale.luma(&plane, 2, 0, 0), Some(0));
    assert_eq!(scale.luma(&plane, 2, 7, 0), Some(200));
    assert_eq!(scale.luma(&plane, 2, 0, 7), Some(100));
    assert_eq!(scale.luma(&plane, 2, 7, 7), Some(50));
    // Between two cells: the blend a bilinear viewer shows.
    let middle = scale.luma(&plane, 2, 4, 0).unwrap();
    assert!(middle > 0 && middle < 200, "{middle}");
}

#[test]
fn the_marker_reads_through_a_three_eighths_picture() {
    // The marker's 32 px cells at 3/8 are 12 px; their centres still read their colour.
    let (sw, sh) = (crate::marker::CELL as usize * crate::marker::CELLS, 64);
    let (pw, ph) = (sw * 3 / 8, sh * 3 / 8);
    let cells = crate::marker::cells(0xa5c3);
    let cell = crate::marker::CELL as usize * 3 / 8;
    let plane: Vec<u8> = (0..ph)
        .flat_map(|_| (0..pw).map(|x| if cells[(x / cell).min(19)] { 235 } else { 16 }))
        .collect();
    let scale = Scale::new((pw, ph), (sw, sh));
    let read = crate::marker::decode_with(true, (0, 0), |x, y| scale.luma(&plane, pw, x, y));
    assert_eq!(read, Some(0xa5c3));
}

#[test]
fn a_scaled_snapshot_is_the_stream_size() {
    let scale = Scale::new((2, 1), (4, 2));
    let (w, h, rgb) = scale.rgb(&[10, 20, 30, 40, 50, 60]);
    assert_eq!((w, h, rgb.len()), (4, 2, 24));
    assert_eq!(&rgb[..3], &[10, 20, 30]);
    assert_eq!(&rgb[9..12], &[40, 50, 60]);
}

#[test]
fn a_rectangle_outside_the_stream_reads_nothing() {
    let scale = Scale::new((2, 2), (4, 4));
    assert_eq!(scale.luma_rect(&[0; 4], 2, (3, 3, 2, 2)), None);
}
