use super::*;
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/deeplinks/web-routes.json");

fn as_json(route: &Route) -> Value {
    let machine = |m: &Option<Machine>| match m {
        Some(Machine::Id(v)) => Some(json!({"id": v})),
        Some(Machine::Name(v)) => Some(json!({"name": v})),
        None => None,
    };
    match route {
        Route::Agent { machine: m, harness, session, message } => {
            let mut v = json!({"kind": "agent", "harness": harness, "session": session});
            if let Some(msg) = message {
                v["message"] = json!(msg);
            }
            if let Some(m) = machine(m) {
                v["machine"] = m;
            }
            v
        }
        Route::Workspace { machine: m, workspace } => {
            let mut v = json!({"kind": "workspace", "workspace": workspace});
            if let Some(m) = machine(m) {
                v["machine"] = m;
            }
            v
        }
    }
}

/// Every vector of the shared file: the route, the refusal's code, and the canonical path, which
/// reads back to the same route.
#[test]
fn the_shared_vectors_read_the_same_here() {
    let file: Value = serde_json::from_str(VECTORS).unwrap();
    let vectors = file["vectors"].as_array().unwrap();
    assert!(vectors.len() > 20);
    for v in vectors {
        let name = v["name"].as_str().unwrap();
        let address = v["address"].as_str().unwrap();
        let got = parse(address);
        match (&v["route"], &v["error"], got) {
            (want @ Value::Object(_), Value::Null, Ok(route)) => {
                assert_eq!(&as_json(&route), want, "{name}: {address}");
                if let Some(path) = v["path"].as_str() {
                    assert_eq!(route.path().as_deref(), Some(path), "{name}: path");
                }
                if let Some(path) = route.path() {
                    assert_eq!(parse(&path), Ok(route.clone()), "{name}: {path} reads back");
                }
            }
            (Value::Null, Value::String(code), Err(e)) => {
                assert_eq!(e.code(), code, "{name}: {address}");
            }
            (_, _, got) => panic!("{name}: {address} read as {got:?}"),
        }
    }
}

#[test]
fn a_route_never_carries_anything_but_its_address_and_message() {
    let route = parse("/m/my-vm/agent/claude/s1?prompt=hi&run=1&approve=all").unwrap();
    assert_eq!(
        route,
        Route::Agent {
            machine: Some(Machine::Name("my-vm".into())),
            harness: "claude".into(),
            session: "s1".into(),
            message: None,
        }
    );
    assert_eq!(route.path().as_deref(), Some("/m/my-vm/agent/claude/s1"));
}

#[test]
fn an_address_too_long_or_with_spaces_is_no_route() {
    let long = format!("/m/my-vm/agent/claude/{}", "s".repeat(4096));
    assert_eq!(parse(&long), Err(RouteError::NotARoute));
    assert_eq!(
        parse("  /m/my-vm/agent/claude/s1  ").map(|r| r.path()),
        Ok(Some("/m/my-vm/agent/claude/s1".into()))
    );
    assert_eq!(parse(""), Err(RouteError::NotARoute));
    assert_eq!(RouteError::Link("x".into()).to_string(), "x");
}
