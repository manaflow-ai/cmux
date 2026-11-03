//! The original VM's receiving bootstrap travels only on the authenticated
//! private child chain. Decoding this frame never grants serving authority:
//! the receiver must obtain a fresh public policy from the root agent first.
use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use cmux_link::keyset::{Keyset, read_keyset};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

use super::receiver::{ReceiverBinding, UniqueJson};

const MAX_HEADER: usize = 8192;
pub const MAX_BYTES: usize = 4 + MAX_HEADER + 32;
const UNAVAILABLE: &str = "VM private receiver bootstrap unavailable";

/// Contains no account bearer, install private key or grant secret. The WG
/// secret and every encoded frame zeroize when their owner releases them.
pub struct NativeBootstrap {
    binding: ReceiverBinding,
    keys: Keyset,
    private_key: Zeroizing<[u8; 32]>,
    generation: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    version: u8,
    binding: ReceiverBinding,
    keyset: Value,
    generation: String,
}

impl NativeBootstrap {
    pub(crate) fn new(
        binding: ReceiverBinding,
        keys: Keyset,
        private_key: Zeroizing<[u8; 32]>,
        generation: String,
    ) -> Result<Self, String> {
        let public = PublicKey::from(&StaticSecret::from(*private_key));
        if private_key.iter().all(|b| *b == 0)
            || STANDARD.encode(public.as_bytes()) != binding.wg_public_key
            || generation.len() != 64
            || !generation.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(UNAVAILABLE.into());
        }
        let value = Self { binding, keys, private_key, generation };
        // Validate the same public keyset representation the recipient reads.
        read_keyset(&value.header().keyset).map_err(|_| UNAVAILABLE)?;
        Ok(value)
    }

    pub fn binding(&self) -> &ReceiverBinding {
        &self.binding
    }

    pub fn keys(&self) -> &Keyset {
        &self.keys
    }

    pub fn generation(&self) -> &str {
        &self.generation
    }

    pub fn into_parts(self) -> (ReceiverBinding, Keyset, Zeroizing<[u8; 32]>, String) {
        (self.binding, self.keys, self.private_key, self.generation)
    }

    fn header(&self) -> Header {
        let keys: serde_json::Map<String, Value> = self.keys.keys.iter().map(|(kid, key)|
            (kid.clone(), json!({"kty":"OKP","crv":"Ed25519","alg":"EdDSA","kid":kid,"x":URL_SAFE_NO_PAD.encode(key)}))
        ).collect();
        Header {
            version: 2,
            binding: self.binding.clone(),
            keyset: json!({"version":self.keys.version,"keys":keys}),
            generation: self.generation.clone(),
        }
    }

    pub fn encode(&self) -> Result<Zeroizing<Vec<u8>>, String> {
        let header = serde_json::to_vec(&self.header()).map_err(|_| UNAVAILABLE)?;
        if header.is_empty() || header.len() > MAX_HEADER {
            return Err(UNAVAILABLE.into());
        }
        let mut bytes = Zeroizing::new(Vec::with_capacity(4 + header.len() + 32));
        bytes.extend_from_slice(&(header.len() as u32).to_be_bytes());
        bytes.extend_from_slice(&header);
        bytes.extend_from_slice(self.private_key.as_slice());
        Ok(bytes)
    }

    /// Authenticate the inherited/private descriptor before reading this frame.
    /// The prefix bounds allocation; exactly one frame is accepted.
    pub fn frame_length(prefix: [u8; 4]) -> Result<usize, String> {
        let length = u32::from_be_bytes(prefix) as usize;
        if length == 0 || length > MAX_HEADER {
            return Err(UNAVAILABLE.into());
        }
        Ok(4 + length + 32)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, String> {
        let prefix = bytes.get(..4).ok_or(UNAVAILABLE)?.try_into().map_err(|_| UNAVAILABLE)?;
        let length = Self::frame_length(prefix)?;
        if bytes.len() != length {
            return Err(UNAVAILABLE.into());
        }
        let (header, private) =
            bytes.get(4..).and_then(<[u8]>::split_last_chunk::<32>).ok_or(UNAVAILABLE)?;
        let _: UniqueJson = serde_json::from_slice(header).map_err(|_| UNAVAILABLE)?;
        let header: Header = serde_json::from_slice(header).map_err(|_| UNAVAILABLE)?;
        if header.version != 2 {
            return Err(UNAVAILABLE.into());
        }
        let keys = read_keyset(&header.keyset).map_err(|_| UNAVAILABLE)?;
        let private = Zeroizing::new(*private);
        Self::new(header.binding, keys, private, header.generation)
    }
}

#[cfg(test)]
#[path = "private_bootstrap_tests.rs"]
mod tests;
