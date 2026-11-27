use super::*;

#[test]
fn named_keys_map_to_virtual_keys() {
    assert_eq!(named_vk("return"), Some((0x0D, false)));
    assert_eq!(named_vk("left"), Some((0x25, true)));
    assert_eq!(named_vk("delete"), Some((0x2E, true)));
    assert_eq!(named_vk("page_down"), Some((0x22, true)));
    assert_eq!(named_vk("f1"), Some((0x70, false)));
    assert_eq!(named_vk("f24"), Some((0x87, false)));
    assert_eq!(named_vk("f25"), None);
    assert_eq!(named_vk("f0"), None);
    assert_eq!(named_vk("hyper"), None);
}

#[test]
fn key_lparams_match_real_keyboard_messages() {
    // 'A' down: repeat 1, scan 0x1E.
    assert_eq!(key_lparam(0x1E, false, false, false), 0x001E_0001);
    // 'A' up: previous state and transition bits.
    assert_eq!(key_lparam(0x1E, false, false, true) as u32, 0xC01E_0001);
    // Left arrow (scan 0x4B) is extended.
    assert_eq!(key_lparam(0x4B, true, false, false), 0x014B_0001);
    // Alt context bit.
    assert_eq!(key_lparam(0x21, false, true, false), 0x2021_0001);
}

#[test]
fn point_lparam_packs_signed_words() {
    assert_eq!(point_lparam(10, 20), (20 << 16) | 10);
    let l = point_lparam(-5, 7) as u32;
    assert_eq!(l & 0xFFFF, 0xFFFB);
    assert_eq!(l >> 16, 7);
}

#[test]
fn wheel_params_and_deltas() {
    assert_eq!(wheel_wparam(-120, 0) as u32, 0xFF88_0000);
    assert_eq!(wheel_wparam(120, 0x0008) as u32, 0x0078_0008);
    // 3 lines per notch: 6 lines down is two notches of -120.
    assert_eq!(wheel_deltas(6.0, 3, true), vec![-120, -120]);
    // Up is positive.
    assert_eq!(wheel_deltas(-3.0, 3, true), vec![120]);
    // A partial notch is one smaller delta.
    assert_eq!(wheel_deltas(4.0, 3, true), vec![-120, -40]);
    // Horizontal: right is positive.
    assert_eq!(wheel_deltas(3.0, 3, false), vec![120]);
    assert_eq!(wheel_deltas(0.0, 3, true), Vec::<i16>::new());
    assert_eq!(wheel_deltas(f64::NAN, 3, true), Vec::<i16>::new());
    // A tiny scroll still sends something.
    assert_eq!(wheel_deltas(0.001, 3, true), vec![-1]);
}

#[test]
fn line_breaks_become_enter() {
    assert_eq!(char_units("a\nb"), vec![97, 13, 98]);
    assert_eq!(char_units("a\r\nb"), vec![97, 13, 98]);
    // Astral characters are two UTF-16 units.
    assert_eq!(char_units("\u{1F600}").len(), 2);
}

#[test]
fn absolute_input_spans_the_virtual_screen() {
    assert_eq!(absolute_input(0.0, 0.0, 0, 0, 1920, 1080), (0, 0));
    assert_eq!(absolute_input(1919.0, 1079.0, 0, 0, 1920, 1080), (65535, 65535));
    // A monitor left of the primary has negative coordinates.
    assert_eq!(absolute_input(-1920.0, 0.0, -1920, 0, 3840, 1080), (0, 0));
    assert_eq!(absolute_input(-5000.0, 0.0, -1920, 0, 3840, 1080).0, 0);
}

#[test]
fn bgra_rows_with_padding_become_opaque_rgba() {
    // 1x2 image, stride 8 (4 bytes of padding per row).
    let bgra = [1, 2, 3, 0, 9, 9, 9, 9, 4, 5, 6, 0, 9, 9, 9, 9];
    assert_eq!(bgra_to_rgba(&bgra, 1, 2, 8), vec![3, 2, 1, 255, 6, 5, 4, 255]);
    assert!(all_black(&[0, 0, 0, 255, 0, 0, 0, 255]));
    assert!(!all_black(&[0, 0, 1, 255]));
}

#[test]
fn crop_clips_to_the_image() {
    // 3x2 image; pixel value = index.
    let img: Vec<u8> = (0..6u8).flat_map(|i| [i, i, i, 255]).collect();
    let (out, w, h) = crop_rgba(&img, 3, 2, 1, 1, 5, 5);
    assert_eq!((w, h), (2, 1));
    assert_eq!(out, vec![4, 4, 4, 255, 5, 5, 5, 255]);
    let (_, w, h) = crop_rgba(&img, 3, 2, 9, 9, 1, 1);
    assert_eq!((w, h), (0, 0));
}

