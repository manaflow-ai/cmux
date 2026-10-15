//! A sized attach of a hosted terminal whose grid it changes (a phone joining
//! a Mac window under the default smallest-viewer policy) used to return
//! before the host applied the resize: the attach replay was built at the old
//! grid, and the host's resize then reached the new view as a second
//! `resized` replay right after it (cnx-ios termqa D4: two full replays on
//! every reattach). The attach now waits for the host's resize, so the
//! view's first replay is already at the effective grid and is the only one.

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
    let harness = RecoveryHarness::start("sized-attach-one-replay");
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
