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

/// A phone view that opted into `size-lease-v1`: like `attach_sized`, with
/// the capability in its client info.
fn attach_leased_phone(
    path: &Path,
    surface: u64,
    cols: u16,
    rows: u16,
    request_id: u64,
) -> (Box<dyn transport::Stream>, BufReader<Box<dyn transport::Stream>>) {
    let stream = transport::connect(path).unwrap();
    stream.set_read_timeout(Some(test_timeout(Duration::from_secs(10)))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    stream_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": request_id + 1000, "cmd": "set-client-info", "name": "phone",
            "kind": "ios", "device_kind": "iphone", "capabilities": ["size-lease-v1"],
        }),
    );
    stream_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": request_id, "cmd": "attach-surface", "surface": surface,
            "cols": cols, "rows": rows,
        }),
    );
    (writer, reader)
}

fn lease_harness(name: &str, lease_ms: &str) -> (RecoveryHarness, u64) {
    lease_harness_with_hold(name, lease_ms, "60000")
}

fn lease_harness_with_hold(name: &str, lease_ms: &str, hold_ms: &str) -> (RecoveryHarness, u64) {
    let mut harness = RecoveryHarness::start_unstarted(name);
    harness.extra_env.push(("CMUX_TUI_TEST_SIZE_LEASE_MS".into(), lease_ms.into()));
    // The grid hold is long, so a test that passes is not the hold ending.
    harness.extra_env.push(("CMUX_TUI_TEST_DEPARTED_GRID_HOLD_MS".into(), hold_ms.into()));
    harness.restart();
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1, "cmd": "run", "argv": ["/bin/sh", "-c", "exec /bin/cat"],
            "new_workspace": true, "name": name, "cols": 120, "rows": 39,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    fit_everyone(&harness.socket, surface);
    (harness, surface)
}

/// The daemon advertises the size lease.
#[test]
fn the_daemon_advertises_the_size_lease() {
    let (harness, surface) = lease_harness("size-lease-identify", "60000");
    let identify = request(&harness.socket, serde_json::json!({"cmd": "identify"}));
    let capabilities = identify["capabilities"].as_array().cloned().unwrap_or_default();
    assert!(
        capabilities.iter().any(|capability| capability == "size-lease-v1"),
        "identify lists no size-lease-v1: {identify}"
    );
    close_terminal_surface(&harness.socket, surface, 50);
    wait_for_no_host_records(&harness.host_root());
}

/// A phone that opted into the size lease and stops refreshing its size (a
/// suspended app whose link has not timed out yet, a bug that never clears
/// the size) loses its claim when the lease ends: the grid returns to the
/// Mac's at once (no departed-view hold: the phone is still attached), and
/// its next refresh claims the size again.
#[test]
fn a_phone_size_claim_ends_when_its_lease_is_not_refreshed() {
    let (harness, surface) = lease_harness("size-lease-expiry", "1500");
    let (_mac_writer, _mac_reader, _) = attach_sized(&harness.socket, surface, 120, 39, 2);
    let (mut phone_writer, mut phone_reader) =
        attach_leased_phone(&harness.socket, surface, 53, 42, 3);
    wait_for_vt_size(&harness.socket, surface, 53, 39);
    let claimed = Instant::now();

    // No refresh: the lease ends and the Mac gets its own grid back.
    wait_for_vt_size(&harness.socket, surface, 120, 39);
    assert!(
        claimed.elapsed() >= Duration::from_millis(1000),
        "the claim ended {:?} after it was made, before its lease",
        claimed.elapsed()
    );

    // The phone is back on screen: its next refresh claims the size again.
    stream_request(
        &mut phone_writer,
        &mut phone_reader,
        serde_json::json!({"id": 10, "cmd": "resize-surface", "surface": surface, "cols": 53, "rows": 42}),
    );
    wait_for_vt_size(&harness.socket, surface, 53, 39);

    close_terminal_surface(&harness.socket, surface, 50);
    wait_for_no_host_records(&harness.host_root());
}

