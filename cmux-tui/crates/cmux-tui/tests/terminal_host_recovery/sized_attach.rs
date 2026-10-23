//! A sized attach of a hosted terminal whose grid it changes (a phone joining
//! a Mac window under the smallest-viewer policy) used to return
//! before the host applied the resize: the attach replay was built at the old
//! grid, and the host's resize then reached the new view as a second
//! `resized` replay right after it (cnx-ios termqa D4: two full replays on
//! every reattach). The attach now waits for the host's resize, so the
//! view's first replay is already at the effective grid and is the only one.
//!
//! The default policy is "last active" since 74ba5f23a34, and a phone that
//! only attaches never takes the grid there, so these tests set "Fit
//! everyone" (`smallest`) on the terminal, where a phone does narrow it.

use super::*;

fn attach_sized(
    path: &Path,
    surface: u64,
    cols: u16,
    rows: u16,
    request_id: u64,
) -> (Box<dyn transport::Stream>, BufReader<Box<dyn transport::Stream>>, serde_json::Value) {
    let stream = transport::connect(path).unwrap();
    stream.set_read_timeout(Some(test_timeout(Duration::from_secs(10)))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    // The phone is narrower than the Mac in these tests; it says it is one.
    if cols < 100 {
        stream_request(
            &mut writer,
            &mut reader,
            serde_json::json!({
                "id": request_id + 1000, "cmd": "set-client-info", "name": "phone",
                "kind": "ios", "device_kind": "iphone",
            }),
        );
    }
    writeln!(
        writer,
        "{}",
        serde_json::json!({
            "id": request_id, "cmd": "attach-surface", "surface": surface,
            "cols": cols, "rows": rows,
        })
    )
    .unwrap();
    let mut state = None;
    let mut responded = false;
    while state.is_none() || !responded {
        let mut line = String::new();
        reader.read_line(&mut line).expect("attach stream closed before its replay");
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        if value["id"] == request_id {
            assert_eq!(value["ok"], true, "attach failed: {value}");
            responded = true;
        } else if value["event"] == "vt-state" {
            state = Some(value);
        } else {
            assert_ne!(value["event"], "resized", "a resize replay came before the attach replay");
        }
    }
    (writer, reader, state.unwrap())
}

/// Sets "Fit everyone" (`smallest`) on `surface`: the grid is the smallest
/// attached view per dimension.
fn fit_everyone(path: &Path, surface: u64) {
    request(
        path,
        serde_json::json!({
            "cmd": "set-size-policy", "surface": surface, "policy": {"mode": "smallest"},
        }),
    );
}

/// Events on an attach stream for `window`, by name.
fn events_within(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    window: Duration,
) -> Vec<serde_json::Value> {
    let deadline = Instant::now() + window;
    let mut events = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return events;
        }
        reader.get_ref().set_read_timeout(Some(remaining)).unwrap();
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => return events,
            Ok(_) => events.push(serde_json::from_str(&line).unwrap()),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                return events;
            }
            Err(error) => panic!("attach stream failed: {error}"),
        }
    }
}

#[test]
fn sized_attach_that_narrows_the_grid_replays_once_at_the_effective_size() {
    let mut harness = RecoveryHarness::start_unstarted("sized-attach-one-replay");
    // A dropped view holds the grid for a grace period (below); keep it short.
    harness.extra_env.push(("CMUX_TUI_TEST_DEPARTED_GRID_HOLD_MS".into(), "300".into()));
    harness.restart();
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "seq 1 300; exec /bin/cat"],
            "new_workspace": true,
            "name": "sized-attach",
            "cols": 120,
            "rows": 39,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    fit_everyone(&harness.socket, surface);
    assert!(wait_for_screen(&harness.socket, surface, "300").contains("300"));

    // The Mac window: wide, 39 rows.
    let (_mac_writer, _mac_reader, mac_state) = attach_sized(&harness.socket, surface, 120, 39, 2);
    assert_eq!((mac_state["cols"].as_u64(), mac_state["rows"].as_u64()), (Some(120), Some(39)));

    for round in 0..3u64 {
        // The phone: narrower and taller. Smallest per dimension is 53x39.
        let (phone_writer, mut phone_reader, phone_state) =
            attach_sized(&harness.socket, surface, 53, 42, 10 + round);
        assert_eq!(
            (phone_state["cols"].as_u64(), phone_state["rows"].as_u64()),
            (Some(53), Some(39)),
            "round {round}: the attach replay was built before the attach's resize"
        );
        let resized = events_within(&mut phone_reader, Duration::from_millis(1500))
            .into_iter()
            .filter(|event| event["event"] == "resized")
            .collect::<Vec<_>>();
        assert!(
            resized.is_empty(),
            "round {round}: a second replay followed the attach replay: {resized:?}"
        );
        // The phone leaves (a dropped link): the grid returns to the Mac's.
        drop(phone_writer);
        drop(phone_reader);
        wait_for_vt_size(&harness.socket, surface, 120, 39);
    }

    close_terminal_surface(&harness.socket, surface, 50);
    wait_for_no_host_records(&harness.host_root());
}

