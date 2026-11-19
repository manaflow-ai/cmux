//! Bench (`#[ignore]`): `LaunchRecord::read` of a record with 5, 60 and 120 sidebar rows (the
//! app's stage 0 draws the sidebar from it before the daemon answers). `benches/read.rs` times a
//! 60-row record padded to the 64 KiB cap; this one keeps each record at its own size, so the
//! rows are what grows.
//!
//! Prints `TTI-BENCH launch_record_read rows=<n> n=<reads> median_ms=<ms> bytes=<size>`.
//!
//! cd cmux-tui && cargo test --release -p cmux-launch-record --test launch_read_bench -- --ignored --nocapture

use cmux_launch_record::{
    Frame, LaunchRecord, LaunchRecordData, SidebarRow, WindowRecord, write_atomic,
};
use std::time::Instant;

const READS: usize = 2_000;

fn data(rows: usize) -> LaunchRecordData {
    LaunchRecordData {
        windows: vec![WindowRecord {
            id: "front".into(),
            frame: Frame { x: 0., y: 0., width: 1280., height: 800. },
            display_id: 1,
            background_rgba: [0, 0, 0, 255],
            bar_rgba: [32, 32, 32, 255],
            image_key: "1-abc/front/1".into(),
            image_pixel_width: 2560,
            image_pixel_height: 1600,
            backing_scale: 2.0,
            appearance: 1,
            appearance_follows_system: 1,
            fullscreen: 0,
            screen_frame: Frame { x: 0., y: 0., width: 1512., height: 982. },
            visible_workspace_id: "visible".into(),
            visible_tab_ids: vec!["chat".into()],
        }],
        sidebar_rows: (0..rows)
            .map(|i| SidebarRow {
                id: format!("018f6e21-7b70-7e70-8000-{i:012}"),
                title: format!("A workspace title of a typical length {i}"),
                icon_key: "folder".into(),
            })
            .collect(),
        session_socket_path: "/tmp/cmux-1000/session.sock".into(),
    }
}

#[test]
#[ignore = "bench: run with --ignored --nocapture"]
fn launch_record_read_bench() {
    let directory = tempdir();
    let profile = if cfg!(debug_assertions) { "debug" } else { "release" };
    for rows in [5, 60, 120] {
        let path = directory.join(format!("record-{rows}"));
        write_atomic(&path, &data(rows)).unwrap();
        let bytes = std::fs::metadata(&path).unwrap().len();
        assert_eq!(LaunchRecord::read(&path).unwrap().front_window().unwrap().id, "front");
        let mut samples: Vec<f64> = (0..READS)
            .map(|_| {
                let start = Instant::now();
                let record =
                    std::hint::black_box(LaunchRecord::read(std::hint::black_box(&path))).unwrap();
                std::hint::black_box(record.front_window().unwrap());
                start.elapsed().as_secs_f64() * 1000.0
            })
            .collect();
        samples.sort_by(f64::total_cmp);
        println!(
            "TTI-BENCH launch_record_read rows={rows} n={READS} median_ms={:.4} p99_ms={:.4} \
             bytes={bytes} profile={profile}",
            samples[READS / 2],
            samples[READS * 99 / 100]
        );
        std::fs::remove_file(path).unwrap();
    }
    std::fs::remove_dir(directory).unwrap();
}

fn tempdir() -> std::path::PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "cmux-launch-record-tti-bench-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir(&directory).unwrap();
    directory
}
