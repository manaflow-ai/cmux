//! The signed Cloud machine channel (pure): what CI publishes at
//! [`CHANNEL_URL`] after every feat-cmux-next push whose cmux-tui build is
//! published (`point-machine-channel` in .github/workflows/cmux-tui-artifacts.yml,
//! payload by scripts/ci/cmux-machine-channel.py).
//!
//! The file is the web update pointer's envelope (scripts/cmux-next/web-ota-pointer.py
//! signs and verifies both), around exact payload bytes:
//!
//! ```json
//! {"schema": 1, "payload": "<base64 payload JSON>", "signatures": [{"key_id": "…", "sig": "<base64>"}]}
//! ```
//!
//! [`verify`] checks an ed25519 signature by a [`KEYS`] key over those bytes
//! before it reads any payload field. The key is the web update channel's
//! (CMUX_WEB_OTA_SIGNING_KEY of the `artifacts` environment; its private half
//! never leaves CI); the two kinds of file cannot stand in for each other:
//! this payload must say [`PURPOSE`] and the channel [`CHANNEL`], and the
//! app's web updater refuses a pointer for any channel but its own.

use std::collections::BTreeMap;

use base64::Engine as _;
use ring::signature::{ED25519, UnparsedPublicKey};
use serde::Deserialize;

/// Public, no credentials. Served with max-age 60, but the CDN does not
/// cache it (its cache status reads DYNAMIC, 2026-11-13), so every check
/// reaches the origin. The origin names an ETag and a Last-Modified and
/// answers a matching conditional GET with 304 and no body, so a check sends
/// the validators of the last file that verified ([`Cache`]) and an unchanged
/// channel costs a few hundred bytes of headers, not the whole file.
pub const CHANNEL_URL: &str = "https://files.cmux.com/cmux-tui/channels/cloud-machine.json";
/// The payload's `channel`.
pub const CHANNEL: &str = "cloud-machine";
/// The payload's `purpose`: no web update payload carries it.
pub const PURPOSE: &str = "cmux-cloud-machine-update";
pub const SCHEMA: u64 = 1;
/// Every binary comes from the immutable commit-addressed publication.
pub const FILES_PREFIX: &str = "https://files.cmux.com/cmux-tui/";
/// The directory of a commit's Cloud machine copy, `cmux-tui/<commit>/machine/`:
/// the same commit built for the machine channel alone (thin LTO), uploaded
/// by `point-machine-channel-early` (scripts/ci/cmux-machine-linux-bytes.sh
/// early) so it never takes the shipped `cmux-tui/<commit>/<name>` names.
pub const MACHINE_DIR: &str = "machine/";
/// A channel file is a few kilobytes.
pub const CHANNEL_MAX_BYTES: usize = 64 * 1024;
/// A cmux-tui build is about 160 MB.
pub const BINARY_MAX_BYTES: u64 = 512 * 1024 * 1024;
/// The binaries an update replaces, by their store file names.
pub const CMUX_TUI: &str = "cmux-tui";
pub const CMUX_TUI_HOOK: &str = "cmux-tui-hook";

/// The keys a channel file may be signed with: `(id, raw ed25519 key, base64)`.
/// The same key as Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json
/// (the test `keys_match_the_web_update_keys` keeps them equal). To rotate,
/// add the next key here and ship it in machines before CI signs with it.
pub const KEYS: &[(&str, &str)] =
    &[("e5d7bbcacc70703d", "uroy2ajE6JWnMjkx3FNdn88SJN4DCMfLpqZjkwx45WY=")];

#[derive(Deserialize)]
struct Envelope {
    schema: u64,
    payload: String,
    signatures: Vec<Signature>,
}

#[derive(Deserialize)]
struct Signature {
    key_id: String,
    sig: String,
}

/// One binary of a build.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Binary {
    pub url: String,
    pub sha256: String,
    pub size: u64,
}

/// The channel's build: the commit, when it was committed (the order a
/// machine never goes back on) and, per Rust target, its binaries by
/// store file name ([`CMUX_TUI`], [`CMUX_TUI_HOOK`]).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Payload {
    pub schema: u64,
    pub purpose: String,
    pub channel: String,
    pub commit: String,
    pub committed_at: u64,
    pub published_at: u64,
    pub expires_at: u64,
    pub targets: BTreeMap<String, BTreeMap<String, Binary>>,
}

