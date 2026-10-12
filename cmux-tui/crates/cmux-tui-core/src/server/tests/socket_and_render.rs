//! Socket paths, the start lock, JSON line limits, and render attach messages, deltas and the shared graphics cache.

use super::*;

#[test]
fn json_line_limit_excludes_the_newline_delimiter() {
    let exact_payload = "x".repeat(MAX_JSON_LINE_BYTES);
    assert_eq!(json_line_payload_len(&exact_payload), MAX_JSON_LINE_BYTES);

    let mut exact_line = exact_payload;
    exact_line.push('\n');
    assert_eq!(json_line_payload_len(&exact_line), MAX_JSON_LINE_BYTES);

    let oversized_payload = "x".repeat(MAX_JSON_LINE_BYTES + 1);
    assert!(json_line_payload_len(&oversized_payload) > MAX_JSON_LINE_BYTES);

    let mut oversized_line = oversized_payload;
    oversized_line.push('\n');
    assert!(json_line_payload_len(&oversized_line) > MAX_JSON_LINE_BYTES);
}

#[test]
fn default_socket_path_preserves_compatible_runtime_dir() {
    let runtime_dir = PathBuf::from("/tmp/cmux-tui-compat");
    assert_eq!(
        default_socket_path_in_runtime_dir("main", runtime_dir.clone()),
        runtime_dir.join("main.sock")
    );
}

#[cfg(unix)]
#[test]
fn socket_start_lock_rejects_a_symlinked_lock_path() {
    use std::os::unix::fs::symlink;

    let dir = TestSocketDir::create("start-lock-symlink");
    let socket = dir.path().join("mux.sock");
    let lock = dir.path().join("mux.sock.spawn-lock");
    let target = dir.path().join("target");
    std::fs::write(&target, b"not the lock").unwrap();
    symlink(&target, &lock).unwrap();

    let error = match SocketStartLock::acquire(&socket, Instant::now()) {
        Ok(_) => panic!("symlinked start lock must be rejected"),
        Err(error) => error,
    };
    assert_eq!(error.raw_os_error(), Some(libc::ELOOP));
}

#[test]
fn socket_start_lock_retry_delay_never_exceeds_remaining_deadline() {
    let now = Instant::now();
    let short_deadline = now + Duration::from_millis(10);
    let delay = socket_start_lock_retry_delay(now, short_deadline)
        .expect("a future deadline should permit a retry");
    assert_eq!(delay, Duration::from_millis(10));
    assert!(delay <= short_deadline.duration_since(now));

    let long_deadline = now + Duration::from_secs(1);
    assert_eq!(socket_start_lock_retry_delay(now, long_deadline), Some(Duration::from_millis(25)));
    assert_eq!(socket_start_lock_retry_delay(short_deadline, short_deadline), None);
    assert_eq!(
        socket_start_lock_retry_delay(short_deadline + Duration::from_millis(1), short_deadline),
        None
    );
}

#[test]
fn socket_start_lock_acquires_a_new_lock_file() {
    let dir = TestSocketDir::create("start-lock-new-file");
    let socket = dir.path().join("mux.sock");
    let lock = dir.path().join("mux.sock.spawn-lock");

    let _guard = SocketStartLock::acquire(&socket, Instant::now()).unwrap();

    assert!(lock.is_file());
}

#[cfg(unix)]
#[test]
fn socket_start_lock_rejects_a_fifo_without_blocking() {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::OpenOptionsExt;

    let dir = TestSocketDir::create("start-lock-fifo");
    let socket = dir.path().join("mux.sock");
    let lock = dir.path().join("mux.sock.spawn-lock");
    let lock_path = CString::new(lock.as_os_str().as_bytes()).unwrap();
    let result = unsafe { libc::mkfifo(lock_path.as_ptr(), 0o600) };
    assert_eq!(result, 0, "mkfifo failed: {}", std::io::Error::last_os_error());

    let (sender, receiver) = std::sync::mpsc::channel();
    let acquire_socket = socket;
    let acquire = std::thread::spawn(move || {
        sender.send(SocketStartLock::acquire(&acquire_socket, Instant::now())).unwrap();
    });

    let outcome = receiver.recv_timeout(Duration::from_secs(1));
    if outcome.is_err() {
        // Release a writer that used blocking open in an unfixed build so
        // this regression test fails promptly instead of leaking a thread.
        let reader = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(&lock)
            .unwrap();
        let _ = receiver.recv_timeout(Duration::from_secs(1));
        drop(reader);
        acquire.join().unwrap();
        panic!("opening a start-lock FIFO blocked before type validation");
    }
    acquire.join().unwrap();
    let error = match outcome.unwrap() {
        Ok(_) => panic!("FIFO start lock must be rejected"),
        Err(error) => error,
    };
    assert_eq!(error.raw_os_error(), Some(libc::ENXIO));
}

