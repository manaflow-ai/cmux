use super::*;
use proptest::prelude::*;
const BUILD: &str = "1234-abcdef0";
const SCREEN: Frame = Frame { x: 0., y: 0., width: 1512., height: 982. };
fn window(id: &str) -> WindowRecord {
    WindowRecord {
        id: id.into(),
        frame: Frame { x: 100., y: 50., width: 800., height: 600. },
        display_id: 7,
        background_rgba: [1, 2, 3, 4],
        bar_rgba: [5, 6, 7, 8],
        image_key: format!("{BUILD}/{id}/3"),
        image_pixel_width: 1600,
        image_pixel_height: 1200,
        backing_scale: 2.0,
        appearance: 1,
        appearance_follows_system: 1,
        fullscreen: 0,
        screen_frame: SCREEN,
        visible_workspace_id: "ws".into(),
        visible_tab_ids: vec!["tab".into()],
    }
}
fn sample() -> LaunchRecordData {
    LaunchRecordData {
        windows: vec![window("w")],
        sidebar_rows: vec![SidebarRow {
            id: "s".into(),
            title: "Side".into(),
            icon_key: "folder".into(),
        }],
        session_socket_path: "/tmp/sock".into(),
        session_registry_id: "reg-1".into(),
    }
}
/// The v1 encoding, as the previous writer produced it.
fn encode_v1(r: &LaunchRecordData) -> Vec<u8> {
    let mut o = Vec::from(&MAGIC[..]);
    for n in [1, r.windows.len(), r.sidebar_rows.len()] {
        put_u16(&mut o, n);
    }
    for w in &r.windows {
        put_string(&mut o, &w.id).unwrap();
        put_frame(&mut o, w.frame);
        o.extend_from_slice(&w.display_id.to_le_bytes());
        o.extend_from_slice(&w.background_rgba);
        o.extend_from_slice(&w.bar_rgba);
        put_string(&mut o, "/tmp/f.png").unwrap();
        o.extend_from_slice(&w.image_pixel_width.to_le_bytes());
        o.extend_from_slice(&w.image_pixel_height.to_le_bytes());
        put_string(&mut o, &w.visible_workspace_id).unwrap();
        put_u16(&mut o, w.visible_tab_ids.len());
        for t in &w.visible_tab_ids {
            put_string(&mut o, t).unwrap();
        }
    }
    for s in &r.sidebar_rows {
        for v in [&s.id, &s.title, &s.icon_key] {
            put_string(&mut o, v).unwrap();
        }
    }
    put_string(&mut o, &r.session_socket_path).unwrap();
    o
}
#[test]
fn round_trip() {
    let b = encode(&sample()).unwrap();
    let r = LaunchRecord::from_bytes(b).unwrap();
    let w = r.front_window().unwrap();
    assert_eq!(w.id, "w");
    assert_eq!(w.visible_tab_ids().collect::<Vec<_>>(), vec!["tab"]);
    assert_eq!(r.session_socket_path(), "/tmp/sock")
}
#[test]
fn v3_carries_the_registry_id_and_a_v2_record_reads_without_one() {
    let data = sample();
    let bytes = encode(&data).unwrap();
    assert_eq!(LaunchRecord::from_bytes(bytes.clone()).unwrap().session_registry_id(), "reg-1");
    // The same record as v2: no registry string after the socket path.
    let mut v2 = bytes[..bytes.len() - 2 - "reg-1".len()].to_vec();
    v2[8..10].copy_from_slice(&2u16.to_le_bytes());
    let r = LaunchRecord::from_bytes(v2.clone()).unwrap();
    assert_eq!(
        (r.version(), r.session_registry_id(), r.session_socket_path()),
        (2, "", "/tmp/sock")
    );
    // A v3 label without the registry string is malformed.
    v2[8..10].copy_from_slice(&3u16.to_le_bytes());
    assert!(LaunchRecord::from_bytes(v2).is_none());
    // The C entry without a registry id writes it empty.
    let dir = TestDir::new();
    let path = std::ffi::CString::new(dir.record().to_str().unwrap()).unwrap();
    assert!(unsafe {
        cmux_launch_record_write(
            path.as_ptr(),
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            c"s".as_ptr(),
        )
    });
    assert_eq!(LaunchRecord::read(dir.record()).unwrap().session_registry_id(), "");
    assert!(unsafe {
        cmux_launch_record_write_registry(
            path.as_ptr(),
            std::ptr::null(),
            0,
            std::ptr::null(),
            0,
            c"s".as_ptr(),
            c"reg-2".as_ptr(),
        )
    });
    assert_eq!(LaunchRecord::read(dir.record()).unwrap().session_registry_id(), "reg-2");
}
#[test]
fn round_trip_every_v2_field() {
    let mut data = sample();
    let w = &mut data.windows[0];
    w.backing_scale = 1.5;
    w.appearance = 1;
    w.appearance_follows_system = 0;
    w.fullscreen = 1;
    w.screen_frame = Frame { x: -1920., y: 120.5, width: 1920., height: 1080. };
    w.visible_tab_ids = vec!["a".into(), "b".into()];
    let r = LaunchRecord::from_bytes(encode(&data).unwrap()).unwrap();
    assert_eq!(r.version(), 3);
    let v = r.front_window().unwrap();
    let w = &data.windows[0];
    let back = WindowRecord {
        id: v.id.into(),
        frame: v.frame,
        display_id: v.display_id,
        background_rgba: v.background_rgba,
        bar_rgba: v.bar_rgba,
        image_key: v.image_key.into(),
        image_pixel_width: v.image_pixel_width,
        image_pixel_height: v.image_pixel_height,
        backing_scale: v.backing_scale,
        appearance: v.appearance,
        appearance_follows_system: v.appearance_follows_system,
        fullscreen: v.fullscreen,
        screen_frame: v.screen_frame,
        visible_workspace_id: v.visible_workspace_id.into(),
        visible_tab_ids: v.visible_tab_ids().map(String::from).collect(),
    };
    assert_eq!(&back, w);
    // And through the FFI writer and reader.
    let dir = TestDir::new();
    let path = std::ffi::CString::new(dir.record().to_str().unwrap()).unwrap();
    let c = |s: &str| std::ffi::CString::new(s).unwrap();
    let (id, key, ws, tabs) = (c(&w.id), c(&w.image_key), c("ws"), [c("a"), c("b")]);
    let tab_ptrs = tabs.iter().map(|t| t.as_ptr()).collect::<Vec<_>>();
    let input = CmuxLaunchWindowInput {
        frame_x: w.frame.x,
        frame_y: w.frame.y,
        frame_width: w.frame.width,
        frame_height: w.frame.height,
        display_id: w.display_id,
        background_rgba: w.background_rgba,
        bar_rgba: w.bar_rgba,
        image_pixel_width: w.image_pixel_width,
        image_pixel_height: w.image_pixel_height,
        window_id: id.as_ptr(),
        image_key: key.as_ptr(),
        visible_workspace_id: ws.as_ptr(),
        visible_tab_ids: tab_ptrs.as_ptr(),
        visible_tab_count: 2,
        backing_scale: w.backing_scale,
        screen_frame_x: w.screen_frame.x,
        screen_frame_y: w.screen_frame.y,
        screen_frame_width: w.screen_frame.width,
        screen_frame_height: w.screen_frame.height,
        appearance: w.appearance,
        appearance_follows_system: w.appearance_follows_system,
        fullscreen: w.fullscreen,
    };
    let socket = c("/tmp/sock");
    assert!(unsafe {
        cmux_launch_record_write(path.as_ptr(), &input, 1, std::ptr::null(), 0, socket.as_ptr())
    });
    let mut written = data.clone();
    written.sidebar_rows.clear();
    // cmux_launch_record_write records no registry id.
    written.session_registry_id.clear();
    assert_eq!(fs::read(dir.record()).unwrap(), encode(&written).unwrap());
    let mut out = CmuxLaunchWindow::default();
    assert!(unsafe { cmux_launch_record_front_window(path.as_ptr(), &mut out) });
    assert_eq!(
        (out.backing_scale, out.appearance, out.appearance_follows_system, out.fullscreen),
        (1.5, 1, 0, 1)
    );
    assert_eq!(
        [out.screen_frame_x, out.screen_frame_y, out.screen_frame_width, out.screen_frame_height],
        [-1920., 120.5, 1920., 1080.]
    );
    assert_eq!(unsafe { CStr::from_ptr(out.image_key.as_ptr()) }.to_str().unwrap(), w.image_key);
}
#[test]
fn rejects() {
    let mut b = encode(&sample()).unwrap();
    b.push(0);
    assert!(LaunchRecord::from_bytes(b).is_none());
    for version in [0, FORMAT_VERSION + 1] {
        let mut b = encode(&sample()).unwrap();
        b[8..10].copy_from_slice(&version.to_le_bytes());
        assert!(LaunchRecord::from_bytes(b).is_none())
    }
    // A v2 body labelled v1 does not parse as v1.
    let mut b = encode(&sample()).unwrap();
    b[8] = 1;
    assert!(LaunchRecord::from_bytes(b).is_none())
}
#[test]
fn v1_record_reads_with_defaults() {
    let data = sample();
    let r = LaunchRecord::from_bytes(encode_v1(&data)).unwrap();
    assert_eq!(r.version(), 1);
    let w = r.front_window().unwrap();
    assert_eq!((w.id, w.frame, w.display_id), ("w", data.windows[0].frame, 7));
    assert_eq!((w.image_pixel_width, w.image_pixel_height), (1600, 1200));
    assert_eq!(w.visible_tab_ids().collect::<Vec<_>>(), vec!["tab"]);
    assert_eq!((w.image_key, w.backing_scale, w.screen_frame), ("", 0.0, Frame::default()));
    assert_eq!((w.appearance, w.appearance_follows_system, w.fullscreen), (0, 0, 0));
    assert_eq!(r.sidebar_rows().next().unwrap().title, "Side");
    assert_eq!(r.session_socket_path(), "/tmp/sock");
}
#[test]
fn ffi_windows_front_first_and_bounded_by_cap() {
    let dir = TestDir::new();
    let path = std::ffi::CString::new(dir.record().to_str().unwrap()).unwrap();
    let mut data = sample();
    data.windows = ["front", "middle", "back"].map(window).to_vec();
    write_atomic(dir.record(), &data).unwrap();
    let mut out = [CmuxLaunchWindow::default(); 4];
    let ids = |out: &[CmuxLaunchWindow]| {
        out.iter()
            .map(|w| unsafe { CStr::from_ptr(w.window_id.as_ptr()) }.to_str().unwrap().to_owned())
            .collect::<Vec<_>>()
    };
    assert_eq!(unsafe { cmux_launch_record_windows(path.as_ptr(), out.as_mut_ptr(), 4) }, 3);
    assert_eq!(ids(&out), ["front", "middle", "back", ""]);
    let mut two = [CmuxLaunchWindow::default(); 2];
    assert_eq!(unsafe { cmux_launch_record_windows(path.as_ptr(), two.as_mut_ptr(), 2) }, 3);
    assert_eq!(ids(&two), ["front", "middle"]);
    assert_eq!(unsafe { cmux_launch_record_windows(path.as_ptr(), std::ptr::null_mut(), 0) }, 3);
    assert_eq!(unsafe { cmux_launch_record_windows(path.as_ptr(), std::ptr::null_mut(), 1) }, 0);
    assert_eq!(unsafe { cmux_launch_record_windows(std::ptr::null(), out.as_mut_ptr(), 4) }, 0);
    // One unusable window makes the whole call fail, zeroing what it wrote.
    data.windows[2].id = "x".repeat(65);
    write_atomic(dir.record(), &data).unwrap();
    assert_eq!(unsafe { cmux_launch_record_windows(path.as_ptr(), out.as_mut_ptr(), 4) }, 0);
    assert_eq!(ids(&out[..3]), ["", "", ""]);
}

