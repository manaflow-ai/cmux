//! Scrollback integrity probes for local PTYs and hosted terminal framing.
//!
//! These tests deliberately retain more than the production default. The
//! default is a byte budget and is allowed to evict old rows; this probe is
//! checking that rows which are retained do not disappear or move while a
//! person reads scrollback.

use super::*;
use std::io::Write;
use std::os::fd::OwnedFd;
use std::os::unix::net::UnixStream;

const ROWS: u16 = 24;
const TOTAL_LINES: u32 = 200_000;
const FIRST_BATCH: u32 = 2_000;
const SCROLLBACK_BYTES: usize = 256 * 1024 * 1024;

fn stress_options() -> SurfaceOptions {
    SurfaceOptions {
        cols: 80,
        rows: ROWS,
        scrollback: SCROLLBACK_BYTES,
        ..SurfaceOptions::default()
    }
}

fn line(number: u32) -> String {
    format!("row-{number:06} 界宽")
}

fn output(from: u32, through: u32) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(((through - from + 1) * 32) as usize);
    for number in from..=through {
        let colour = number % 8;
        bytes.extend_from_slice(format!("\x1b[3{colour}m{}\x1b[0m\r\n", line(number)).as_bytes());
    }
    bytes
}

fn history_rows_after(lines: u32) -> u32 {
    // Every producer row ends in CRLF, leaving one empty active row.
    lines + 1 - u32::from(ROWS)
}

fn row_texts(rows: &[Vec<ghostty_vt::Cell>]) -> Vec<String> {
    ghostty_vt::rows_to_runs(rows)
        .into_iter()
        .map(|runs| runs.into_iter().map(|run| run.text).collect::<String>().trim_end().to_owned())
        .collect()
}

fn assert_numbered_rows(rows: &[Vec<ghostty_vt::Cell>], first: u32) {
    for (index, (row, text)) in rows.iter().zip(row_texts(rows)).enumerate() {
        let number = first + index as u32;
        assert_eq!(text, line(number), "producer row {number} was missing or changed");
        assert_eq!(row[0].fg, ghostty_vt::ColorSpec::Palette((number % 8) as u8));
        use ghostty_vt::CellWidth::{SpacerTail, Wide};
        assert_eq!(
            [row[11].width, row[12].width, row[13].width, row[14].width],
            [Wide, SpacerTail, Wide, SpacerTail],
            "wide cells in row {number}"
        );
    }
}

fn wait_for_lines(surface: &Arc<Surface>, lines: u32) {
    let progress = &surface.as_pty().unwrap().stream_progress;
    let mut observed = progress.revision();
    let deadline = Instant::now() + Duration::from_secs(30);
    let rows = history_rows_after(lines);
    loop {
        if surface.with_terminal(|term| term.history_rows() >= rows).unwrap_or(false) {
            return;
        }
        assert!(Instant::now() < deadline, "terminal never parsed all {lines} producer rows");
        observed = progress
            .wait_for_change(observed, deadline)
            .unwrap_or_else(|| panic!("terminal stream did not reach {rows} history rows"));
    }
}

fn assert_retained_rows(surface: &Arc<Surface>, expected_through: u32) {
    surface.with_terminal(|term| {
        let retained = term.history_rows();
        assert_eq!(retained, history_rows_after(expected_through), "history rows were lost");
        let mut start = 0u32;
        while start < retained {
            let count = (retained - start).min(1024) as u16;
            let rows = term.styled_history_rows(start, count).expect("history rows");
            assert_eq!(rows.len(), count as usize, "history page was truncated");
            assert_numbered_rows(&rows, start + 1);
            start += u32::from(count);
        }
    });
}

fn assert_render_grid(
    surface: &Arc<Surface>,
    first: u32,
    trailing_blank: bool,
    attach: &RenderAttachStream,
) {
    let pty = surface.as_pty().unwrap();
    let mut term = pty.term.lock().unwrap();
    let generation = pty.render_generation.fetch_add(1, Ordering::AcqRel) + 1;
    pty.build_frame_locked(&mut term, generation, false).unwrap();
    drop(term);
    let frame = loop {
        match attach.stream.try_recv() {
            Ok(RenderAttachFrame::Frame(frame)) => break frame,
            Ok(_) => continue,
            Err(error) => panic!("render attach did not receive a frame: {error:?}"),
        }
    };
    let rows = frame.frame.styled_rows();
    assert_eq!(rows.len(), usize::from(ROWS));
    let numbered = rows.len() - usize::from(trailing_blank);
    assert_numbered_rows(&rows[..numbered], first);
    if trailing_blank {
        assert_eq!(row_texts(&rows[numbered..]), vec![String::new()]);
    }
}

fn assert_following(surface: &Arc<Surface>, lines: u32, attach: &RenderAttachStream) {
    surface.with_terminal(|term| {
        let scrollbar = term.scrollbar().unwrap();
        assert!(!scrollbar.scrolled_back(), "returning to bottom did not resume follow");
        assert_eq!(scrollbar.offset, u64::from(history_rows_after(lines)));
    });
    assert_render_grid(surface, history_rows_after(lines) + 1, true, attach);
}

