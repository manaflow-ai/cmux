//! Pairing code, fingerprint words and QR payload (server.md 6.2).
//!
//! Code: 8 Crockford base32 symbols (40 bits) from 5 random bytes the caller
//! provides, shown as `7KQ4-M2XD`. Input is case-insensitive and accepts
//! `O` for `0` and `I`/`L` for `1`; `U` is refused. Words: 4 words from the
//! 2,048-word list, from the first 44 bits of SHA-256(install public key).
//! QR: `https://cmux.com/pair?c=<code>#fp=<first 16 base32 symbols of
//! SHA-256(pubkey)>`.

mod base32;
mod words;

use sha2::{Digest, Sha256};
use std::fmt;

pub use base32::{ALPHABET, decode_symbol, encode_bits};
pub use words::{WORDLIST, word_count};

pub const CODE_LEN: usize = 8;
pub const FP_LEN: usize = 16;
pub const PAIR_URL: &str = "https://cmux.com/pair";

/// A pairing code: 8 canonical Crockford symbols.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PairingCode([u8; CODE_LEN]);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodeError {
    /// `U` is not a Crockford symbol (it is reserved).
    ReservedU,
    /// A character that is not a symbol, a hyphen or a space.
    Invalid(char),
    /// Not 8 symbols after removing hyphens and spaces.
    Length(usize),
}

impl PairingCode {
    pub fn from_random(bytes: [u8; 5]) -> PairingCode {
        let symbols = encode_bits(&bytes, CODE_LEN);
        let mut out = [0u8; CODE_LEN];
        out.copy_from_slice(symbols.as_bytes());
        PairingCode(out)
    }

    /// The canonical form, as sent to the API and in the QR: `7KQ4M2XD`.
    pub fn as_str(&self) -> &str {
        std::str::from_utf8(&self.0).expect("symbols are ASCII")
    }

    /// The display form: `7KQ4-M2XD`.
    pub fn display(&self) -> String {
        format!("{}-{}", &self.as_str()[..4], &self.as_str()[4..])
    }

    /// Parses what a person typed or read aloud.
    pub fn normalize(input: &str) -> Result<PairingCode, CodeError> {
        let mut out = Vec::with_capacity(CODE_LEN);
        for c in input.chars() {
            if c == '-' || c.is_whitespace() {
                continue;
            }
            let upper = c.to_ascii_uppercase();
            if upper == 'U' {
                return Err(CodeError::ReservedU);
            }
            let canonical = decode_symbol(upper).ok_or(CodeError::Invalid(c))?;
            out.push(ALPHABET[canonical as usize]);
        }
        if out.len() != CODE_LEN {
            return Err(CodeError::Length(out.len()));
        }
        let mut code = [0u8; CODE_LEN];
        code.copy_from_slice(&out);
        Ok(PairingCode(code))
    }
}

impl fmt::Display for PairingCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.display())
    }
}

/// Four words from the first 44 bits of SHA-256(pubkey), 11 bits each.
pub fn fingerprint_words(pubkey: &[u8]) -> [&'static str; 4] {
    let digest = Sha256::digest(pubkey);
    let bits = u64::from_be_bytes(digest[..8].try_into().expect("8 bytes"));
    std::array::from_fn(|i| {
        let index = (bits >> (64 - 11 * (i as u32 + 1))) & 0x7ff;
        WORDLIST[index as usize]
    })
}

/// The first 16 Crockford symbols (80 bits) of SHA-256(pubkey).
pub fn key_fingerprint(pubkey: &[u8]) -> String {
    encode_bits(&Sha256::digest(pubkey), FP_LEN)
}

pub fn qr_payload(code: &PairingCode, pubkey: &[u8]) -> String {
    format!("{PAIR_URL}?c={}#fp={}", code.as_str(), key_fingerprint(pubkey))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QrError {
    /// Not `https://cmux.com/pair?c=…#fp=…`.
    Malformed,
    Code(CodeError),
    /// The fingerprint does not match the key the pairing record holds:
    /// the code was swapped (server.md 6.2 step 3).
    FingerprintMismatch,
}

/// Checks a scanned payload against the install key the pairing record
/// holds and returns the code. Symbols are compared after normalization.
pub fn verify_qr_fp(payload: &str, pubkey: &[u8]) -> Result<PairingCode, QrError> {
    let rest = payload.strip_prefix(PAIR_URL).and_then(|r| r.strip_prefix("?c=")).ok_or(QrError::Malformed)?;
    let (code, fp) = rest.split_once("#fp=").ok_or(QrError::Malformed)?;
    if code.contains(['&', '#', '?']) || fp.contains(['&', '#', '?']) {
        return Err(QrError::Malformed);
    }
    let code = PairingCode::normalize(code).map_err(QrError::Code)?;
    let mut scanned = String::with_capacity(FP_LEN);
    for c in fp.chars() {
        let v = decode_symbol(c.to_ascii_uppercase()).ok_or(QrError::Malformed)?;
        scanned.push(ALPHABET[v as usize] as char);
    }
    if scanned.len() != FP_LEN {
        return Err(QrError::Malformed);
    }
    if scanned != key_fingerprint(pubkey) {
        return Err(QrError::FingerprintMismatch);
    }
    Ok(code)
}
