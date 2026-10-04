//! Raw protocol handlers of the asset blob store (`icon-assets-v1`,
//! plans/cmux-next/sidebar-sections.md section 9a). `put-blob` stores one
//! PNG, JPEG, WebP or sanitized SVG and returns its content address and the
//! icon value that names it; `get-blob` returns the stored bytes. Icon
//! fields then take `image:sha256-<hex>` or `svg:sha256-<hex>`.

use base64::Engine;
use serde::Deserialize;
use serde_json::Value;

use super::Mux;
use crate::workspace_registry::personal_store::blobs::{
    IconAssetError, MAX_BASE64_BYTES, invalid_asset, prepare_blob,
};

/// The blob store, `put-blob`, `get-blob`, and asset icon values
/// (`image:sha256-<hex>`, `svg:sha256-<hex>`) on every icon field.
pub const ICON_ASSETS_CAPABILITY: &str = "icon-assets-v1";

/// `put-blob`: one asset, base64 in `data`.
#[derive(Deserialize)]
pub(super) struct PutParams {
    media_type: String,
    data: String,
}

/// `get-blob`: `blob` is `blob:sha256-<hex>` or an asset icon value.
#[derive(Deserialize)]
pub(super) struct GetParams {
    blob: String,
}

/// The `error_code` of a refused blob command or icon asset.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<IconAssetError>().map(|error| error.code().to_string())
}

pub(super) fn put(mux: &Mux, params: PutParams) -> anyhow::Result<Value> {
    if params.data.len() > MAX_BASE64_BYTES {
        return Err(invalid_asset(format!("data exceeds {MAX_BASE64_BYTES} base64 bytes")));
    }
    let data = base64::engine::general_purpose::STANDARD
        .decode(params.data.as_bytes())
        .map_err(|_| invalid_asset("data must be standard base64"))?;
    // Sanitize and hash before the registry lock: neither needs the store.
    let blob = prepare_blob(&params.media_type, &data)?;
    let blob = mux.workspace_registry.lock().unwrap().put_blob(blob)?;
    Ok(blob.to_json(false))
}

pub(super) fn get(mux: &Mux, params: GetParams) -> anyhow::Result<Value> {
    let blob = mux.workspace_registry.lock().unwrap().get_blob(&params.blob)?;
    Ok(blob.to_json(true))
}

#[cfg(test)]
#[path = "icon_asset_tests.rs"]
mod tests;
