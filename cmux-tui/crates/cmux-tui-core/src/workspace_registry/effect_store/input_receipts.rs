//! Completion records and pruning of transient input receipts (moved out of
//! effect_store.rs).

use super::*;

pub(super) fn is_transient_input_operation(operation: &str) -> bool {
    operation.starts_with("terminal.input.")
        || operation.starts_with("browser.input.")
        || operation == "sidebar_view.input"
        || operation == "terminal.viewport.scroll"
}

pub(super) fn record_resource_input_receipt_completion(
    transaction: &Transaction<'_>,
    idempotency_key: &str,
    operation: &str,
) -> anyhow::Result<()> {
    if !is_transient_input_operation(operation) {
        return Ok(());
    }
    transaction.execute(
        "INSERT INTO resource_input_receipt_completions(idempotency_key) VALUES(?1)",
        [idempotency_key],
    )?;
    let sequence = u64::try_from(transaction.last_insert_rowid())
        .context("resource input receipt completion sequence is negative")?;
    if sequence % u64::try_from(RESOURCE_INPUT_RECEIPT_PRUNE_INTERVAL)? == 0 {
        prune_resource_input_receipts(transaction)?;
    }
    Ok(())
}

pub(super) fn prune_resource_input_receipts(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute(
        &format!(
            "DELETE FROM resource_effect_receipts
             WHERE idempotency_key IN (
               SELECT completion.idempotency_key
               FROM resource_input_receipt_completions AS completion
               JOIN resource_effect_receipts AS effect
                 ON effect.idempotency_key = completion.idempotency_key
               WHERE effect.state = 'committed'
                 AND {TRANSIENT_INPUT_EFFECT_SQL}
                 AND NOT EXISTS (
                   SELECT 1
                   FROM resource_creation_receipts AS creation
                   WHERE creation.idempotency_key = effect.idempotency_key
                 )
               ORDER BY completion.sequence DESC
               LIMIT -1 OFFSET ?1
             )"
        ),
        [i64::try_from(RESOURCE_INPUT_RECEIPT_CAPACITY)?],
    )?;
    Ok(())
}
