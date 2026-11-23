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