/// A phone that refreshes its size inside the lease keeps it, and a refresh
/// at the same size never resizes the terminal (no `resized` replay, so an
/// inline TUI never redraws for a heartbeat).
#[test]
fn a_refreshed_size_lease_keeps_the_claim_without_resizing() {
    let (harness, surface) = lease_harness("size-lease-refresh", "1500");
    let (_mac_writer, _mac_reader, _) = attach_sized(&harness.socket, surface, 120, 39, 2);
    let (mut phone_writer, mut phone_reader) =
        attach_leased_phone(&harness.socket, surface, 53, 42, 3);
    wait_for_vt_size(&harness.socket, surface, 53, 39);

    let started = Instant::now();
    let mut id = 20;
    while started.elapsed() < Duration::from_millis(4000) {
        id += 1;
        stream_request(
            &mut phone_writer,
            &mut phone_reader,
            serde_json::json!({"id": id, "cmd": "resize-surface", "surface": surface, "cols": 53, "rows": 42}),
        );
        let resized = events_within(&mut phone_reader, Duration::from_millis(500))
            .into_iter()
            .filter(|event| event["event"] == "resized")
            .collect::<Vec<_>>();
        assert!(resized.is_empty(), "a same-size refresh resized the terminal: {resized:?}");
        let state =
            request(&harness.socket, serde_json::json!({"cmd": "vt-state", "surface": surface}));
        assert_eq!(
            (state["cols"].as_u64(), state["rows"].as_u64()),
            (Some(53), Some(39)),
            "a refreshed claim ended {:?} in",
            started.elapsed()
        );
    }

    close_terminal_surface(&harness.socket, surface, 50);
    wait_for_no_host_records(&harness.host_root());
}

/// A phone that releases its size on purpose (it left the terminal, went to
/// the background) gives the Mac its grid back at once, and its connection
/// closing after that sets no departed-view hold.
#[test]
fn a_released_phone_size_returns_the_grid_at_once_and_its_drop_holds_nothing() {
    let (harness, surface) = lease_harness("size-release-then-drop", "60000");
    let (_mac_writer, _mac_reader, _) = attach_sized(&harness.socket, surface, 120, 39, 2);
    let (mut phone_writer, mut phone_reader) =
        attach_leased_phone(&harness.socket, surface, 53, 42, 3);
    wait_for_vt_size(&harness.socket, surface, 53, 39);

    let released = Instant::now();
    let release = stream_request(
        &mut phone_writer,
        &mut phone_reader,
        serde_json::json!({"id": 30, "cmd": "release-surface-size", "surface": surface}),
    );
    assert_eq!(release["outcome"], "applied", "release-surface-size: {release}");
    wait_for_vt_size(&harness.socket, surface, 120, 39);
    assert!(
        released.elapsed() < Duration::from_secs(2),
        "the release took {:?}",
        released.elapsed()
    );

    // Claimed again, released again, then the channel closes: no hold.
    let reclaim = stream_request(
        &mut phone_writer,
        &mut phone_reader,
        serde_json::json!({"id": 31, "cmd": "resize-surface", "surface": surface, "cols": 53, "rows": 42}),
    );
    assert_eq!(reclaim["outcome"], "applied", "resize-surface: {reclaim}");
    wait_for_vt_size(&harness.socket, surface, 53, 39);
    // The release is answered before the connection closes (a phone, and
    // cmux-mobile-host for a phone's closed channel, wait for the answer):
    // an end of file read before the release is a dropped view and holds.
    stream_request(
        &mut phone_writer,
        &mut phone_reader,
        serde_json::json!({"id": 32, "cmd": "release-surface-size", "surface": surface}),
    );
    drop(phone_writer);
    drop(phone_reader);
    wait_for_vt_size(&harness.socket, surface, 120, 39);

    close_terminal_surface(&harness.socket, surface, 50);
    wait_for_no_host_records(&harness.host_root());
}

/// A leased phone whose connection drops (a dead link, hostd killed) holds
/// the grid for the departed-view grace at most until its lease would have
/// ended: a phone that can no longer refresh never pins the Mac's grid for
/// longer than its lease.
#[test]
fn a_dropped_leased_phone_holds_the_grid_only_until_its_lease_ends() {
    let (harness, surface) = lease_harness("size-lease-drop", "2000");
    let (_mac_writer, _mac_reader, _) = attach_sized(&harness.socket, surface, 120, 39, 2);
    let (phone_writer, phone_reader) = attach_leased_phone(&harness.socket, surface, 53, 42, 3);
    wait_for_vt_size(&harness.socket, surface, 53, 39);
    let claimed = Instant::now();
    drop(phone_writer);
    drop(phone_reader);

    // The hold (60 s here) keeps the grid at first ...
    std::thread::sleep(Duration::from_millis(500));
    let state =
        request(&harness.socket, serde_json::json!({"cmd": "vt-state", "surface": surface}));
    assert_eq!((state["cols"].as_u64(), state["rows"].as_u64()), (Some(53), Some(39)));
    // ... and ends with the lease, not after 60 s.
    wait_for_vt_size(&harness.socket, surface, 120, 39);
    assert!(
        claimed.elapsed() >= Duration::from_millis(1500),
        "the grid grew {:?} after the claim, before its lease ended",
        claimed.elapsed()
    );

    close_terminal_surface(&harness.socket, surface, 50);
    wait_for_no_host_records(&harness.host_root());
}

