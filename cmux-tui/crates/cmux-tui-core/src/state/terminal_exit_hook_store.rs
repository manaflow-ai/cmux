//! Terminal exit hooks (`terminal-exit-hooks-v1`): what the daemon does once
//! when a terminal's process ends (a durable notice, an agent message, or
//! both). Rows are shared state of the session, keyed by a hook id; the
//! exit hook pump (`mux/terminal_exit_hook_pump.rs`) fires each armed row
//! from the terminal's durable exit receipt and records what it did. The
//! table is additive: an older binary that opens the store ignores it.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

/// Fired or failed hooks the store keeps (the newest ones).
const KEPT_ENDED: i64 = 500;
/// Armed hooks one session may hold.
pub(crate) const MAX_ARMED: i64 = 1000;
/// Longest accepted label, in characters.
pub(crate) const MAX_LABEL_CHARS: usize = 200;
/// Longest accepted title or text template, in characters.
pub(crate) const MAX_TEMPLATE_CHARS: usize = 2000;

pub(crate) fn create_exit_hook_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS terminal_exit_hooks (
           hook_id TEXT PRIMARY KEY,
           terminal_id TEXT NOT NULL,
           actor TEXT NOT NULL,
           notify INTEGER NOT NULL CHECK(notify IN (0,1)),
           send_to TEXT,
           label TEXT,
           title TEXT,
           text TEXT,
           state TEXT NOT NULL CHECK(state IN ('armed','fired','failed')),
           outcome_json TEXT,
           status TEXT,
           notification_id TEXT,
           message_id TEXT,
           error TEXT,
           created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
           fired_at_ms INTEGER
         );
         CREATE INDEX IF NOT EXISTS terminal_exit_hooks_by_state
           ON terminal_exit_hooks(state, created_at_ms);
         CREATE INDEX IF NOT EXISTS terminal_exit_hooks_by_terminal
           ON terminal_exit_hooks(terminal_id, created_at_ms);",
    )?;
    Ok(())
}

/// A hook as it is armed.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub(crate) struct NewExitHook {
    pub(crate) id: String,
    pub(crate) terminal_id: String,
    /// `Actor::wire()` of who armed it: the notice and the message are theirs.
    pub(crate) actor: String,
    pub(crate) notify: bool,
    /// A resolved recipient address (`acp:<id>` or `term_<hex>`).
    pub(crate) send_to: Option<String>,
    pub(crate) label: Option<String>,
    /// Notice title template (`{name}`, `{status}`, `{code}`, `{signal}`, `{terminal}`).
    pub(crate) title: Option<String>,
    /// Message (and notice body) template, the same placeholders.
    pub(crate) text: Option<String>,
}

/// An armed hook the pump fires.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ArmedExitHook {
    pub(crate) hook: NewExitHook,
    pub(crate) notification_id: Option<String>,
    pub(crate) message_id: Option<String>,
}

/// What firing a hook did.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct ExitHookFiring {
    pub(crate) outcome: Value,
    pub(crate) status: String,
    pub(crate) notification_id: Option<String>,
    pub(crate) message_id: Option<String>,
    pub(crate) error: Option<String>,
}

/// Arms `hook` unless a hook of that id exists (a retry of the same
/// request); keeps the newest [`KEPT_ENDED`] ended hooks.
pub(crate) fn insert_hook(
    transaction: &Transaction<'_>,
    hook: &NewExitHook,
    now_ms: u64,
) -> anyhow::Result<()> {
    let exists: Option<String> = transaction
        .query_row(
            "SELECT hook_id FROM terminal_exit_hooks WHERE hook_id = ?1",
            [&hook.id],
            |row| row.get(0),
        )
        .optional()?;
    if exists.is_some() {
        return Ok(());
    }
    let armed: i64 = transaction.query_row(
        "SELECT COUNT(*) FROM terminal_exit_hooks WHERE state = 'armed'",
        [],
        |row| row.get(0),
    )?;
    if armed >= MAX_ARMED {
        anyhow::bail!("bad request: a session holds at most {MAX_ARMED} armed exit hooks");
    }
    transaction.execute(
        "INSERT INTO terminal_exit_hooks
           (hook_id, terminal_id, actor, notify, send_to, label, title, text, state, created_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'armed', ?9)",
        params![
            hook.id,
            hook.terminal_id,
            hook.actor,
            hook.notify,
            hook.send_to,
            hook.label,
            hook.title,
            hook.text,
            i64::try_from(now_ms).unwrap_or(i64::MAX),
        ],
    )?;
    transaction.execute(
        "DELETE FROM terminal_exit_hooks WHERE state != 'armed' AND hook_id NOT IN (
           SELECT hook_id FROM terminal_exit_hooks WHERE state != 'armed'
           ORDER BY fired_at_ms DESC, hook_id DESC LIMIT ?1)",
        [KEPT_ENDED],
    )?;
    Ok(())
}

