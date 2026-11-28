//! TEMPORARY probe (sessions-2000-attached): per-prompt stage times, one line each, into
//! `$ACPMUX_HOME/prompt-trace.log` when `ACPMUX_PROMPT_TRACE=1`. A writer thread does the I/O,
//! so a mark costs one channel send. Removed with the fix it finds.

use std::io::Write;
use std::sync::OnceLock;
use std::sync::mpsc::{Sender, channel};

static WRITER: OnceLock<Option<Sender<String>>> = OnceLock::new();

fn writer() -> Option<&'static Sender<String>> {
    WRITER
        .get_or_init(|| {
            if std::env::var("ACPMUX_PROMPT_TRACE").as_deref() != Ok("1") {
                return None;
            }
            let path = crate::config::home().join("prompt-trace.log");
            let mut f = std::io::BufWriter::new(
                std::fs::OpenOptions::new().create(true).append(true).open(path).ok()?,
            );
            let (tx, rx) = channel::<String>();
            std::thread::Builder::new()
                .name("prompt-probe".into())
                .spawn(move || {
                    while let Ok(line) = rx.recv() {
                        let _ = f.write_all(line.as_bytes());
                        while let Ok(more) = rx.try_recv() {
                            let _ = f.write_all(more.as_bytes());
                        }
                        let _ = f.flush();
                    }
                })
                .ok()?;
            Some(tx)
        })
        .as_ref()
}

fn now_us() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros())
        .unwrap_or(0)
}

/// One stage of one prompt: `key` names the chat, `prompt` its prompt id when known.
pub fn mark(stage: &str, key: &str, prompt: &str) {
    if let Some(tx) = writer() {
        let _ = tx.send(format!("{} {stage} {key} {prompt}\n", now_us()));
    }
}

/// `mark` with the key and prompt id read from a request's params.
pub fn mark_params(stage: &str, params: &serde_json::Value) {
    if writer().is_none() {
        return;
    }
    let key = params.get("sessionId").and_then(|v| v.as_str()).unwrap_or("-");
    let prompt = params.pointer("/_meta/acpmux/promptId").and_then(|v| v.as_str()).unwrap_or("-");
    mark(stage, key, prompt);
}
