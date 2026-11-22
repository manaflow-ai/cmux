//! cx-1a6: terminal env values never rest in the exactly-once receipts.

use serde_json::json;

use super::*;

const SECRET: &str = "receipt-secret-value-9d2e";
/// The value of the still-running effect, which keeps it on purpose.
const LIVE: &str = "receipt-live-value-41c7";

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-receipt-env-{label}-{}", new_uuid_v4()))
}

fn request(path: bool, secret: &str) -> Value {
    let mut value = json!({
        "fields": {"cwd": "/tmp", "env": {"CMUX_API_TOKEN": secret, "COLORTERM": "truecolor"}},
        "operation": "tab.create_terminal",
        "selectors": {"pane": "pane_1"},
    });
    if path {
        value["path"] = json!({"pane": "pane_1"});
    }
    value
}

fn insert_effect(registry: &WorkspaceRegistry, key: &str, state: &str) {
    let committed = state == "committed";
    let secret = if committed { SECRET } else { LIVE };
    registry
        .connection
        .execute(
            "INSERT INTO resource_effect_receipts(
               idempotency_key, operation, fingerprint, intent_json, state,
               outcome_json, committed_revision
             ) VALUES(?1, 'tab.create_terminal', ?2, ?3, ?4, ?5, ?6)",
            params![
                key,
                canonical_json(&request(false, secret)).unwrap(),
                canonical_json(&request(true, secret)).unwrap(),
                state,
                committed.then_some("{\"kind\":\"success\",\"value\":{}}"),
                committed.then_some(1_i64),
            ],
        )
        .unwrap();
}

fn texts(registry: &WorkspaceRegistry, table: &str, key: &str) -> Vec<(String, String, String)> {
    let mut statement = registry
        .connection
        .prepare(&format!("SELECT {key}, fingerprint, intent_json FROM {table} ORDER BY {key}"))
        .unwrap();
    statement
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

/// Receipts written before the rule are rewritten in place when the registry
/// opens: fingerprints keep keys with a keyed hash, finished intents keep
/// keys only, and an effect that may still run keeps its values.
#[test]
fn reopening_scrubs_env_values_from_stored_receipts() {
    let root = temp_root("migrate");
    let registry = WorkspaceRegistry::open(&root, "receipt-env").unwrap();
    insert_effect(&registry, "effect-committed", "committed");
    insert_effect(&registry, "effect-pending", "pending");
    registry
        .connection
        .execute(
            "INSERT INTO resource_creation_receipts(
               correlation_key, operation, fingerprint, idempotency_key, intent_json,
               execution_kind, attempt, state, execution_generation, created_path_json,
               generation, committed_revision
             ) VALUES('creation-done', 'tab.create_terminal', ?1, 'effect-committed', ?2,
                      'effect', 1, 'created', NULL, '{}', 'generation', 1)",
            params![
                canonical_json(&request(false, SECRET)).unwrap(),
                canonical_json(&request(true, SECRET)).unwrap()
            ],
        )
        .unwrap();
    drop(registry);

    let reopened = WorkspaceRegistry::open(&root, "receipt-env").unwrap();
    let effects = texts(&reopened, "resource_effect_receipts", "idempotency_key");
    let creations = texts(&reopened, "resource_creation_receipts", "correlation_key");
    for (id, fingerprint, intent) in effects.iter().chain(creations.iter()) {
        assert!(
            !fingerprint.contains(SECRET) && !fingerprint.contains(LIVE),
            "{id}: fingerprint keeps the value: {fingerprint}"
        );
        let fingerprint: Value = serde_json::from_str(fingerprint).unwrap();
        assert!(
            fingerprint["fields"]["env"]["CMUX_API_TOKEN"]["hmac"].is_string(),
            "{id}: the fingerprint keeps the key with a keyed hash: {fingerprint}"
        );
        let intent: Value = serde_json::from_str(intent).unwrap();
        let token = &intent["fields"]["env"]["CMUX_API_TOKEN"];
        if id == "effect-pending" {
            assert_eq!(token, LIVE, "an effect that may still run keeps its values");
        } else {
            assert!(token.is_null(), "{id}: a finished intent keeps the key only: {intent}");
        }
    }
    drop(reopened);
    // No old page image keeps a scrubbed value: not the main file, not the WAL.
    let mut pending = vec![root.clone()];
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                pending.push(path);
            } else {
                let bytes = fs::read(&path).unwrap();
                assert!(
                    !bytes.windows(SECRET.len()).any(|window| window == SECRET.as_bytes()),
                    "{} keeps a scrubbed value",
                    path.display()
                );
            }
        }
    }
    let _ = fs::remove_dir_all(root);
}