impl Payload {
    /// The binaries for `target`, both of them, checked.
    pub fn binaries_for(&self, target: &str) -> Result<(&Binary, &Binary), String> {
        let set = self
            .targets
            .get(target)
            .ok_or_else(|| format!("the channel has no build for {target}"))?;
        let get = |name: &str| {
            let binary =
                set.get(name).ok_or_else(|| format!("the channel has no {name} for {target}"))?;
            check_binary(binary, &self.commit, &format!("{name}-{target}"))?;
            Ok::<_, String>(binary)
        };
        Ok((get(CMUX_TUI)?, get(CMUX_TUI_HOOK)?))
    }
}

pub fn lower_hex(text: &str, len: usize) -> bool {
    text.len() == len && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The two URLs a binary of `commit` may have: its publication
/// `cmux-tui/<commit>/<name>`, or its Cloud machine copy
/// `cmux-tui/<commit>/machine/<name>`. A binary's url must equal one of them
/// exactly; nothing else under the prefix (another commit, another name,
/// another directory) passes.
pub fn allowed_urls(commit: &str, published_name: &str) -> [String; 2] {
    [
        format!("{FILES_PREFIX}{commit}/{published_name}"),
        format!("{FILES_PREFIX}{commit}/{MACHINE_DIR}{published_name}"),
    ]
}

fn check_binary(binary: &Binary, commit: &str, published_name: &str) -> Result<(), String> {
    let urls = allowed_urls(commit, published_name);
    if !urls.contains(&binary.url) {
        return Err(format!("{published_name}: the url is neither {} nor {}", urls[0], urls[1]));
    }
    if !lower_hex(&binary.sha256, 64) {
        return Err(format!("{published_name}: the sha256 is not a sha256"));
    }
    if binary.size == 0 || binary.size > BINARY_MAX_BYTES {
        return Err(format!("{published_name}: size {} is out of range", binary.size));
    }
    Ok(())
}

/// The trusted keys of [`KEYS`], decoded.
pub fn trusted_keys() -> Vec<(String, [u8; 32])> {
    KEYS.iter()
        .filter_map(|(id, b64)| {
            let raw = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
            let raw: [u8; 32] = raw.try_into().ok()?;
            Some(((*id).to_owned(), raw))
        })
        .collect()
}

/// The payload of `body` when a `keys` signature covers it and it is this
/// channel's, unexpired at `now` (unix seconds); else why not.
pub fn verify(body: &[u8], keys: &[(String, [u8; 32])], now: u64) -> Result<Payload, String> {
    let envelope: Envelope =
        serde_json::from_slice(body).map_err(|_| "the channel file is not an envelope")?;
    if envelope.schema != SCHEMA {
        return Err(format!("unknown envelope schema {}", envelope.schema));
    }
    let b64 = base64::engine::general_purpose::STANDARD;
    let payload = b64.decode(&envelope.payload).map_err(|_| "the payload is not base64")?;
    let signed = envelope.signatures.iter().any(|signature| {
        let Some((_, key)) = keys.iter().find(|(id, _)| *id == signature.key_id) else {
            return false;
        };
        let Ok(sig) = b64.decode(&signature.sig) else { return false };
        UnparsedPublicKey::new(&ED25519, key).verify(&payload, &sig).is_ok()
    });
    if !signed {
        return Err("no valid signature by a trusted key".to_owned());
    }
    let payload: Payload =
        serde_json::from_slice(&payload).map_err(|e| format!("the payload does not parse: {e}"))?;
    if payload.schema != SCHEMA {
        return Err(format!("unknown payload schema {}", payload.schema));
    }
    if payload.purpose != PURPOSE || payload.channel != CHANNEL {
        return Err(format!(
            "the payload is for {} channel {}, not a Cloud machine update",
            payload.purpose, payload.channel
        ));
    }
    if !lower_hex(&payload.commit, 40) {
        return Err("the payload names no commit".to_owned());
    }
    if payload.expires_at <= now {
        return Err(format!("the channel file expired at {} (now {now})", payload.expires_at));
    }
    Ok(payload)
}

/// What one read of [`CHANNEL_URL`] answered.
#[derive(Debug, PartialEq, Eq)]
pub enum Answer {
    /// 200: the file, and the validators its response named.
    Full { body: Vec<u8>, etag: Option<String>, last_modified: Option<String> },
    /// 304: the file is the one the validators sent name.
    NotModified,
}

/// A response header longer than this is not a validator to send back.
const VALIDATOR_MAX: usize = 256;

/// `value` when it can go back out as a request header as it is: visible
/// ASCII and spaces, no CR or LF, short.
fn validator(value: &str) -> Option<String> {
    let value = value.trim();
    let ok = !value.is_empty()
        && value.len() <= VALIDATOR_MAX
        && value.bytes().all(|b| (0x20..0x7f).contains(&b));
    ok.then(|| value.to_owned())
}

/// The [`Answer`] in curl's `--include` output: the status line and headers,
/// a blank line, the body. A block another block follows (a 1xx, a proxy's
/// CONNECT, a response `--retry` read again) is skipped: a channel file
/// starts with `{`, never `HTTP/`. Any status but 200 and 304 is an error (curl's
/// `--fail` already refuses 4xx and 5xx; redirects are not followed).
pub fn parse_response(raw: &[u8]) -> Result<Answer, String> {
    let mut rest = raw;
    loop {
        let end = rest
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .ok_or("the response has no header block")?;
        let (head, body) = rest.split_at_checked(end).ok_or("the response has no header block")?;
        let body = body.strip_prefix(b"\r\n\r\n").ok_or("the response has no header block")?;
        let head = std::str::from_utf8(head).map_err(|_| "the headers are not text")?;
        let status: u16 = head
            .split("\r\n")
            .next()
            .filter(|line| line.starts_with("HTTP/"))
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|code| code.parse().ok())
            .ok_or("the response has no status line")?;
        if (100..200).contains(&status) || body.starts_with(b"HTTP/") {
            rest = body;
            continue;
        }
        let header = |name: &str| {
            head.split("\r\n").skip(1).find_map(|line| {
                let (key, value) = line.split_once(':')?;
                key.trim().eq_ignore_ascii_case(name).then(|| validator(value)).flatten()
            })
        };
        return match status {
            200 => Ok(Answer::Full {
                body: body.to_vec(),
                etag: header("etag"),
                last_modified: header("last-modified"),
            }),
            304 => Ok(Answer::NotModified),
            other => Err(format!("the origin answered HTTP {other}")),
        };
    }
}

