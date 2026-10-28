//! Each rule has a fixture the check refuses and one it accepts, on both
//! schema files. The v2 fixture is cut from the real
//! `spec/resource-operations-v2.json`, plus the wire attributes its JSON
//! Schema declares.

use std::collections::{BTreeMap, BTreeSet};

use cmux_api_compat::wire::{
    LEDGER_FILE, RESOURCE_OPERATIONS, SDK_SCHEMA, WireIds, WireLedgers, WireProblem, WireRule,
    check_against_base, check_all, ids_from_resource_operations, ids_from_sdk_schema,
};
use serde_json::{Value, json};

fn spec(name: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec").join(name);
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

fn uint16() -> Value {
    json!({"kind": "scalar", "name": "uint16"})
}

/// A v12 IR with the `tabs` command family (0x02), two commands in it, and
/// one event in the `tab-events` family (0xC0). The binary request type has
/// a field named `description`.
fn sdk() -> Value {
    json!({
        "families": {
            "tabs": {"id": 2, "description": "Tabs.", "next_ordinal": 3},
            "tab-events": {"id": 0xC0, "description": "Tab events.", "next_ordinal": 2}
        },
        "types": {"Size": {"kind": "object", "additional_properties": false, "fields": {
            "cols": {"type": uint16(), "presence": "required", "nullable": false},
            "description": {"type": {"kind": "scalar", "name": "string"}, "presence": "required",
                            "nullable": false, "max_bytes": 64}
        }}},
        "commands": {
            "new-tab": {"method_id": 0x0201, "priority": "control", "durability": "memory",
                        "request": {"kind": "object", "fields": {}}},
            "resize-attached-view": {
                "method_id": 0x0202, "priority": "input", "durability": "memory",
                "payload": "binary", "layout_version": 1,
                "request": {"kind": "ref", "name": "Size"}}
        },
        "events": {"tab-moved": {"event_id": 0xC001, "priority": "control",
                                 "payload": {"kind": "object", "fields": {}}}}
    })
}

/// The real v2 catalog cut to `agent.list` and `agent.report` (family
/// `agent`, 0x60) and its one local operation, `sidebar_plugin.install`,
/// which has no frame id.
fn operations() -> Value {
    let mut ops = spec(RESOURCE_OPERATIONS);
    let mut list = ops["operations"]["agent.list"].clone();
    list["method_id"] = json!(0x6000);
    list["priority"] = json!("control");
    let mut report = ops["operations"]["agent.report"].clone();
    report["method_id"] = json!(0x6001);
    report["priority"] = json!("control");
    let install = ops["local_operations"]["sidebar_plugin.install"].clone();
    ops["families"] = json!({
        "agent": {"id": 0x60, "description": "Agent sessions.", "next_ordinal": 2}
    });
    ops["operations"] = json!({"agent.list": list, "agent.report": report});
    ops["local_operations"] = json!({"sidebar_plugin.install": install});
    ops
}

fn files(sdk: &Value, operations: &Value) -> BTreeMap<String, WireIds> {
    BTreeMap::from([
        (SDK_SCHEMA.to_owned(), ids_from_sdk_schema(sdk).unwrap()),
        (RESOURCE_OPERATIONS.to_owned(), ids_from_resource_operations(operations).unwrap()),
    ])
}

/// The ledger file after `--write` recorded the base fixtures.
fn recorded() -> WireLedgers {
    let ledgers = check_all(&WireLedgers::default(), &files(&sdk(), &operations())).ledgers;
    ledgers.validate().unwrap();
    ledgers
}

fn named(problems: &[(String, WireProblem)]) -> Vec<(String, WireRule)> {
    problems.iter().map(|(file, p)| (format!("{file}:{}", p.name), p.rule)).collect()
}

fn rules(compat: &WireLedgers, sdk: &Value, operations: &Value) -> Vec<(String, WireRule)> {
    named(&check_all(compat, &files(sdk, operations)).problems)
}

fn sdk_rule(name: &str, rule: WireRule) -> Vec<(String, WireRule)> {
    vec![(format!("{SDK_SCHEMA}:{name}"), rule)]
}

fn ops_rule(name: &str, rule: WireRule) -> Vec<(String, WireRule)> {
    vec![(format!("{RESOURCE_OPERATIONS}:{name}"), rule)]
}

#[test]
fn api_compat_wire_first_record_and_unchanged_schema_pass() {
    let compat = WireLedgers::default();
    let report = check_all(&compat, &files(&sdk(), &operations()));
    assert!(report.problems.is_empty(), "{:?}", report.problems);
    assert!(report.is_stale(&compat), "new ids must be written to the ledger");
    let ledger = &report.ledgers.files[SDK_SCHEMA];
    assert_eq!(ledger.methods["resize-attached-view"].id, 0x0202);
    assert_eq!(ledger.families["tab-events"].id, 0xC0);
    assert_eq!(report.ledgers.files[RESOURCE_OPERATIONS].methods.len(), 2);

    let compat = recorded();
    let again = check_all(&compat, &files(&sdk(), &operations()));
    assert!(again.problems.is_empty() && !again.is_stale(&compat));
}

#[test]
fn api_compat_wire_ledger_survives_a_json_round_trip() {
    let compat = recorded();
    let bytes = serde_json::to_vec(&compat).unwrap();
    assert_eq!(WireLedgers::from_json(&bytes).unwrap(), compat);
}

#[test]
fn api_compat_wire_reads_only_the_validated_shape() {
    // Ids are integers, as ipc_meta.py and the v2 JSON Schema require.
    let mut bad = sdk();
    bad["commands"]["new-tab"]["method_id"] = json!("0x0201");
    assert!(ids_from_sdk_schema(&bad).is_err());
    let mut bad = sdk();
    bad["families"]["tabs"] = json!(2);
    assert!(ids_from_sdk_schema(&bad).is_err());
    let mut bad = operations();
    bad["operations"]["agent.list"]["payload"] = json!({"kind": "binary", "layout_version": 1});
    assert!(ids_from_resource_operations(&bad).is_err());
    let mut bad = operations();
    bad["operations"]["agent.list"]["layout_version"] = json!(1);
    assert!(ids_from_resource_operations(&bad).is_err(), "layout_version needs payload binary");
    // A local operation runs in the app and has no frame id.
    let mut bad = operations();
    bad["local_operations"]["sidebar_plugin.install"]["method_id"] = json!(0x6002);
    assert!(ids_from_resource_operations(&bad).is_err());
}

const WIRE_KEYS: [&str; 5] =
    ["method_id", "priority", "priority_changed_reason", "payload", "layout_version"];

/// The v2 fixture uses only keys the catalog's JSON Schema declares, so the
/// reader's format is the validated contract (`check-resource-api-boundary.py`
/// and its tests check the catalog against the same schema).
#[test]
fn api_compat_wire_resource_operation_fixture_fits_its_json_schema() {
    let schema = spec("resource-operations-v2.schema.json");
    let keys = |value: &Value| -> BTreeSet<String> {
        value.as_object().unwrap().keys().cloned().collect()
    };
    let declared = |pointer: &str| keys(schema.pointer(pointer).unwrap());
    let mut ops = operations();
    let list = &mut ops["operations"]["agent.list"];
    list["payload"] = json!("binary");
    list["layout_version"] = json!(1);
    list["priority_changed_reason"] = json!("reason");
    assert!(keys(&ops).is_subset(&declared("/properties")));
    let family = declared("/$defs/family/properties");
    assert!(ops["families"].as_object().unwrap().values().all(|f| keys(f).is_subset(&family)));
    let transported = declared("/$defs/transportedOperation/properties");
    assert!(WIRE_KEYS.iter().all(|key| transported.contains(*key)), "{transported:?}");
    for operation in ops["operations"].as_object().unwrap().values() {
        assert!(keys(operation).is_subset(&transported), "{:?}", keys(operation));
    }
    let local = declared("/$defs/localOperation/properties");
    assert!(WIRE_KEYS.iter().all(|key| !local.contains(*key)), "{local:?}");
    for operation in ops["local_operations"].as_object().unwrap().values() {
        assert!(keys(operation).is_subset(&local), "{:?}", keys(operation));
    }
    let byte = schema.pointer("/$defs/familyByte").unwrap();
    assert_eq!((byte["minimum"].as_u64(), byte["maximum"].as_u64()), (Some(0x60), Some(0xBF)));
}

#[test]
fn api_compat_wire_reused_id_is_refused() {
    let compat = recorded();
    // A new command takes the id of an existing one.
    let mut bad = sdk();
    bad["commands"]["close-tab"] = json!({"method_id": 0x0201, "priority": "control"});
    assert_eq!(
        rules(&compat, &bad, &operations()),
        sdk_rule("close-tab", WireRule::ReusedId),
        "only the new name is blamed, never the recorded owner"
    );
    // Two new commands share one fresh id: the second is refused.
    let mut bad = sdk();
    bad["commands"]["a-tab"] = json!({"method_id": 0x0209, "priority": "control"});
    bad["commands"]["b-tab"] = json!({"method_id": 0x0209, "priority": "control"});
    assert_eq!(rules(&compat, &bad, &operations()), sdk_rule("b-tab", WireRule::ReusedId));
    // A new event takes the id of a tombstoned event.
    let mut tomb = compat.clone();
    let ledger = tomb.files.get_mut(SDK_SCHEMA).unwrap();
    ledger.events.get_mut("tab-moved").unwrap().removed = Some("merged".into());
    let mut gone = sdk();
    gone["events"] = json!({"tab-reordered": {"event_id": 0xC001}});
    assert_eq!(rules(&tomb, &gone, &operations()), sdk_rule("tab-reordered", WireRule::ReusedId));
    // A v2 operation takes a v2 id already given out.
    let mut ops = operations();
    ops["operations"]["agent.get"] = json!({"method_id": 0x6001});
    assert_eq!(rules(&compat, &sdk(), &ops), ops_rule("agent.get", WireRule::ReusedId));
    // A fresh id passes.
    let mut good = sdk();
    good["commands"]["close-tab"] = json!({"method_id": 0x0203, "priority": "control"});
    assert_eq!(rules(&compat, &good, &operations()), vec![]);
}

#[test]
fn api_compat_wire_ids_are_unique_across_both_files() {
    let compat = recorded();
    // A v2 family that takes the byte of the v12 `tabs` family.
    let mut ops = operations();
    ops["families"]["tabs-v2"] = json!({"id": 2, "description": "Tabs."});
    let found = rules(&compat, &sdk(), &ops);
    let name = format!("{RESOURCE_OPERATIONS}:tabs-v2");
    assert!(found.contains(&(name.clone(), WireRule::ReusedId)), "{found:?}");
    assert!(found.contains(&(name, WireRule::OutOfRange)), "{found:?}");
    // A v2 operation that takes the frame id of a v12 command.
    let mut ops = operations();
    ops["operations"]["agent.get"] = json!({"method_id": 0x0201});
    let found = rules(&compat, &sdk(), &ops);
    let name = format!("{RESOURCE_OPERATIONS}:agent.get");
    assert!(found.contains(&(name.clone(), WireRule::ReusedId)), "{found:?}");
    assert!(found.contains(&(name, WireRule::OutOfRange)), "{found:?}");
    // A ledger with one family byte in both files is invalid.
    let mut clash = compat.clone();
    let tabs = clash.files[SDK_SCHEMA].families["tabs"].clone();
    clash.files.get_mut(RESOURCE_OPERATIONS).unwrap().families.insert("tabs".into(), tabs);
    assert!(clash.validate().is_err());
    // New families and ids in their own files' ranges pass.
    let mut ops = operations();
    ops["families"]["workspace"] = json!({"id": 0x62, "description": "Workspaces."});
    ops["operations"]["agent.get"] = json!({"method_id": 0x6200});
    let mut good = sdk();
    good["families"]["panes"] = json!({"id": 3, "description": "Panes."});
    good["commands"]["split"] = json!({"method_id": 0x0300, "priority": "control"});
    assert_eq!(rules(&compat, &good, &ops), vec![]);
}

#[test]
fn api_compat_wire_ids_stay_in_their_files_range() {
    let compat = recorded();
    // A v12 family in the v2 range.
    let mut bad = sdk();
    bad["families"]["panes"] = json!({"id": 0x70, "description": "Panes."});
    assert_eq!(rules(&compat, &bad, &operations()), sdk_rule("panes", WireRule::OutOfRange));
    // A v2 family outside the v2 range.
    let mut ops = operations();
    ops["families"]["workspace"] = json!({"id": 0x30, "description": "Workspaces."});
    assert_eq!(rules(&compat, &sdk(), &ops), ops_rule("workspace", WireRule::OutOfRange));
    // An event id in a command family.
    let mut bad = sdk();
    bad["events"]["tab-closed"] = json!({"event_id": 0x0205});
    assert_eq!(rules(&compat, &bad, &operations()), sdk_rule("tab-closed", WireRule::OutOfRange));
    // An operation id in the v2 range but in no declared family.
    let mut ops = operations();
    ops["operations"]["agent.get"] = json!({"method_id": 0x6300});
    assert_eq!(rules(&compat, &sdk(), &ops), ops_rule("agent.get", WireRule::OutOfRange));
}

#[test]
fn api_compat_wire_renumbered_id_is_refused() {
    let compat = recorded();
    let mut bad = sdk();
    bad["commands"]["new-tab"]["method_id"] = json!(0x0205);
    assert_eq!(rules(&compat, &bad, &operations()), sdk_rule("new-tab", WireRule::Renumbered));
    let mut bad = sdk();
    bad["events"]["tab-moved"]["event_id"] = json!(0xC002);
    assert_eq!(rules(&compat, &bad, &operations()), sdk_rule("tab-moved", WireRule::Renumbered));
    let mut ops = operations();
    ops["operations"]["agent.list"]["method_id"] = json!(0x6002);
    assert_eq!(rules(&compat, &sdk(), &ops), ops_rule("agent.list", WireRule::Renumbered));
    // The same ids pass.
    assert_eq!(rules(&compat, &sdk(), &operations()), vec![]);
}

#[test]
fn api_compat_wire_removal_needs_a_tombstone() {
    let compat = recorded();
    let mut bad = sdk();
    bad["commands"].as_object_mut().unwrap().remove("new-tab");
    let report = check_all(&compat, &files(&bad, &operations()));
    assert_eq!(named(&report.problems), sdk_rule("new-tab", WireRule::RemovedWithoutTombstone));
    let why = &report.problems[0].1.why;
    assert!(why.contains(&format!("spec/{LEDGER_FILE}")), "{why}");
    assert_eq!(LEDGER_FILE, "api-compat.wire.json");
    let mut ops = operations();
    ops["operations"].as_object_mut().unwrap().remove("agent.report");
    assert_eq!(
        rules(&compat, &sdk(), &ops),
        ops_rule("agent.report", WireRule::RemovedWithoutTombstone)
    );
    // With a tombstone the removal passes, and the name stays retired.
    let mut tomb = compat;
    let ledger = tomb.files.get_mut(SDK_SCHEMA).unwrap();
    ledger.methods.get_mut("new-tab").unwrap().removed = Some("replaced by tab.create".into());
    tomb.validate().unwrap();
    assert_eq!(rules(&tomb, &bad, &operations()), vec![]);
    assert_eq!(rules(&tomb, &sdk(), &operations()), sdk_rule("new-tab", WireRule::Resurrected));
    // An empty reason is not a tombstone.
    let ledger = tomb.files.get_mut(SDK_SCHEMA).unwrap();
    ledger.methods.get_mut("new-tab").unwrap().removed = Some(" ".into());
    assert!(tomb.validate().is_err());
}

#[test]
fn api_compat_wire_family_renumber_is_refused() {
    let compat = recorded();
    // Moving a family moves its ids too: every member is renumbered.
    let mut bad = sdk();
    bad["families"]["tabs"]["id"] = json!(3);
    bad["commands"]["new-tab"]["method_id"] = json!(0x0301);
    bad["commands"]["resize-attached-view"]["method_id"] = json!(0x0302);
    let found = rules(&compat, &bad, &operations());
    assert_eq!(found[0], (format!("{SDK_SCHEMA}:tabs"), WireRule::Renumbered), "{found:?}");
    assert_eq!(found.len(), 3, "{found:?}");
    // Giving a new family the byte of an existing one is a reuse.
    let mut bad = sdk();
    bad["families"]["panes"] = json!({"id": 2});
    assert_eq!(rules(&compat, &bad, &operations()), sdk_rule("panes", WireRule::ReusedId));
    // Dropping a family needs a tombstone.
    let mut ops = operations();
    ops["families"].as_object_mut().unwrap().remove("agent");
    ops["operations"] = json!({});
    let found = rules(&compat, &sdk(), &ops);
    assert!(found.contains(&ops_rule("agent", WireRule::RemovedWithoutTombstone)[0]), "{found:?}");
    // Appending a family passes.
    let mut good = sdk();
    good["families"]["panes"] = json!({"id": 4});
    assert_eq!(rules(&compat, &good, &operations()), vec![]);
}

#[test]
fn api_compat_wire_priority_change_needs_a_reason() {
    let compat = recorded();
    let mut bad = sdk();
    bad["commands"]["new-tab"]["priority"] = json!("bulk");
    assert_eq!(
        rules(&compat, &bad, &operations()),
        sdk_rule("new-tab", WireRule::PriorityWithoutReason)
    );
    let mut ops = operations();
    ops["operations"]["agent.list"]["priority"] = json!("background");
    assert_eq!(
        rules(&compat, &sdk(), &ops),
        ops_rule("agent.list", WireRule::PriorityWithoutReason)
    );
    // With a reason it passes and the ledger records both.
    let mut good = sdk();
    good["commands"]["new-tab"]["priority"] = json!("bulk");
    good["commands"]["new-tab"]["priority_changed_reason"] =
        json!("new-tab replies after the shell spawns");
    let report = check_all(&compat, &files(&good, &operations()));
    assert!(report.problems.is_empty(), "{:?}", report.problems);
    let next = report.ledgers;
    let record = &next.files[SDK_SCHEMA].methods["new-tab"];
    assert_eq!(record.priority.as_deref(), Some("bulk"));
    // A second change cannot ride on the first change's reason.
    good["commands"]["new-tab"]["priority"] = json!("input");
    assert_eq!(
        rules(&next, &good, &operations()),
        sdk_rule("new-tab", WireRule::PriorityWithoutReason)
    );
    good["commands"]["new-tab"]["priority_changed_reason"] = json!("typed from the palette");
    assert_eq!(rules(&next, &good, &operations()), vec![]);
}

#[test]
fn api_compat_wire_dropping_a_priority_keeps_the_recorded_one() {
    let compat = recorded();
    // An event that stops stating its priority passes: the IR has no place
    // for a reason without a priority.
    let mut quiet = sdk();
    quiet["events"]["tab-moved"].as_object_mut().unwrap().remove("priority");
    let report = check_all(&compat, &files(&quiet, &operations()));
    assert!(report.problems.is_empty(), "{:?}", report.problems);
    assert!(!report.is_stale(&compat), "the recorded priority stays");
    // Stating a different one again still needs a reason.
    quiet["events"]["tab-moved"]["priority"] = json!("bulk");
    assert_eq!(
        rules(&compat, &quiet, &operations()),
        sdk_rule("tab-moved", WireRule::PriorityWithoutReason)
    );
}

#[test]
fn api_compat_wire_binary_layout_change_needs_a_version_bump() {
    let compat = recorded();
    // Editing the referenced type changes the layout.
    let mut bad = sdk();
    bad["types"]["Size"]["fields"]["rows"] = json!({"type": uint16(), "presence": "required"});
    assert_eq!(
        rules(&compat, &bad, &operations()),
        sdk_rule("resize-attached-view", WireRule::LayoutWithoutVersionBump)
    );
    // Lowering the version is refused even with the same fields.
    let mut up = sdk();
    up["commands"]["resize-attached-view"]["layout_version"] = json!(3);
    let report = check_all(&compat, &files(&up, &operations()));
    assert!(report.problems.is_empty(), "{:?}", report.problems);
    up["commands"]["resize-attached-view"]["layout_version"] = json!(2);
    assert_eq!(
        rules(&report.ledgers, &up, &operations()),
        sdk_rule("resize-attached-view", WireRule::LayoutWithoutVersionBump)
    );
    // A binary payload without a version, or with version 0, cannot be read.
    let mut bad = sdk();
    bad["commands"]["resize-attached-view"].as_object_mut().unwrap().remove("layout_version");
    assert!(ids_from_sdk_schema(&bad).is_err());
    bad["commands"]["resize-attached-view"]["layout_version"] = json!(0);
    assert!(ids_from_sdk_schema(&bad).is_err());
    // A v2 operation that turns binary later records its first layout, and
    // then needs a bump as well.
    let mut ops = operations();
    ops["operations"]["agent.list"]["payload"] = json!("binary");
    ops["operations"]["agent.list"]["layout_version"] = json!(1);
    let report = check_all(&compat, &files(&sdk(), &ops));
    assert!(report.problems.is_empty(), "{:?}", report.problems);
    let next = report.ledgers;
    ops["operations"]["agent.list"]["result"] =
        json!({"kind": "array", "items": {"kind": "primitive", "name": "string"}});
    assert_eq!(
        rules(&next, &sdk(), &ops),
        ops_rule("agent.list", WireRule::LayoutWithoutVersionBump)
    );
    ops["operations"]["agent.list"]["layout_version"] = json!(2);
    assert_eq!(rules(&next, &sdk(), &ops), vec![]);
    // The same v12 change with a bump passes; a description edit needs none.
    let mut good = sdk();
    good["types"]["Size"]["fields"]["rows"] = json!({"type": uint16(), "presence": "required"});
    good["commands"]["resize-attached-view"]["layout_version"] = json!(2);
    assert_eq!(rules(&compat, &good, &operations()), vec![]);
    let mut docs = sdk();
    docs["types"]["Size"]["description"] = json!("columns of the attached view");
    docs["types"]["Size"]["fields"]["cols"]["description"] = json!("columns");
    assert_eq!(rules(&compat, &docs, &operations()), vec![]);
}

/// `description` and `constraints` are annotations on a type or field, but
/// in a `fields` map they are wire field names.
#[test]
fn api_compat_wire_fields_named_like_annotations_are_layout() {
    let compat = recorded();
    let refused = sdk_rule("resize-attached-view", WireRule::LayoutWithoutVersionBump);
    let mut bad = sdk();
    bad["types"]["Size"]["fields"]["description"]["type"] = uint16();
    assert_eq!(rules(&compat, &bad, &operations()), refused, "retyped `description` field");
    let mut bad = sdk();
    bad["types"]["Size"]["fields"].as_object_mut().unwrap().remove("description");
    assert_eq!(rules(&compat, &bad, &operations()), refused, "removed `description` field");
    let mut bad = sdk();
    bad["types"]["Size"]["fields"]["constraints"] =
        json!({"type": uint16(), "presence": "required", "nullable": false});
    assert_eq!(rules(&compat, &bad, &operations()), refused, "added `constraints` field");
    // A field default is data, not documentation.
    let mut bad = sdk();
    bad["types"]["Size"]["fields"]["cols"]["default"] = json!({"description": 1});
    let report = check_all(&compat, &files(&bad, &operations()));
    let mut worse = bad.clone();
    worse["types"]["Size"]["fields"]["cols"]["default"] = json!({"description": 2});
    let report = check_all(&report.ledgers, &files(&worse, &operations()));
    assert_eq!(named(&report.problems), refused, "changed default");

    // The same on a binary v2 operation, whose params gain a field named
    // `description` (workspace.update has one).
    let mut ops = operations();
    ops["operations"]["agent.list"]["payload"] = json!("binary");
    ops["operations"]["agent.list"]["layout_version"] = json!(1);
    let next = check_all(&compat, &files(&sdk(), &ops)).ledgers;
    let mut grown = ops.clone();
    grown["operations"]["agent.list"]["params"]["fields"]["description"] =
        json!({"required": false, "type": {"kind": "primitive", "name": "string"}});
    assert_eq!(
        rules(&next, &sdk(), &grown),
        ops_rule("agent.list", WireRule::LayoutWithoutVersionBump)
    );
    let mut documented = ops;
    documented["operations"]["agent.list"]["params"]["fields"]["state"]["description"] =
        json!("only agents in this state");
    assert_eq!(rules(&next, &sdk(), &documented), vec![]);
}

#[test]
fn api_compat_wire_ledger_refuses_one_id_for_two_names() {
    let mut compat = recorded();
    let ledger = compat.files.get_mut(SDK_SCHEMA).unwrap();
    let id = ledger.methods["new-tab"].clone();
    ledger.methods.insert("open-tab".into(), id);
    assert!(compat.validate().is_err());
}

/// A pull request cannot get past the rules by editing the ledger: they
/// start from the base branch's ledger.
#[test]
fn api_compat_wire_base_ledger_refuses_dropped_or_edited_entries() {
    let base = recorded();
    let edited = |head: &WireLedgers, sdk: &Value| {
        let report = check_against_base(&base, head, &files(sdk, &operations())).unwrap();
        assert!(report.is_stale(head), "--write puts the base entry back");
        (named(&report.problems), named(&report.edits))
    };
    // A command and its ledger entry deleted together.
    let mut gone = sdk();
    gone["commands"].as_object_mut().unwrap().remove("new-tab");
    let mut head = base.clone();
    head.files.get_mut(SDK_SCHEMA).unwrap().methods.remove("new-tab");
    assert!(check_all(&head, &files(&gone, &operations())).problems.is_empty(), "the bypass");
    let (problems, edits) = edited(&head, &gone);
    assert_eq!(problems, sdk_rule("new-tab", WireRule::RemovedWithoutTombstone));
    assert_eq!(edits, sdk_rule("new-tab", WireRule::LedgerEdited));
    // A renumbered command whose ledger id was edited to match.
    let mut moved = sdk();
    moved["commands"]["new-tab"]["method_id"] = json!(0x0203);
    let mut head = base.clone();
    head.files.get_mut(SDK_SCHEMA).unwrap().methods.get_mut("new-tab").unwrap().id = 0x0203;
    let (problems, edits) = edited(&head, &moved);
    assert_eq!(problems, sdk_rule("new-tab", WireRule::Renumbered));
    assert_eq!(edits, sdk_rule("new-tab", WireRule::LedgerEdited));
    // A priority change whose ledger priority was edited instead of giving a reason.
    let mut bulk = sdk();
    bulk["commands"]["new-tab"]["priority"] = json!("bulk");
    let mut head = base.clone();
    let record = head.files.get_mut(SDK_SCHEMA).unwrap().methods.get_mut("new-tab").unwrap();
    record.priority = Some("bulk".into());
    let (problems, edits) = edited(&head, &bulk);
    assert_eq!(problems, sdk_rule("new-tab", WireRule::PriorityWithoutReason));
    assert_eq!(edits, sdk_rule("new-tab", WireRule::LedgerEdited));
    // A base tombstone taken away by hand.
    let mut retired = base.clone();
    let record = retired.files.get_mut(SDK_SCHEMA).unwrap().methods.get_mut("new-tab").unwrap();
    record.removed = Some("replaced".into());
    let report = check_against_base(&retired, &base, &files(&sdk(), &operations())).unwrap();
    assert_eq!(named(&report.problems), sdk_rule("new-tab", WireRule::Resurrected));
    assert_eq!(named(&report.edits), sdk_rule("new-tab", WireRule::LedgerEdited));
}

#[test]
fn api_compat_wire_base_ledger_accepts_tombstones_and_written_changes() {
    let base = recorded();
    let clean = |head: &WireLedgers, sdk: &Value| {
        let report = check_against_base(&base, head, &files(sdk, &operations())).unwrap();
        assert!(report.problems.is_empty() && report.edits.is_empty(), "{report:?}");
        assert!(!report.is_stale(head));
    };
    // A tombstone added by hand.
    let mut gone = sdk();
    gone["commands"].as_object_mut().unwrap().remove("new-tab");
    let mut head = base.clone();
    let record = head.files.get_mut(SDK_SCHEMA).unwrap().methods.get_mut("new-tab").unwrap();
    record.removed = Some("replaced by tab.create".into());
    clean(&head, &gone);
    // A priority change with a reason, after --write recorded it.
    let mut bulk = sdk();
    bulk["commands"]["new-tab"]["priority"] = json!("bulk");
    bulk["commands"]["new-tab"]["priority_changed_reason"] = json!("replies after the spawn");
    let written = check_against_base(&base, &base, &files(&bulk, &operations())).unwrap();
    assert!(written.problems.is_empty() && written.edits.is_empty());
    clean(&written.ledgers, &bulk);
    // A new command, after --write appended it.
    let mut grown = sdk();
    grown["commands"]["close-tab"] = json!({"method_id": 0x0203, "priority": "control"});
    let written = check_against_base(&base, &base, &files(&grown, &operations())).unwrap();
    clean(&written.ledgers, &grown);
}

#[test]
fn api_compat_wire_real_spec_files_match_the_ledger() {
    let compat = WireLedgers::from_json(
        &std::fs::read(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec").join(LEDGER_FILE),
        )
        .unwrap(),
    )
    .unwrap();
    let report = check_all(&compat, &files(&spec(SDK_SCHEMA), &spec(RESOURCE_OPERATIONS)));
    assert!(report.problems.is_empty(), "{:?}", report.problems);
    assert!(!report.is_stale(&compat), "run api-compat-check --write");
}
