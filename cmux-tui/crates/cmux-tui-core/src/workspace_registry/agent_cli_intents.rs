//! Non-secret UI update intent identity, durably recorded before dispatch.
//! This ledger grants no execution authority and never contains argv or credentials.
//! A settled intent is deleted; recording prunes rows past an age and count bound,
//! and a read never returns a row past the age bound.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use serde_json::json;

use super::{
    Actor, MachinePublicId, PanePublicId, ScreenPublicId, SessionPublicId, TabPublicId,
    TerminalPublicId, WorkspacePublicId, WorkspaceRegistry,
};
use cmux_json::JsonSet as _;

pub(crate) fn create_schema(tx: &Transaction<'_>) -> anyhow::Result<()> {
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS agent_cli_intents (
        actor TEXT NOT NULL, intent_key TEXT NOT NULL, intent_json TEXT NOT NULL,
        receipt_json TEXT, recorded_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(actor, intent_key)
    );",
    )?;
    // A pre-release ledger without the column: its rows read as oldest and prune first.
    let has_recorded_at = tx
        .prepare("SELECT 1 FROM pragma_table_info('agent_cli_intents') WHERE name='recorded_at'")?
        .exists([])?;
    if !has_recorded_at {
        tx.execute_batch(
            "ALTER TABLE agent_cli_intents ADD COLUMN recorded_at INTEGER NOT NULL DEFAULT 0;",
        )?;
    }
    Ok(())
}

/// Rows kept per actor; recording drops the oldest beyond it instead of failing.
const MAX_ROWS: i64 = 256;
/// An update unsettled this long has ended; its row no longer blocks or resumes.
const MAX_AGE_MS: i64 = 7 * 24 * 60 * 60 * 1000;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct AgentCLIIntent {
    pub key: String,
    pub root_key: String,
    pub machine: String,
    pub session: String,
    pub cli: String,
    pub profiles: Vec<String>,
}

impl WorkspaceRegistry {
    pub(crate) fn record_agent_cli_intents(
        &mut self,
        actor: &Actor,
        intents: &[AgentCLIIntent],
    ) -> anyhow::Result<(Vec<Value>, bool)> {
        self.record_agent_cli_intents_at(actor, intents, i64::try_from(super::unix_epoch_ms()?)?)
    }

