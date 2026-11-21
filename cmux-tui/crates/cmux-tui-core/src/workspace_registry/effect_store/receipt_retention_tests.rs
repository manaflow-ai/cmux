//! The committed effect and creation receipts keep a replay window, not every
//! receipt a session ever wrote (CMUX-571, slope 3: an infinite session's
//! registry grew with every tab and workspace it had ever made).

use super::*;
use crate::workspace_registry::resource_store::RESOURCE_MUTATION_REPLAY_CAPACITY as WINDOW;

const OVER: usize = 100;
const NOTIFICATIONS: usize = 300;

fn insert_effect(
    tx: &Transaction<'_>,
    key: &str,
    operation: &str,
    state: &str,
    outcome: Option<&str>,
) {
    let committed = state == "committed";
    tx.execute(
        "INSERT INTO resource_effect_receipts(
           idempotency_key, operation, fingerprint, intent_json, state, outcome_json, committed_revision
         ) VALUES(?1, ?2, '{}', '{}', ?3, ?4, ?5)",
        params![key, operation, state, outcome, committed.then_some(1_i64)],
    )
    .unwrap();
}

fn insert_creation(
    tx: &Transaction<'_>,
    correlation: &str,
    key: &str,
    operation: &str,
    state: &str,
) {
    let created = state == "created";
    tx.execute(
        "INSERT INTO resource_creation_receipts(
           correlation_key, operation, fingerprint, idempotency_key, intent_json, execution_kind,
           attempt, state, execution_generation, created_path_json, generation, committed_revision
         ) VALUES(?1, ?2, '{}', ?3, '{}', 'effect', 1, ?4, NULL, ?5, ?6, ?7)",
        params![
            correlation,
            operation,
            key,
            state,
            created.then_some("{}"),
            created.then_some("generation"),
            created.then_some(1_i64),
        ],
    )
    .unwrap();
}

fn count(registry: &WorkspaceRegistry, sql: &str) -> usize {
    let found: i64 = registry.connection.get().query_row(sql, [], |row| row.get(0)).unwrap();
    usize::try_from(found).unwrap()
}

fn exists(registry: &WorkspaceRegistry, sql: &str, key: &str) -> bool {
    registry.connection.get().query_row(sql, [key], |row| row.get::<_, bool>(0)).unwrap()
}

#[test]
fn committed_receipts_keep_a_replay_window_and_every_in_flight_or_notification_receipt() {
    let root = std::env::temp_dir().join(format!("cmux-receipt-window-{}", new_uuid_v4()));
    {
        let registry = WorkspaceRegistry::open(&root, "receipt-window").unwrap();
        let db = registry.connection.get();
        let tx = db.unchecked_transaction().unwrap();
        // Older than every committed receipt: still in flight when the
        // daemon stopped, so the open's recovery and a retry need them.
        insert_effect(&tx, "in-flight-effect", "tab.create_browser", "executing", None);
        insert_creation(
            &tx,
            "in-flight-creation",
            "in-flight-effect",
            "tab.create_browser",
            "executing",
        );
        insert_effect(&tx, "pending-effect", "tab.close", "pending", None);
        for index in 0..WINDOW + OVER {
            // A creation and the effect that made it, as tab.create_browser
            // and workspace.create write them.
            let key = format!("create-{index:06}");
            insert_effect(
                &tx,
                &key,
                "tab.create_browser",
                "committed",
                Some(r#"{"kind":"success","value":{}}"#),
            );
            insert_creation(
                &tx,
                &format!("correlation-{index:06}"),
                &key,
                "tab.create_browser",
                "created",
            );
            // An effect with no creation, as tab.close writes it.
            insert_effect(
                &tx,
                &format!("close-{index:06}"),
                "tab.close",
                "committed",
                Some(r#"{"kind":"success","value":{}}"#),
            );
        }
        // The notification ledger reads its own receipts (the feed, acks,
        // clears and the shown list): this window leaves them alone.
        for index in 0..NOTIFICATIONS {
            insert_effect(
                &tx,
                &format!("notify-{index:06}"),
                "notification.create",
                "committed",
                Some(format!(r#"{{"kind":"success","value":{{"id":"ntf_{index:06}"}}}}"#).as_str()),
            );
        }
        tx.commit().unwrap();
    }

    let registry = WorkspaceRegistry::open(&root, "receipt-window").unwrap();
    assert_eq!(
        count(&registry, "SELECT COUNT(*) FROM resource_creation_receipts WHERE state = 'created'"),
        WINDOW,
        "committed creation receipts past the replay window stay"
    );
    assert_eq!(
        count(
            &registry,
            "SELECT COUNT(*) FROM resource_effect_receipts WHERE operation = 'tab.close'"
        ),
        WINDOW + 1,
        "committed effects past the window stay (the pending one is kept too)"
    );
    assert_eq!(
        count(
            &registry,
            "SELECT COUNT(*) FROM resource_effect_receipts
             WHERE operation = 'tab.create_browser' AND state = 'committed'"
        ),
        WINDOW,
        "a creation's effect receipt goes with its creation receipt"
    );
    assert_eq!(
        count(
            &registry,
            "SELECT COUNT(*) FROM resource_creation_receipts AS creation
             WHERE NOT EXISTS (SELECT 1 FROM resource_effect_receipts AS effect
                               WHERE effect.idempotency_key = creation.idempotency_key)"
        ),
        0,
        "no creation receipt is left without its effect"
    );
    assert_eq!(
        count(
            &registry,
            "SELECT COUNT(*) FROM resource_effect_receipts WHERE operation = 'notification.create'"
        ),
        NOTIFICATIONS
    );
    let effect = "SELECT EXISTS(SELECT 1 FROM resource_effect_receipts WHERE idempotency_key = ?1)";
    let creation =
        "SELECT EXISTS(SELECT 1 FROM resource_creation_receipts WHERE correlation_key = ?1)";
    for key in ["in-flight-effect", "pending-effect"] {
        assert!(exists(&registry, effect, key), "{key} is in flight");
    }
    assert!(exists(&registry, creation, "in-flight-creation"));
    let newest = WINDOW + OVER - 1;
    assert!(exists(&registry, creation, &format!("correlation-{newest:06}")));
    assert!(exists(&registry, effect, &format!("close-{newest:06}")));
    assert!(exists(&registry, creation, &format!("correlation-{OVER:06}")), "the oldest kept");
    assert!(!exists(&registry, creation, &format!("correlation-{:06}", OVER - 1)));
    assert!(!exists(&registry, effect, &format!("create-{:06}", OVER - 1)));
    assert!(!exists(&registry, effect, &format!("close-{:06}", OVER - 1)));
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
