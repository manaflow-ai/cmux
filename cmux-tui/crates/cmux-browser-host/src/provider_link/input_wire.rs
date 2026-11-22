//! Agent input events to the app: `input {event}` frames (automation.input
//! v1, schemas/automation-input). Drivers emit the events (hq-07); this
//! module only carries them, verbatim, so the app draws the agent cursor.

use super::*;

/// The driver event that carries one agent input.
pub const AUTOMATION_INPUT: &str = "automation.input";

impl ProviderDriver {
    /// Sends one `automation.input` event to the app (dropped once the link is closed).
    pub fn send_input(&self, event: Value) {
        if self.closed_reason().is_some() {
            return;
        }
        let mut writer = self.writer.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = write_frame(&mut *writer, &Frame::Input { event });
    }
}

/// The sink a provider session's driver gets: every event goes on to
/// `events`, and an `automation.input` event of `session` also goes to the
/// app as an `input` frame. A CEF tab's events reach every subscribed
/// session (`ProviderDriver::publish`), so only the session the event names
/// sends it: one input, one frame. The link is held weakly.
pub fn tee_inputs(events: EventSink, provider: &Arc<ProviderDriver>, session: &str) -> EventSink {
    let provider = Arc::downgrade(provider);
    let session = session.to_owned();
    Arc::new(move |event: DriverEvent| {
        if event.name == AUTOMATION_INPUT
            && event.payload.get("session_id").and_then(Value::as_str) == Some(session.as_str())
            && let Some(provider) = provider.upgrade()
        {
            provider.send_input(event.payload.clone());
        }
        events(event);
    })
}
