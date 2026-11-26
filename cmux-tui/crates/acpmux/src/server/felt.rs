//! The felt-latency histograms (`cmux-felt`) at the daemon's prompt path: a prompt's time from the
//! request reaching the daemon to the chat taking it (the ack the pane's "Sending" waits on). Only
//! the number is kept: no prompt text, chat id or sender.

use std::time::Instant;

use serde_json::Value;

type OnAccepted = Option<Box<dyn FnOnce(Value) + Send>>;

/// `on_accepted`, also recording the time since `started` as the prompt's send-to-ack once the
/// chat takes it. A prompt the chat already had (`duplicate`) is not a send, so it records none.
pub(super) fn time_ack(started: Instant, on_accepted: OnAccepted) -> OnAccepted {
    Some(Box::new(move |accepted: Value| {
        if accepted.get("duplicate") != Some(&Value::Bool(true)) {
            cmux_felt::record(cmux_felt::Metric::PromptSendToAck, started.elapsed());
        }
        if let Some(next) = on_accepted {
            next(accepted);
        }
    }))
}

#[cfg(test)]
#[path = "felt_tests.rs"]
mod tests;
