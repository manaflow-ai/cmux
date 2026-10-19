//! An explicit registry-only refresh over cached installation evidence.
//! It never probes a program, reads sign-ins, rescans profiles or updates.

use std::collections::BTreeMap;
use std::sync::PoisonError;
use std::time::Duration;

use futures::{StreamExt, stream};
use serde_json::{Value, json};

use super::{HealthService, channel, inventory, latest, now_ms, probe, save};
use crate::rpc::RpcError;

pub(crate) const INVENTORY_REFRESH_FEATURE: &str = "harnessInventoryRefresh";
// The same bounded prefix the inventory projection can expose. Requests
// share the check lock without waiting, so a slow owner cannot queue work.
const REGISTRY_PARALLELISM: usize = 4;
const REFRESH_LIMIT: Duration = Duration::from_secs(20);

fn refused(reason: &str) -> RpcError {
    RpcError::new(-32000, reason)
        .with_data(json!({"reason":reason,"retryable":reason != "harness_inventory.unsupported"}))
}

impl HealthService {
    /// Updates only latest-version fields for existing cached installations.
    /// A failed source retains its old value and timestamp as older evidence.
    pub(crate) async fn refresh_inventory_latest(&self) -> Result<Value, RpcError> {
        let _check = self.checking.try_lock().map_err(|_| refused("harness_inventory.busy"))?;
        let settings = self.settings.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let sources =
            settings.sources.as_ref().ok_or_else(|| refused("harness_inventory.unsupported"))?;
        let queries: BTreeMap<String, channel::Channel> = {
            let rows = self.rows.lock().unwrap_or_else(PoisonError::into_inner);
            inventory::visible_rows(&rows)
                .filter_map(|row| {
                    let install = channel::Install {
                        channel: row.channel,
                        package: row.package.clone(),
                        writes: None,
                    };
                    latest::url(&install, sources).map(|url| (url, row.channel))
                })
                .collect()
        };
        let requests = stream::iter(queries).map(|(url, channel)| async move {
            let value = latest::fetch_json(&url)
                .await
                .ok()
                .and_then(|body| latest::parse(channel, &body))
                .filter(|version| {
                    inventory::safe_version(Some(version)).is_some()
                        && probe::compare_versions(version, version).is_some()
                });
            (url, value)
        });
        let answers: BTreeMap<String, Option<String>> = tokio::time::timeout(
            REFRESH_LIMIT,
            requests.buffer_unordered(REGISTRY_PARALLELISM).collect(),
        )
        .await
        .map_err(|_| refused("harness_inventory.timeout"))?;
        // A startup/configuration replacement cannot commit answers from its
        // former registry into the new owner's cache. Lock order is settings,
        // then rows, as set_auto_update uses too.
        let current_settings = self.settings.lock().unwrap_or_else(PoisonError::into_inner);
        if current_settings.cache != settings.cache
            || !current_settings
                .sources
                .as_ref()
                .is_some_and(|current| current.npm == sources.npm && current.brew == sources.brew)
        {
            return Err(refused("harness_inventory.unavailable"));
        }
        let checked_at = now_ms();
        let rows = self.update_rows(|rows| {
            for row in rows.iter_mut() {
                let install = channel::Install {
                    channel: row.channel,
                    package: row.package.clone(),
                    writes: None,
                };
                let Some(Some(latest)) =
                    latest::url(&install, sources).and_then(|url| answers.get(&url))
                else {
                    continue;
                };
                row.latest = Some(latest.clone());
                row.latest_checked_at = Some(checked_at);
                row.outdated =
                    row.version.as_deref().is_some_and(|version| probe::is_newer(latest, version));
            }
            rows.clone()
        });
        if let Some(cache) = current_settings.cache.as_deref() {
            save(cache, &rows);
        }
        Ok(inventory::snapshot(&rows))
    }
}
