//! Pins the reader surface other crates use: read a record from a path, its format version, and
//! every window's v2 fields, front first. Only public items appear here.
use cmux_launch_record::{
    FORMAT_VERSION, Frame, LaunchRecord, LaunchRecordData, WindowRecord, WindowView, write_atomic,
};

fn window(id: &str, x: f64) -> WindowRecord {
    WindowRecord {
        id: id.into(),
        frame: Frame { x, y: 80.0, width: 1100.0, height: 720.0 },
        display_id: 1,
        background_rgba: [20, 20, 24, 255],
        bar_rgba: [30, 30, 36, 255],
        image_key: format!("4294.abc123/{id}/7"),
        image_pixel_width: 2200,
        image_pixel_height: 1440,
        backing_scale: 2.0,
        appearance: 1,
        appearance_follows_system: 1,
        fullscreen: 0,
        screen_frame: Frame { x: 0.0, y: 0.0, width: 1512.0, height: 982.0 },
        visible_workspace_id: "ws".into(),
        visible_tab_ids: vec![],
    }
}

/// The fields a dependent crate reads, by name, so a rename breaks this test.
#[allow(clippy::type_complexity)]
fn fields<'a>(
    w: &WindowView<'a>,
) -> (&'a str, Frame, [u8; 4], [u8; 4], f64, u8, u8, u8, Frame, &'a str, u32, u32) {
    (
        w.id,
        w.frame,
        w.background_rgba,
        w.bar_rgba,
        w.backing_scale,
        w.appearance,
        w.appearance_follows_system,
        w.fullscreen,
        w.screen_frame,
        w.image_key,
        w.image_pixel_width,
        w.image_pixel_height,
    )
}

#[test]
fn a_record_reads_from_its_path_front_first_with_v2_fields_and_v1_defaults() {
    let dir =
        std::env::temp_dir().join(format!("cmux-launch-record-public-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("launch-record");
    let mut back = window("back", 300.0);
    (back.backing_scale, back.appearance, back.appearance_follows_system, back.fullscreen) =
        (1.0, 0, 0, 1);
    let data = LaunchRecordData {
        windows: vec![window("front", 100.0), back],
        sidebar_rows: vec![],
        session_socket_path: String::new(),
        session_registry_id: String::new(),
    };
    write_atomic(&path, &data).unwrap();

    let record: Option<LaunchRecord> = LaunchRecord::read(&path);
    let record = record.unwrap();
    assert_eq!(record.version(), FORMAT_VERSION);
    assert_eq!(FORMAT_VERSION, 3);
    assert_eq!(record.session_registry_id(), "");
    let windows: Vec<WindowView<'_>> = record.windows().collect();
    assert_eq!(windows.len(), 2);
    let screen = Frame { x: 0.0, y: 0.0, width: 1512.0, height: 982.0 };
    let front = Frame { x: 100.0, y: 80.0, width: 1100.0, height: 720.0 };
    assert_eq!(
        fields(&windows[0]),
        (
            "front",
            front,
            [20, 20, 24, 255],
            [30, 30, 36, 255],
            2.0,
            1,
            1,
            0,
            screen,
            "4294.abc123/front/7",
            2200,
            1440
        )
    );
    let back = fields(&windows[1]);
    assert_eq!((back.0, back.1.x, back.4, back.5, back.6, back.7), ("back", 300.0, 1.0, 0, 0, 1));
    assert_eq!(record.front_window().unwrap().id, "front");

    // A v1 record (format 1: no scale, flags or screen frame) still reads; scale is 0.0.
    let mut b = b"CMUXLR01".to_vec();
    for n in [1u16, 1, 0] {
        b.extend(n.to_le_bytes());
    }
    let string = |b: &mut Vec<u8>, s: &str| {
        b.extend((s.len() as u16).to_le_bytes());
        b.extend(s.as_bytes());
    };
    string(&mut b, "old");
    for n in [100.0f64, 80.0, 1100.0, 720.0] {
        b.extend(n.to_le_bytes());
    }
    b.extend(1u32.to_le_bytes());
    b.extend([20, 20, 24, 255, 30, 30, 36, 255]);
    string(&mut b, "/saved/frame.png");
    b.extend(2200u32.to_le_bytes());
    b.extend(1440u32.to_le_bytes());
    string(&mut b, "ws");
    b.extend(0u16.to_le_bytes());
    string(&mut b, "");
    std::fs::write(&path, b).unwrap();
    let old = LaunchRecord::read(&path).unwrap();
    assert_eq!(old.version(), 1);
    let w = old.windows().next().unwrap();
    assert_eq!(
        fields(&w),
        (
            "old",
            front,
            [20, 20, 24, 255],
            [30, 30, 36, 255],
            0.0,
            0,
            0,
            0,
            Frame::default(),
            "",
            2200,
            1440
        )
    );

    assert!(LaunchRecord::read(dir.join("missing")).is_none());
    std::fs::remove_dir_all(&dir).unwrap();
}
