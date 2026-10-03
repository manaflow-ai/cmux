//! Secret vault and output masking, below the agent's JS VM.
//!
//! The VM holds only handles (`{__secret: name}`). The host types a secret's
//! value only into a frame whose URL matches the secret's domains, computes
//! TOTP codes itself, and masks every value variant in all text that leaves
//! the host. Passwords are not secrets here: agents use the Secure sign-in
//! sheet and never see them (plans/cmux-next/browser-host.md section 4).

use crate::policy::{DomainPattern, PolicyError};
use serde_json::Value;
use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;
use url::Url;

struct Entry {
    value: String,
    domains: Vec<DomainPattern>,
    totp: bool,
    /// Set from agent code: the agent already knows the value; masking only.
    agent_known: bool,
}

impl fmt::Debug for Entry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Entry")
            .field("value", &"<redacted>")
            .field("domains", &self.domains.iter().map(|d| d.raw.as_str()).collect::<Vec<_>>())
            .field("totp", &self.totp)
            .field("agent_known", &self.agent_known)
            .finish()
    }
}

/// What the VM may learn about a secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SecretInfo {
    pub name: String,
    pub domains: Vec<String>,
    pub totp: bool,
    pub agent_known: bool,
}

#[derive(Debug, Default)]
pub struct Vault {
    entries: BTreeMap<String, Entry>,
}

impl Vault {
    /// Adds or replaces a secret. `totp` values must be base32.
    pub fn set(
        &mut self,
        name: &str,
        value: &str,
        domains: &[String],
        totp: bool,
        agent_known: bool,
    ) -> Result<(), PolicyError> {
        let valid_name = !name.is_empty()
            && name.len() <= 64
            && name.chars().all(|c| c.is_ascii_alphanumeric() || "_.-".contains(c));
        if !valid_name {
            return Err(PolicyError(format!(
                "name: expected letters, digits, _, . or - (at most 64), got {name:?}"
            )));
        }
        if value.is_empty() {
            return Err(PolicyError(format!("{name}: value: expected a non-empty string")));
        }
        if domains.is_empty() {
            return Err(PolicyError(format!(
                "{name}: domains: expected the domains it may be typed into; a secret without domains is not accepted"
            )));
        }
        let totp = totp || name.ends_with("bu_2fa_code");
        if totp && base32_decode(value).is_none() {
            return Err(PolicyError(format!("{name}: a TOTP secret must be base32")));
        }
        let domains =
            domains.iter().map(|d| DomainPattern::parse(d)).collect::<Result<Vec<_>, _>>()?;
        self.entries
            .insert(name.to_owned(), Entry { value: value.to_owned(), domains, totp, agent_known });
        Ok(())
    }

    /// Whether `name` was set by agent code (`None`: no such secret).
    pub fn agent_known(&self, name: &str) -> Option<bool> {
        self.entries.get(name).map(|entry| entry.agent_known)
    }

    pub fn delete(&mut self, name: &str) -> bool {
        self.entries.remove(name).is_some()
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }

    pub fn list(&self) -> Vec<SecretInfo> {
        self.entries
            .iter()
            .map(|(name, entry)| SecretInfo {
                name: name.clone(),
                domains: entry.domains.iter().map(|d| d.raw.clone()).collect(),
                totp: entry.totp,
                agent_known: entry.agent_known,
            })
            .collect()
    }

    /// The text to type for a handle into a frame at `frame_url`: the value,
    /// or the current TOTP code. Refused when the frame is not on one of the
    /// secret's domains (https only, http on loopback).
    pub fn text_for_frame(
        &self,
        name: &str,
        frame_url: &str,
        unix_ms: u64,
    ) -> Result<String, PolicyError> {
        let entry = self
            .entries
            .get(name)
            .ok_or_else(|| PolicyError(format!("secret {name:?} does not exist")))?;
        let url = Url::parse(frame_url)
            .map_err(|_| PolicyError(format!("secret {name:?}: the focused frame has no URL")))?;
        if !entry.domains.iter().any(|d| d.matches(&url, true)) {
            let place = frame_url.split(['?', '#']).next().unwrap_or(frame_url);
            let list: Vec<&str> = entry.domains.iter().map(|d| d.raw.as_str()).collect();
            return Err(PolicyError(format!(
                "secret {name:?} may not be typed into {place}; its domains are {}",
                list.join(", ")
            )));
        }
        if entry.totp {
            let key = base32_decode(&entry.value)
                .ok_or_else(|| PolicyError("TOTP secret is not base32".into()))?;
            return Ok(totp(&key, unix_ms, 6, 30));
        }
        Ok(entry.value.clone())
    }

    /// A masker for the current secrets (rebuild after every change).
    pub fn masker(&self) -> Masker {
        let mut pairs: Vec<(String, String)> = Vec::new();
        for (name, entry) in &self.entries {
            if entry.totp {
                continue;
            }
            let mask = format!("<secret:{name}>");
            let mut variants = vec![
                entry.value.clone(),
                uri_component(&entry.value),
                uri_component(&entry.value).replace("%20", "+"),
                json_escaped(&entry.value),
                html_escaped(&entry.value),
            ];
            variants.sort();
            variants.dedup();
            for variant in variants.into_iter().filter(|v| !v.is_empty()) {
                pairs.push((variant, mask.clone()));
            }
        }
        pairs.sort_by_key(|(variant, _)| std::cmp::Reverse(variant.len()));
        Masker { pairs }
    }
}

