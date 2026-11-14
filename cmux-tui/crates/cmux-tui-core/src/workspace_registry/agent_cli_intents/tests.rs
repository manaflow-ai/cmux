use super::*;
use serde_json::json;

fn intent() -> AgentCLIIntent {
    AgentCLIIntent {
        key: "original-child".into(),
        root_key: "original-root".into(),
        machine: format!("machine_{}", "1".repeat(32)),
        session: format!("session_{}", "2".repeat(32)),
        cli: "claude".into(),
        profiles: vec!["work-profile".into()],
    }
}

fn actor() -> Actor {
    Actor::Frontend { install_id: "original-install".into() }
}

fn root() -> std::path::PathBuf {
    std::env::temp_dir().join(format!("cmux-agent-intents-{}", super::super::new_uuid_v4()))
}

fn receipt() -> Value {
    json!({"machine":intent().machine,"session":intent().session,"cli":"claude",
            "revision":"18446744073709551615","replayed":false,"path":{
                "kind":"terminal","workspace_id":format!("ws_{}", "a".repeat(32)),
                "screen_id":format!("screen_{}", "a".repeat(32)),"pane_id":format!("pane_{}", "a".repeat(32)),
                "tab_id":format!("tab_{}", "a".repeat(32)),"terminal_id":format!("term_{}", "a".repeat(32))}})
}