struct TestDir(std::path::PathBuf);
impl TestDir {
    fn new() -> Self {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "cmux-launch-record-test-{}-{}-{}",
            std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn record(&self) -> std::path::PathBuf {
        self.0.join("record")
    }
}
impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn exact_cap_and_one_byte_over() {
    // Zero windows/rows, then a socket string; both are structurally valid.
    for version in [1u8, 2] {
        for extra in [0, 1] {
            let mut bytes = Vec::from(&b"CMUXLR01\x00\x00\x00\x00\x00\x00"[..]);
            bytes[8] = version;
            bytes.extend_from_slice(&((MAX_BYTES - 16 + extra) as u16).to_le_bytes());
            bytes.resize(MAX_BYTES + extra, b'x');
            let dir = TestDir::new();
            fs::write(dir.record(), &bytes).unwrap();
            assert_eq!(LaunchRecord::from_bytes(bytes).is_some(), extra == 0);
            assert_eq!(LaunchRecord::read(dir.record()).is_some(), extra == 0);
        }
    }
    // The writer stops at the same bound.
    let mut data = sample();
    let length = encode(&data).unwrap().len();
    data.session_socket_path.push_str(&"x".repeat(MAX_BYTES - length));
    assert_eq!(encode(&data).unwrap().len(), MAX_BYTES);
    data.session_socket_path.push('x');
    assert!(encode(&data).is_err());
}

#[test]
fn atomic_write_preserves_previous_on_invalid_input() {
    let dir = TestDir::new();
    let mut data = sample();
    write_atomic(dir.record(), &data).unwrap();
    data.windows[0].id = "replacement".into();
    write_atomic(dir.record(), &data).unwrap();
    assert_eq!(LaunchRecord::read(dir.record()).unwrap().front_window().unwrap().id, "replacement");
    let previous = fs::read(dir.record()).unwrap();
    data.session_socket_path = "x".repeat(MAX_BYTES);
    assert!(write_atomic(dir.record(), &data).is_err());
    assert_eq!(fs::read(dir.record()).unwrap(), previous);
    assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 1);
    assert!(LaunchRecord::read(dir.0.join("missing")).is_none());
}

