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
    // One plugin serves a fixed terminal. One outstanding wake
    // suffices even when many more records arrive while the sender is draining.
    let (wake, work) = mpsc::sync_channel(1);
    std::thread::scope(|scope| {
        let journal = &socket;
        scope.spawn(move || {
            journal_append::send_plugin_queue(journal, work);
        });
        let mut out = io::stdout().lock();
        writeln!(out, "ready")?;
        out.flush()?;
        let mut input = io::stdin().lock();
        let mut line = Vec::new();
        loop {
            line.clear();
            // A compact JSON [identity,event,payload] line. Match the one-shot limit
            // for native input, with room for the event and array framing.
            let limit = MAX_NATIVE_PAYLOAD_BYTES + 1024;
            let n = input.by_ref().take(limit + 1).read_until(b'\n', &mut line)?;
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
                    encode_native(source, &event, Some(&terminal), native, Some(identity))?;
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
