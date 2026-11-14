use super::*;

#[test]
fn the_embedded_table_loads() {
    assert_eq!(Capabilities::load_error(), None);
    let table = Capabilities::get();
    assert!(!table.api_version.is_empty());
    assert!(table.op("workspace.list").is_some());
}

/// The two tables agree: every scope an op needs is decided by one rule
/// of scope-classes.json (not by which of two generic rules comes first),
/// and every rule classifies an op scope or says what else it gates.
#[test]
fn every_op_scope_has_one_deciding_rule_and_every_rule_is_used() {
    let problems = cross_check(Capabilities::get(), SCOPE_CLASSES);
    assert!(
        problems.is_empty(),
        "scopes.json and scope-classes.json disagree:\n{}",
        problems.join("\n")
    );
}

#[test]
fn templates_and_ungated_scopes_are_typed() {
    let table = Capabilities::get();
    let fetch = table.op("net.fetch").expect("net.fetch");
    assert_eq!(fetch.scope, OpScope::NetHost);
    assert!(fetch.scope.external());
    assert_eq!(fetch.risk().map(|i| i.class), Some(ScopeClass::Sensitive));
    let toast = table.op("toast.show").expect("toast.show");
    assert_eq!(toast.scope, OpScope::Ungated);
    assert_eq!(toast.risk(), None);
    assert_eq!(
        table.op("integration.request").map(|op| op.scope.clone()),
        Some(OpScope::IntegrationProvider)
    );
}

#[test]
fn a_row_says_scope_class_risk_consent_gesture_and_escalation() {
    let table = Capabilities::get();
    let row = table.describe("workspace.create").expect("workspace.create");
    assert_eq!(row["scope"], "workspace:write");
    assert_eq!(row["class"], "mutation");
    assert_eq!(row["risk"], "sensitive");
    assert_eq!(row["escalation"]["scope"], "workspace:execute");
    assert!(row["consent"].as_str().is_some_and(|t| !t.is_empty()));
    assert_eq!(table.describe("tab.focus").expect("tab.focus")["gesture"], true);
    let never = table.never().next().expect("a never op");
    assert_eq!(table.describe(never).expect("never row")["never"], true);
    assert_eq!(table.describe("made.up"), None);
}

#[test]
fn the_manifest_carries_the_types_and_version() {
    let table = Capabilities::get();
    let manifest = table.manifest_json(None).expect("manifest");
    assert_eq!(manifest["apiVersion"], table.api_version.as_str());
    assert_eq!(manifest["types"], APP_TYPES);
    assert_eq!(manifest["ops"].as_array().map(Vec::len), Some(table.ops().count()),);
    assert_eq!(manifest["typesDigest"], types_digest());
    assert_eq!(types_digest().len(), 64);
    assert_eq!(table.summary_json()["typesDigest"], types_digest());
    let one = table.manifest_json(Some("workspace.list")).expect("one op");
    assert_eq!(one["ops"][0]["op"], "workspace.list");
    assert!(one.get("types").is_none());
}

#[test]
fn cross_check_flags_unclassified_scopes_order_decided_scopes_and_dead_rules() {
    let ops = Capabilities::parse(
        r#"{"apiVersion":"1","ops":{
                "a.list":{"scope":"a:read","class":"read"},
                "b.go":{"scope":"zz:fly","class":"mutation"},
                "c.list":{"scope":"integration:read","class":"read"}}}"#,
    )
    .expect("ops");
    let classes = r#"{"rules":[
            {"pattern":"^[a-z]+:read$","class":"standard"},
            {"pattern":"^integration:[a-z]+$","class":"sensitive"},
            {"pattern":"^dead:thing$","class":"restricted"},
            {"pattern":"^spawn:thing$","class":"restricted","gates":"a server's spawn"}]}"#;
    let problems = cross_check(&ops, classes);
    assert_eq!(problems.len(), 4, "{problems:#?}");
    assert!(problems[0].contains("integration:read matches 2 rules"), "{problems:#?}");
    assert!(problems[1].contains("zz:fly matches no rule"), "{problems:#?}");
    // The provider rule only ever lost to the generic one: unused.
    assert!(problems[2].contains("^integration:[a-z]+$"), "{problems:#?}");
    assert!(problems[3].contains("^dead:thing$"), "{problems:#?}");
    // A literal exception first is the fix: it decides, nothing is order-decided.
    let fixed = classes.replace(
        r#"[
            {"pattern":"^[a-z]+:read$""#,
        r#"[
            {"pattern":"^integration:read$","class":"standard"},
            {"pattern":"^[a-z]+:read$""#,
    );
    let problems = cross_check(&ops, &fixed);
    assert!(problems.iter().all(|p| !p.contains("integration:read matches")), "{problems:#?}");
}
