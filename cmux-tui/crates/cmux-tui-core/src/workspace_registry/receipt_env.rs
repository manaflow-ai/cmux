//! Terminal environment values never rest in the exactly-once receipts
//! (cx-1a6). A terminal-creating request carries `fields.env`, which routinely
//! holds credentials (`CMUX_*_TOKEN`, passwords, cookies).
//!
//! - Fingerprints (`resource_effect_receipts.fingerprint`,
//!   `resource_creation_receipts.fingerprint`) keep every env key and, per
//!   value, a keyed HMAC under the registry's resource-effect pepper
//!   (`{"hmac": "<hex>"}`). A retry with the same values still matches; a
//!   retry with another value is still a different payload; the value itself
//!   is not recoverable, even for a short password.
//! - Intents keep the raw values only while the effect may still run
//!   (`pending`/`executing` effects, `prepared`/`executing` creations). A
//!   trigger replaces every value with `null` once the row reaches a final
//!   state. A not-applied creation that is retried takes the values from the
//!   retrying request, whose fingerprint proved they are the same.
//! - [`scrub_stored_receipts`] rewrites rows written before this rule.

use super::*;

const RECEIPT_ENV_DOMAIN: &[u8] = b"cmux.resource-receipt-env.v1";

const SCRUB_EFFECT_INTENTS: &str = "UPDATE resource_effect_receipts
     SET intent_json = json_set(intent_json, '$.fields.env', json((
       SELECT json_group_object(key, NULL) FROM json_each(intent_json, '$.fields.env'))))
     WHERE state IN ('committed', 'indeterminate')
       AND json_type(intent_json, '$.fields.env') = 'object'";

const SCRUB_CREATION_INTENTS: &str = "UPDATE resource_creation_receipts
     SET intent_json = json_set(intent_json, '$.fields.env', json((
       SELECT json_group_object(key, NULL) FROM json_each(intent_json, '$.fields.env'))))
     WHERE state IN ('created', 'not_applied', 'indeterminate')
       AND json_type(intent_json, '$.fields.env') = 'object'";

impl ResourceEffectPepper {
    fn env_value_hmac(&self, key: &str, value: &str) -> String {
        const BLOCK_BYTES: usize = 64;
        let mut key_block = [0_u8; BLOCK_BYTES];
        key_block[..RESOURCE_EFFECT_PEPPER_BYTES].copy_from_slice(self.0.as_ref());
        let mut inner_pad = [0x36_u8; BLOCK_BYTES];
        let mut outer_pad = [0x5c_u8; BLOCK_BYTES];
        for index in 0..BLOCK_BYTES {
            inner_pad[index] ^= key_block[index];
            outer_pad[index] ^= key_block[index];
        }
        let mut inner = Sha256::new();
        inner.update(inner_pad);
        update_sha256_part(&mut inner, RECEIPT_ENV_DOMAIN);
        update_sha256_part(&mut inner, key.as_bytes());
        update_sha256_part(&mut inner, value.as_bytes());
        let inner = inner.finalize();
        let mut outer = Sha256::new();
        outer.update(outer_pad);
        outer.update(inner);
        let digest = outer.finalize().into();
        key_block.zeroize();
        inner_pad.zeroize();
        outer_pad.zeroize();
        hex_sha256(digest)
    }
}

/// `value` with every string in `fields.env` replaced by its keyed HMAC.
/// Already redacted values (objects) stay as they are, so this is idempotent.
fn redact_env_values(value: &Value, pepper: &ResourceEffectPepper) -> Value {
    let mut value = value.clone();
    if let Some(env) = value.pointer_mut("/fields/env").and_then(Value::as_object_mut) {
        for (key, entry) in env.iter_mut() {
            if let Some(raw) = entry.as_str() {
                *entry = serde_json::json!({ "hmac": pepper.env_value_hmac(key, raw) });
            }
        }
    }
    value
}

impl WorkspaceRegistry {
    /// The canonical fingerprint as the receipts store and compare it.
    pub(super) fn stored_fingerprint(&self, fingerprint: &Value) -> anyhow::Result<String> {
        canonical_json(&redact_env_values(fingerprint, &self.resource_effect_pepper))
    }
}

/// A stored intent whose env values were scrubbed, with the values of the
/// retrying request `live` (same keys, proven equal by the fingerprint).
pub(super) fn rehydrate(mut stored: Value, live: &Value) -> Value {
    if let (Some(env), Some(live_env)) = (
        stored.pointer_mut("/fields/env").and_then(Value::as_object_mut),
        live.pointer("/fields/env").and_then(Value::as_object),
    ) {
        for (key, entry) in env.iter_mut() {
            if entry.is_null()
                && let Some(value) = live_env.get(key).filter(|value| value.is_string())
            {
                *entry = value.clone();
            }
        }
    }
    stored
}

/// Triggers that scrub intent env values when a receipt reaches a final state.
pub(super) fn create_scrub_triggers(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(&format!(
        "CREATE TRIGGER IF NOT EXISTS resource_effect_receipts_scrub_env
           AFTER UPDATE OF state ON resource_effect_receipts
           WHEN NEW.state IN ('committed', 'indeterminate')
         BEGIN {SCRUB_EFFECT_INTENTS} AND idempotency_key = NEW.idempotency_key; END;
         CREATE TRIGGER IF NOT EXISTS resource_creation_receipts_scrub_env
           AFTER UPDATE OF state ON resource_creation_receipts
           WHEN NEW.state IN ('created', 'not_applied', 'indeterminate')
         BEGIN {SCRUB_CREATION_INTENTS} AND correlation_key = NEW.correlation_key; END;"
    ))?;
    Ok(())
}

/// Rewrite receipts stored before the rule: redact every fingerprint's env
/// values and scrub the intents of finished receipts, in place. True when a
/// row changed; the caller then checkpoints the WAL so no old page image
/// keeps a value (`secure_delete` is on for the registry connection).
pub(super) fn scrub_stored_receipts(
    transaction: &Transaction<'_>,
    pepper: &ResourceEffectPepper,
) -> anyhow::Result<bool> {
    let mut changed = 0;
    create_scrub_triggers(transaction)?;
    for (table, key) in [
        ("resource_effect_receipts", "idempotency_key"),
        ("resource_creation_receipts", "correlation_key"),
    ] {
        let rows = {
            let mut statement = transaction.prepare(&format!(
                "SELECT {key}, fingerprint FROM {table}
                 WHERE json_type(fingerprint, '$.fields.env') = 'object'"
            ))?;
            statement
                .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
                .collect::<Result<Vec<_>, _>>()?
        };
        for (id, fingerprint) in rows {
            let redacted =
                canonical_json(&redact_env_values(&serde_json::from_str(&fingerprint)?, pepper))?;
            if redacted != fingerprint {
                changed += transaction.execute(
                    &format!("UPDATE {table} SET fingerprint = ?2 WHERE {key} = ?1"),
                    params![id, redacted],
                )?;
            }
        }
    }
    changed += transaction.execute(SCRUB_EFFECT_INTENTS, [])?;
    changed += transaction.execute(SCRUB_CREATION_INTENTS, [])?;
    Ok(changed > 0)
}
