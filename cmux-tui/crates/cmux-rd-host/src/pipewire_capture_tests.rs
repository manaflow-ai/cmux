use super::*;

#[test]
fn bgrx_copies_rows_with_strides() {
    // 3x2 source with 4 bytes of row padding; copy the 2x2 rect at (1, 0).
    let src: Vec<u8> = (0..32).collect();
    let mut dst = vec![0u8; 3 * 2 * 4];
    copy_rect_to_bgrx(&src, 16, PixelFormat::Bgrx, Rect { x: 1, y: 0, w: 2, h: 2 }, &mut dst, 12);
    assert_eq!(&dst[0..4], &[0, 0, 0, 0]);
    assert_eq!(&dst[4..12], &src[4..12]);
    assert_eq!(&dst[12..16], &[0, 0, 0, 0]);
    assert_eq!(&dst[16..24], &src[20..28]);
}

#[test]
fn rgbx_swaps_red_and_blue() {
    let src = [10u8, 20, 30, 255, 1, 2, 3, 0];
    let mut dst = vec![0u8; 8];
    copy_rect_to_bgrx(&src, 8, PixelFormat::Rgbx, Rect { x: 0, y: 0, w: 2, h: 1 }, &mut dst, 8);
    assert_eq!(dst, [30, 20, 10, 255, 3, 2, 1, 0]);
}

#[test]
fn pixel_formats_map_from_spa() {
    use spa::param::video::VideoFormat as F;
    assert_eq!(PixelFormat::from_spa(F::BGRx), Some(PixelFormat::Bgrx));
    assert_eq!(PixelFormat::from_spa(F::BGRA), Some(PixelFormat::Bgrx));
    assert_eq!(PixelFormat::from_spa(F::RGBx), Some(PixelFormat::Rgbx));
    assert_eq!(PixelFormat::from_spa(F::RGBA), Some(PixelFormat::Rgbx));
    assert_eq!(PixelFormat::from_spa(F::I420), None);
}

#[test]
fn damage_is_full_frame_without_meta_or_regions() {
    let full = vec![Rect { x: 0, y: 0, w: 64, h: 32 }];
    assert_eq!(damage_rects(None, 64, 32), full);
    assert_eq!(damage_rects(Some(&[]), 64, 32), full);
    assert_eq!(damage_rects(Some(&[(0, 0, 0, 0), (1, 1, 4, 4)]), 64, 32), full);
}

#[test]
fn damage_regions_are_clipped_and_end_at_the_first_empty_one() {
    let got =
        damage_rects(Some(&[(-4, 2, 10, 4), (60, 30, 10, 10), (0, 0, 0, 0), (5, 5, 1, 1)]), 64, 32);
    assert_eq!(got, vec![Rect { x: 0, y: 2, w: 6, h: 4 }, Rect { x: 60, y: 30, w: 4, h: 2 }]);
}

#[test]
fn param_pods_serialize() {
    assert!(spa::pod::Pod::from_bytes(&enum_format_pod().unwrap()).is_some());
    let (b, m) = buffer_pods().unwrap();
    assert!(spa::pod::Pod::from_bytes(&b).is_some());
    assert!(spa::pod::Pod::from_bytes(&m).is_some());
}
