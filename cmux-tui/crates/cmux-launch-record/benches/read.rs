use cmux_launch_record::{
    Frame, LaunchRecord, LaunchRecordData, MAX_BYTES, SidebarRow, WindowRecord, write_atomic,
};
use std::time::Instant;

fn main() {
    let directory = std::env::temp_dir().join(format!(
        "cmux-launch-record-bench-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("record");
    let mut data = LaunchRecordData {
        windows: vec![WindowRecord {
            id: "front".into(),
            frame: Frame { x: 0., y: 0., width: 1280., height: 800. },
            display_id: 1,
            background_rgba: [0, 0, 0, 255],
            bar_rgba: [32, 32, 32, 255],
            image_path: "/saved/frame.png".into(),
            image_pixel_width: 2560,
            image_pixel_height: 1600,
            visible_workspace_id: "visible".into(),
            visible_tab_ids: vec!["chat".into()],
        }],
        sidebar_rows: (0..60)
            .map(|i| SidebarRow {
                id: i.to_string(),
                title: "Workspace".into(),
                icon_key: "folder".into(),
            })
            .collect(),
        session_socket_path: String::new(),
    };
    write_atomic(&path, &data).unwrap();
    let length = std::fs::metadata(&path).unwrap().len() as usize;
    data.session_socket_path = "x".repeat(MAX_BYTES - length);
    write_atomic(&path, &data).unwrap();
    assert_eq!(std::fs::metadata(&path).unwrap().len(), MAX_BYTES as u64);
    assert_eq!(LaunchRecord::read(&path).unwrap().front_window().unwrap().id, "front");
    let mut samples = Vec::with_capacity(10_000);
    for _ in 0..10_000 {
        let start = Instant::now();
        let record = std::hint::black_box(LaunchRecord::read(std::hint::black_box(&path))).unwrap();
        std::hint::black_box(record.front_window().unwrap());
        samples.push(start.elapsed().as_nanos());
    }
    samples.sort_unstable();
    println!(
        "valid 64 KiB record: n={} median={} ns p99={} ns max={} ns",
        samples.len(),
        samples[5000],
        samples[9900],
        samples[9999]
    );
    std::fs::remove_file(path).unwrap();
    std::fs::remove_dir(directory).unwrap();
    assert!(samples[9900] < 1_000_000, "64 KiB read p99 exceeds 1 ms");
}