/// A phone or tablet view whose connection drops keeps the grid from growing
/// for a grace period (a Mac or TUI view that leaves does not). A phone that reattaches inside it finds the grid it left, so the
/// PTY is never resized: an inline TUI such as Codex sees no width change, and
/// does not rebuild (and truncate) its scrollback twice per drop (cnx-ios
/// termqa V2-5). After the grace the grid follows the remaining views.
#[test]
fn dropped_view_holds_the_grid_until_a_reattach_or_the_grace_ends() {
    let mut harness = RecoveryHarness::start_unstarted("sized-attach-drop-hold");
    harness.extra_env.push(("CMUX_TUI_TEST_DEPARTED_GRID_HOLD_MS".into(), "4000".into()));
    harness.restart();
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "exec /bin/cat"],
            "new_workspace": true,
            "name": "drop-hold",
            "cols": 120,
            "rows": 39,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    fit_everyone(&harness.socket, surface);
    let (_mac_writer, _mac_reader, _) = attach_sized(&harness.socket, surface, 120, 39, 2);
    let (phone_writer, phone_reader, _) = attach_sized(&harness.socket, surface, 53, 42, 3);
    wait_for_vt_size(&harness.socket, surface, 53, 39);

    // The link drops: the grid stays.
    drop(phone_writer);
    drop(phone_reader);
    let started = Instant::now();
    while started.elapsed() < Duration::from_millis(1500) {
        let state =
            request(&harness.socket, serde_json::json!({"cmd": "vt-state", "surface": surface}));
        assert_eq!(
            (state["cols"].as_u64(), state["rows"].as_u64()),
            (Some(53), Some(39)),
            "the grid grew {:?} after a dropped view",
            started.elapsed()
        );
        std::thread::sleep(Duration::from_millis(100));
    }

    // The phone reattaches inside the grace: one replay at the same grid.
    let (phone_writer, mut phone_reader, phone_state) =
        attach_sized(&harness.socket, surface, 53, 42, 4);
    assert_eq!((phone_state["cols"].as_u64(), phone_state["rows"].as_u64()), (Some(53), Some(39)));
    let resized = events_within(&mut phone_reader, Duration::from_millis(1000))
        .into_iter()
        .filter(|event| event["event"] == "resized")
        .count();
    assert_eq!(resized, 0, "the reattach resized the terminal");

    // It leaves for longer than the grace: the grid follows the Mac.
    drop(phone_writer);
    drop(phone_reader);
    wait_for_vt_size(&harness.socket, surface, 120, 39);

    close_terminal_surface(&harness.socket, surface, 50);
    wait_for_no_host_records(&harness.host_root());
}

/// A phone that comes back at a larger size (rotated to landscape, a tablet
/// in a wider split) gets its own size at once: the hold its departure set is
/// for the grid it left, and capping the new view to it would resize the PTY a
/// second time when the hold ends (PR #20809 review, finding 1).
#[test]
fn a_phone_back_at_a_larger_size_ends_the_hold() {
    let mut harness = RecoveryHarness::start_unstarted("sized-attach-hold-return-wider");
    harness.extra_env.push(("CMUX_TUI_TEST_DEPARTED_GRID_HOLD_MS".into(), "20000".into()));
    harness.restart();
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "exec /bin/cat"],
            "new_workspace": true,
            "name": "hold-return-wider",
            "cols": 120,
            "rows": 39,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    fit_everyone(&harness.socket, surface);
    let (_mac_writer, _mac_reader, _) = attach_sized(&harness.socket, surface, 120, 39, 2);
    let (phone_writer, phone_reader, _) = attach_sized(&harness.socket, surface, 53, 42, 3);
    wait_for_vt_size(&harness.socket, surface, 53, 39);
    drop(phone_writer);
    drop(phone_reader);

    // Back in landscape, well inside the hold: 90 columns, not the 53 it left.
    let (_phone_writer, _phone_reader, phone_state) =
        attach_sized(&harness.socket, surface, 90, 30, 4);
    assert_eq!(
        (phone_state["cols"].as_u64(), phone_state["rows"].as_u64()),
        (Some(90), Some(30)),
        "the hold of the departed view capped the returning one"
    );

    close_terminal_surface(&harness.socket, surface, 50);
    wait_for_no_host_records(&harness.host_root());
}
