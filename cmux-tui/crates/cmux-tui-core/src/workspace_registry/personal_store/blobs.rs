//! Content-addressed asset blobs of the home session (`icon-assets-v1`,
//! plans/cmux-next/sidebar-sections.md section 9a): custom icon images that
//! an icon field names as `image:sha256-<hex>` or `svg:sha256-<hex>`.
//!
//! A blob is keyed by the SHA-256 of its stored bytes, so `put-blob` is
//! idempotent: the same bytes again return the same reference and only
//! refresh the blob's age. PNG, JPEG and WebP are stored as given (at most
//! 256 KiB, checked by magic bytes, never by the declared type alone). An SVG
//! is parsed and re-serialized by `svg::sanitize_svg` and the sanitized
//! bytes are stored (at most 64 KiB before and after).
//!
//! Garbage collection: a sweep at registry open and before each new put
//! deletes the blobs that no field in `ICON_REFERENCE_FIELDS` names and that
//! nobody put for `UNREFERENCED_GRACE_MS`. A put that would take the store
//! past `MAX_TOTAL_BYTES` after the sweep is refused.
//!
//! The table is additive and carries no foreign key, so an older binary that
//! opens the registry ignores it. Blobs are not journaled and emit no event:
//! a blob never changes, and the icon field that names it carries the change.

use std::collections::HashSet;

use base64::Engine;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use sha2::{Digest, Sha256};

use super::super::WorkspaceRegistry;
use super::super::presentation_store::{
    IconAssetKind, is_sha256_hex, parse_icon_asset, validate_presentation_icon,
};
use super::super::session_journal::unix_epoch_ms;

mod svg;
pub use svg::sanitize_svg;

/// Largest stored PNG, JPEG or WebP, in bytes.
pub const MAX_RASTER_BYTES: usize = 256 * 1024;
/// Largest SVG, in bytes, before and after sanitizing.
pub const MAX_SVG_BYTES: usize = 64 * 1024;
/// Largest total size of every stored blob, in bytes.
pub const MAX_TOTAL_BYTES: u64 = 64 * 1024 * 1024;
/// How long a blob that no field names survives after its last put.
pub const UNREFERENCED_GRACE_MS: u64 = 7 * 24 * 60 * 60 * 1000;
/// Longest accepted base64 `data`: the raster limit, encoded with padding.
pub const MAX_BASE64_BYTES: usize = MAX_RASTER_BYTES.div_ceil(3) * 4;

/// Every stored field that can hold an icon value (or a JSON document with
/// icon values). The sweep keeps each blob one of them names. A new entity
/// that takes an icon adds its field here.
pub(crate) const ICON_REFERENCE_FIELDS: &[(&str, &str)] = &[
    ("workspace_presentation", "icon"),
    ("screen_presentation", "icon"),
    ("saved_screen_groups", "members_json"),
    ("profiles", "icon"),
    ("browser_profiles", "icon"),
    ("workspace_status_entries", "icon"),
    ("closed_history", "record_json"),
];

pub(crate) fn create_blob_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS personal_blobs (
           digest TEXT PRIMARY KEY NOT NULL,
           media_type TEXT NOT NULL,
           data BLOB NOT NULL,
           size INTEGER NOT NULL CHECK(size >= 0),
           touched_ms INTEGER NOT NULL CHECK(touched_ms >= 0)
         );",
    )?;
    Ok(())
}

/// A refused blob or icon asset request with a stable `error_code`.
#[derive(Debug)]
pub struct IconAssetError {
    code: &'static str,
    message: String,
}

impl IconAssetError {
    pub fn code(&self) -> &'static str {
        self.code
    }
}

impl std::fmt::Display for IconAssetError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for IconAssetError {}

/// `invalid_params`: the media type, data, size or SVG is refused.
pub(crate) fn invalid_asset(message: impl std::fmt::Display) -> anyhow::Error {
    IconAssetError { code: "invalid_params", message: format!("bad request: {message}") }.into()
}

fn asset_error(code: &'static str, message: String) -> anyhow::Error {
    IconAssetError { code, message }.into()
}

/// The media types the store accepts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlobMediaType {
    Png,
    Jpeg,
    Webp,
    Svg,
}

impl BlobMediaType {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "image/png" => Some(Self::Png),
            "image/jpeg" => Some(Self::Jpeg),
            "image/webp" => Some(Self::Webp),
            "image/svg+xml" => Some(Self::Svg),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Jpeg => "image/jpeg",
            Self::Webp => "image/webp",
            Self::Svg => "image/svg+xml",
        }
    }

    pub fn kind(self) -> IconAssetKind {
        if self == Self::Svg { IconAssetKind::Svg } else { IconAssetKind::Raster }
    }

    /// Whether `data` starts with this raster type's signature.
    fn matches_magic(self, data: &[u8]) -> bool {
        match self {
            Self::Png => data.starts_with(b"\x89PNG\r\n\x1a\n"),
            Self::Jpeg => data.starts_with(b"\xff\xd8\xff"),
            Self::Webp => data.len() >= 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WEBP",
            Self::Svg => false,
        }
    }
}

/// One stored blob.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredBlob {
    pub digest: String,
    pub media_type: BlobMediaType,
    pub data: Vec<u8>,
}

impl StoredBlob {
    /// `blob:sha256-<hex>`.
    pub fn reference(&self) -> String {
        format!("blob:sha256-{}", self.digest)
    }

