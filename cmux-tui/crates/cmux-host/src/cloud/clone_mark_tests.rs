use super::super::client::MemoryStore;
use super::*;

use super::super::wire::Env;

const A: &str = "vm_00000000000000000001";
const B: &str = "vm_00000000000000000002";

fn bind(machine: &str) -> String {
    serde_json::json!({
        "team": "team_00000000000000000001", "machine": machine,
        "bind_token": "bt_vector_one_time_token_000000000000000000",
        "env": "dev", "api_origin": Env::Dev.api_origin(),
    })
    .to_string()
}

fn bound(machine: &str) -> String {
    serde_json::to_string(&Bound {
        machine: machine.into(),
        team: "team_00000000000000000001".into(),
        host: "host_00000000000000000001".into(),
        epoch: 1,
        install: "inst_00000000000000000001".into(),
        user: "user_00000000000000000001".into(),
        grant: "grant_00000000000000000001".into(),
        env: Env::Dev,
        api_origin: Env::Dev.api_origin().into(),
        keyset: serde_json::Value::Null,
        bound_at: 1,
    })
    .unwrap()
}

fn store(files: &[(&str, String)]) -> MemoryStore {
    let mut store = MemoryStore::default();
    for (file, text) in files {
        store.write(file, text, 0o600).unwrap();
    }
    store
}

#[test]
fn a_bind_for_another_machine_is_a_copy() {
    let s = store(&[(BOUND_FILE, bound(A)), (BIND_FILE, bind(B))]);
    let copied = copied(&s).unwrap();
    assert_eq!(copied, Copied { from: A.into(), to: B.into() });
    let text: serde_json::Value = serde_json::from_str(&marker_text(&copied)).unwrap();
    assert_eq!(text, serde_json::json!({"from": A, "to": B}));
}

#[test]
fn the_same_machine_a_fresh_one_or_no_bind_is_no_copy() {
    assert_eq!(copied(&store(&[(BOUND_FILE, bound(A)), (BIND_FILE, bind(A))])), None);
    assert_eq!(copied(&store(&[(BIND_FILE, bind(A))])), None);
    assert_eq!(copied(&store(&[(BOUND_FILE, bound(A))])), None);
    // A bind file that does not parse is no evidence either way.
    assert_eq!(copied(&store(&[(BOUND_FILE, bound(A)), (BIND_FILE, "{}".to_owned())])), None);
}
