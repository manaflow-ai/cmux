//! `cmux-relay-snapshot-v1`: the sealed source-of-truth snapshot a relay stores so a viewer that opens
//! cold (a phone on LTE) gets first content from the relay edge while its live link is still dialing
//! (RFD 0142 R2; RFD 0163 pick 5). The relay holds ciphertext only: it holds no key that opens or forges one.
//!
//! The seal is PROTOCOL.md's ECIES, as `cmux-mobile-host`'s `seal.rs` and CryptoKit do it, with a new
//! context and a signature over the whole envelope:
//!
//! - an ephemeral key `E`; `z = ECDH(E, R)` (x coordinate) for the viewer's key `R`;
//! - `k = HKDF-SHA256(ikm: z, salt: E_pub || R_pub, info: context, 32 bytes)`;
//! - AES-256-GCM, a random 12-byte nonce, associated data `header || context`;
//! - an ECDSA P-256 / SHA-256 signature (fixed 64 bytes, as the Secure Enclave and `ring` give it) by the
//!   source's identity key over [`SIGNATURE_DOMAIN`], the context and every envelope byte before it.
//!
//! The context is `cmux-relay-snapshot-v1 \0 source key id \0 viewer key id \0 stream`, so a snapshot
//! opens only for the viewer, from the source and for the stream it was made for (a relay that swaps one
//! stream's blob for another's, or serves one viewer's to another, is refused).
//!
//! Wire (big endian), version 1:
//!
//! ```text
//! 0      version (1)
//! 1..9   epoch u64          the source's boot or lease generation
//! 9..17  seq u64            counts up within an epoch
//! 17..49 source key id      SHA-256 of the source identity key's X9.63 point
//! 49..114 E_pub             X9.63 uncompressed
//! 114..126 nonce
//! 126..130 ciphertext length u32 (with the 16-byte tag)
//! 130..    ciphertext || tag
//! then   signature (64)
//! ```
//!
//! `(epoch, seq)` is ordered by [`Position`]. The relay's Durable Object keeps only the newest envelope
//! per stream and viewer ([`peek`] reads the position without any key); the viewer keeps the highest
//! position it accepted ([`Floor`]) and refuses anything older, so a stale replay never replaces newer
//! state. The header is in the associated data and the signature, so the relay cannot relabel a position.

use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use hkdf::Hkdf;
use p256::ecdsa::signature::{Signer, Verifier};
use p256::ecdsa::{Signature, SigningKey, VerifyingKey};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{PublicKey, SecretKey};
use sha2::{Digest, Sha256};

pub mod delta;

/// The HKDF info prefix (the seal's context string).
pub const CONTEXT_DOMAIN: &str = "cmux-relay-snapshot-v1";
/// The signature's domain, so the signature means nothing in any other message.
pub const SIGNATURE_DOMAIN: &str = "cmux-relay-snapshot-sig-v1";
/// The envelope's version byte.
pub const VERSION: u8 = 1;

const POINT_LEN: usize = 65;
const NONCE_LEN: usize = 12;
const TAG_LEN: usize = 16;
const KEY_ID_LEN: usize = 32;
const SIGNATURE_LEN: usize = 64;
/// Bytes before the ciphertext length: the associated data of the AEAD.
const HEADER_LEN: usize = 1 + 8 + 8 + KEY_ID_LEN + POINT_LEN + NONCE_LEN;
const FIXED_LEN: usize = HEADER_LEN + 4 + TAG_LEN + SIGNATURE_LEN;

/// The most plaintext one snapshot holds (one sealed snapshot per pair: the DO's value size is far above this).
pub const MAX_PLAINTEXT: usize = 256 * 1024;

/// Where a snapshot sits in its source's history: the epoch, then the sequence within it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Position {
    pub epoch: u64,
    pub seq: u64,
}

