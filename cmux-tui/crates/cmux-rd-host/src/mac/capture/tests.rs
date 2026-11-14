use super::*;

#[test]
fn sizes_fit_the_decoder_and_stay_even() {
    assert_eq!(fit(3456, 2234, None), (3342, 2160));
    assert_eq!(fit(1920, 1080, Some(1280)), (1280, 720));
    assert_eq!(fit(1366, 768, None), (1366, 768));
}

#[test]
fn refresh_rates_round_and_zero_means_unknown() {
    assert_eq!(hz_to_fps(120.0), Some(120));
    assert_eq!(hz_to_fps(119.88), Some(120));
    assert_eq!(hz_to_fps(59.94), Some(60));
    assert_eq!(hz_to_fps(0.0), None);
    assert_eq!(hz_to_fps(f64::NAN), None);
    assert_eq!(hz_to_fps(500.0), Some(MAX_REFRESH_FPS));
}

#[test]
fn dirty_points_become_clamped_pixels() {
    let rect = to_pixels((10.0, 20.0, 5.0, 5.0), 2.0, (100, 100));
    assert_eq!(rect, Some(Rect { x: 20, y: 40, width: 10, height: 10 }));
    assert_eq!(to_pixels((60.0, 60.0, 10.0, 10.0), 2.0, (100, 100)), None);
}