#[cfg(unix)]
#[test]
fn socket_start_lock_migrates_existing_lock_to_owner_only_mode() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let dir = TestSocketDir::create("start-lock-mode");
    let socket = dir.path().join("mux.sock");
    let lock = dir.path().join("mux.sock.spawn-lock");
    std::fs::write(&lock, b"").unwrap();
    std::fs::set_permissions(&lock, std::fs::Permissions::from_mode(0o644)).unwrap();

    let _guard = SocketStartLock::acquire(&socket, Instant::now()).unwrap();
    let metadata = std::fs::metadata(&lock).unwrap();
    assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
    assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
}

#[cfg(unix)]
#[test]
fn socket_start_lock_rejects_a_hard_linked_lock_without_chmod() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let dir = TestSocketDir::create("start-lock-hard-link");
    let socket = dir.path().join("mux.sock");
    let lock = dir.path().join("mux.sock.spawn-lock");
    let alias = dir.path().join("lock-alias");
    std::fs::write(&lock, b"").unwrap();
    std::fs::set_permissions(&lock, std::fs::Permissions::from_mode(0o644)).unwrap();
    std::fs::hard_link(&lock, &alias).unwrap();

    let error = match SocketStartLock::acquire(&socket, Instant::now()) {
        Ok(_) => panic!("hard-linked start lock must be rejected"),
        Err(error) => error,
    };
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    let metadata = std::fs::metadata(&lock).unwrap();
    assert_eq!(metadata.nlink(), 2);
    assert_eq!(metadata.permissions().mode() & 0o777, 0o644);
}

#[test]
fn session_name_validation_rejects_path_escape_input() {
    for session in ["", ".", "..", "../escape", "nested/session", "nested\\session"] {
        assert!(validate_session_name(session).is_err(), "accepted {session:?}");
    }
    assert!(validate_session_name("main").is_ok());
    assert!(validate_session_name("legacy name").is_ok());
    assert_ne!(default_socket_path("../escape"), default_socket_path("main"));
}

#[test]
fn journal_filter_rejects_secret_max_sensitivity() {
    let error = JournalStreamFilter::parse(Some(&json!({
        "max_sensitivity":"secret",
    })))
    .err()
    .expect("secret journal sensitivity must be rejected");
    assert_eq!(error.code, "validation.invalid");
    assert_eq!(error.details["field"], "filter.max_sensitivity");
}

#[test]
fn indeterminate_journal_commit_remains_retryable() {
    let error = journal_extension_error(
        "session.journal.append",
        anyhow::Error::new(crate::journal_ingress::JournalCommitIndeterminate::after(
            Duration::from_secs(3),
        )),
    );

    assert_eq!(error.code, "transport.closed");
    assert!(error.retryable);
    assert!(error.message.contains("indeterminate"));
}

#[test]
fn journal_filter_requires_an_explicit_sensitive_opt_in() {
    assert_eq!(
        JournalStreamFilter::parse(None).unwrap().max_sensitivity,
        Some(JournalSensitivity::Metadata)
    );
    assert_eq!(
        JournalStreamFilter::parse(Some(&json!({}))).unwrap().max_sensitivity,
        Some(JournalSensitivity::Metadata)
    );
    assert_eq!(
        JournalStreamFilter::parse(Some(&json!({"max_sensitivity":"sensitive"})))
            .unwrap()
            .max_sensitivity,
        Some(JournalSensitivity::Sensitive)
    );
}

#[cfg(unix)]
#[test]
fn default_socket_path_falls_back_for_long_tmpdir() {
    let long_tmpdir = PathBuf::from("/tmp").join("x".repeat(200));
    let preferred_runtime_dir = long_tmpdir.join("cmux-tui-test-user");
    let path =
        default_socket_path_in_runtime_dir("cmux-browser-0123456789abcdef", preferred_runtime_dir);

    assert_eq!(path, platform::fallback_runtime_dir().join("cmux-browser-0123456789abcdef.sock"));
    assert!(unix_socket_path_fits(&path));
    assert_ne!(path.parent(), Some(Path::new("/tmp")));
}