#[test]
fn cmux_next_agent_cli_intent_keeps_original_identity_and_receipt_after_reopen() {
    let root = root();
    {
        let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
        let (rows, changed) = registry.record_agent_cli_intents(&actor(), &[intent()]).unwrap();
        assert!(changed);
        assert_eq!(rows[0]["key"], "original-child");
        assert_eq!(rows[0]["root_key"], "original-root");
        assert_eq!(rows[0]["receipt"], Value::Null);
        let (row, changed) = registry
            .attach_agent_cli_intent_receipt(&actor(), "original-child", &receipt())
            .unwrap();
        assert!(changed);
        assert_eq!(row["receipt"]["revision"], "18446744073709551615");
    }
    let registry = WorkspaceRegistry::open(&root, "intents").unwrap();
    let rows = registry.list_agent_cli_intents(&actor()).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["machine"], intent().machine);
    assert_eq!(rows[0]["receipt"]["path"]["terminal_id"], receipt()["path"]["terminal_id"]);
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn cmux_next_agent_cli_intent_batch_is_atomic_and_keys_cannot_retarget() {
    let root = root();
    let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
    let mut bad = intent();
    bad.key = "second".into();
    bad.session = "current".into();
    assert!(registry.record_agent_cli_intents(&actor(), &[intent(), bad]).is_err());
    assert!(registry.list_agent_cli_intents(&actor()).unwrap().is_empty());
    registry.record_agent_cli_intents(&actor(), &[intent()]).unwrap();
    assert!(!registry.record_agent_cli_intents(&actor(), &[intent()]).unwrap().1);
    for field in ["machine", "session", "cli", "root_key", "profiles"] {
        let mut changed = serde_json::to_value(intent()).unwrap();
        changed[field] =
            if field == "profiles" { json!(["other-profile"]) } else { json!("different") };
        let changed: AgentCLIIntent = serde_json::from_value(changed).unwrap();
        assert!(registry.record_agent_cli_intents(&actor(), &[changed]).is_err());
    }
    assert_eq!(registry.list_agent_cli_intents(&actor()).unwrap().len(), 1);
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn cmux_next_agent_cli_intent_receipts_require_the_original_owner_cli_and_public_path() {
    let root = root();
    let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
    registry.record_agent_cli_intents(&actor(), &[intent()]).unwrap();
    for field in ["machine", "session", "cli", "argv"] {
        let mut foreign = receipt();
        foreign[field] = json!("foreign");
        assert!(
            registry.attach_agent_cli_intent_receipt(&actor(), "original-child", &foreign).is_err()
        );
    }
    let mut malformed = receipt();
    malformed["path"]["terminal_id"] = json!("private-host-id");
    assert!(
        registry.attach_agent_cli_intent_receipt(&actor(), "original-child", &malformed).is_err()
    );
    registry.attach_agent_cli_intent_receipt(&actor(), "original-child", &receipt()).unwrap();
    let mut replay = receipt();
    replay["replayed"] = json!(true);
    assert!(
        !registry.attach_agent_cli_intent_receipt(&actor(), "original-child", &replay).unwrap().1
    );
    replay["path"]["terminal_id"] = json!(format!("term_{}", "b".repeat(32)));
    assert!(registry.attach_agent_cli_intent_receipt(&actor(), "original-child", &replay).is_err());
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

fn keyed(key: &str) -> AgentCLIIntent {
    AgentCLIIntent { key: key.into(), ..intent() }
}

#[test]
fn cmux_next_agent_cli_intent_settle_deletes_only_the_named_rows_and_is_idempotent() {
    let root = root();
    let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
    registry.record_agent_cli_intents(&actor(), &[keyed("settled"), keyed("kept")]).unwrap();
    let (rows, changed) =
        registry.settle_agent_cli_intents(&actor(), &["settled".to_owned()]).unwrap();
    assert!(changed);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["key"], "kept");
    assert!(!registry.settle_agent_cli_intents(&actor(), &["settled".to_owned()]).unwrap().1);
    let other = Actor::Frontend { install_id: "other-install".into() };
    assert!(!registry.settle_agent_cli_intents(&other, &["kept".to_owned()]).unwrap().1);
    assert!(registry.settle_agent_cli_intents(&Actor::Daemon, &["kept".to_owned()]).is_err());
    assert!(registry.settle_agent_cli_intents(&actor(), &[]).is_err());
    assert_eq!(registry.list_agent_cli_intents(&actor()).unwrap().len(), 1);
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn cmux_next_agent_cli_intent_ledger_prunes_old_and_excess_rows_instead_of_filling() {
    let root = root();
    let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
    let start = 1_000_000_000_000;
    registry.record_agent_cli_intents_at(&actor(), &[keyed("stale")], start).unwrap();
    let later = start + MAX_AGE_MS + 1;
    for batch in 0..5 {
        let rows: Vec<_> = (0..64).map(|n| keyed(&format!("row-{batch}-{n:02}"))).collect();
        registry.record_agent_cli_intents_at(&actor(), &rows, later + batch).unwrap();
    }
    let rows = registry.list_agent_cli_intents_at(&actor(), later + 4).unwrap();
    assert_eq!(rows.len(), MAX_ROWS as usize);
    assert!(rows.iter().all(|row| row["key"] != "stale"));
    assert!(rows.iter().all(|row| !row["key"].as_str().unwrap().starts_with("row-0-")));
    assert!(rows.iter().any(|row| row["key"] == "row-4-63"));
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn cmux_next_agent_cli_intent_reads_hide_rows_past_the_age_bound_without_a_record() {
    let root = root();
    let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
    let start = 1_000_000_000_000;
    registry.record_agent_cli_intents_at(&actor(), &[keyed("blocked")], start).unwrap();
    let fresh = registry.list_agent_cli_intents_at(&actor(), start + MAX_AGE_MS).unwrap();
    assert_eq!(fresh.len(), 1);
    let aged = registry.list_agent_cli_intents_at(&actor(), start + MAX_AGE_MS + 1).unwrap();
    assert!(aged.is_empty());
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn cmux_next_agent_cli_intent_ledger_without_recorded_at_gains_it_and_prunes_old_rows() {
    let root = root();
    let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
    {
        let db = registry.connection.get();
        db.execute_batch(
            "DROP TABLE agent_cli_intents;
                 CREATE TABLE agent_cli_intents (
                   actor TEXT NOT NULL, intent_key TEXT NOT NULL, intent_json TEXT NOT NULL,
                   receipt_json TEXT, PRIMARY KEY(actor, intent_key));",
        )
        .unwrap();
        db.execute(
            "INSERT INTO agent_cli_intents(actor,intent_key,intent_json) VALUES(?1,?2,?3)",
            params![
                frontend(&actor()).unwrap(),
                "pre-column",
                serde_json::to_string(&keyed("pre-column")).unwrap()
            ],
        )
        .unwrap();
        let tx = db.unchecked_transaction().unwrap();
        create_schema(&tx).unwrap();
        create_schema(&tx).unwrap();
        tx.commit().unwrap();
    }
    let now = 1_000_000_000_000;
    assert!(registry.list_agent_cli_intents_at(&actor(), now).unwrap().is_empty());
    let (rows, changed) =
        registry.record_agent_cli_intents_at(&actor(), &[keyed("new")], now).unwrap();
    assert!(changed);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["key"], "new");
    let kept: i64 = registry
        .connection
        .get()
        .query_row("SELECT count(*) FROM agent_cli_intents", [], |row| row.get(0))
        .unwrap();
    assert_eq!(kept, 1, "the pre-column row reads as oldest and is pruned");
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn cmux_next_agent_cli_intent_reads_skip_a_bad_row_instead_of_failing_the_list() {
    let root = root();
    let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
    let now = 1_000_000_000_000;
    registry.record_agent_cli_intents_at(&actor(), &[keyed("good")], now).unwrap();
    {
        let db = registry.connection.get();
        let mut bad_cli = keyed("bad-cli");
        bad_cli.cli = "not-a-cli".into();
        let insert =
            "INSERT INTO agent_cli_intents(actor,intent_key,intent_json,receipt_json,recorded_at)
                 VALUES(?1,?2,?3,?4,?5)";
        let actor = frontend(&actor()).unwrap();
        for (key, input, receipt) in [
            ("bad-cli", serde_json::to_string(&bad_cli).unwrap(), None),
            ("bad-json", "{".to_owned(), None),
            (
                "bad-receipt",
                serde_json::to_string(&keyed("bad-receipt")).unwrap(),
                Some(json!({"machine": "machine_other"}).to_string()),
            ),
        ] {
            db.execute(insert, params![actor, key, input, receipt, now]).unwrap();
        }
    }
    let rows = registry.list_agent_cli_intents_at(&actor(), now).unwrap();
    assert_eq!(rows.len(), 1, "only the valid row reads: {rows:?}");
    assert_eq!(rows[0]["key"], "good");
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn cmux_next_agent_cli_intent_store_is_principal_scoped_and_not_execution_authority() {
    let root = root();
    let mut registry = WorkspaceRegistry::open(&root, "intents").unwrap();
    registry.record_agent_cli_intents(&actor(), &[intent()]).unwrap();
    let other = Actor::Frontend { install_id: "other-install".into() };
    assert!(registry.list_agent_cli_intents(&other).unwrap().is_empty());
    assert!(
        registry.attach_agent_cli_intent_receipt(&other, "original-child", &receipt()).is_err()
    );
    for denied in [Actor::Daemon, Actor::local_user(), Actor::App { id: "claim".into() }] {
        assert!(registry.record_agent_cli_intents(&denied, &[intent()]).is_err());
        assert!(registry.list_agent_cli_intents(&denied).is_err());
    }
    let mut arbitrary = serde_json::to_value(intent()).unwrap();
    arbitrary["argv"] = json!(["anything"]);
    assert!(serde_json::from_value::<AgentCLIIntent>(arbitrary).is_err());
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}