    pub(crate) fn record_agent_cli_intents_at(
        &mut self,
        actor: &Actor,
        intents: &[AgentCLIIntent],
        now_ms: i64,
    ) -> anyhow::Result<(Vec<Value>, bool)> {
        let actor = frontend(actor)?;
        anyhow::ensure!(!intents.is_empty() && intents.len() <= 64, "invalid intent batch size");
        for intent in intents {
            validate_intent(intent)?;
        }
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let mut changed = tx.execute(
            "DELETE FROM agent_cli_intents WHERE actor=?1 AND recorded_at<?2",
            params![actor, now_ms.saturating_sub(MAX_AGE_MS)],
        )? > 0;
        for intent in intents {
            let previous: Option<String> = tx
                .query_row(
                    "SELECT intent_json FROM agent_cli_intents WHERE actor=?1 AND intent_key=?2",
                    params![actor, intent.key],
                    |row| row.get(0),
                )
                .optional()?;
            if let Some(previous) = previous {
                anyhow::ensure!(
                    serde_json::from_str::<AgentCLIIntent>(&previous)? == *intent,
                    "original update intent cannot be retargeted"
                );
            } else {
                tx.execute(
                    "INSERT INTO agent_cli_intents(actor,intent_key,intent_json,recorded_at)
                     VALUES(?1,?2,?3,?4)",
                    params![actor, intent.key, serde_json::to_string(intent)?, now_ms],
                )?;
                changed = true;
            }
        }
        // The newest rows stay; a batch (at most 64) is always newer than what it drops.
        changed |= tx.execute(
            "DELETE FROM agent_cli_intents WHERE actor=?1 AND rowid IN (
               SELECT rowid FROM agent_cli_intents WHERE actor=?1
               ORDER BY recorded_at DESC, rowid DESC LIMIT -1 OFFSET ?2)",
            params![actor, MAX_ROWS],
        )? > 0;
        if changed {
            super::personal_store::commit_personal(
                &tx,
                "agent-cli-intents-recorded",
                vec![],
                &json!({"actor":actor,"keys":intents.iter().map(|i| &i.key).collect::<Vec<_>>()}),
            )?;
        }
        tx.commit()?;
        Ok((read_rows(&db, &actor, now_ms)?, changed))
    }

    /// Forgets settled intents. A key already gone is not an error: settling is idempotent.
    pub(crate) fn settle_agent_cli_intents(
        &mut self,
        actor: &Actor,
        keys: &[String],
    ) -> anyhow::Result<(Vec<Value>, bool)> {
        let actor = frontend(actor)?;
        anyhow::ensure!(!keys.is_empty() && keys.len() <= 64, "invalid settle batch size");
        for key in keys {
            super::validate_identifier("intent key", key)?;
        }
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let mut changed = false;
        for key in keys {
            changed |= tx.execute(
                "DELETE FROM agent_cli_intents WHERE actor=?1 AND intent_key=?2",
                params![actor, key],
            )? > 0;
        }
        if changed {
            super::personal_store::commit_personal(
                &tx,
                "agent-cli-intents-settled",
                vec![],
                &json!({"actor":actor,"keys":keys}),
            )?;
        }
        tx.commit()?;
        Ok((read_rows(&db, &actor, i64::try_from(super::unix_epoch_ms()?)?)?, changed))
    }

    pub(crate) fn list_agent_cli_intents(&self, actor: &Actor) -> anyhow::Result<Vec<Value>> {
        self.list_agent_cli_intents_at(actor, i64::try_from(super::unix_epoch_ms()?)?)
    }

    /// A blocked family never records, so the read applies the age bound too:
    /// a row no session settled (a closed tab, a reinstalled server) stops blocking.
    pub(crate) fn list_agent_cli_intents_at(
        &self,
        actor: &Actor,
        now_ms: i64,
    ) -> anyhow::Result<Vec<Value>> {
        read_rows(&self.connection.get(), &frontend(actor)?, now_ms)
    }

    pub(crate) fn attach_agent_cli_intent_receipt(
        &mut self,
        actor: &Actor,
        key: &str,
        receipt: &Value,
    ) -> anyhow::Result<(Value, bool)> {
        let actor = frontend(actor)?;
        super::validate_identifier("intent key", key)?;
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let (input, old): (String, Option<String>) = tx.query_row(
            "SELECT intent_json,receipt_json FROM agent_cli_intents WHERE actor=?1 AND intent_key=?2",
            params![actor,key], |row| Ok((row.get(0)?,row.get(1)?)))?;
        let input: AgentCLIIntent = serde_json::from_str(&input)?;
        let receipt = normalize_receipt(&input, receipt)?;
        let changed = if let Some(old) = old {
            anyhow::ensure!(
                serde_json::from_str::<Value>(&old)? == receipt,
                "original update receipt cannot be replaced"
            );
            false
        } else {
            tx.execute(
                "UPDATE agent_cli_intents SET receipt_json=?3 WHERE actor=?1 AND intent_key=?2",
                params![actor, key, serde_json::to_string(&receipt)?],
            )?;
            super::personal_store::commit_personal(
                &tx,
                "agent-cli-intent-receipted",
                vec![],
                &json!({"actor":actor,"key":key}),
            )?;
            true
        };
        tx.commit()?;
        Ok((row_value(&input, Some(receipt))?, changed))
    }
}

fn frontend(actor: &Actor) -> anyhow::Result<String> {
    anyhow::ensure!(
        matches!(actor, Actor::Frontend { install_id } if !install_id.is_empty()),
        "a verified frontend is required"
    );
    Ok(actor.wire())
}

fn validate_intent(intent: &AgentCLIIntent) -> anyhow::Result<()> {
    super::validate_identifier("intent key", &intent.key)?;
    super::validate_identifier("root intent key", &intent.root_key)?;
    MachinePublicId::parse(intent.machine.clone())?;
    SessionPublicId::parse(intent.session.clone())?;
    anyhow::ensure!(
        matches!(
            intent.cli.as_str(),
            "claude"
                | "codex"
                | "opencode"
                | "pi"
                | "chief"
                | "gemini"
                | "amp"
                | "copilot"
                | "cursor"
        ),
        "a known CLI is required"
    );
    anyhow::ensure!(intent.profiles.len() <= 128, "too many profile labels");
    for profile in &intent.profiles {
        super::validate_identifier("profile label", profile)?;
    }
    Ok(())
}