/// Replaces secret value variants with `<secret:name>`, longest first.
#[derive(Debug, Clone, Default)]
pub struct Masker {
    pairs: Vec<(String, String)>,
}

impl Masker {
    pub fn is_empty(&self) -> bool {
        self.pairs.is_empty()
    }

    fn longest(&self) -> usize {
        self.pairs.first().map(|(v, _)| v.len()).unwrap_or(0)
    }

    pub fn mask<'a>(&self, text: &'a str) -> Cow<'a, str> {
        let mut out = Cow::Borrowed(text);
        for (variant, mask) in &self.pairs {
            if out.contains(variant.as_str()) {
                out = Cow::Owned(out.replace(variant.as_str(), mask));
            }
        }
        out
    }

    /// Masks every string inside a JSON value (keys included).
    pub fn mask_value(&self, value: &Value) -> Value {
        if self.is_empty() {
            return value.clone();
        }
        match value {
            Value::String(text) => Value::String(self.mask(text).into_owned()),
            Value::Array(items) => Value::Array(items.iter().map(|v| self.mask_value(v)).collect()),
            Value::Object(map) => Value::Object(
                map.iter().map(|(k, v)| (self.mask(k).into_owned(), self.mask_value(v))).collect(),
            ),
            other => other.clone(),
        }
    }

    /// A masker for a text stream written in pieces (REPL print output), so a
    /// value split across two writes is still masked.
    pub fn stream(&self) -> StreamMasker {
        StreamMasker { masker: self.clone(), pending: String::new() }
    }
}

/// Holds back the tail that could start a secret until the next write.
#[derive(Debug)]
pub struct StreamMasker {
    masker: Masker,
    pending: String,
}

impl StreamMasker {
    /// Text that is safe to emit now.
    pub fn write(&mut self, chunk: &str) -> String {
        self.pending.push_str(chunk);
        let keep = self.masker.longest().saturating_sub(1);
        let masked = self.masker.mask(&self.pending).into_owned();
        if keep == 0 || masked.len() <= keep {
            if keep == 0 {
                self.pending.clear();
                return masked;
            }
            // Everything could still be a secret prefix; emit nothing yet,
            // unless masking already changed it.
            if masked != self.pending {
                self.pending.clear();
                return masked;
            }
            return String::new();
        }
        let mut cut = masked.len() - keep;
        while !masked.is_char_boundary(cut) {
            cut -= 1;
        }
        // Never split inside a mask that was just inserted.
        if let Some(open) = masked[..cut].rfind("<secret:")
            && !masked[open..cut].contains('>')
        {
            cut = open;
        }
        let emit = masked[..cut].to_owned();
        self.pending = masked[cut..].to_owned();
        emit
    }

    /// The rest, at the end of the stream.
    pub fn finish(&mut self) -> String {
        let rest = self.masker.mask(&self.pending).into_owned();
        self.pending.clear();
        rest
    }
}

fn uri_component(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        if byte.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn json_escaped(text: &str) -> String {
    let quoted = serde_json::to_string(text).unwrap_or_default();
    quoted.get(1..quoted.len().saturating_sub(1)).unwrap_or("").to_owned()
}

fn html_escaped(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// RFC 4648 base32 (no padding needed, case-insensitive, spaces ignored).
pub fn base32_decode(text: &str) -> Option<Vec<u8>> {
    let mut bits: u64 = 0;
    let mut count = 0;
    let mut out = Vec::new();
    for c in text.chars().filter(|c| !c.is_whitespace() && *c != '=') {
        let v = match c.to_ascii_uppercase() {
            c @ 'A'..='Z' => u64::from(u32::from(c) - u32::from('A')),
            c @ '2'..='7' => u64::from(u32::from(c) - u32::from('2')) + 26,
            _ => return None,
        };
        bits = (bits << 5) | v;
        count += 5;
        if count >= 8 {
            count -= 8;
            out.push((bits >> count) as u8);
            bits &= (1 << count) - 1;
        }
    }
    (!out.is_empty()).then_some(out)
}

/// RFC 6238 TOTP with HMAC-SHA1.
pub fn totp(key: &[u8], unix_ms: u64, digits: u32, period_s: u64) -> String {
    use hmac::{Hmac, Mac};
    let counter = (unix_ms / 1000) / period_s;
    let mut mac =
        <Hmac<sha1::Sha1> as Mac>::new_from_slice(key).expect("HMAC takes any key length");
    mac.update(&counter.to_be_bytes());
    let hash = mac.finalize().into_bytes();
    let offset = (hash[hash.len() - 1] & 0x0f) as usize;
    let code = (u32::from(hash[offset] & 0x7f) << 24)
        | (u32::from(hash[offset + 1]) << 16)
        | (u32::from(hash[offset + 2]) << 8)
        | u32::from(hash[offset + 3]);
    let modulus = 10u32.pow(digits);
    format!("{:0width$}", code % modulus, width = digits as usize)
}

#[cfg(test)]
#[path = "secrets_tests.rs"]
mod tests;