#[cfg(unix)]
#[test]
fn default_socket_path_hash_prefers_runtime_base_and_falls_back_to_tmp() {
    let session = format!("legacy-{}", "x".repeat(200));
    let preferred_runtime = PathBuf::from("/run/user/501/cmux-tui-501");
    let preferred = default_socket_path_in_runtime_dir(&session, preferred_runtime);
    assert_eq!(
        preferred,
        platform::hashed_runtime_dir_for_base(Path::new("/run/user/501"))
            .join("e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2.sock",)
    );
    assert!(unix_socket_path_fits(&preferred));

    let long_base = PathBuf::from("/tmp").join("x".repeat(200));
    let fallback =
        default_socket_path_in_runtime_dir(&session, long_base.join("cmux-tui-test-user"));
    assert!(fallback.starts_with(platform::fallback_hashed_runtime_dir()));
    assert!(unix_socket_path_fits(&fallback));
}

#[cfg(unix)]
#[test]
fn runtime_socket_directory_rejects_symlinks_and_non_directories() {
    use std::os::unix::fs::symlink;

    let root = TestSocketDir::create("runtime-directory-security");
    let target = root.path().join("target");
    std::fs::create_dir(&target).unwrap();
    let alias = root.path().join("alias");
    symlink(&target, &alias).unwrap();
    assert!(prepare_runtime_socket_directory(&alias).is_err());

    let file = root.path().join("file");
    std::fs::write(&file, b"not a directory").unwrap();
    assert!(prepare_runtime_socket_directory(&file).is_err());
}

#[cfg(unix)]
#[test]
fn runtime_socket_directory_tightens_existing_owned_directory() {
    use std::os::unix::fs::PermissionsExt;

    let root = TestSocketDir::create("runtime-directory-mode");
    let directory = root.path().join("runtime");
    std::fs::create_dir(&directory).unwrap();
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
    prepare_runtime_socket_directory(&directory).unwrap();
    assert_eq!(std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777, 0o700);
}

#[cfg(unix)]
#[test]
fn private_socket_connect_requires_a_private_derived_parent() {
    use std::os::unix::fs::{PermissionsExt, symlink};

    let root = TestSocketDir::create("private-socket");
    let runtime = root.path().join("rt");
    std::fs::create_dir(&runtime).unwrap();
    let socket = runtime.join("m.sock");
    let _listener = transport::listen(&socket).unwrap();

    std::fs::set_permissions(&runtime, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(connect_session_socket(&socket, false).is_ok(), "explicit paths are unchanged");
    let error = connect_session_socket(&socket, true)
        .err()
        .expect("a derived socket in a shared directory must be refused");
    assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);

    std::fs::set_permissions(&runtime, std::fs::Permissions::from_mode(0o700)).unwrap();
    assert!(connect_session_socket(&socket, true).is_ok());

    let alias = root.path().join("al");
    symlink(&runtime, &alias).unwrap();
    let error = connect_session_socket(&alias.join("m.sock"), true)
        .err()
        .expect("a derived socket behind a symlinked directory must be refused");
    assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);

    let missing = root.path().join("missing").join("m.sock");
    let error = connect_session_socket(&missing, true).err().expect("nothing listens there");
    assert_eq!(error.kind(), std::io::ErrorKind::NotFound);
}

#[cfg(unix)]
#[test]
fn serve_paused_preserves_explicit_socket_parent_permissions() {
    use std::os::unix::fs::PermissionsExt;

    let root = TestSocketDir::create("explicit-runtime-directory");
    let directory = root.path().join("socket-parent");
    std::fs::create_dir(&directory).unwrap();
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o755)).unwrap();
    let pending = serve_paused(test_mux(), Some(directory.join("mux.sock"))).unwrap();
    drop(pending);
    assert_eq!(std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777, 0o755);
}

/// A configured socket path longer than sun_path is refused with the
/// path and the limit, never a bare bind error.
#[cfg(unix)]
#[test]
fn serve_paused_names_a_socket_path_longer_than_sun_path() {
    let root = TestSocketDir::create("long");
    let directory = root.path().join("d".repeat(cmux_unix_socket::MAX_PATH_BYTES));
    let socket = directory.join("mux.sock");
    let Err(error) = serve_paused(test_mux(), Some(socket.clone())) else {
        panic!("a socket path longer than sun_path must be refused");
    };
    let message = format!("{error:#}");
    assert!(message.contains(&socket.display().to_string()), "{message}");
    assert!(message.contains("Unix socket limit"), "{message}");
    assert!(!directory.exists(), "nothing is created for a refused path");
}

