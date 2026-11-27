//! The sealed record format for end-to-end encrypted browser sync (RFD 0125 D8, second row of the table), used first
//! for open tabs. The header (version, profile, collection, record id, key version) is plain so a store can route
//! and replace records; it is also the AEAD's associated data, so a sealed body cannot be moved to another record,
//! profile, collection or key version without failing to open.

use anyhow::{bail, ensure};
use serde::{Deserialize, Serialize};

use crate::keys::{ProfileKey, b64, open, seal, unb64};

/// The format version.
pub const ENVELOPE_VERSION: u32 = 1;

/// One sealed record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Envelope {
    pub v: u32,
    pub profile: String,
    /// `tabs` first; `history` and `bookmarks` follow in step 3.
    pub collection: String,
    /// The record's id in its collection (for tabs: the device id, one snapshot per device).
    pub record: String,
    pub key_version: u32,
    pub nonce: String,
    pub ciphertext: String,
}

fn header(profile: &str, collection: &str, record: &str, key_version: u32) -> Vec<u8> {
    format!("cmux-browser-sync/envelope/v{ENVELOPE_VERSION}\n{profile}\n{collection}\n{record}\n{key_version}")
        .into_bytes()
}

impl Envelope {
    pub fn seal(
        key: &ProfileKey,
        profile: &str,
        collection: &str,
        record: &str,
        key_version: u32,
        plaintext: &[u8],
    ) -> anyhow::Result<Self> {
        for (name, value) in [("profile", profile), ("collection", collection), ("record", record)]
        {
            ensure!(
                !value.is_empty() && !value.contains('\n'),
                "envelope {name} must be one non-empty line"
            );
        }
        let (nonce, ciphertext) =
            seal(key.bytes(), &header(profile, collection, record, key_version), plaintext)?;
        Ok(Self {
            v: ENVELOPE_VERSION,
            profile: profile.to_owned(),
            collection: collection.to_owned(),
            record: record.to_owned(),
            key_version,
            nonce: b64(&nonce),
            ciphertext: b64(&ciphertext),
        })
    }

    pub fn open(&self, key: &ProfileKey) -> anyhow::Result<Vec<u8>> {
        if self.v != ENVELOPE_VERSION {
            bail!("envelope version {} is not supported", self.v);
        }
        let aad = header(&self.profile, &self.collection, &self.record, self.key_version);
        open(key.bytes(), &aad, &unb64(&self.nonce)?, &unb64(&self.ciphertext)?)
    }
}

/// One open tab, as another device shows it ("Open tabs on other devices"). URLs first (RFD 0125 table, row 7).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenTab {
    pub url: String,
    #[serde(default)]
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    #[serde(default)]
    pub pinned: bool,
}

/// A device's open tabs in one profile: the whole snapshot, replaced on each change (last writer wins per device).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenTabs {
    pub device: String,
    pub captured_at_ms: u64,
    pub tabs: Vec<OpenTab>,
}

/// The collection name of open tabs.
pub const TABS: &str = "tabs";

impl OpenTabs {
    pub fn seal(
        &self,
        key: &ProfileKey,
        profile: &str,
        key_version: u32,
    ) -> anyhow::Result<Envelope> {
        Envelope::seal(key, profile, TABS, &self.device, key_version, &serde_json::to_vec(self)?)
    }

    pub fn open(envelope: &Envelope, key: &ProfileKey) -> anyhow::Result<Self> {
        ensure!(envelope.collection == TABS, "not an open-tabs envelope");
        let tabs: Self = serde_json::from_slice(&envelope.open(key)?)?;
        ensure!(
            tabs.device == envelope.record,
            "the sealed device does not match the envelope's record"
        );
        Ok(tabs)
    }
}
