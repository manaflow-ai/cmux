//! Read-only, explicitly enabled experiment; never used by runner selection.
use serde_json::{json, Map, Value};
use std::{collections::BTreeSet, env, fs, process::ExitCode};

fn object<'a>(value: &'a Value, context: &str) -> Result<&'a Map<String, Value>, String> {
    value
        .as_object()
        .ok_or_else(|| format!("{context}: expected an object"))
}

fn audit(runners: &Value, labels: &Value) -> Result<Value, String> {
    let labels = object(labels, "label inventory")?;
    for (label, details) in labels {
        if !matches!(details["os"].as_str(), Some("linux" | "macos" | "windows"))
            || details["owned"].as_bool().is_none()
        {
            return Err(format!("invalid inventory entry: {label}"));
        }
    }
    let pools = object(&runners["pools"], "runners.pools")?;
    let mut rows = Vec::new();
    let mut findings = 0;
    let mut linux_pools = 0;
    for (name, pool) in pools {
        if name.starts_with('$') {
            continue;
        }
        let members = pool["members"]
            .as_array()
            .filter(|members| !members.is_empty())
            .ok_or_else(|| format!("{name}: members must be a nonempty array"))?;
        let mut owned = Vec::new();
        let mut unknown = Vec::new();
        let mut systems = BTreeSet::new();
        for member in members {
            let label = member
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or_else(|| format!("{name}: each member must be a nonempty label"))?;
            match labels.get(label) {
                Some(details) => {
                    let os = details["os"].as_str().unwrap();
                    systems.insert(os);
                    if os == "linux" && details["owned"] == true {
                        owned.push(label);
                    }
                }
                None => unknown.push(label),
            }
        }
        // A known Linux member or the Linux namespace identifies the pool.
        // Unclassified pools never disappear behind a healthy verdict.
        let linux = systems.contains("linux") || name == "linux" || name.starts_with("linux_");
        if linux {
            linux_pools += 1;
        }
        let hosted = match pool.get("hosted") {
            None => false,
            Some(value) => value
                .as_bool()
                .ok_or_else(|| format!("{name}: hosted must be boolean"))?,
        };
        let reason = pool["hosted_why"].as_str().filter(|s| !s.trim().is_empty());
        if hosted && reason.is_none() {
            return Err(format!("{name}: hosted requires hosted_why"));
        }
        let status = if !unknown.is_empty() {
            "unknown-label"
        } else if systems.len() > 1 || (linux && !systems.contains("linux")) {
            "mixed-platform"
        } else if linux && hosted {
            // This is a declared constraint, not evidence of independent capacity.
            "hosted-required"
        } else if linux && owned.is_empty() {
            "missing-owned"
        } else if linux {
            "owned-member-configured"
        } else {
            "not-linux"
        };
        if matches!(status, "unknown-label" | "mixed-platform" | "missing-owned") {
            findings += 1;
        }
        rows.push(json!({"pool": name, "status": status, "members": members,
            "owned_linux_members": owned, "unknown_labels": unknown,
            "hosted_reason": if hosted { reason } else { None }}));
    }
    if rows.is_empty() || linux_pools == 0 {
        return Err("no Linux pools found; audit is inconclusive".into());
    }
    Ok(
        json!({"schema_version": 1, "experiment": "ci-compute-pool-audit", "enabled": true,
        "linux_pools": linux_pools, "findings": findings, "pools": rows}),
    )
}

fn run(args: &[String]) -> Result<Value, String> {
    let mut enabled = false;
    let mut runners = ".github/runners.json";
    let mut labels = "experiments/ci-compute/labels.json";
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--enable" => enabled = true,
            "--runners" => runners = args.next().ok_or("--runners requires a path")?,
            "--labels" => labels = args.next().ok_or("--labels requires a path")?,
            _ => {
                return Err(format!(
                    "unknown argument: {arg}; use --enable [--runners PATH] [--labels PATH]"
                ))
            }
        }
    }
    if !enabled {
        return Ok(
            json!({"schema_version": 1, "experiment": "ci-compute-pool-audit", "enabled": false}),
        );
    }
    let read = |path: &str| -> Result<Value, String> {
        let bytes = fs::read(path).map_err(|e| format!("{path}: {e}"))?;
        serde_json::from_slice(&bytes).map_err(|e| format!("{path}: {e}"))
    };
    let mut report = audit(&read(runners)?, &read(labels)?)?;
    report["runners_path"] = json!(runners);
    report["labels_path"] = json!(labels);
    Ok(report)
}

fn main() -> ExitCode {
    match run(&env::args().skip(1).collect::<Vec<_>>()) {
        Ok(report) => {
            println!("{}", serde_json::to_string_pretty(&report).unwrap());
            if report["findings"].as_u64().unwrap_or(0) > 0 {
                ExitCode::from(2)
            } else {
                ExitCode::SUCCESS
            }
        }
        Err(error) => {
            eprintln!("ci-compute-pool-audit: {error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inventory() -> Value {
        json!({"owned": {"os":"linux", "owned":true},
            "small": {"os":"linux", "owned":false}, "large": {"os":"linux", "owned":false},
            "mac": {"os":"macos", "owned":true}})
    }
    fn report(members: Value) -> Value {
        audit(
            &json!({"pools":{"linux":{"members":members}}}),
            &inventory(),
        )
        .unwrap()
    }
    #[test]
    fn more_sizes_do_not_add_independent_capacity() {
        assert_eq!(
            report(json!(["small", "large"]))["pools"][0]["status"],
            "missing-owned"
        );
        assert_eq!(report(json!(["small", "owned"]))["findings"], 0);
    }
    #[test]
    fn unknown_owned_looking_label_does_not_pass() {
        assert_eq!(
            report(json!(["owned", "cmux-new-linux"]))["pools"][0]["status"],
            "unknown-label"
        );
    }
    #[test]
    fn owned_mac_cannot_cover_linux() {
        assert_eq!(
            report(json!(["mac"]))["pools"][0]["status"],
            "mixed-platform"
        );
        assert_eq!(report(json!(["small", "mac"]))["findings"], 1);
    }
    #[test]
    fn detects_linux_in_arbitrarily_named_pool() {
        let result = audit(
            &json!({"pools":{"checks":{"members":["small"]}}}),
            &inventory(),
        )
        .unwrap();
        assert_eq!(result["findings"], 1);
        assert_eq!(result["linux_pools"], 1);
    }
    #[test]
    fn empty_and_malformed_inputs_fail() {
        for input in [
            json!({}),
            json!({"pools":{}}),
            json!({"pools":{"linux":{"members":[]}}}),
            json!({"pools":{"linux":{"members":[42]}}}),
        ] {
            assert!(audit(&input, &inventory()).is_err());
        }
        assert!(audit(&json!({"pools":{}}), &json!({"bad":{"os":"linux"}})).is_err());
    }
    #[test]
    fn hosted_exception_is_visible_and_requires_reason() {
        let mut input = json!({"pools":{"linux":{"members":["small"], "hosted":true}}});
        assert!(audit(&input, &inventory()).is_err());
        input["pools"]["linux"]["hosted_why"] =
            json!("Artifact identity requires hosted execution");
        assert_eq!(
            audit(&input, &inventory()).unwrap()["pools"][0]["status"],
            "hosted-required"
        );
    }
    #[test]
    fn disabled_does_not_open_input_files() {
        assert_eq!(
            run(&["--runners".into(), "/missing/input.json".into()]).unwrap()["enabled"],
            false
        );
    }
}