#[test]
fn ffi_strings_are_terminated_or_output_is_zero() {
    let dir = TestDir::new();
    let path = std::ffi::CString::new(dir.record().to_str().unwrap()).unwrap();
    for (id_len, key_len, expected) in [(64, 1024, true), (65, 1024, false), (64, 1025, false)] {
        let mut data = sample();
        data.windows[0].id = "w".repeat(id_len);
        data.windows[0].image_key = "p".repeat(key_len);
        write_atomic(dir.record(), &data).unwrap();
        let mut out = CmuxLaunchWindow { display_id: 999, ..Default::default() };
        assert_eq!(unsafe { cmux_launch_record_front_window(path.as_ptr(), &mut out) }, expected);
        if expected {
            assert_eq!(unsafe { CStr::from_ptr(out.window_id.as_ptr()) }.to_bytes().len(), id_len);
            assert_eq!(unsafe { CStr::from_ptr(out.image_key.as_ptr()) }.to_bytes().len(), key_len);
        } else {
            assert_eq!(out.display_id, 0);
            assert_eq!(out.frame_width, 0.0);
            assert!(out.window_id.iter().chain(out.image_key.iter()).all(|&v| v == 0));
        }
    }
    let mut out = CmuxLaunchWindow { display_id: 999, ..Default::default() };
    assert!(!unsafe { cmux_launch_record_front_window(std::ptr::null(), &mut out) });
    assert_eq!(out.display_id, 0);
    let mut data = sample();
    data.windows[0].image_key = "a\0b".into();
    write_atomic(dir.record(), &data).unwrap();
    assert!(!unsafe { cmux_launch_record_front_window(path.as_ptr(), &mut out) });
    assert_eq!(out.display_id, 0);
    // A v1 record still reads, with an empty key and defaulted v2 fields.
    fs::write(dir.record(), encode_v1(&sample())).unwrap();
    assert!(unsafe { cmux_launch_record_front_window(path.as_ptr(), &mut out) });
    assert_eq!((out.display_id, out.backing_scale, out.image_key[0]), (7, 0.0, 0));
}

