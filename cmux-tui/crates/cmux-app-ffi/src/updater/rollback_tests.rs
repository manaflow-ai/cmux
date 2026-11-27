use super::*;

fn kept(build: &str, at: Option<f64>) -> Kept {
    Kept {
        build: build.into(),
        store_schemas: Some(BTreeMap::from([("sessions".into(), 3)])),
        team_id: Some("T".into()),
        kept_at: at,
    }
}

fn stored(pairs: &[(&str, i64)]) -> BTreeMap<String, i64> {
    pairs.iter().map(|(k, v)| ((*k).into(), *v)).collect()
}

#[test]
fn numeric_compare_reads_digit_runs_by_value() {
    assert!(is_newer("100", "99"));
    assert!(is_newer("0.10.1", "0.9.9"));
    assert!(!is_newer("99", "100"));
    assert!(!is_newer("42", "42"));
    assert!(!is_newer("007", "7"));
    assert!(is_newer("1.2b", "1.2a"));
}

#[test]
fn previous_is_the_most_recently_kept_older_build() {
    let list = [kept("120", Some(10.0)), kept("110", Some(30.0)), kept("100", Some(20.0))];
    // 120 is above the running 115: never picked.
    assert_eq!(previous(&list, "115"), Some(1));
    assert_eq!(previous(&list, "100"), None);
}

#[test]
fn previous_puts_undated_builds_last_newest_number_first() {
    let list = [kept("90", None), kept("95", None), kept("80", Some(1.0))];
    assert_eq!(previous(&list, "100"), Some(2));
    let undated = [kept("90", None), kept("95", None)];
    assert_eq!(previous(&undated, "100"), Some(1));
}

#[test]
fn decide_refuses_with_the_case_the_app_shows() {
    let list = [kept("110", Some(1.0))];
    let none = BTreeMap::new();
    assert_eq!(decide(&[], None, Some("120"), &none, Some("T")), Err(Refusal::NothingKept));
    assert_eq!(
        decide(&list, None, Some("100"), &none, Some("T")),
        Err(Refusal::NothingOlder { running: "100".into() })
    );
    assert_eq!(decide(&list, Some("9"), None, &none, Some("T")), Err(Refusal::NothingKept));
    assert_eq!(
        decide(&list, None, Some("120"), &none, Some("U")),
        Err(Refusal::Signature { index: 0 })
    );
    assert_eq!(decide(&list, None, Some("120"), &none, None), Err(Refusal::Signature { index: 0 }));
    let mut old = list.clone();
    old[0].store_schemas = None;
    assert_eq!(
        decide(&old, None, Some("120"), &none, Some("T")),
        Err(Refusal::PredatesRollback { index: 0 })
    );
    assert_eq!(
        decide(&list, None, Some("120"), &stored(&[("sessions", 4)]), Some("T")),
        Err(Refusal::StoreTooNew { store: "sessions".into(), stored: 4, readable: 3, index: 0 })
    );
    assert_eq!(
        decide(&list, None, Some("120"), &stored(&[("zeta", 1), ("alpha", 1)]), Some("T")),
        Err(Refusal::UnknownStore { store: "alpha".into(), index: 0 })
    );
    assert_eq!(decide(&list, None, Some("120"), &stored(&[("sessions", 3)]), Some("T")), Ok(0));
    // An old caller with no running build takes the newest kept one.
    assert_eq!(decide(&list, None, None, &none, Some("T")), Ok(0));
}

#[test]
fn ops_answer_json() {
    let request = json!({
        "kept": [{"build": "110", "storeSchemas": {"sessions": 3}, "teamID": "T", "keptAt": 1.0,
                  "shortVersion": "0.1", "bundle": "/x"}],
        "running": "120", "stored": {"sessions": 4}, "teamID": "T"
    });
    assert_eq!(
        call("rollback.decide", &request),
        Ok(
            json!({"refusal": {"kind": "storeTooNew", "store": "sessions", "stored": 4, "readable": 3, "index": 0}})
        )
    );
    assert_eq!(call("rollback.previous", &request), Ok(json!(0)));
    assert_eq!(call("rollback.nope", &request), Err(OpError::Unknown));
    assert!(matches!(call("rollback.decide", &json!({})), Err(OpError::Invalid(_))));
}
