//! A Kitty image sent as a file path (`t=f`, what `kitten icat
//! --transfer-mode=file` does) shows on a viewer that cannot open the path:
//! the daemon reads the file where the program runs and streams the image
//! in-band, so the attach stream carries direct data, never the path.
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
mod support;
use base64::Engine;
use cmux_tui_core::{AttachFrame, Mux, SurfaceOptions};
use support::DaemonMuxOps;

const PNG_1X1_RED: &str = concat!(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA",
    "DUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
);

fn unique(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

#[test]
fn file_medium_image_reaches_an_attached_viewer_in_band() {
    let base64 = base64::engine::general_purpose::STANDARD;
    let dir = std::env::temp_dir().join(unique("cmux-kitty-file-media-e2e"));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("red.png");
    std::fs::write(&path, base64.decode(PNG_1X1_RED).unwrap()).unwrap();
    let encoded_path = base64.encode(path.to_str().unwrap());
    // The program waits for a line so the viewer attaches first and sees
    // the command on the live stream.
    let script = format!(
        r"read _; printf '\033_Ga=T,f=100,i=91,c=2,r=1,q=2,t=f;{encoded_path}\033\\'; echo image-sent; sleep 30"
    );
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), script]),
        ..Default::default()
    };
    let mux = Mux::new(unique("test-kitty-file-media"), options);
    mux.set_cell_pixel_size(9, 18);
    let surface = mux.new_workspace(None, Some((20, 4))).unwrap();

    let attach = surface.attach_stream().unwrap();
    let mut viewer =
        ghostty_vt::Terminal::new(attach.cols, attach.rows, 1000, ghostty_vt::Callbacks::default())
            .unwrap();
    viewer.resize(attach.cols, attach.rows, 9, 18).unwrap();
    viewer.vt_write(&attach.replay);
    viewer.vt_write(&attach.pending_sequence);
    surface.write_bytes(b"\n").unwrap();

    let mut live = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !viewer.plain_text().unwrap().contains("image-sent") {
        assert!(Instant::now() < deadline, "the program's output never arrived");
        match attach.stream.recv_timeout(Duration::from_millis(200)) {
            Ok(AttachFrame::Output(bytes))
            | Ok(AttachFrame::OutputWithColors { output: bytes, .. }) => {
                viewer.vt_write(&bytes);
                live.extend(bytes);
            }
            _ => {}
        }
    }

    let live = String::from_utf8_lossy(&live);
    assert!(live.contains("\x1b_Ga=T,f=100,i=91,c=2,r=1,q=2;"), "direct data on the wire");
    assert!(!live.contains(&encoded_path), "the path never reaches the viewer");
    let graphics = viewer.kitty_graphics_snapshot().unwrap();
    let image = graphics.image(91).expect("the viewer shows the image");
    assert_eq!((image.width, image.height), (1, 1));
    assert_eq!(graphics.placements.len(), 1);

    let _ = mux.close_surface(surface.id);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Before/after on the reader-to-parser pipeline: libghostty parsing 64 KiB
/// reads alone, then with the rewrite scan in front, for output with no
/// Kitty commands. Alternating rounds, medians, so machine noise hits both.
///
/// `cargo test --release -p cmux-tui-core --test kitty_file_media -- --ignored --nocapture`
#[test]
#[ignore = "benchmark; run in release with --ignored"]
fn rewrite_scan_costs_under_one_percent_of_parsing() {
    use cmux_kitty_media::KittyMediaRewriter;
    use std::hint::black_box;

    const READ: usize = 64 * 1024;
    const READS: usize = 512;
    let workloads: [(&str, &[u8]); 3] = [
        ("yes", b"y\n"),
        ("ls --color", b"\x1b[01;34mdirectory\x1b[0m  \x1b[01;32mexec\x1b[0m  plain.txt\r\n"),
        ("cat source", b"    let value = compute(&input, 42); // comment\n"),
    ];
    for (name, pattern) in workloads {
        let read: Vec<u8> = pattern.iter().copied().cycle().take(READ).collect();
        let mut terminal =
            ghostty_vt::Terminal::new(120, 40, 1000, ghostty_vt::Callbacks::default()).unwrap();
        let mut rewriter = KittyMediaRewriter::new();
        let mut scratch = Vec::new();
        let mut before = Vec::new();
        let mut after = Vec::new();
        let mut parse = |rewrite: bool| {
            let start = Instant::now();
            for _ in 0..READS {
                if rewrite {
                    terminal.vt_write(rewriter.rewrite_borrowed(black_box(&read), &mut scratch));
                } else {
                    terminal.vt_write(black_box(&read));
                }
            }
            start.elapsed()
        };
        for round in 0..15 {
            // Alternate which goes first so warm-up and drift hit both.
            let first = round % 2 == 0;
            let a = parse(first);
            let b = parse(!first);
            let (with, without) = if first { (a, b) } else { (b, a) };
            after.push(with);
            before.push(without);
        }
        before.sort();
        after.sort();
        let (before, after) = (before[before.len() / 2], after[after.len() / 2]);
        // The scan alone, which bounds what it can add to the pipeline.
        let start = Instant::now();
        for _ in 0..READS * 16 {
            black_box(rewriter.rewrite_borrowed(black_box(&read), &mut scratch).len());
        }
        let scan = start.elapsed() / 16;
        let mib = (READ * READS) as f64 / f64::from(1u32 << 20);
        println!(
            "{name:>11}: parse {:.0} MiB/s, scan+parse {:.0} MiB/s ({:+.2}%), scan alone {:.3}% of parse",
            mib / before.as_secs_f64(),
            mib / after.as_secs_f64(),
            (after.as_secs_f64() / before.as_secs_f64() - 1.0) * 100.0,
            scan.as_secs_f64() / before.as_secs_f64() * 100.0,
        );
        assert!(scan < before / 100, "{name}: the scan costs over 1% of parsing");
    }
}
