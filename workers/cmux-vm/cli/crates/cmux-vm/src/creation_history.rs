//! Pending history advances bounded index work only during this explicit command.
use cmux_vm_client::raw::{Client, types};
use serde_json::Value;

use crate::{error::CliError, fetch_body};

pub async fn fetch(
    client: &Client,
    raw_cursor: Option<String>,
    limit: Option<u32>,
    pending: bool,
    index_pages: u32,
) -> Result<Vec<u8>, CliError> {
    if let Some(value) = &raw_cursor {
        let pending_cursor = value.starts_with("p1_") || value.starts_with("i1_");
        if pending != pending_cursor {
            return Err(CliError::usage(
                "the cursor belongs to a different history view; preserve --pending when continuing",
            ));
        }
    }
    let mut cursor = raw_cursor
        .map(|value| value.parse::<types::VmCreationsListVmCreationsCursor>())
        .transpose()
        .map_err(|_| CliError::usage("invalid --cursor"))?;
    let limit = limit.map(|value| value.to_string());
    let state = pending.then_some(types::VmCreationsListVmCreationsState::Pending);
    for attempt in 0..index_pages {
        let body = fetch_body(client.vm_creations_list_vm_creations(
            cursor.as_ref(),
            limit.as_deref(),
            state,
            None,
        ))
        .await?;
        if !pending {
            return Ok(body);
        }
        let page: Value = serde_json::from_slice(&body)
            .map_err(|_| CliError::unexpected("invalid pending history response"))?;
        let items = page["items"]
            .as_array()
            .ok_or_else(|| CliError::unexpected("invalid pending history items"))?;
        if items
            .iter()
            .any(|item| item["state"].as_str() != Some("pending"))
        {
            return Err(CliError::unexpected(
                "pending history returned a completed or unresolved creation",
            ));
        }
        match page["pendingIndex"].as_str() {
            Some("ready" | "unavailable") => return Ok(body),
            Some("building") if items.is_empty() => {}
            _ => {
                return Err(CliError::unexpected(
                    "this API does not support pending history",
                ));
            }
        }
        let next = page["nextCursor"]
            .as_str()
            .filter(|value| value.starts_with("i1_"))
            .ok_or_else(|| CliError::unexpected("pending history omitted its index cursor"))?;
        if cursor.as_ref().is_some_and(|old| old.to_string() == next) {
            return Err(CliError::unexpected(
                "pending history index made no progress",
            ));
        }
        cursor = Some(
            next.parse()
                .map_err(|_| CliError::unexpected("invalid pending history index cursor"))?,
        );
        if attempt + 1 == index_pages {
            return Ok(body);
        }
    }
    Err(CliError::usage("index page budget must be positive"))
}