/// Why a snapshot was not made or did not open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// Not a version-1 envelope (short, wrong version, a bad length or point).
    Malformed,
    /// The envelope names another source key than the one the viewer pinned.
    WrongSource,
    /// The source's signature does not verify.
    BadSignature,
    /// Older than the newest position the viewer accepted.
    Stale { have: Position, got: Position },
    /// Not sealed to this viewer key, stream or source (or altered).
    Unopened,
    /// A context part with a NUL byte, or a plaintext over [`MAX_PLAINTEXT`].
    BadInput,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Malformed => f.write_str("not a relay snapshot"),
            Self::WrongSource => f.write_str("the snapshot is from another source key"),
            Self::BadSignature => f.write_str("the snapshot's signature does not verify"),
            Self::Stale { have, got } => write!(
                f,
                "stale snapshot ({}, {}) is older than ({}, {})",
                got.epoch, got.seq, have.epoch, have.seq
            ),
            Self::Unopened => {
                f.write_str("the snapshot does not open with this key, source and stream")
            }
            Self::BadInput => f.write_str("bad snapshot input"),
        }
    }
}

impl std::error::Error for Error {}

/// What a relay reads of an envelope without any key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub position: Position,
    /// SHA-256 of the source identity key's X9.63 point.
    pub source_key_id: [u8; KEY_ID_LEN],
}

/// A snapshot that opened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opened {
    pub position: Position,
    pub plaintext: Vec<u8>,
}

/// A key's id: SHA-256 of its X9.63 uncompressed point.
pub fn key_id(key: &PublicKey) -> [u8; KEY_ID_LEN] {
    Sha256::digest(point(key)).into()
}

fn point(key: &PublicKey) -> [u8; POINT_LEN] {
    let mut out = [0u8; POINT_LEN];
    out.copy_from_slice(key.to_encoded_point(false).as_bytes());
    out
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The HKDF info and associated data: binds source, viewer and stream.
pub fn context(source: &PublicKey, viewer: &PublicKey, stream: &str) -> Result<Vec<u8>, Error> {
    if stream.as_bytes().contains(&0) {
        return Err(Error::BadInput);
    }
    let mut out = CONTEXT_DOMAIN.as_bytes().to_vec();
    for part in [hex(&key_id(source)), hex(&key_id(viewer)), stream.to_owned()] {
        out.push(0);
        out.extend_from_slice(part.as_bytes());
    }
    Ok(out)
}

fn signature_message(context: &[u8], body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(SIGNATURE_DOMAIN.len() + 2 + context.len() + body.len());
    out.extend_from_slice(SIGNATURE_DOMAIN.as_bytes());
    out.push(0);
    out.extend_from_slice(context);
    out.push(0);
    out.extend_from_slice(body);
    out
}

/// Seals `plaintext` for `viewer` as the source's snapshot of `stream` at `position`, with a fresh
/// ephemeral key and nonce.
pub fn seal(
    source: &SigningKey,
    viewer: &PublicKey,
    stream: &str,
    position: Position,
    plaintext: &[u8],
) -> Result<Vec<u8>, Error> {
    let ephemeral = SecretKey::random(&mut rand_core::OsRng);
    let mut nonce = [0u8; NONCE_LEN];
    rand_core::RngCore::try_fill_bytes(&mut rand_core::OsRng, &mut nonce)
        .map_err(|_| Error::BadInput)?;
    seal_with(source, viewer, stream, position, plaintext, &ephemeral, &nonce)
}

/// [`seal`] with a given ephemeral key and nonce (test vectors). Never reuse a nonce with one ephemeral key.
pub fn seal_with(
    source: &SigningKey,
    viewer: &PublicKey,
    stream: &str,
    position: Position,
    plaintext: &[u8],
    ephemeral: &SecretKey,
    nonce: &[u8; NONCE_LEN],
) -> Result<Vec<u8>, Error> {
    if plaintext.len() > MAX_PLAINTEXT {
        return Err(Error::BadInput);
    }
    let source_public = PublicKey::from(source.verifying_key());
    let context = context(&source_public, viewer, stream)?;
    let ephemeral_point = point(&ephemeral.public_key());
    let mut out = Vec::with_capacity(FIXED_LEN + plaintext.len());
    out.push(VERSION);
    out.extend_from_slice(&position.epoch.to_be_bytes());
    out.extend_from_slice(&position.seq.to_be_bytes());
    out.extend_from_slice(&key_id(&source_public));
    out.extend_from_slice(&ephemeral_point);
    out.extend_from_slice(nonce);
    let shared = ephemeral.agree(viewer)?;
    let key = derive(&shared, &ephemeral_point, &point(viewer), &context)?;
    let mut aad = out.clone();
    aad.extend_from_slice(&context);
    let ciphertext = Aes256Gcm::new(&key.into())
        .encrypt(Nonce::from_slice(nonce), Payload { msg: plaintext, aad: &aad })
        .map_err(|_| Error::BadInput)?;
    out.extend_from_slice(
        &u32::try_from(ciphertext.len()).map_err(|_| Error::BadInput)?.to_be_bytes(),
    );
    out.extend_from_slice(&ciphertext);
    let signature: Signature = source.sign(&signature_message(&context, &out));
    out.extend_from_slice(&signature.to_bytes());
    Ok(out)
}

/// Reads the position and source key id of an envelope, checking only its shape: what the relay's Durable
/// Object uses to keep the newest. It proves nothing about the sender; the viewer's [`open`] does.
pub fn peek(envelope: &[u8]) -> Result<Header, Error> {
    split(envelope).map(|parts| parts.header)
}

struct Parts<'a> {
    header: Header,
    ephemeral_point: &'a [u8],
    nonce: &'a [u8],
    ciphertext: &'a [u8],
    /// The bytes before the signature.
    body: &'a [u8],
    signature: &'a [u8],
}

