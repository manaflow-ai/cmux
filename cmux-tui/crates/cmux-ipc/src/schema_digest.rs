//! The content digest both schema generators write: FNV-1a 64 over a schema
//! file's bytes. `build.rs` compiles this same file (`#[path]`), and the Swift
//! side's one copy is CmuxNextWireDigest's `WireDigest`, which CmuxNextWireGen
//! and CmuxNextIPC share, so the Rust and Swift bindings name the schema bytes
//! they were built from with one number.

/// FNV-1a 64 of `bytes` (offset basis 0xcbf29ce484222325, prime 0x100000001b3).
#[must_use]
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}