#[cfg(unix)]
#[test]
fn local_pty_scrollback_stays_put_during_a_200k_line_flood() {
    let mux = Mux::new_for_test("scroll-stress-local", stress_options());
    let (reader, mut writer) = UnixStream::pair().unwrap();
    writer.set_write_timeout(Some(Duration::from_secs(30))).unwrap();
    let master = std::fs::File::from(OwnedFd::from(reader.try_clone().unwrap()));
    let geometry = PtyGeometry { cols: 80, rows: ROWS, cell_width: 8, cell_height: 16 };
    let (end_tx, end_rx) = std::sync::mpsc::channel();
    let surface = Surface::spawn_local(
        LocalSpawn {
            id: 51_001,
            opts: stress_options(),
            mux: Arc::downgrade(&mux),
            terminal_public_id: None,
            kitty_reservation: None,
            initial_kitty_limits: KittyGraphicsLimits::disabled(),
            resource_identity: None,
            lifetime: PtyLifetime::DaemonOwned,
            cell_pixels: (8, 16),
            initial_geometry: geometry,
            host_identity: None,
        },
        LocalLaunch {
            master: Box::new(FdMasterPty { file: master, size: Mutex::new(geometry.pty_size()) }),
            reader: Box::new(reader),
            writer: Box::new(std::io::sink()),
            killer: Box::new(TestChildKiller),
            wait: Box::new(move || {
                let _ = end_rx.recv();
                TerminalEnd::ProcessEnded(TerminalExit::unknown("scroll stress ended"))
            }),
            pid: None,
            command: Vec::new(),
            cwd: None,
            supports_clear_history_key_fallback: false,
            holder: None,
        },
    )
    .unwrap();
    let attach = surface.attach_render_stream().unwrap();

    for chunk_start in (1..=FIRST_BATCH).step_by(500) {
        writer.write_all(&output(chunk_start, (chunk_start + 499).min(FIRST_BATCH))).unwrap();
    }
    wait_for_lines(&surface, FIRST_BATCH);
    surface.scroll_delta(-12).unwrap();
    let held = surface.with_terminal(|term| term.viewport_text().unwrap()).unwrap();
    assert_render_grid(&surface, history_rows_after(FIRST_BATCH) + 1 - 12, false, &attach);

    for chunk_start in (FIRST_BATCH + 1..=TOTAL_LINES).step_by(500) {
        writer.write_all(&output(chunk_start, (chunk_start + 499).min(TOTAL_LINES))).unwrap();
    }
    wait_for_lines(&surface, TOTAL_LINES);
    let after = surface.with_terminal(|term| term.viewport_text().unwrap()).unwrap();
    assert_eq!(after, held, "local output moved the viewport while scrolled back");
    assert_render_grid(&surface, history_rows_after(FIRST_BATCH) + 1 - 12, false, &attach);
    assert_retained_rows(&surface, TOTAL_LINES);

    surface.scroll_to_bottom().unwrap();
    assert_following(&surface, TOTAL_LINES, &attach);
    writer.write_all(&output(TOTAL_LINES + 1, TOTAL_LINES + 1)).unwrap();
    wait_for_lines(&surface, TOTAL_LINES + 1);
    assert_following(&surface, TOTAL_LINES + 1, &attach);
    drop(writer);
    let _ = end_tx.send(());
}

#[test]
fn hosted_frames_preserve_the_same_scrollback_rows_and_viewport() {
    let mux = Mux::new_for_test("scroll-stress-hosted", stress_options());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (mut attachment, mut host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    host.set_write_timeout(Some(Duration::from_secs(30))).unwrap();
    let terminal_id = attachment.record.terminal_id.clone();
    attachment.record.workspace_key = workspace.key.clone();
    mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();
    attachment.smart_renderer = true;
    let surface = Surface::spawn_hosted(
        51_002,
        stress_options(),
        Arc::downgrade(&mux),
        HostedSurfaceLaunch {
            adopted: false,
            attachment,
            kitty_reservation: None,
            terminate_on_error: false,
            defer_launch_activation: false,
            lifetime: PtyLifetime::SessionOwned,
            terminal_public_id: None,
            resource_identity: None,
        },
    )
    .unwrap();
    let attach = surface.attach_render_stream().unwrap();

    let mut sequence = 1;
    for chunk_start in (1..=FIRST_BATCH).step_by(500) {
        let mut frame = Frame::new(
            MessageKind::Output,
            output(chunk_start, (chunk_start + 499).min(FIRST_BATCH)),
        );
        frame.sequence = sequence;
        sequence += 1;
        crate::terminal_host_protocol::write_frame(&mut host, &frame).unwrap();
    }
    wait_for_lines(&surface, FIRST_BATCH);
    surface.scroll_delta(-12).unwrap();
    let held = surface.with_terminal(|term| term.viewport_text().unwrap()).unwrap();
    assert_render_grid(&surface, history_rows_after(FIRST_BATCH) + 1 - 12, false, &attach);
    for chunk_start in (FIRST_BATCH + 1..=TOTAL_LINES).step_by(500) {
        let mut frame = Frame::new(
            MessageKind::Output,
            output(chunk_start, (chunk_start + 499).min(TOTAL_LINES)),
        );
        frame.sequence = sequence;
        sequence += 1;
        crate::terminal_host_protocol::write_frame(&mut host, &frame).unwrap();
    }
    wait_for_lines(&surface, TOTAL_LINES);
    let after = surface.with_terminal(|term| term.viewport_text().unwrap()).unwrap();
    assert_eq!(after, held, "hosted output moved the viewport while scrolled back");
    assert_render_grid(&surface, history_rows_after(FIRST_BATCH) + 1 - 12, false, &attach);
    assert_retained_rows(&surface, TOTAL_LINES);
    surface.scroll_to_bottom().unwrap();
    assert_following(&surface, TOTAL_LINES, &attach);
    let mut frame = Frame::new(MessageKind::Output, output(TOTAL_LINES + 1, TOTAL_LINES + 1));
    frame.sequence = sequence;
    crate::terminal_host_protocol::write_frame(&mut host, &frame).unwrap();
    wait_for_lines(&surface, TOTAL_LINES + 1);
    assert_following(&surface, TOTAL_LINES + 1, &attach);
}