#[test]
fn serve_paused_creates_missing_explicit_socket_parent() {
    let root = TestSocketDir::create("explicit-runtime-directory-missing");
    let directory = root.path().join("missing").join("nested");
    let socket = directory.join("mux.sock");
    let pending = serve_paused(test_mux(), Some(socket.clone())).unwrap();
    drop(pending);
    assert!(directory.is_dir());
    assert!(!socket.exists());
}

/// Stale-socket recovery (probe, unlink, bind) is not atomic, so
/// unserialized concurrent starts could both classify the socket as
/// stale and the second unlink would strand the first starter on an
/// unreachable socket. The start lock makes exactly one starter win
/// while the winner stays reachable.
#[test]
fn serve_paused_serializes_concurrent_starts_over_a_stale_socket() {
    // Short names keep the socket under the unix path-length cap even in
    // deep macOS temp directories, unlike this module's sibling tests.
    let root = TestSocketDir::create("race");
    let socket = root.path().join("m.sock");
    std::fs::write(&socket, b"stale").unwrap();
    let results: Vec<_> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..2)
            .map(|_| {
                let socket = socket.clone();
                scope.spawn(move || serve_paused(test_mux(), Some(socket)))
            })
            .collect();
        handles.into_iter().map(|handle| handle.join().unwrap()).collect()
    });
    let winners = results.iter().filter(|result| result.is_ok()).count();
    assert_eq!(winners, 1, "exactly one concurrent starter may bind a stale socket");
    assert!(transport::connect(&socket).is_ok(), "the winner must stay reachable");
    drop(results);
}

#[cfg(unix)]
#[test]
fn unix_socket_path_reserves_trailing_nul() {
    const SUN_PATH_CAPACITY: usize = cmux_unix_socket::SUN_PATH_CAPACITY;
    assert!(unix_socket_path_fits(Path::new(&"x".repeat(SUN_PATH_CAPACITY - 1))));
    assert!(!unix_socket_path_fits(Path::new(&"x".repeat(SUN_PATH_CAPACITY))));
}

#[test]
fn large_rgba_render_state_serializes_and_queues_within_websocket_budget() {
    assert_eq!(LARGE_RENDER_IMAGE_RAW_BYTES, 3_145_728);
    assert_eq!(LARGE_RENDER_IMAGE_BASE64_CHARS, 4_194_304);

    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(&large_rgba_kitty_transmission());
    let mut render_state = RenderState::new().unwrap();
    let frame = render_protocol_frame(&mut terminal, &mut render_state);
    let value = render_state_message(&RenderService::new(), 7, &frame);
    let serialized = serde_json::to_string(&value).unwrap();

    assert_eq!(
        value.graphics.images.as_ref().unwrap()[0].data.len(),
        LARGE_RENDER_IMAGE_BASE64_CHARS
    );
    assert!(
        serialized.len() > 4 * 1024 * 1024,
        "JSON overhead must put the payload beyond the old 4 MiB boundary"
    );
    assert!(
        serialized.len() <= OUTBOUND_BYTE_CAPACITY,
        "{}-byte render state exceeds the configured {}-byte outbound boundary",
        serialized.len(),
        OUTBOUND_BYTE_CAPACITY
    );

    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let stream = writer.start_stream(&attach_overflow_json(7)).unwrap();
    writer.send_initial(&value, &stream).unwrap();
    assert_eq!(outbound.try_pop().unwrap(), serialized);
    assert!(writer.is_open());
    assert!(stream.is_open());
    eprintln!("1024x768 RGBA render-state bytes: {}", serialized.len());
}

#[test]
fn render_image_base64_cache_shares_encodes_and_evicts_within_its_byte_cap() {
    let first_pixels: Arc<[u8]> = Arc::from([1_u8, 2, 3, 4, 5, 6]);
    let second_pixels: Arc<[u8]> = Arc::from([7_u8, 8, 9, 10, 11, 12]);
    let encoded_len = base64::engine::general_purpose::STANDARD.encode(&*first_pixels).len();
    let mut cache = RenderGraphicBase64Cache::new(encoded_len, 2);

    let first = cache.encode(&first_pixels);
    let shared = cache.encode(&first_pixels);
    assert!(Arc::ptr_eq(&first, &shared), "same immutable pixels were encoded twice");
    assert_eq!(cache.entries.len(), 1);
    assert_eq!(cache.retained_bytes, encoded_len);

    let second = cache.encode(&second_pixels);
    assert_eq!(cache.entries.len(), 1);
    assert_eq!(cache.retained_bytes, encoded_len);
    assert!(!Arc::ptr_eq(&first, &second));
    assert!(
        cache.entries.values().all(|entry| {
            entry.source.upgrade().is_some_and(|source| Arc::ptr_eq(&source, &second_pixels))
        }),
        "byte-cap eviction retained the older image"
    );
}

