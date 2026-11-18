//! `device-setup {device, verb: "setup"|"start", allow_agents?, dry_run?}`: the app's set-up and
//! "Start cmux on <Mac>" buttons (Leo, 2026-11-14: "i dont wanna open up cmux nightly myself").
//! Each step streams as a `device-setup-step` event carrying the step line `cmux device setup
//! --json` prints (`{device, step, state, detail, fix}`); the reply's data is the summary line.
//! The run is the cmux-tui binary's (crate::device_setup). It runs on a wait worker, off the
//! connection's dispatcher (connection_wait.rs), and only for the verified app: an agent runs
//! the same through `cmux device setup` or the MCP tools.

use serde_json::{Value, json};

use super::{MessageWriter, Mux, remote_host_command};
use crate::device_setup::{self, DeviceSetupRequest};

/// The event each step line streams as.
pub(super) const STEP_EVENT: &str = "device-setup-step";

pub(super) fn handle(
    mux: &Mux,
    client: u64,
    writer: &MessageWriter,
    device: String,
    verb: &str,
    allow_agents: bool,
    dry_run: bool,
) -> anyhow::Result<Value> {
    let caller = remote_host_command::caller(mux, client).map_err(anyhow::Error::from)?;
    if !caller.verified_app {
        anyhow::bail!("device-setup is the cmux app's; agents run `cmux device setup`");
    }
    let start_only = match verb {
        "setup" => false,
        "start" => true,
        other => anyhow::bail!("device-setup verb must be setup or start, not {other:?}"),
    };
    if device.trim().is_empty() {
        anyhow::bail!("device-setup needs a device");
    }
    let request = DeviceSetupRequest { device, start_only, allow_agents, dry_run };
    run(&request, &mut |line| {
        let _ = writer.send_control(&line);
    })
}

/// The run, with each step line turned into its event.
pub(super) fn run(
    request: &DeviceSetupRequest,
    send: &mut dyn FnMut(Value),
) -> anyhow::Result<Value> {
    device_setup::run(request, &mut |line| send(step_event(line))).map_err(anyhow::Error::msg)
}

/// A step line as its event: the same fields, plus `event`.
pub(super) fn step_event(line: Value) -> Value {
    let mut event = json!({"event": STEP_EVENT});
    if let (Some(fields), Value::Object(line)) = (event.as_object_mut(), line) {
        fields.extend(line);
    }
    event
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_step_line_streams_as_its_event_with_every_field() {
        let line = json!({"device": "studio-mac", "step": "app", "state": "ok",
                          "detail": "NIGHTLY 2100 is current", "fix": ""});
        assert_eq!(
            step_event(line),
            json!({"event": "device-setup-step", "device": "studio-mac", "step": "app",
                   "state": "ok", "detail": "NIGHTLY 2100 is current", "fix": ""})
        );
    }

    #[test]
    fn identify_lists_device_setup_v1_once_a_runner_is_installed() {
        device_setup::on_device_setup(device_setup::tests::fake);
        assert!(
            super::super::capabilities::advertised_capabilities(false)
                .contains(&device_setup::CAPABILITY)
        );
    }
}