/// An earlier connection's lease ending never ends the hold a later
/// connection's drop set (a phone that reattached and dropped again): that
/// hold runs to its own lease (PR #24226 review, finding 3).
#[test]
fn an_earlier_connections_lease_never_ends_a_later_drops_hold() {
    let (harness, surface) = lease_harness_with_hold("size-lease-two-drops", "2000", "6000");
    let (_mac_writer, _mac_reader, _) = attach_sized(&harness.socket, surface, 120, 39, 2);
    let (first_writer, first_reader) = attach_leased_phone(&harness.socket, surface, 53, 42, 3);
    wait_for_vt_size(&harness.socket, surface, 53, 39);
    let start = Instant::now();
    drop(first_writer);
    drop(first_reader);
    std::thread::sleep(Duration::from_millis(1200));
    // The phone is back on a new connection, then drops again.
    let (second_writer, second_reader) = attach_leased_phone(&harness.socket, surface, 53, 42, 4);
    let second_claim = Instant::now();
    drop(second_writer);
    drop(second_reader);
    // The first lease ends (~2 s after start); the second drop's hold stays.
    while second_claim.elapsed() < Duration::from_millis(1600) {
        let state =
            request(&harness.socket, serde_json::json!({"cmd": "vt-state", "surface": surface}));
        assert_eq!(
            (state["cols"].as_u64(), state["rows"].as_u64()),
            (Some(53), Some(39)),
            "the grid grew {:?} after the first drop: the first lease ended the second drop's hold",
            start.elapsed()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    // The second lease ends: its hold ends with it.
    wait_for_vt_size(&harness.socket, surface, 120, 39);

    close_terminal_surface(&harness.socket, surface, 50);
    wait_for_no_host_records(&harness.host_root());
}

/// A phone view that cannot show a grid larger than its own (every phone
/// build so far: it renders the PTY's output into its own grid, so a wider
/// PTY overprints and cuts its rows): like `attach_sized`, with the given
/// client capabilities.
fn attach_phone_with_capabilities(
    path: &Path,
    surface: u64,
    cols: u16,
    rows: u16,
    request_id: u64,
    capabilities: &[&str],
) -> (Box<dyn transport::Stream>, BufReader<Box<dyn transport::Stream>>) {
    let stream = transport::connect(path).unwrap();
    stream.set_read_timeout(Some(test_timeout(Duration::from_secs(10)))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    stream_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": request_id + 1000, "cmd": "set-client-info", "name": "phone",
            "kind": "ios", "device_kind": "iphone", "capabilities": capabilities,
        }),
    );
    stream_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id": request_id, "cmd": "attach-surface", "surface": surface,
            "cols": cols, "rows": rows,
        }),
    );
    (writer, reader)
}

