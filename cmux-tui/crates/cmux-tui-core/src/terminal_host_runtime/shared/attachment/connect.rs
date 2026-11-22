//! The owner handshake with a live host: connect over `sys::HostStream`,
//! negotiate the protocol version (smart renderer first, then each legacy
//! version), and build the `HostAttachment` from the initial snapshot.

use super::*;

pub(crate) fn connect_record(
    record: TerminalHostRecord,
    record_path: PathBuf,
    intent: OwnerIntent,
) -> anyhow::Result<HostAttachment> {
    connect_record_with_timeout(record, record_path, HOST_HANDSHAKE_TIMEOUT, intent)
}

pub(crate) fn connect_record_with_timeout(
    record: TerminalHostRecord,
    record_path: PathBuf,
    handshake_timeout: Duration,
    intent: OwnerIntent,
) -> anyhow::Result<HostAttachment> {
    let endpoint = PathBuf::from(&record.endpoint);
    let mut stream = Some(
        connect_with_retry(&endpoint)
            .with_context(|| format!("connect terminal host at {}", endpoint.display()))?,
    );
    let mut failures = Vec::new();
    let attempts = std::iter::once((PROTOCOL_VERSION, true))
        .chain((LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).rev().map(|version| (version, false)));
    'protocols: for (protocol_version, smart_renderer) in attempts {
        let mut transient_retries = 0;
        loop {
            let error = match connect_record_at_version(
                record.clone(),
                record_path.clone(),
                handshake_timeout,
                protocol_version,
                smart_renderer,
                stream.take().expect("protocol attempt has a connected stream"),
                intent,
            ) {
                Ok(attachment) => return Ok(attachment),
                Err(error) => error,
            };
            if transient_retries < HOST_HANDSHAKE_TRANSIENT_RETRIES
                && is_transient_handshake_transport(&error)
            {
                transient_retries += 1;
                failures.push(format!(
                    "protocol {protocol_version} transient attempt {transient_retries}: {error:#}"
                ));
                match connect_with_retry(&endpoint) {
                    Ok(next_stream) => {
                        stream = Some(next_stream);
                        continue;
                    }
                    Err(reconnect_error) => {
                        failures.push(format!("protocol retry reconnect: {reconnect_error:#}"));
                        break 'protocols;
                    }
                }
            }
            failures.push(format!("protocol {protocol_version}: {error:#}"));
            break;
        }
        match connect_with_retry(&endpoint) {
            Ok(next_stream) => stream = Some(next_stream),
            Err(error) => {
                failures.push(format!("protocol fallback reconnect: {error:#}"));
                break;
            }
        }
    }
    anyhow::bail!("terminal-host adoption failed: {}", failures.join("; "))
}

pub(crate) fn connect_current_record_with_timeout(
    record: TerminalHostRecord,
    record_path: PathBuf,
    handshake_timeout: Duration,
    intent: OwnerIntent,
) -> anyhow::Result<HostAttachment> {
    if record.record_version >= HOST_RECORD_VERSION {
        // Fence-capable records are emitted only by the current smart
        // protocol. After an existing owner connection fails, probing
        // every legacy version can outlive the control request while the
        // already-terminating host removes its socket. One current
        // handshake is sufficient; durable tombstone reconciliation
        // retries independently if that bounded attempt loses the race.
        let endpoint = PathBuf::from(&record.endpoint);
        let stream = connect_with_retry(&endpoint)
            .with_context(|| format!("connect terminal host at {}", endpoint.display()))?;
        return connect_record_at_version(
            record,
            record_path,
            handshake_timeout,
            PROTOCOL_VERSION,
            true,
            stream,
            intent,
        );
    }
    connect_record_with_timeout(record, record_path, handshake_timeout, intent)
}

pub(crate) fn is_transient_handshake_transport(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause.downcast_ref::<std_io::Error>().is_some_and(|error| {
            matches!(
                error.kind(),
                std_io::ErrorKind::Interrupted
                    | std_io::ErrorKind::TimedOut
                    | std_io::ErrorKind::WouldBlock
            )
        })
    })
}