#[test]
fn roles_and_ids() {
    assert_eq!(role_for_control_type(50000), "button");
    assert_eq!(role_for_control_type(50004), "text_field");
    assert_eq!(role_for_control_type(50032), "window");
    assert_eq!(role_for_control_type(1), "unknown");
    assert_eq!(parse_element_id(&element_id(7, 42)), Some((7, 42)));
    assert_eq!(parse_element_id("7"), None);
    assert_eq!(parse_element_id("a.b"), None);
    assert_eq!(parse_window_id("132456"), Some(132456));
    assert_eq!(parse_window_id("0"), None);
    assert_eq!(parse_window_id("0x10"), None);
}

#[test]
fn app_ids() {
    let aumid = "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App";
    assert_eq!(parse_app_id(aumid), Ok(AppId::Aumid(aumid.into())));
    assert_eq!(
        parse_app_id(r"C:\Windows\notepad.exe"),
        Ok(AppId::Exe(r"C:\Windows\notepad.exe".into()))
    );
    assert_eq!(parse_app_id("notepad.exe"), Ok(AppId::Exe("notepad.exe".into())));
    assert_eq!(parse_app_id("notepad"), Ok(AppId::Exe("notepad.exe".into())));
    assert!(parse_app_id("ms-settings:privacy").is_err());
    assert!(parse_app_id("https://example.com").is_err());
    assert!(parse_app_id("evil.bat").is_err());
    assert!(parse_app_id(r"C:\x\run.ps1").is_err());
    assert!(parse_app_id(r"C:\Users\a\Desktop\App.lnk").is_err());
    assert!(parse_app_id("notepad.exe\" C:\\x").is_err());
    assert!(parse_app_id("").is_err());
    assert_eq!(exe_id(r"C:\Program Files\App\MyApp.EXE"), "myapp.exe");
    assert_eq!(exe_id("notepad.exe"), "notepad.exe");
    assert_eq!(exe_display_name(r"C:\Windows\notepad.exe"), "Notepad");
    assert_eq!(exe_display_name("tool"), "Tool");
}

#[test]
fn own_input_is_told_apart_across_the_tick_wrap() {
    assert!(input_is_ours(1010, Some(1000), 50));
    assert!(!input_is_ours(1100, Some(1000), 50));
    assert!(!input_is_ours(1010, None, 50));
    // The person typed before our injection: theirs.
    assert!(!input_is_ours(990, Some(1000), 50));
    // Across the wrap.
    assert!(input_is_ours(5, Some(u32::MAX - 5), 50));
    assert_eq!(ticks_since(5, u32::MAX - 5), 11);
}

#[test]
fn glide_eases_out_and_lands() {
    assert_eq!(glide((0.0, 0.0), (100.0, 50.0), 0.0), (0.0, 0.0));
    assert_eq!(glide((0.0, 0.0), (100.0, 50.0), 1.0), (100.0, 50.0));
    assert_eq!(glide((0.0, 0.0), (100.0, 50.0), 7.0), (100.0, 50.0));
    // Ease-out: past halfway at half time.
    assert!(glide((0.0, 0.0), (100.0, 0.0), 0.5).0 > 80.0);
}

#[test]
fn arrow_is_blue_inside_white_at_the_edge_and_clear_outside() {
    let blue = [0x0A, 0x84, 0xFF];
    let white = [0xFF, 0xFF, 0xFF];
    let a = arrow_bitmap(2.0, blue, white);
    let px = |x: usize, y: usize| {
        let i = (y * a.width + x) * 4;
        [a.bgra[i], a.bgra[i + 1], a.bgra[i + 2], a.bgra[i + 3]]
    };
    // Inside the body (units (3, 10)): opaque cmux blue, as BGRA.
    let (bx, by) = (a.tip.0 + 6, a.tip.1 + 20);
    assert_eq!(px(bx, by), [0xFF, 0x84, 0x0A, 0xFF]);
    // The tip is covered by the white outline.
    let tip = px(a.tip.0, a.tip.1);
    assert!(tip[3] > 0 && tip[0] > 0xC0 && tip[1] > 0xC0 && tip[2] > 0xC0);
    // Far right of the top rows is clear.
    assert_eq!(px(a.width - 1, 0)[3], 0);
    // Premultiplied: no channel exceeds alpha.
    assert!(a.bgra.chunks_exact(4).all(|p| p[0] <= p[3] && p[1] <= p[3] && p[2] <= p[3]));
}