#[test]
fn render_graphics_message_borrows_the_shared_base64_payload() {
    let service = RenderService::new();
    let pixels: Arc<[u8]> = Arc::from([1_u8, 2, 3, 4, 5, 6]);
    let encoded = service.encode_graphic(&pixels);
    let graphics = ghostty_vt::KittyGraphicsSnapshot {
        generation: 1,
        images: vec![ghostty_vt::KittyImage {
            id: 1,
            number: 0,
            generation: 1,
            width: 2,
            height: 1,
            format: ghostty_vt::KittyImageFormat::Rgb,
            data: pixels,
        }],
        placements: Vec::new(),
    };

    let message = render_graphics_message(&service, &graphics, None, &[], true);
    let data = &message.images.as_ref().unwrap()[0].data;

    assert!(
        Arc::ptr_eq(data, &encoded),
        "render message copied the cached base64 payload before serialization"
    );
}

#[test]
fn outbound_memory_budget_is_shared_across_connections() {
    let first_overflow = attach_overflow_json(1);
    let second_overflow = attach_overflow_json(2);
    let message = json!({"event": "render-state", "data": "x".repeat(300)});
    let budget = serde_json::to_vec(&first_overflow).unwrap().len()
        + serde_json::to_vec(&second_overflow).unwrap().len()
        + serde_json::to_vec(&message).unwrap().len();
    let service = Arc::new(RenderService::new_with_outbound_budget(budget));
    let first_outbound = Arc::new(BoundedOutbound::default());
    let second_outbound = Arc::new(BoundedOutbound::default());
    let first = MessageWriter::new_with_render_service(
        QueuedSink { outbound: first_outbound.clone(), control: None },
        service.clone(),
    );
    let second = MessageWriter::new_with_render_service(
        QueuedSink { outbound: second_outbound, control: None },
        service,
    );
    let first_stream = first.start_stream(&first_overflow).unwrap();
    let second_stream = second.start_stream(&second_overflow).unwrap();

    first.send_initial(&message, &first_stream).unwrap();
    let error = second.send_initial(&message, &second_stream).unwrap_err();
    assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);

    drop(first_outbound.try_pop().expect("first queued message"));
    second.send_initial(&message, &second_stream).unwrap();
}

#[test]
fn global_render_pressure_does_not_starve_control_replies() {
    let overflow = attach_overflow_json(1);
    let render = json!({"event": "render-state", "data": "x".repeat(300)});
    let render_bytes = {
        let probe = RenderService::new_with_outbound_budget(usize::MAX);
        probe.serialize(&render).unwrap().retained_bytes
    };
    let service = Arc::new(RenderService::new_with_outbound_budgets(render_bytes, 1_024));
    let render_outbound = Arc::new(BoundedOutbound::default());
    let control_outbound = Arc::new(BoundedOutbound::default());
    let render_writer = MessageWriter::new_with_render_service(
        QueuedSink { outbound: render_outbound, control: None },
        service.clone(),
    );
    let control_writer = MessageWriter::new_with_render_service(
        QueuedSink { outbound: control_outbound.clone(), control: None },
        service,
    );
    let render_stream = render_writer.start_stream(&overflow).unwrap();
    let blocked_stream = control_writer.start_stream(&overflow).unwrap();

    render_writer.send_initial(&render, &render_stream).unwrap();
    assert_eq!(
        control_writer.send_initial(&render, &blocked_stream).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    control_writer.send_control(&json!({"id": 7, "ok": true})).unwrap();

    let reply: Value = serde_json::from_str(&control_outbound.try_pop().unwrap()).unwrap();
    assert_eq!(reply["id"], 7);
    assert!(control_writer.is_open());
}

#[test]
fn render_service_shares_cache_across_connections_and_releases_it_with_its_owner() {
    let service = Arc::new(RenderService::new());
    let weak = Arc::downgrade(&service);
    let first_writer = MessageWriter::new_with_render_service(
        QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None },
        service.clone(),
    );
    let second_writer = MessageWriter::new_with_render_service(
        QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None },
        service.clone(),
    );
    let pixels: Arc<[u8]> = Arc::from([1_u8, 2, 3, 4, 5, 6]);

    let first = first_writer.render_service.encode_graphic(&pixels);
    let second = second_writer.render_service.encode_graphic(&pixels);
    assert!(Arc::ptr_eq(&first, &second));

    drop(service);
    assert!(weak.upgrade().is_some(), "connection writers must retain their server service");
    drop(first_writer);
    drop(second_writer);
    assert!(weak.upgrade().is_none(), "the cache outlived its server and connections");
}