fn split(bytes: &[u8]) -> Result<Parts<'_>, Error> {
    if bytes.len() < FIXED_LEN || bytes.first() != Some(&VERSION) {
        return Err(Error::Malformed);
    }
    let epoch = u64::from_be_bytes(
        bytes.get(1..9).ok_or(Error::Malformed)?.try_into().map_err(|_| Error::Malformed)?,
    );
    let seq = u64::from_be_bytes(
        bytes.get(9..17).ok_or(Error::Malformed)?.try_into().map_err(|_| Error::Malformed)?,
    );
    let source_key_id: [u8; KEY_ID_LEN] = bytes
        .get(17..17 + KEY_ID_LEN)
        .ok_or(Error::Malformed)?
        .try_into()
        .map_err(|_| Error::Malformed)?;
    let ephemeral_start = 17 + KEY_ID_LEN;
    let nonce_start = ephemeral_start + POINT_LEN;
    let length_start = nonce_start + NONCE_LEN;
    let length = u32::from_be_bytes(
        bytes
            .get(length_start..length_start + 4)
            .ok_or(Error::Malformed)?
            .try_into()
            .map_err(|_| Error::Malformed)?,
    ) as usize;
    let ciphertext_start = length_start + 4;
    let ciphertext_end = ciphertext_start.checked_add(length).ok_or(Error::Malformed)?;
    let envelope_end = ciphertext_end.checked_add(SIGNATURE_LEN).ok_or(Error::Malformed)?;
    if length < TAG_LEN || bytes.len() != envelope_end || bytes.get(ephemeral_start) != Some(&4) {
        return Err(Error::Malformed);
    }
    Ok(Parts {
        header: Header { position: Position { epoch, seq }, source_key_id },
        ephemeral_point: bytes.get(ephemeral_start..nonce_start).ok_or(Error::Malformed)?,
        nonce: bytes.get(nonce_start..length_start).ok_or(Error::Malformed)?,
        ciphertext: bytes.get(ciphertext_start..ciphertext_end).ok_or(Error::Malformed)?,
        body: bytes.get(..ciphertext_end).ok_or(Error::Malformed)?,
        signature: bytes.get(ciphertext_end..).ok_or(Error::Malformed)?,
    })
}