    /// The icon value that names this blob.
    pub fn icon(&self) -> String {
        let prefix = if self.media_type == BlobMediaType::Svg { "svg" } else { "image" };
        format!("{prefix}:sha256-{}", self.digest)
    }

    /// The `put-blob` and `get-blob` result fields (`data` only for get).
    pub fn to_json(&self, with_data: bool) -> serde_json::Value {
        let mut value = serde_json::json!({
            "ref": self.reference(),
            "icon": self.icon(),
            "media_type": self.media_type.as_str(),
            "size": self.data.len(),
        });
        if with_data {
            value["data"] = base64::engine::general_purpose::STANDARD.encode(&self.data).into();
        }
        value
    }
}

/// The digest a `get-blob` reference names: `blob:sha256-<hex>`, or an
/// icon value `image:sha256-<hex>` / `svg:sha256-<hex>`.
pub fn parse_blob_reference(value: &str) -> Option<&str> {
    if let Some(digest) = value.strip_prefix("blob:sha256-") {
        return is_sha256_hex(digest).then_some(digest);
    }
    parse_icon_asset(value).map(|asset| asset.digest)
}

/// Check, size, sanitize and hash one asset. Returns the bytes to store.
pub(crate) fn prepare_blob(media_type: &str, data: &[u8]) -> anyhow::Result<StoredBlob> {
    let _ = (media_type, data);
    Err(invalid_asset("icon assets are not implemented yet"))
}

/// Store one prepared blob in the caller's transaction. An existing blob
/// only refreshes its age (`changed` false). A new blob first sweeps, then
/// must fit under `MAX_TOTAL_BYTES`.
pub(crate) fn put_blob_in(
    transaction: &Transaction<'_>,
    blob: &StoredBlob,
    now_ms: u64,
) -> anyhow::Result<bool> {
    let _ = (transaction, blob, now_ms);
    Err(invalid_asset("icon assets are not implemented yet"))
}

pub(crate) fn read_blob(connection: &Connection, digest: &str) -> anyhow::Result<Option<StoredBlob>> {
    let _ = (connection, digest);
    Ok(None)
}

/// Refuse an icon value that names an asset the store does not hold with a
/// matching media type. Symbols and emoji pass. Setters call this in the
/// transaction that writes the icon, so no sweep can run in between.
pub(crate) fn require_icon_asset(connection: &Connection, icon: &str) -> anyhow::Result<()> {
    let _ = connection;
    validate_presentation_icon(icon)
}

/// Every digest any registered icon field names. A JSON field counts every
/// `sha256-<hex>` it contains, so the set may only over-keep.
pub(crate) fn referenced_digests(connection: &Connection) -> anyhow::Result<HashSet<String>> {
    let _ = connection;
    Ok(HashSet::new())
}

/// Delete every blob that no registered field names and that was last put
/// more than `UNREFERENCED_GRACE_MS` before `now_ms`. Returns the count.
pub(crate) fn sweep_blobs(connection: &Connection, now_ms: u64) -> anyhow::Result<usize> {
    let _ = (connection, now_ms);
    Ok(0)
}

/// Create the table and run the open-time sweep, in the open transaction.
pub(crate) fn open_blob_store(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    create_blob_schema(transaction)?;
    sweep_blobs(transaction, unix_epoch_ms()?)?;
    Ok(())
}

impl WorkspaceRegistry {
    /// `put-blob`: store one asset and return it (without re-reading).
    pub fn put_blob(&mut self, media_type: &str, data: &[u8]) -> anyhow::Result<StoredBlob> {
        let blob = prepare_blob(media_type, data)?;
        let tx = self.connection.transaction()?;
        put_blob_in(&tx, &blob, unix_epoch_ms()?)?;
        tx.commit()?;
        Ok(blob)
    }

    /// `get-blob`: the stored asset a reference names.
    pub fn get_blob(&self, reference: &str) -> anyhow::Result<StoredBlob> {
        let digest = parse_blob_reference(reference).ok_or_else(|| {
            invalid_asset("blob must be blob:sha256-<64 lowercase hex> or an asset icon value")
        })?;
        read_blob(&self.connection, digest)?
            .ok_or_else(|| asset_error("not_found", format!("not found: no blob {reference}")))
    }

    /// Refuse an icon that names an asset this store does not hold (checks
    /// made before a multi-step command starts; see [`require_icon_asset`]).
    pub(crate) fn require_icon_asset(&self, icon: &str) -> anyhow::Result<()> {
        require_icon_asset(&self.connection, icon)
    }

    /// Run the sweep as if the clock read `now_ms` (tests).
    #[cfg(test)]
    pub(crate) fn sweep_blobs_at(&mut self, now_ms: u64) -> anyhow::Result<usize> {
        sweep_blobs(&self.connection, now_ms)
    }

    /// Store a blob as if the clock read `now_ms` (tests).
    #[cfg(test)]
    pub(crate) fn put_blob_at(
        &mut self,
        media_type: &str,
        data: &[u8],
        now_ms: u64,
    ) -> anyhow::Result<StoredBlob> {
        let blob = prepare_blob(media_type, data)?;
        let tx = self.connection.transaction()?;
        put_blob_in(&tx, &blob, now_ms)?;
        tx.commit()?;
        Ok(blob)
    }
}

#[cfg(test)]
#[path = "blobs_tests.rs"]
mod tests;