#[test]
fn render_budget_covers_max_image_and_placement_metadata() {
    let placement = ghostty_vt::KittyPlacement {
        key: ghostty_vt::KittyPlacementKey {
            image_id: u32::MAX,
            placement_id: u32::MAX,
            ordinal: u32::MAX,
        },
        image_id: u32::MAX,
        placement_id: u32::MAX,
        is_internal: false,
        x_offset: u32::MAX,
        y_offset: u32::MAX,
        source_x: u32::MAX,
        source_y: u32::MAX,
        source_width: u32::MAX,
        source_height: u32::MAX,
        columns: u32::MAX,
        rows: u32::MAX,
        grid_cols: u32::MAX,
        grid_rows: u32::MAX,
        pixel_width: u32::MAX,
        pixel_height: u32::MAX,
        viewport_col: i32::MIN,
        viewport_row: i32::MIN,
        viewport_visible: false,
        anchor: Some(ghostty_vt::KittyPlacementAnchor { col: u16::MAX, row: u32::MAX }),
        z: i32::MIN,
    };
    let graphics = ghostty_vt::KittyGraphicsSnapshot {
        generation: u64::MAX,
        images: Vec::new(),
        placements: vec![placement],
    };
    let message = render_graphics_message(&RenderService::new(), &graphics, None, &[], true);
    let serialized = serde_json::to_value(&message).unwrap();
    let placement_bytes = serde_json::to_string(&serialized["placements"][0]).unwrap().len();
    let placement_array_bytes = 2
        + placement_bytes * RENDER_GRAPHIC_MAX_PLACEMENTS
        + RENDER_GRAPHIC_MAX_PLACEMENTS.saturating_sub(1);
    let image_base64_bytes = RENDER_GRAPHIC_MAX_DECODED_BYTES.div_ceil(3) * 4;
    let required_without_rows = image_base64_bytes + placement_array_bytes;

    assert_eq!(placement_bytes, 485);
    assert_eq!(placement_array_bytes, 7_962_625);
    assert_eq!(image_base64_bytes, 13_333_336);
    assert_eq!(required_without_rows, 21_295_961);
    assert_eq!(placement_bytes, RENDER_GRAPHIC_MAX_PLACEMENT_JSON_BYTES);
    assert_eq!(placement_array_bytes, RENDER_GRAPHIC_MAX_PLACEMENT_ARRAY_BYTES);
    assert_eq!(image_base64_bytes, RENDER_GRAPHIC_MAX_ENCODED_BYTES);
    assert_eq!(OUTBOUND_BYTE_CAPACITY - required_without_rows, 12_258_471);
    assert!(
        required_without_rows < OUTBOUND_BYTE_CAPACITY,
        "{required_without_rows} image and placement bytes exceed the configured \
         {OUTBOUND_BYTE_CAPACITY}-byte outbound boundary before rows and wrapper metadata"
    );
}

#[test]
fn render_delta_omits_graphics_for_text_only_damage() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(RED_IMAGE_41);
    let mut render_state = RenderState::new().unwrap();
    let mut client = render_protocol_client(&mut terminal, &mut render_state);

    terminal.vt_write(b"text");
    let frame = render_protocol_frame(&mut terminal, &mut render_state);
    let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();

    assert!(delta.get("graphics").is_none(), "{delta:#}");
}

#[test]
fn render_delta_sends_placement_geometry_without_unchanged_pixels() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(RED_IMAGE_41);
    let mut render_state = RenderState::new().unwrap();
    let mut client = render_protocol_client(&mut terminal, &mut render_state);

    terminal.vt_write(b"\x1b[3G\x1b_Ga=p,i=41,p=9,c=1,r=1,q=2;\x1b\\");
    let frame = render_protocol_frame(&mut terminal, &mut render_state);
    let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();
    let graphics = &delta["graphics"];

    assert!(graphics.get("images").is_none(), "{delta:#}");
    assert!(graphics.get("removed_image_ids").is_none(), "{delta:#}");
    assert_eq!(graphics["placements"].as_array().unwrap().len(), 2);
    assert!(graphics["placements"].as_array().unwrap().iter().any(|placement| {
        placement["placement_id"] == 9
            && placement["viewport_col"] == 2
            && placement["anchor_col"] == 2
            && placement["anchor_row"] == 0
    }));
}