fn text<'a>(value: &'a Value, field: &str) -> anyhow::Result<&'a str> {
    value[field].as_str().ok_or_else(|| anyhow::anyhow!("invalid receipt field {field}"))
}

fn normalize_receipt(intent: &AgentCLIIntent, receipt: &Value) -> anyhow::Result<Value> {
    anyhow::ensure!(
        receipt.as_object().is_some_and(|o| o.len() == 6)
            && receipt["machine"] == intent.machine
            && receipt["session"] == intent.session
            && receipt["cli"] == intent.cli
            && receipt["replayed"].is_boolean(),
        "receipt identity mismatch"
    );
    let revision = text(receipt, "revision")?;
    anyhow::ensure!(revision.parse::<u64>()?.to_string() == revision, "invalid receipt revision");
    let path = &receipt["path"];
    anyhow::ensure!(
        path.as_object().is_some_and(|o| o.len() == 6) && path["kind"] == "terminal",
        "invalid terminal receipt path"
    );
    WorkspacePublicId::parse(text(path, "workspace_id")?.to_owned())?;
    ScreenPublicId::parse(text(path, "screen_id")?.to_owned())?;
    PanePublicId::parse(text(path, "pane_id")?.to_owned())?;
    TabPublicId::parse(text(path, "tab_id")?.to_owned())?;
    TerminalPublicId::parse(text(path, "terminal_id")?.to_owned())?;
    let mut receipt = receipt.clone();
    receipt.set("replayed", json!(true));
    Ok(receipt)
}

fn row_value(intent: &AgentCLIIntent, receipt: Option<Value>) -> anyhow::Result<Value> {
    let mut value = serde_json::to_value(intent)?;
    value.set("receipt", receipt.unwrap_or(Value::Null));
    Ok(value)
}

fn read_rows(db: &Connection, actor: &str, now_ms: i64) -> anyhow::Result<Vec<Value>> {
    let mut statement = db.prepare(
        "SELECT intent_json,receipt_json FROM agent_cli_intents WHERE actor=?1 AND recorded_at>=?2
         ORDER BY intent_key",
    )?;
    let rows = statement
        .query_map(params![actor, now_ms.saturating_sub(MAX_AGE_MS)], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    // One unreadable row is skipped, not the whole ledger: the others still block and resume.
    Ok(rows
        .into_iter()
        .filter_map(|(input, receipt)| match read_row(&input, receipt.as_deref()) {
            Ok(row) => Some(row),
            Err(error) => {
                eprintln!("cmux-tui: skipping an unreadable agent CLI intent row: {error:#}");
                None
            }
        })
        .collect())
}

fn read_row(input: &str, receipt: Option<&str>) -> anyhow::Result<Value> {
    let input: AgentCLIIntent = serde_json::from_str(input)?;
    validate_intent(&input)?;
    let receipt = receipt
        .map(|s| -> anyhow::Result<Value> { normalize_receipt(&input, &serde_json::from_str(s)?) })
        .transpose()?;
    row_value(&input, receipt)
}

#[cfg(test)]
mod tests {
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
                registry
                    .attach_agent_cli_intent_receipt(&actor(), "original-child", &foreign)
                    .is_err()
            );
        }
        let mut malformed = receipt();
        malformed["path"]["terminal_id"] = json!("private-host-id");
        assert!(
            registry
                .attach_agent_cli_intent_receipt(&actor(), "original-child", &malformed)
                .is_err()
        );
        registry.attach_agent_cli_intent_receipt(&actor(), "original-child", &receipt()).unwrap();
        let mut replay = receipt();
        replay["replayed"] = json!(true);
        assert!(
            !registry
                .attach_agent_cli_intent_receipt(&actor(), "original-child", &replay)
                .unwrap()
                .1
        );
        replay["path"]["terminal_id"] = json!(format!("term_{}", "b".repeat(32)));
        assert!(
            registry.attach_agent_cli_intent_receipt(&actor(), "original-child", &replay).is_err()
        );
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
            let insert = "INSERT INTO agent_cli_intents(actor,intent_key,intent_json,receipt_json,recorded_at)
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
}