/// Records a step the pump finished (a notice or a message), so a retry
/// after a crash does not ask for it under a new key.
pub(crate) fn note_step(
    transaction: &Transaction<'_>,
    hook_id: &str,
    notification_id: Option<&str>,
    message_id: Option<&str>,
) -> anyhow::Result<()> {
    transaction.execute(
        "UPDATE terminal_exit_hooks
         SET notification_id = COALESCE(?2, notification_id),
             message_id = COALESCE(?3, message_id)
         WHERE hook_id = ?1 AND state = 'armed'",
        params![hook_id, notification_id, message_id],
    )?;
    Ok(())
}

/// Ends an armed hook: `fired`, or `failed` when a step could not be done.
pub(crate) fn finish_hook(
    transaction: &Transaction<'_>,
    hook_id: &str,
    firing: &ExitHookFiring,
    now_ms: u64,
) -> anyhow::Result<bool> {
    let state = if firing.error.is_some() { "failed" } else { "fired" };
    let changed = transaction.execute(
        "UPDATE terminal_exit_hooks
         SET state = ?2, outcome_json = ?3, status = ?4,
             notification_id = COALESCE(?5, notification_id),
             message_id = COALESCE(?6, message_id), error = ?7, fired_at_ms = ?8
         WHERE hook_id = ?1 AND state = 'armed'",
        params![
            hook_id,
            state,
            firing.outcome.to_string(),
            firing.status,
            firing.notification_id,
            firing.message_id,
            firing.error,
            i64::try_from(now_ms).unwrap_or(i64::MAX),
        ],
    )?;
    Ok(changed > 0)
}

/// Up to `limit` armed hooks, oldest first.
pub(crate) fn armed_hooks(
    connection: &Connection,
    limit: i64,
) -> anyhow::Result<Vec<ArmedExitHook>> {
    let mut statement = connection.prepare(
        "SELECT hook_id, terminal_id, actor, notify, send_to, label, title, text,
                notification_id, message_id
         FROM terminal_exit_hooks WHERE state = 'armed'
         ORDER BY created_at_ms ASC, hook_id ASC LIMIT ?1",
    )?;
    let rows = statement
        .query_map([limit], |row| {
            Ok(ArmedExitHook {
                hook: NewExitHook {
                    id: row.get(0)?,
                    terminal_id: row.get(1)?,
                    actor: row.get(2)?,
                    notify: row.get(3)?,
                    send_to: row.get(4)?,
                    label: row.get(5)?,
                    title: row.get(6)?,
                    text: row.get(7)?,
                },
                notification_id: row.get(8)?,
                message_id: row.get(9)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

/// The public form of hook `hook_id`, if the store has it.
pub(crate) fn hook_snapshot(connection: &Connection, hook_id: &str) -> anyhow::Result<Value> {
    hook_snapshots(connection, None, Some(hook_id))?
        .into_iter()
        .next()
        .ok_or_else(|| anyhow::anyhow!("exit hook {hook_id} was not stored"))
}

/// Hooks, newest first: one terminal's, or every terminal's.
pub(crate) fn hook_snapshots(
    connection: &Connection,
    terminal_id: Option<&str>,
    hook_id: Option<&str>,
) -> anyhow::Result<Vec<Value>> {
    let mut statement = connection.prepare(
        "SELECT hook_id, terminal_id, notify, send_to, label, state, outcome_json, status,
                notification_id, message_id, error, created_at_ms, fired_at_ms
         FROM terminal_exit_hooks
         WHERE (?1 IS NULL OR terminal_id = ?1) AND (?2 IS NULL OR hook_id = ?2)
         ORDER BY created_at_ms DESC, hook_id DESC",
    )?;
    let rows = statement
        .query_map(params![terminal_id, hook_id], |row| {
            let outcome: Option<String> = row.get(6)?;
            let fired: Option<i64> = row.get(12)?;
            Ok(json!({
                "id": row.get::<_, String>(0)?,
                "terminal_id": row.get::<_, String>(1)?,
                "notify": row.get::<_, bool>(2)?,
                "send_to": row.get::<_, Option<String>>(3)?,
                "label": row.get::<_, Option<String>>(4)?,
                "state": row.get::<_, String>(5)?,
                // A row another build wrote with a bad outcome shows none.
                "outcome": outcome
                    .and_then(|outcome| serde_json::from_str::<Value>(&outcome).ok())
                    .unwrap_or(Value::Null),
                "status": row.get::<_, Option<String>>(7)?,
                "notification_id": row.get::<_, Option<String>>(8)?,
                "message_id": row.get::<_, Option<String>>(9)?,
                "error": row.get::<_, Option<String>>(10)?,
                "created_at_ms": row.get::<_, i64>(11)?.to_string(),
                "fired_at_ms": fired.map(|fired| fired.to_string()),
            }))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}