#[test]
fn placing_an_initially_unplaced_image_does_not_resend_its_pixels() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b_Ga=t,t=d,f=24,i=43,s=1,v=1,q=2;/wAA\x1b\\");
    let mut render_state = RenderState::new().unwrap();
    let mut initial = render_protocol_frame(&mut terminal, &mut render_state);
    initial.frame.kitty_graphics = render_state.snapshot_kitty_graphics(&terminal, true).unwrap();
    assert!(initial.frame.kitty_graphics.image(43).is_some());
    assert!(initial.frame.kitty_graphics_delta.image_generations.is_empty());
    let mut client = RenderClientState::new(Arc::new(RenderService::new()), &initial);

    terminal.vt_write(b"\x1b_Ga=p,i=43,p=9,c=1,r=1,q=2;\x1b\\");
    let frame = render_protocol_frame(&mut terminal, &mut render_state);
    let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();
    let graphics = &delta["graphics"];

    assert!(graphics.get("images").is_none(), "{delta:#}");
    assert_eq!(graphics["placements"].as_array().unwrap().len(), 1);
    assert_eq!(graphics["placements"][0]["image_id"], 43);
}

#[test]
fn deleting_an_initially_unplaced_image_releases_client_pixels() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b_Ga=t,t=d,f=24,i=43,s=1,v=1,q=2;/wAA\x1b\\");
    let mut render_state = RenderState::new().unwrap();
    let mut initial = render_protocol_frame(&mut terminal, &mut render_state);
    initial.frame.kitty_graphics = render_state.snapshot_kitty_graphics(&terminal, true).unwrap();
    let mut client = RenderClientState::new(Arc::new(RenderService::new()), &initial);

    terminal.vt_write(b"\x1b_Ga=d,d=I,i=43,q=2;\x1b\\");
    let frame = render_protocol_frame(&mut terminal, &mut render_state);
    let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();

    assert_eq!(delta["graphics"]["removed_image_ids"], json!([43]), "{delta:#}");
    assert!(delta["graphics"].get("images").is_none(), "{delta:#}");
}

#[test]
fn render_delta_upserts_only_images_with_changed_generations() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(RED_IMAGE_41);
    terminal.vt_write(GREEN_IMAGE_42);
    let mut render_state = RenderState::new().unwrap();
    let mut frame = render_protocol_frame(&mut terminal, &mut render_state);
    let mut client = RenderClientState::new(Arc::new(RenderService::new()), &frame);
    replace_render_image(&mut frame, 41, [0, 0, 255]);
    let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();
    let images = delta["graphics"]["images"].as_array().unwrap();

    assert_eq!(images.len(), 1, "{delta:#}");
    assert_eq!(images[0]["id"], 41);
    assert_eq!(images[0]["data"], "AAD/");
    assert!(delta["graphics"].get("placements").is_none(), "{delta:#}");
}

#[test]
fn pixel_only_render_delta_does_not_rescan_the_full_graphics_scene() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(RED_IMAGE_41);
    terminal.vt_write(GREEN_IMAGE_42);
    let mut render_state = RenderState::new().unwrap();
    let mut frame = render_protocol_frame(&mut terminal, &mut render_state);
    let placement_revision = frame.frame.kitty_graphics_delta.placement_revision;
    let mut client = RenderClientState::new(Arc::new(RenderService::new()), &frame);

    replace_render_image(&mut frame, 41, [0, 0, 255]);
    let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();

    assert_eq!(
        delta["graphics"]["images"]
            .as_array()
            .unwrap_or_else(|| panic!("pixel update omitted graphics: {delta:#}"))
            .len(),
        1
    );
    assert_eq!(
        client.image_generation_scan_count, 0,
        "pixel-only animation rebuilt the complete image-generation map"
    );
    assert_eq!(
        frame.frame.kitty_graphics_delta.placement_revision, placement_revision,
        "pixel-only animation changed the shared placement revision"
    );
}

#[test]
fn render_client_that_skips_a_graphics_frame_falls_back_to_one_linear_diff() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(RED_IMAGE_41);
    terminal.vt_write(GREEN_IMAGE_42);
    let mut render_state = RenderState::new().unwrap();
    let initial = render_protocol_frame(&mut terminal, &mut render_state);
    let mut client = RenderClientState::new(Arc::new(RenderService::new()), &initial);
    let mut skipped = initial;
    replace_render_image(&mut skipped, 41, [0, 0, 255]);
    let mut latest = skipped;
    replace_render_image(&mut latest, 42, [255, 255, 0]);

    let delta = serde_json::to_value(client.delta_message(1, &latest)).unwrap();
    let images = delta["graphics"]["images"].as_array().unwrap();

    assert_eq!(images.len(), 2, "{delta:#}");
    assert_eq!(
        client.image_generation_scan_count, 2,
        "a skipped frame did not use one bounded linear image diff"
    );
    assert!(delta["graphics"].get("placements").is_none(), "{delta:#}");
}

