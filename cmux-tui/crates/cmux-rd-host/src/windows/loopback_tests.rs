use super::*;

#[test]
fn viewer_reads_exact_sample_surrounded_by_different_pixels() {
    // A runner service in session 0, or a locked session, has no desktop a
    // visible window can paint, so GetPixel reads white. The selftest skips
    // its capture cell for the same reason.
    if let Some(reason) = crate::windows::no_interactive_desktop() {
        eprintln!("skipped: {reason}");
        return;
    }
    let (width, height) = (640, 360);
    let mut rgb = vec![0; width * height * 3];
    let center = (height / 2 * width + width / 2) * 3;
    rgb[center..center + 3].copy_from_slice(&[0xc3, 0x51, 0x33]);
    let mut viewer = ViewerWindow::new(640, 480).unwrap();
    assert_eq!(viewer.present(&rgb, width, height).unwrap(), 0x3351c3);
}

#[test]
fn preview_preserves_exact_samples_and_channel_order() {
    let (width, height) = (640, 360);
    let mut rgb = vec![0; width * height * 3];
    for y in 0..height {
        for x in 0..width {
            let i = (y * width + x) * 3;
            rgb[i..i + 3].copy_from_slice(&[x as u8, y as u8, (x ^ y) as u8]);
        }
    }
    let mut preview = vec![0; PREVIEW_WIDTH * PREVIEW_HEIGHT * 3];
    preview_bgr(&rgb, width, height, &mut preview).unwrap();
    for (x, y) in [(0, 0), (1, 1), (160, 90), (319, 179)] {
        let i = (y * PREVIEW_WIDTH + x) * 3;
        assert_eq!(&preview[i..i + 3], &[(2 * x ^ 2 * y) as u8, (2 * y) as u8, (2 * x) as u8]);
    }
    assert!(preview_bgr(&rgb[..3], width, height, &mut preview).is_err());
}

#[test]
fn optional_4k_mode_does_not_hide_product_or_required_mode_failures() {
    assert!(optional_4k_mode_unavailable(3840, 2160, DISP_CHANGE_BADMODE));
    assert!(!optional_4k_mode_unavailable(1920, 1080, DISP_CHANGE_BADMODE));
    assert!(!optional_4k_mode_unavailable(3840, 2160, DISP_CHANGE_SUCCESSFUL));
    assert!(!optional_4k_mode_unavailable(3840, 2160, -1));
}
