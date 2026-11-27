use super::*;
#[test]
fn dxgi_dirty_rectangles_clip_negative_and_offscreen_edges() {
    assert_eq!(
        clip(RECT { left: -10, top: -20, right: 50, bottom: 60 }, 40, 40),
        Some(Rect { x: 0, y: 0, width: 40, height: 40 })
    );
    assert_eq!(clip(RECT { left: 40, top: 0, right: 60, bottom: 5 }, 40, 40), None);
    assert_eq!(clip(RECT { left: 20, top: 10, right: 10, bottom: 5 }, 40, 40), None);
}
#[test]
fn dxgi_dirty_and_move_destinations_keep_unchanged_pixels_and_ignore_row_padding() {
    // The acquired desktop is complete. A dirty rectangle and an overlapping
    // move destination both read these final bytes, never the old CPU image.
    let width = 4usize;
    let pitch = 24usize;
    let mut source = vec![0xee; pitch * 3];
    for y in 0..3 {
        for x in 0..width {
            source[y * pitch + x * 4..y * pitch + x * 4 + 4].fill((y * width + x) as u8);
        }
    }
    let mut backing = vec![0x99; width * 3 * 4];
    let regions =
        [Rect { x: 1, y: 0, width: 2, height: 2 }, Rect { x: 2, y: 1, width: 2, height: 2 }];
    let copied = copy_regions(&source, pitch, &mut backing, width * 4, &regions).expect("copy");
    assert_eq!(copied, 32);
    for y in 0..3 {
        for x in 0..width {
            let touched = regions.iter().any(|r| {
                x >= r.x as usize
                    && x < (r.x + r.width) as usize
                    && y >= r.y as usize
                    && y < (r.y + r.height) as usize
            });
            let expected = if touched { (y * width + x) as u8 } else { 0x99 };
            assert_eq!(&backing[(y * width + x) * 4..(y * width + x + 1) * 4], &[expected; 4]);
        }
    }
    assert!(copy_regions(&source[..1], pitch, &mut backing, width * 4, &regions).is_err());
}
