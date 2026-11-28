//! Plugin hosts already run code for each event. A private pipe to one helper
//! keeps journal normalization and durable handoff in Rust for the whole host
//! lifetime. Command hooks with synchronous provider decisions use run_cli as before.
use super::*;
use std::sync::mpsc;

fn plugin(source: &str) -> bool {
    matches!(source, "opencode" | "amp" | "pi" | "omp" | "campfire" | "hermes-agent")
}

fn identity(value: &str) -> Option<(u64, String)> {
    let (time, key) = value.split_once(':')?;
    if key.len() != 32 || !key.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    Some((time.parse().ok()?, key.into()))
}

pub(super) fn one_shot_identity(source: &str) -> Option<(u64, String)> {
    if !plugin(source) {
        return None;
    }
    identity(&env::var("CMUX_TUI_PLUGIN_EVENT").ok()?)
}

pub(super) fn serve(source: &str) -> anyhow::Result<()> {
    anyhow::ensure!(plugin(source), "unsupported plugin source");
    let (socket, Some(terminal)) = session_route(source).context("missing plugin route")? else {
        bail!("missing plugin terminal");
    };
    serve_io(source, &socket, &terminal, io::stdin().lock(), io::stdout().lock())
}

fn serve_io(
    source: &str,
    socket: &Path,
    terminal: &str,
    mut input: impl BufRead,
    mut out: impl Write,
) -> anyhow::Result<()> {
    // One plugin serves a fixed terminal. One outstanding wake
    // suffices even when many more records arrive while the sender is draining.
    let (wake, work) = mpsc::sync_channel(1);
    std::thread::scope(|scope| {
        let journal = socket;
        scope.spawn(move || {
            journal_append::send_plugin_queue(journal, work);
        });
        writeln!(out, "ready")?;
        out.flush()?;
        let mut line = Vec::new();
        loop {
            line.clear();
            // A compact JSON [identity,event,payload] line. Match the one-shot limit
            // for native input, with room for the event and array framing.
            let limit = MAX_NATIVE_PAYLOAD_BYTES + 1024;
            let n = Read::by_ref(&mut input).take(limit + 1).read_until(b'\n', &mut line)?;
            if n == 0 {
                break;
            }
            if n as u64 > limit || line.last() != Some(&b'\n') {
                break;
            }
            let result = (|| -> anyhow::Result<()> {
                let (key, event, native): (String, String, Value) = serde_json::from_slice(&line)?;
                let identity = identity(&key).context("invalid plugin event identity")?;
                let (id, encoded) =
                    encode_native(source, &event, Some(terminal), native, Some(identity))?;
                if let Ok(spool) = hook_spool::Spool::for_request(journal, &encoded)
                    && spool.append(&encoded).is_ok()
                {
                    match wake.try_send(spool) {
                        Ok(()) | Err(mpsc::TrySendError::Full(_)) => {}
                        Err(mpsc::TrySendError::Disconnected(_)) => bail!("journal sender exited"),
                    }
                } else {
                    // No private spool (including platforms without one). Use
                    // the one-shot transport's retry and receipt semantics.
                    append_with_receipt(journal, &id, &encoded, &|| {})?;
                }
                Ok(())
            })();
            writeln!(out, "{}", if result.is_ok() { "ok" } else { "error" })?;
            out.flush()?;
        }
        drop(wake);
        Ok(())
    })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn plugin_stream_queues_a_burst_offline_and_keeps_retry_identities() {
        let root = tempfile::tempdir().unwrap();
        let terminal = "term_00000000000000000000000000000001";
        let socket = root.path().join("daemon.sock");
        let mut input = Vec::new();
        let mut expected = Vec::new();
        for sequence in 0..128 {
            let key = format!("{sequence:032x}");
            let native = json!({"event": {"properties": {"sequence": sequence}}});
            let (_, encoded) = encode_native(
                "opencode",
                "tool.execute.after",
                Some(terminal),
                native.clone(),
                Some((1000, key.clone())),
            )
            .unwrap();
            expected.push(serde_json::from_slice::<Value>(&encoded).unwrap());
            writeln!(input, "{}", json!([format!("1000:{key}"), "tool.execute.after", native]))
                .unwrap();
        }
        let mut output = Vec::new();
        serve_io("opencode", &socket, terminal, &input[..], &mut output).unwrap();
        assert_eq!(String::from_utf8(output).unwrap(), format!("ready\n{}", "ok\n".repeat(128)));
        let queues = hook_spool::session_queues(&socket, None).unwrap();
        assert_eq!(queues.len(), 1);
        let mut offset = 0;
        for event in expected {
            let (line, next) = queues[0].line_at(offset).unwrap().unwrap();
            assert_eq!(serde_json::from_slice::<Value>(&line).unwrap(), event);
            offset = next;
        }
        assert!(queues[0].line_at(offset).unwrap().is_none());
    }
}
