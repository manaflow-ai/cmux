//! The seam behind the daemon's `device-setup` command (server/device_setup_command.rs): the
//! app's "Start cmux on <Mac>" and set-up buttons ask the daemon, never a `cmux` child. The run
//! itself lives in the cmux-tui binary (devices/setup.rs, the same code `cmux device setup|start`
//! runs), which installs it here at start, the way `git_seed::on_seeded` works.

use std::sync::OnceLock;

use serde_json::Value;

/// One `device-setup` request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceSetupRequest {
    /// A device id, name or address, as `cmux device list` shows it.
    pub device: String,
    /// `verb: "start"`: reach, login item and start only.
    pub start_only: bool,
    /// Turn on "My agents can turn screen sharing and control on my machines" (the person's
    /// click in the app; never on without it).
    pub allow_agents: bool,
    pub dry_run: bool,
}

/// Runs one request: every step line (`{device, step, state, detail, fix}`) goes to `step` as
/// it is made; the answer is the summary line (`{device, summary, changed, failed}`).
pub type DeviceSetupRunner =
    fn(&DeviceSetupRequest, &mut dyn FnMut(Value)) -> Result<Value, String>;

static RUNNER: OnceLock<DeviceSetupRunner> = OnceLock::new();

/// Sets the runner; the first call wins.
pub fn on_device_setup(runner: DeviceSetupRunner) {
    let _ = RUNNER.set(runner);
}

pub(crate) fn run(
    request: &DeviceSetupRequest,
    step: &mut dyn FnMut(Value),
) -> Result<Value, String> {
    let Some(runner) = RUNNER.get() else {
        return Err("this cmux daemon has no device setup".into());
    };
    runner(request, step)
}

/// The capability a daemon that runs `device-setup` advertises in `identify`: the app shows its
/// set-up and start buttons only when it is there.
pub const CAPABILITY: &str = "device-setup-v1";

/// [`CAPABILITY`] when a runner is installed (the cmux-tui binary installs one at start).
pub fn advertised() -> Vec<&'static str> {
    if RUNNER.get().is_some() { vec![CAPABILITY] } else { Vec::new() }
}

#[cfg(test)]
pub(crate) mod tests {
    use serde_json::json;

    use super::*;

    pub(crate) fn fake(
        request: &DeviceSetupRequest,
        step: &mut dyn FnMut(Value),
    ) -> Result<Value, String> {
        step(json!({"device": request.device, "step": "reach", "state": "ok"}));
        Ok(json!({"device": request.device, "summary": true, "changed": [], "failed": []}))
    }

    #[test]
    fn an_installed_runner_is_advertised_and_runs() {
        on_device_setup(fake);
        assert_eq!(advertised(), [CAPABILITY]);
        let request = DeviceSetupRequest {
            device: "studio-mac".into(),
            start_only: false,
            allow_agents: false,
            dry_run: false,
        };
        let mut steps = Vec::new();
        let summary = run(&request, &mut |line| steps.push(line));
        assert_eq!(steps.len(), 1);
        assert_eq!(summary.ok().and_then(|s| s.get("device").cloned()), Some(json!("studio-mac")));
    }
}