#[test]
fn render_delta_reports_deleted_image_ids_without_resending_survivors() {
    let mut terminal = Terminal::new(10, 3, 0, Callbacks::default()).unwrap();
    terminal.vt_write(RED_IMAGE_41);
    terminal.vt_write(GREEN_IMAGE_42);
    let mut render_state = RenderState::new().unwrap();
    let mut client = render_protocol_client(&mut terminal, &mut render_state);

    terminal.vt_write(b"\x1b_Ga=d,d=I,i=41,q=2;\x1b\\");
    let frame = render_protocol_frame(&mut terminal, &mut render_state);
    let delta = serde_json::to_value(client.delta_message(1, &frame)).unwrap();
    let graphics = &delta["graphics"];

    assert_eq!(graphics["removed_image_ids"], json!([41]));
    assert!(graphics.get("images").is_none(), "{delta:#}");
    assert!(
        graphics["placements"]
            .as_array()
            .unwrap()
            .iter()
            .all(|placement| placement["image_id"] == 42)
    );
}

#[test]
fn resource_protocol_responses_are_identical_for_unix_and_websocket_clients() {
    let mux = test_mux();
    let request = serde_json::to_string(&json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":"transport-parity",
        "operation":"session.ping",
        "params":{"machine":"current","session":"current"},
    }))
    .unwrap();
    let mut responses = Vec::new();
    for transport in [ClientTransport::Unix, ClientTransport::WebSocket] {
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(transport, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));
        responses.push(outbound.try_pop().expect("one resource response"));
        disconnect_client(&mux, client, false);
    }

    assert_eq!(responses[0], responses[1]);
    let response: Value = serde_json::from_str(&responses[0]).unwrap();
    assert_eq!(response["protocol"], "cmux.protocol/2");
    assert_eq!(response["type"], "response");
    assert_eq!(response["id"], "transport-parity");
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["alive"], true);
    assert_eq!(response["result"]["cursor"]["revision"], "0");
    assert!(response["result"]["cursor"]["generation"].as_str().is_some());
}

#[test]
fn browser_provider_is_owner_only_loopback_and_released_on_disconnect() {
    let mux = test_mux();
    let local_writer = test_writer();
    let local = mux.control_clients.register(ClientTransport::Unix, local_writer.clone());
    let tab_id = "tab_00000000000000000000000000000001";
    let registered = handle_command(
        &mux,
        local,
        Command::RegisterBrowserProvider {
            provider_id: "browser-process-1".into(),
            endpoint: "ws://127.0.0.1:9222/devtools/browser/one".into(),
            authentication: "bearer".into(),
            bearer_token: Some("secret-token".into()),
            targets: vec![BrowserProviderTargetRequest {
                tab_id: tab_id.into(),
                target_id: "target-one".into(),
            }],
        },
        &local_writer,
    )
    .unwrap();
    assert_eq!(registered["available"], true);
    assert_eq!(registered["authentication"], "bearer");
    assert_eq!(registered["targets"][0]["tab_id"], tab_id);

    let discovered =
        handle_command(&mux, local, Command::GetBrowserProvider, &local_writer).unwrap();
    assert!(
        discovered.get("bearer_token").is_none(),
        "provider discovery must not expose a registered bearer token"
    );

    let remote_writer = test_writer();
    let remote = mux.control_clients.register(ClientTransport::WebSocket, remote_writer.clone());
    let error = handle_command(
        &mux,
        remote,
        Command::RegisterBrowserProvider {
            provider_id: "browser-process-1".into(),
            endpoint: "ws://127.0.0.1:9222/devtools/browser/one".into(),
            authentication: "none".into(),
            bearer_token: None,
            targets: vec![],
        },
        &remote_writer,
    )
    .unwrap_err();
    assert!(error.to_string().contains("trusted local"));
    assert!(
        handle_command(&mux, remote, Command::GetBrowserProvider, &remote_writer)
            .unwrap_err()
            .to_string()
            .contains("trusted local")
    );

    let error = browser_provider_registration(
        "browser-process-1".into(),
        "ws://192.0.2.1:9222/devtools/browser/one".into(),
        "none".into(),
        None,
        vec![],
    )
    .unwrap_err();
    assert!(error.to_string().contains("loopback"));

    assert!(disconnect_client(&mux, local, false));
    assert!(mux.browser_provider_snapshot().is_none());
}