/// Opens an envelope sealed to `viewer` by `source` for `stream`. Order of refusals: shape, source key id,
/// signature, then `floor` (a position older than it is [`Error::Stale`]; equal is accepted, a replay of
/// what the viewer already shows), then decryption.
pub fn open<V: Viewer + ?Sized>(
    viewer: &V,
    source: &PublicKey,
    stream: &str,
    floor: Option<Position>,
    envelope: &[u8],
) -> Result<Opened, Error> {
    let parts = split(envelope)?;
    if parts.header.source_key_id != key_id(source) {
        return Err(Error::WrongSource);
    }
    let viewer_public = viewer.public_key();
    let context = context(source, &viewer_public, stream)?;
    let signature = Signature::from_slice(parts.signature).map_err(|_| Error::BadSignature)?;
    VerifyingKey::from(source)
        .verify(&signature_message(&context, parts.body), &signature)
        .map_err(|_| Error::BadSignature)?;
    if let Some(have) = floor
        && parts.header.position < have
    {
        return Err(Error::Stale { have, got: parts.header.position });
    }
    let ephemeral =
        PublicKey::from_sec1_bytes(parts.ephemeral_point).map_err(|_| Error::Malformed)?;
    let shared = viewer.agree(&ephemeral)?;
    let key = derive(&shared, parts.ephemeral_point, &point(&viewer_public), &context)?;
    let mut aad = envelope.get(..HEADER_LEN).ok_or(Error::Malformed)?.to_vec();
    aad.extend_from_slice(&context);
    let plaintext = Aes256Gcm::new(&key.into())
        .decrypt(Nonce::from_slice(parts.nonce), Payload { msg: parts.ciphertext, aad: &aad })
        .map_err(|_| Error::Unopened)?;
    Ok(Opened { position: parts.header.position, plaintext })
}

/// The viewer's key agreement: a [`SecretKey`] in memory, or a key that never leaves its
/// hardware (the phone's Secure Enclave push key, through the app's FFI), which only agrees.
pub trait Viewer {
    fn public_key(&self) -> PublicKey;
    /// The ECDH shared secret's x coordinate with `peer`.
    fn agree(&self, peer: &PublicKey) -> Result<[u8; 32], Error>;
}

impl Viewer for SecretKey {
    fn public_key(&self) -> PublicKey {
        SecretKey::public_key(self)
    }

    fn agree(&self, peer: &PublicKey) -> Result<[u8; 32], Error> {
        let shared = p256::ecdh::diffie_hellman(self.to_nonzero_scalar(), peer.as_affine());
        Ok((*shared.raw_secret_bytes()).into())
    }
}

/// The newest position a viewer accepted for one stream and source: the rollback guard to persist.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Floor(Option<Position>);

impl Floor {
    /// A floor restored from storage.
    pub fn at(position: Position) -> Self {
        Self(Some(position))
    }

    pub fn position(&self) -> Option<Position> {
        self.0
    }

    /// [`open`] under this floor; on success the floor rises to the snapshot's position.
    pub fn open<V: Viewer + ?Sized>(
        &mut self,
        viewer: &V,
        source: &PublicKey,
        stream: &str,
        envelope: &[u8],
    ) -> Result<Opened, Error> {
        let opened = open(viewer, source, stream, self.0, envelope)?;
        self.0 = Some(self.0.map_or(opened.position, |have| have.max(opened.position)));
        Ok(opened)
    }
}

/// The AES key: HKDF over the ECDH x coordinate, salted with both points.
fn derive(
    shared: &[u8; 32],
    ephemeral_point: &[u8],
    viewer_point: &[u8],
    context: &[u8],
) -> Result<[u8; 32], Error> {
    let mut salt = Vec::with_capacity(2 * POINT_LEN);
    salt.extend_from_slice(ephemeral_point);
    salt.extend_from_slice(viewer_point);
    let mut key = [0u8; 32];
    Hkdf::<Sha256>::new(Some(&salt), shared)
        .expand(context, &mut key)
        .map_err(|_| Error::BadInput)?;
    Ok(key)
}

#[cfg(test)]
mod tests;
