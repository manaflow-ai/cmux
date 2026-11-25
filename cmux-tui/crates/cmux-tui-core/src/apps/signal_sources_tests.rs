use super::*;

fn manifest(sources: Value) -> Value {
    json!({ "implements": { INTERFACE: { "options": { "sources": sources } } } })
}

fn tickets() -> Source {
    let m = manifest(json!({
        "open": {
            "docs": "Open tickets",
            "value": { "type": "object", "required": ["count"], "properties": { "count": { "type": "integer" } } },
            "pollFloorSeconds": 10,
            "staleAfterSeconds": 60
        }
    }));
    sources_of("acme/help-desk", &m).remove(0)
}

#[test]
fn a_source_is_named_and_scoped_by_its_apps_namespace() {
    let s = tickets();
    assert_eq!(s.name, "acme.help_desk.open");
    assert_eq!(s.scope, "acme.help_desk:read");
    assert_eq!(s.stream(), "acme.help_desk.open.changed");
    assert_eq!(s.floor, Duration::from_secs(10));
    assert_eq!(s.stale_after, Some(Duration::from_secs(60)));
    assert!(s.readable("acme/help-desk", &Grant::default()), "its own app reads it");
    assert!(!s.readable("other/app", &Grant::default()));
    let grant = Grant { scopes: ["acme.help_desk:read".to_string()].into(), ..Grant::default() };
    assert!(s.readable("other/app", &grant));
}

#[test]
fn entries_the_options_schema_refuses_are_not_sources() {
    let m = manifest(json!({
        "Bad": { "value": {}, "pollFloorSeconds": 5 },
        "nofloor": { "value": {} },
        "zero": { "value": {}, "pollFloorSeconds": 0 },
        "noschema": { "pollFloorSeconds": 5 },
        "ok": { "value": {}, "pollFloorSeconds": 5 }
    }));
    let names: Vec<String> = sources_of("local/spy", &m).into_iter().map(|s| s.name).collect();
    assert_eq!(names, ["local.spy.ok"]);
    assert!(sources_of("local/spy", &json!({})).is_empty());
}

#[test]
fn a_publish_is_checked_against_the_value_schema_and_size() {
    let s = tickets();
    let mut kept = SignalSources::default();
    let now = Instant::now();
    let err = kept.publish(&s, json!({ "count": "three" }), now, 1).unwrap_err();
    assert_eq!(err["code"], "validation.invalid");
    let err = kept
        .publish(&s, json!({ "count": 1, "pad": "x".repeat(MAX_VALUE_BYTES) }), now, 1)
        .unwrap_err();
    assert_eq!(err["code"], "app.limit");
    assert_eq!(kept.read(&s, now), json!({ "value": null, "updatedAt": null, "stale": false }));
}

#[test]
fn publishes_inside_the_floor_coalesce_into_one_tell_with_the_newest_value() {
    let s = tickets();
    let mut kept = SignalSources::default();
    let t0 = Instant::now();
    assert_eq!(kept.publish(&s, json!({ "count": 1 }), t0, 100).unwrap(), Tell::Now);
    let t1 = t0 + Duration::from_secs(3);
    assert_eq!(
        kept.publish(&s, json!({ "count": 2 }), t1, 103).unwrap(),
        Tell::After(Duration::from_secs(7))
    );
    // A per-frame publisher: every later publish rides the one scheduled tell.
    for n in 3..100 {
        assert_eq!(kept.publish(&s, json!({ "count": n }), t1, 104).unwrap(), Tell::Queued);
    }
    assert_eq!(kept.read(&s, t1)["value"], json!({ "count": 99 }), "a read always gets the newest");
    let t2 = t0 + Duration::from_secs(10);
    assert!(kept.due(&s.name, t2));
    assert!(!kept.due(&s.name, t2), "one tell per floor");
    // The floor restarts at the tell.
    let t3 = t2 + Duration::from_secs(4);
    assert_eq!(
        kept.publish(&s, json!({ "count": 100 }), t3, 114).unwrap(),
        Tell::After(Duration::from_secs(6))
    );
    let t4 = t2 + Duration::from_secs(11);
    assert!(kept.due(&s.name, t4));
    assert_eq!(
        kept.publish(&s, json!({ "count": 101 }), t4 + Duration::from_secs(10), 125).unwrap(),
        Tell::Now
    );
}

#[test]
fn a_value_older_than_stale_after_reads_stale_and_an_uninstall_forgets_it() {
    let s = tickets();
    let mut kept = SignalSources::default();
    let t0 = Instant::now();
    kept.publish(&s, json!({ "count": 4 }), t0, 500).unwrap();
    assert_eq!(
        kept.read(&s, t0),
        json!({ "value": { "count": 4 }, "updatedAt": 500, "stale": false })
    );
    assert_eq!(kept.read(&s, t0 + Duration::from_secs(60))["stale"], true);
    kept.forget_app("other/app");
    assert_eq!(kept.read(&s, t0)["updatedAt"], 500);
    kept.forget_app("acme/help-desk");
    assert_eq!(kept.read(&s, t0)["value"], Value::Null);
}

#[test]
fn a_value_schema_that_does_not_compile_refuses_publishes() {
    let mut s = tickets();
    s.value = json!({ "type": 12 });
    let err = SignalSources::default().publish(&s, json!({}), Instant::now(), 1).unwrap_err();
    assert_eq!(err["code"], "validation.invalid");
    assert!(err["message"].as_str().unwrap().contains("does not compile"), "{err}");
}

#[test]
fn the_interface_and_its_ops_are_known() {
    assert!(cmux_app_manifest::KNOWN_INTERFACES.contains(&INTERFACE));
    let ops = super::super::grants::ScopeTable::get().known_ops();
    for op in [PUBLISH, READ, LIST] {
        assert!(ops.iter().any(|o| o == op), "{op} is in generated/scopes.json");
    }
}
