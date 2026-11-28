use super::*;

fn words(s: &str) -> Vec<String> {
    s.split(' ').map(str::to_owned).collect()
}

#[test]
fn parses_the_spec_line() {
    let ask = parse(&words("--vcpu 64 --mem 128G --fanout 2 --for build --until 2h")).unwrap();
    assert_eq!(
        Value::Object(ask.0),
        json!({"vcpu": 64, "mem_gib": 128, "fanout": 2, "for": "build", "until": "2h"})
    );
    let ask = parse(&words("--vcpu=8 --kind GPU --for=train")).unwrap();
    assert_eq!(ask.0["kind"], "gpu");
}

#[test]
fn needs_vcpu_and_for() {
    assert!(parse(&words("--for x")).unwrap_err().contains("--vcpu"));
    assert!(parse(&words("--vcpu 4")).unwrap_err().contains("--for"));
    assert!(parse(&words("--vcpu 0 --for x")).is_err());
    assert!(parse(&words("--vcpu 4 --for x --kind tpu")).is_err());
}

#[test]
fn prints_and_exits_by_outcome() {
    let reply =
        json!({"ok": true, "outcome": "grow", "message": "Growing to xl", "machine": "vm_1"});
    let mut out = Vec::new();
    assert_eq!(print(&reply, OutputMode::Human, &mut out), 0);
    assert_eq!(String::from_utf8(out).unwrap(), "grow: Growing to xl\n");
    let reply = json!({"ok": true, "outcome": "fanout", "message": "2 x 2xl", "machine": "vm_1"});
    let mut out = Vec::new();
    assert_eq!(print(&reply, OutputMode::Json, &mut out), 3);
    let printed: Value = serde_json::from_slice(&out).unwrap();
    assert_eq!(printed, json!({"outcome": "fanout", "message": "2 x 2xl", "machine": "vm_1"}));
}