/// The PTY grid stays `want` for `window` (sampled).
fn assert_grid_stays(path: &Path, surface: u64, want: (u16, u16), window: Duration, what: &str) {
    let started = Instant::now();
    while started.elapsed() < window {
        let state = request(path, serde_json::json!({"cmd": "vt-state", "surface": surface}));
        assert_eq!(
            (state["cols"].as_u64(), state["rows"].as_u64()),
            (Some(u64::from(want.0)), Some(u64::from(want.1))),
            "{what}: the grid left {want:?} after {:?}",
            started.elapsed()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Under the default policy (last active) a Mac that was active last keeps
/// the grid when a phone attaches. A phone that cannot show a larger grid
/// (it does not list `host-grid-view-v1`, as no phone build does yet) then
/// rendered the Mac's wider output into its own grid: a Claude Code session
/// on the user's TestFlight phone overprinted and cut every row
/// (2026-10-23). The PTY grid now never exceeds such a phone's own size
/// while it is attached with one, whoever is active, and follows the Mac
/// again once the phone leaves.
#[test]
fn a_phone_that_cannot_show_a_larger_grid_caps_it_under_last_active() {
    let mut harness = RecoveryHarness::start_unstarted("sized-attach-phone-cap");
    harness.extra_env.push(("CMUX_TUI_TEST_DEPARTED_GRID_HOLD_MS".into(), "300".into()));
    harness.restart();
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1, "cmd": "run", "argv": ["/bin/sh", "-c", "exec /bin/cat"],
            "new_workspace": true, "name": "phone-cap", "cols": 120, "rows": 39,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    // The default policy: no `set-size-policy`.
    let (mut mac_writer, mut mac_reader, _) = attach_sized(&harness.socket, surface, 120, 39, 2);
    wait_for_vt_size(&harness.socket, surface, 120, 39);

    // The old phone attaches (its attach is not activity): the grid fits it.
    let (phone_writer, phone_reader) =
        attach_phone_with_capabilities(&harness.socket, surface, 53, 42, 3, &[]);
    wait_for_vt_size(&harness.socket, surface, 53, 39);

    // The Mac types (activity): it is last active, and the phone still sees
    // a grid no wider than its own.
    stream_request(
        &mut mac_writer,
        &mut mac_reader,
        serde_json::json!({"id": 4, "cmd": "send", "surface": surface, "text": "x"}),
    );
    assert_grid_stays(
        &harness.socket,
        surface,
        (53, 39),
        Duration::from_millis(1200),
        "the Mac's input widened the grid past the phone",
    );

    // The phone releases its size (its terminal left the screen): the grid
    // is the Mac's at once; its next report caps it again.
    let (mut phone_writer, mut phone_reader) = (phone_writer, phone_reader);
    stream_request(
        &mut phone_writer,
        &mut phone_reader,
        serde_json::json!({"id": 5, "cmd": "release-surface-size", "surface": surface}),
    );
    wait_for_vt_size(&harness.socket, surface, 120, 39);
    stream_request(
        &mut phone_writer,
        &mut phone_reader,
        serde_json::json!({"id": 6, "cmd": "resize-surface", "surface": surface, "cols": 53, "rows": 42}),
    );
    wait_for_vt_size(&harness.socket, surface, 53, 39);

    // The phone leaves: the grid is the Mac's again.
    drop(phone_writer);
    drop(phone_reader);
    wait_for_vt_size(&harness.socket, surface, 120, 39);

    close_terminal_surface(&harness.socket, surface, 50);
    wait_for_no_host_records(&harness.host_root());
}

/// A phone that lists `host-grid-view-v1` shows a larger grid itself
/// (letterbox or pan): it is not capped, and under last active the Mac that
/// was active keeps its grid when the phone only attaches.
#[test]
fn a_phone_that_shows_a_larger_grid_does_not_cap_it() {
    let mut harness = RecoveryHarness::start_unstarted("sized-attach-phone-host-grid");
    harness.restart();
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1, "cmd": "run", "argv": ["/bin/sh", "-c", "exec /bin/cat"],
            "new_workspace": true, "name": "phone-host-grid", "cols": 120, "rows": 39,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    // A Mac-wins policy: a cmux-next daemon that reads the settings file
    // defaults to `smallest` (host-size-policy-v1), where a phone narrows the
    // grid by design. Pin `latest` (a phone's attach is not activity) so the
    // test checks only that a phone listing host-grid-view-v1 is not capped.
    request(
        &harness.socket,
        serde_json::json!({"cmd": "set-size-policy", "surface": surface, "policy": {"mode": "latest"}}),
    );
    let identify = request(&harness.socket, serde_json::json!({"cmd": "identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .is_some_and(|list| list.iter().any(|capability| capability == "host-grid-view-v1")),
        "identify lists no host-grid-view-v1: {identify}"
    );
    let (_mac_writer, _mac_reader, _) = attach_sized(&harness.socket, surface, 120, 39, 2);
    wait_for_vt_size(&harness.socket, surface, 120, 39);
    let (_phone_writer, _phone_reader) =
        attach_phone_with_capabilities(&harness.socket, surface, 53, 42, 3, &["host-grid-view-v1"]);
    assert_grid_stays(
        &harness.socket,
        surface,
        (120, 39),
        Duration::from_millis(1200),
        "a phone that shows larger grids took the grid by attaching",
    );

    close_terminal_surface(&harness.socket, surface, 50);
    wait_for_no_host_records(&harness.host_root());
}
