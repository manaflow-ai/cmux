use super::*;
use std::collections::BTreeSet;

/// A read op and its scope from the generated table, so the test follows
/// the catalog instead of naming an op that may be renamed.
fn some_scoped_read() -> (String, String) {
    let table = ScopeTable::get();
    for op in table.known_ops() {
        for scope in ["workspace:read", "document:read", "terminal:read"] {
            let grant = Grant { scopes: BTreeSet::from([scope.to_string()]), ..Grant::default() };
            if matches!(table.check(&op, &Value::Null, &grant), Decision::Allow(OpClass::Read))
                && matches!(
                    table.check(&op, &Value::Null, &Grant::default()),
                    Decision::ScopeMissing(_)
                )
            {
                return (op, scope.to_string());
            }
        }
    }
    panic!("the catalog has no scoped read op");
}

fn bridge(scopes: &[&str]) -> PageBridge {
    PageBridge::new(Grant {
        scopes: scopes.iter().map(|s| (*s).to_string()).collect(),
        ..Grant::default()
    })
}

fn call(id: &str, op: &str) -> String {
    json!({ "id": id, "op": op, "params": {} }).to_string()
}

#[test]
fn a_granted_op_is_admitted_with_its_id() {
    let (op, scope) = some_scoped_read();
    let mut page = bridge(&[&scope]);
    let admitted = page.admit(&call("c1", &op), Instant::now()).expect("admitted");
    assert_eq!((admitted.id.as_str(), admitted.op.as_str()), ("c1", op.as_str()));
    assert_eq!(admitted.class, OpClass::Read);
}

#[test]
fn an_op_outside_the_granted_scopes_is_scope_missing() {
    let (op, _) = some_scoped_read();
    let mut page = bridge(&[]);
    let refused = page.admit(&call("c1", &op), Instant::now()).unwrap_err();
    assert_eq!(refused.code, "scope.missing");
    assert_eq!(refused.id.as_deref(), Some("c1"));
    assert!(!page.allowed_ops().contains(&op), "the page must not even see {op}");
}

#[test]
fn the_page_sees_exactly_the_ops_its_grant_allows() {
    let (op, scope) = some_scoped_read();
    let page = bridge(&[&scope]);
    let grant = Grant { scopes: BTreeSet::from([scope]), ..Grant::default() };
    assert_eq!(page.allowed_ops(), ScopeTable::get().allowed_ops(&grant));
    assert!(page.allowed_ops().contains(&op));
}

#[test]
fn an_unknown_op_is_unsupported() {
    let mut page = bridge(&["workspace:read"]);
    let refused = page.admit(&call("c1", "no.such.op"), Instant::now()).unwrap_err();
    assert_eq!(refused.code, "operation.unsupported");
}

#[test]
fn the_201st_call_in_one_second_is_rate_limited() {
    let (op, scope) = some_scoped_read();
    let mut page = bridge(&[&scope]);
    let start = Instant::now();
    for i in 0..MAX_CALLS_PER_SECOND {
        // Spread over the second, all inside it.
        let at = start + Duration::from_millis(i as u64 * 4);
        page.admit(&call(&format!("c{i}"), &op), at).expect("within budget");
    }
    let refused = page.admit(&call("c200", &op), start + Duration::from_millis(999)).unwrap_err();
    assert_eq!(refused.code, "rate.limited");
    assert_eq!(refused.id.as_deref(), Some("c200"));
    assert!(refused.retryable);
    assert_eq!(page.rate_limited_count(), 1);
    assert_eq!(refused.to_answer()["error"]["code"], "rate.limited");
    // A second after the first call, its slot is free again.
    page.admit(&call("c201", &op), start + Duration::from_secs(1)).expect("slot freed");
}

#[test]
fn junk_spends_budget_too() {
    let mut page = bridge(&[]);
    let now = Instant::now();
    for _ in 0..MAX_CALLS_PER_SECOND {
        assert_eq!(page.admit("not json", now).unwrap_err().code, "bridge.bad_message");
    }
    assert_eq!(page.admit("not json", now).unwrap_err().code, "rate.limited");
}

#[test]
fn a_257_kib_message_is_refused_before_it_is_parsed() {
    let (op, scope) = some_scoped_read();
    let mut page = bridge(&[&scope]);
    let pad = "x".repeat(257 * 1024);
    let raw = json!({ "id": "big", "op": op, "params": { "pad": pad } }).to_string();
    let refused = page.admit(&raw, Instant::now()).unwrap_err();
    assert_eq!(refused.code, "bridge.message_too_large");
    // Refused before it spent rate budget or was parsed (no id echoed).
    assert_eq!(refused.id, None);
    // Exactly the limit still passes the size check.
    let mut exact = json!({ "id": "ok", "op": op, "params": { "pad": "" } }).to_string();
    let fill = MAX_MESSAGE_BYTES - exact.len();
    exact = json!({ "id": "ok", "op": op, "params": { "pad": "y".repeat(fill) } }).to_string();
    assert_eq!(exact.len(), MAX_MESSAGE_BYTES);
    page.admit(&exact, Instant::now()).expect("256 KiB exactly is allowed");
}

#[test]
fn a_call_without_an_id_is_refused_there_is_no_sync_form() {
    let (op, scope) = some_scoped_read();
    let mut page = bridge(&[&scope]);
    let raw = json!({ "op": op }).to_string();
    assert_eq!(page.admit(&raw, Instant::now()).unwrap_err().code, "bridge.bad_message");
}

#[test]
fn a_revoked_grant_admits_nothing() {
    let (op, scope) = some_scoped_read();
    let mut page = bridge(&[&scope]);
    page.set_grant(Grant { revoked: true, ..Grant::default() });
    assert_eq!(page.admit(&call("c", &op), Instant::now()).unwrap_err().code, "scope.missing");
    assert!(page.allowed_ops().is_empty());
}