/// The last channel file that verified, kept in memory with the validators
/// of the response that carried it. A 304 is only ever an answer to those
/// validators, and it is never trusted by itself: [`Cache::take`] verifies
/// the kept bytes again (signature, channel and expiry against `now`), as if
/// they had just arrived.
#[derive(Debug, Default)]
pub struct Cache {
    kept: Option<Kept>,
}

#[derive(Debug)]
struct Kept {
    body: Vec<u8>,
    etag: Option<String>,
    last_modified: Option<String>,
}

impl Cache {
    pub const fn new() -> Self {
        Self { kept: None }
    }

    /// `(If-None-Match, If-Modified-Since)` for the next read: the kept
    /// file's validators, none when no file is kept.
    pub fn validators(&self) -> (Option<String>, Option<String>) {
        match &self.kept {
            Some(kept) => (kept.etag.clone(), kept.last_modified.clone()),
            None => (None, None),
        }
    }

    /// The payload `answer` stands for. A 200 is verified and, when it
    /// verifies and names a validator, kept; a 304 verifies the kept file
    /// again, and with no kept file it is refused. A file that fails (a new
    /// one that does not verify, a kept one that expired) is not kept, so
    /// the next read is unconditional.
    pub fn take(
        &mut self,
        answer: Answer,
        keys: &[(String, [u8; 32])],
        now: u64,
    ) -> Result<Payload, String> {
        match answer {
            Answer::NotModified => {
                let Some(kept) = &self.kept else {
                    return Err("304 Not Modified, but no verified file is kept".to_owned());
                };
                let verified = verify(&kept.body, keys, now);
                if verified.is_err() {
                    self.kept = None;
                }
                verified
            }
            Answer::Full { body, etag, last_modified } => {
                let verified = verify(&body, keys, now);
                self.kept = match (&verified, etag.is_some() || last_modified.is_some()) {
                    (Ok(_), true) => Some(Kept { body, etag, last_modified }),
                    _ => None,
                };
                verified
            }
        }
    }
}

/// This machine's Rust target, as the published binaries name it.
pub fn local_target() -> Option<&'static str> {
    match std::env::consts::ARCH {
        "x86_64" => Some("x86_64-unknown-linux-musl"),
        "aarch64" => Some("aarch64-unknown-linux-musl"),
        _ => None,
    }
}