pub(crate) fn connect_record_at_version(
    record: TerminalHostRecord,
    record_path: PathBuf,
    handshake_timeout: Duration,
    protocol_version: u16,
    smart_renderer: bool,
    mut stream: HostStream,
    intent: OwnerIntent,
) -> anyhow::Result<HostAttachment> {
    if !(LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&protocol_version) {
        anyhow::bail!("unsupported terminal-host adoption protocol {protocol_version}");
    }
    let terminal_id = TerminalId::from_bytes(decode_hex_array(&record.terminal_id)?);
    let incarnation = HostIncarnation::from_bytes(decode_hex_array(&record.incarnation)?);
    let owner_token = CapabilityToken::from_bytes(decode_hex_array(&record.owner_token)?);
    stream.set_read_timeout(Some(handshake_timeout))?;
    stream.set_write_timeout(Some(handshake_timeout))?;
    let hello = ClientHello {
        min_version: protocol_version,
        max_version: protocol_version,
        role: ClientRole::Admin,
        requested_rights: owner_rights_for(&record, protocol_version, intent),
        terminal_id,
        token: owner_token,
    };
    let mut hello_frame = hello.into_frame(1);
    hello_frame.version = protocol_version;
    let terminal_metadata_requested =
        protocol_version == PROTOCOL_VERSION && record.supports_terminal_metadata;
    if smart_renderer {
        hello_frame.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
    }
    if terminal_metadata_requested {
        hello_frame.flags |= FLAG_TERMINAL_METADATA;
    }
    write_frame(&mut stream, &hello_frame)?;
    let hello_frame = read_required_frame(&mut stream, "host hello")?;
    if hello_frame.kind != MessageKind::HostHello
        || hello_frame.version != protocol_version
        || hello_frame.flags
            & !(FLAG_VIEWER_SIZE_ACKS
                | FLAG_SMART_RENDERER
                | FLAG_LAUNCH_ACTIVATION_REQUIRED
                | FLAG_TERMINAL_METADATA)
            != 0
        || hello_frame.request_id != 1
        || hello_frame.sequence != 0
        || (smart_renderer && hello_frame.flags & FLAG_SMART_RENDERER == 0)
        || (!terminal_metadata_requested && hello_frame.flags & FLAG_TERMINAL_METADATA != 0)
    {
        anyhow::bail!("terminal host rejected owner handshake");
    }
    let launch_activation_pending = hello_frame.flags & FLAG_LAUNCH_ACTIVATION_REQUIRED != 0;
    if launch_activation_pending && protocol_version < LAUNCH_ACTIVATION_PROTOCOL_VERSION {
        anyhow::bail!("legacy terminal host requested launch activation");
    }
    let host_hello = HostHello::decode(&hello_frame.payload)?;
    if host_hello.selected_version != protocol_version
        || host_hello.terminal_id != terminal_id
        || host_hello.incarnation != incarnation
        || host_hello.granted_rights != hello.requested_rights
    {
        anyhow::bail!("terminal-host record identity does not match live host");
    }
    let terminal_metadata_negotiated = hello_frame.flags & FLAG_TERMINAL_METADATA != 0;
    let snapshot_frame = read_required_frame(&mut stream, "terminal snapshot")?;
    if snapshot_frame.kind != MessageKind::Snapshot
        || snapshot_frame.version != protocol_version
        || snapshot_frame.flags != 0
        || snapshot_frame.request_id != 0
    {
        anyhow::bail!("terminal host did not send an initial snapshot");
    }
    let mut snapshot = decode_snapshot_for_version(
        &snapshot_frame.payload,
        protocol_version,
        terminal_metadata_negotiated,
    )?;
    let colors_frame = read_required_frame(&mut stream, "terminal color state")?;
    if colors_frame.kind != MessageKind::Colors
        || colors_frame.version != protocol_version
        || colors_frame.flags != 0
        || colors_frame.sequence != snapshot_frame.sequence
        || colors_frame.request_id != 0
    {
        anyhow::bail!("terminal host did not send Colors at the snapshot sequence boundary");
    }
    snapshot.sequence_boundary = snapshot_frame.sequence;
    snapshot.colors = decode_terminal_color_overrides(&colors_frame.payload)?;
    if smart_renderer {
        let ready_frame = read_required_frame(&mut stream, "terminal ready boundary")?;
        if ready_frame.kind != MessageKind::Ready
            || ready_frame.version != protocol_version
            || ready_frame.flags != 0
            || ready_frame.sequence != snapshot_frame.sequence
            || ready_frame.request_id != 0
            || !ready_frame.payload.is_empty()
        {
            anyhow::bail!("terminal host did not send Ready at the snapshot sequence boundary");
        }
    }
    let snapshot_size = (snapshot.cols, snapshot.rows);
    stream.set_read_timeout(None)?;
    // Keep bounded writes for the lifetime of the disposable admin
    // mirror. A stopped or wedged host must not block a mux/control thread
    // forever while it sends input, mouse, resize, or Terminate. Reads are
    // unbounded because the dedicated reader thread is intentionally
    // long-lived and reconnects on any eventual EOF/protocol failure.
    let reader = stream.try_clone()?;
    let attachment = HostAttachment {
        record,
        record_path,
        snapshot,
        protocol_version,
        smart_renderer,
        reader: Some(reader),
        writer: Arc::new(Mutex::new(stream)),
        control_responses: Arc::new(ControlResponses::with_clipboard_reads(
            hello.requested_rights.contains(CapabilityRights::CLIPBOARD_READ),
        )),
        next_request: AtomicU64::new(2),
        // New hosts do not register Admin as a viewer. Initialize this as
        // if they did so the unconditional release below also upgrades
        // live protocol-v1 hosts whose older implementation registered
        // every connection at the snapshot grid.
        viewer_size: Mutex::new(Some(snapshot_size)),
        launch_process: None,
        launch_activation_pending,
        pty_custody: None,
    };
    attachment.release_viewer_size()?;
    Ok(attachment)
}
