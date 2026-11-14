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
mod tests;
