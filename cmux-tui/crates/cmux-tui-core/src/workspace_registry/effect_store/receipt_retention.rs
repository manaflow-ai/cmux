//! The replay window of committed effect and creation receipts (CMUX-571,
//! slope 3).
//!
//! A receipt answers a retry of its request exactly once: the same key gets
//! the stored outcome instead of a second tab or workspace. A retry comes
//! from a client that lost the answer (a reconnect, a restart mid-request),
//! so it names a recent request; nothing reads a committed receipt for any
//! other reason once its commit is done. They were kept forever, so a session
//! that is never closed grew a row (1.1-1.4 KB with its intent and outcome)
//! for every tab, browser and workspace it had ever made: 2,360 creation and
//! 2,972 effect receipts after three simulated days at 1,000 workspaces.
//!
//! The window is the one `resource_mutations` already keeps for the same
//! retries ([`RESOURCE_MUTATION_REPLAY_CAPACITY`]), in insertion order, and
//! it runs where that one runs: at each open and every
//! `RESOURCE_MUTATION_PRUNE_INTERVAL` revisions. It never removes
//! - a receipt still in flight (pending, prepared, executing, indeterminate):
//!   the open's recovery and a resumed request read it;
//! - a `notification.create` receipt: it is the notification ledger itself
//!   (the shown list, reads, acks, clears and the local feed read it);
//! - a transient input receipt: those keep their own window
//!   (`input_receipts`).
//!
//! A creation receipt and the effect receipt that made it go together, so a
//! retry past the window is a new request on both, never half of one.

use super::*;
use crate::workspace_registry::resource_store::RESOURCE_MUTATION_REPLAY_CAPACITY;

/// The committed creation receipts past the window, newest kept.
const CREATIONS_PAST_WINDOW: &str = "SELECT correlation_key FROM resource_creation_receipts
   WHERE state IN ('created', 'not_applied')
   ORDER BY rowid DESC
   LIMIT -1 OFFSET ?1";

pub(crate) fn compact_resource_receipts(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let window = i64::try_from(RESOURCE_MUTATION_REPLAY_CAPACITY)?;
    // The effects of the creations about to go, while those still name them.
    transaction.execute(
        &format!(
            "DELETE FROM resource_effect_receipts
             WHERE state = 'committed'
               AND operation != 'notification.create'
               AND idempotency_key IN (
                 SELECT idempotency_key FROM resource_creation_receipts
                 WHERE correlation_key IN ({CREATIONS_PAST_WINDOW})
               )"
        ),
        [window],
    )?;
    transaction.execute(
        &format!(
            "DELETE FROM resource_creation_receipts
             WHERE correlation_key IN ({CREATIONS_PAST_WINDOW})"
        ),
        [window],
    )?;
    // The effects no creation names: tab.close, tab.create_terminal's
    // effect-only paths and the rest.
    transaction.execute(
        &format!(
            "DELETE FROM resource_effect_receipts
             WHERE idempotency_key IN (
               SELECT effect.idempotency_key
               FROM resource_effect_receipts AS effect
               WHERE effect.state = 'committed'
                 AND effect.operation != 'notification.create'
                 AND NOT {TRANSIENT_INPUT_EFFECT_SQL}
                 AND NOT EXISTS (
                   SELECT 1 FROM resource_creation_receipts AS creation
                   WHERE creation.idempotency_key = effect.idempotency_key
                 )
               ORDER BY effect.rowid DESC
               LIMIT -1 OFFSET ?1
             )"
        ),
        [window],
    )?;
    Ok(())
}
