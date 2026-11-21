//! Read-only Labs probe. Only the worker answers permission questions; the
//! CLI never probes its own process's grants or requests OS consent.

use serde_json::{Value, json};

use super::{GlobalArgs, Outcome, caller, new_call_id, with_machine};

const SETTING: &str = "labs.previewFeatures";

pub(super) fn run(global: &GlobalArgs, machine: Option<&str>) -> i32 {
    let setting = super::super::mcp::agent_app(
        global,
        "settings.get",
        json!({"path": SETTING}),
        super::super::app::READ_TIMEOUT,
        None,
    );
    let outcome = probe(setting, || {
        caller(global).call("status", &with_machine(json!({}), machine), &new_call_id())
    });
    match outcome {
        Ok(outcome) => {
            let not_ready = matches!(&outcome, Outcome::Output(out)
                if !out.is_error && out.body["readiness"]["ready"] != true);
            let code = super::print(global, outcome);
            if not_ready { 1 } else { code }
        }
        Err(error) => super::super::wire::print_local_error(&error, global.output, 1),
    }
}

fn probe(
    setting: Result<Value, Value>,
    status: impl FnOnce() -> Outcome,
) -> Result<Outcome, Value> {
    // A missing, invalid, or unreadable setting never starts a worker call.
    if setting?["value"] != true {
        return Err(json!({
            "code": "experiment_disabled",
            "message": crate::localization::computer_use_readiness_disabled(),
            "setting": SETTING,
        }));
    }
    let mut outcome = status();
    if let Outcome::Output(out) = &mut outcome
        && !out.is_error
    {
        let readiness = report(&out.body);
        if let Some(body) = out.body.as_object_mut() {
            body.insert("readiness".into(), readiness);
        }
    }
    Ok(outcome)
}

fn report(status: &Value) -> Value {
    let mut missing = Vec::new();
    let mut unknown = Vec::new();
    for name in ["accessibility", "screen_capture", "input"] {
        match status["permissions"][name].as_str() {
            Some("granted" | "not_needed") => {}
            Some("denied") => missing.push(name),
            _ => unknown.push(name),
        }
    }
    json!({
        "schema_version": 1,
        "source": "worker_status",
        "scope": "os_permissions",
        "ready": missing.is_empty() && unknown.is_empty(),
        "state": if !missing.is_empty() { "needs_permission" }
            else if !unknown.is_empty() { "unknown" } else { "ready" },
        "missing": missing,
        "unknown": unknown,
        // OS grants do not authorize any app, session, or remote caller.
        "target_authorization": "unchanged",
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_computer_use::ToolOutput;

    #[test]
    fn readiness_off_or_unreadable_never_contacts_worker() {
        for value in [json!({}), json!({"value": false}), json!({"value": "true"})] {
            let error = probe(Ok(value), || panic!("worker contacted while off")).unwrap_err();
            assert_eq!(error["code"], "experiment_disabled");
        }
        let error = json!({"code": "transport.timeout"});
        let answer = probe(Err(error.clone()), || panic!("worker contacted without settings"));
        assert_eq!(answer.unwrap_err(), error);
    }

    #[test]
    fn readiness_requires_every_grant_and_preserves_worker_identity_and_policy() {
        let status = json!({
            "machine": "target", "mode": "approvedApps", "denied_apps": ["cmux"],
            "permissions": {"accessibility": "granted", "screen_capture": "granted", "input": "not_needed"}
        });
        let result =
            probe(Ok(json!({"value": true})), || Outcome::Output(ToolOutput::ok(status.clone())))
                .unwrap();
        let Outcome::Output(out) = result else { panic!("no report") };
        assert_eq!(out.body["readiness"]["ready"], true);
        assert_eq!(out.body["readiness"]["scope"], "os_permissions");
        let mut body = out.body;
        body.as_object_mut().unwrap().remove("readiness");
        assert_eq!(body, status);
        for name in ["accessibility", "screen_capture", "input"] {
            for value in
                [json!("denied"), json!("unknown"), Value::Null, json!(true), json!("future")]
            {
                let mut denied = status.clone();
                denied["permissions"][name] = value.clone();
                let report = report(&denied);
                assert_eq!(report["ready"], false, "{name}: {value}");
                assert_eq!(
                    report["state"],
                    if value == "denied" { "needs_permission" } else { "unknown" }
                );
            }
        }
        assert_eq!(
            report(&json!({}))["unknown"],
            json!(["accessibility", "screen_capture", "input"])
        );
    }

    #[test]
    fn readiness_preserves_off_transport_and_tool_refusals() {
        let run = |outcome| probe(Ok(json!({"value": true})), || outcome).unwrap();
        assert!(
            matches!(run(Outcome::Off("disabled".into())), Outcome::Off(reason) if reason == "disabled")
        );
        assert!(
            matches!(run(Outcome::Failed { code: "denied".into(), message: "refused".into() }), Outcome::Failed { code, .. } if code == "denied")
        );
        let Outcome::Output(out) = run(Outcome::Output(ToolOutput::error("denied", "refused")))
        else {
            panic!("no refusal")
        };
        assert!(out.is_error);
        assert!(out.body.get("readiness").is_none());
    }
}