#[test]
fn ffi_rejects_impossible_counts_before_dereference() {
    assert!(
        unsafe {
            input_data(std::ptr::null(), usize::MAX, std::ptr::null(), 0, std::ptr::null(), "")
        }
        .is_none()
    );
    assert!(
        unsafe {
            input_data(std::ptr::null(), 0, std::ptr::null(), usize::MAX, std::ptr::null(), "")
        }
        .is_none()
    );
}

#[test]
fn window_min_bytes_matches_encoding() {
    let mut data = sample();
    data.sidebar_rows.clear();
    data.session_socket_path.clear();
    let empty = encode(&LaunchRecordData { windows: vec![], ..data.clone() }).unwrap().len();
    let w = &mut data.windows[0];
    (w.id, w.image_key, w.visible_workspace_id, w.visible_tab_ids) =
        (String::new(), String::new(), String::new(), vec![]);
    assert_eq!(encode(&data).unwrap().len() - empty, WINDOW_MIN_BYTES);
}

#[test]
fn unicode_round_trip_and_invalid_utf8_rejected() {
    let mut data = sample();
    data.sidebar_rows[0].title = "作業 🦀".into();
    data.windows[0].image_key = format!("{BUILD}/画面/1");
    let bytes = encode(&data).unwrap();
    let r = LaunchRecord::from_bytes(bytes).unwrap();
    assert_eq!(r.sidebar_rows().next().unwrap().title, data.sidebar_rows[0].title);
    assert_eq!(r.front_window().unwrap().image_key, data.windows[0].image_key);
    let mut invalid = encode(&sample()).unwrap();
    invalid[16] = 0xff; // First window id.
    assert!(LaunchRecord::from_bytes(invalid).is_none());
}

#[test]
fn stage_zero_is_closed_over_allowlist() {
    assert!(stage_zero_task_is_allowed(LaunchTask {
        name: "read_launch_record",
        stage: LaunchStage::Shell
    }));
    assert!(stage_zero_task_is_allowed(LaunchTask {
        name: "restore_everything",
        stage: LaunchStage::Rest
    }));
    assert!(!stage_zero_task_is_allowed(LaunchTask {
        name: "restore_everything",
        stage: LaunchStage::Shell
    }));
}

proptest! {
    #[test]
    fn arbitrary_bytes_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..(MAX_BYTES + 128))) {
        let _ = LaunchRecord::from_bytes(bytes);
    }
}
