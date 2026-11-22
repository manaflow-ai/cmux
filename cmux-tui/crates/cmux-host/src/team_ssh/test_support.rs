//! Builders for the team_ssh tests: base64, KRL headers, CA lines and
//! certificate blobs in the OpenSSH wire formats.

use super::trust::Snapshot;

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn b64(bytes: &[u8]) -> String {
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i)) as usize & 63] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

pub fn string(out: &mut Vec<u8>, s: &[u8]) {
    out.extend_from_slice(&(s.len() as u32).to_be_bytes());
    out.extend_from_slice(s);
}

/// An empty OpenSSH KRL with this version (a valid file for sshd).
pub fn krl(version: u64) -> Vec<u8> {
    let mut out = b"SSHKRL\n\0".to_vec();
    out.extend_from_slice(&1u32.to_be_bytes());
    out.extend_from_slice(&version.to_be_bytes());
    out.extend_from_slice(&0u64.to_be_bytes()); // generated date
    out.extend_from_slice(&0u64.to_be_bytes()); // flags
    string(&mut out, b""); // reserved
    string(&mut out, b""); // comment
    out
}

pub fn ca_line(seed: u8) -> String {
    let mut blob = Vec::new();
    string(&mut blob, b"ssh-ed25519");
    string(&mut blob, &[seed; 32]);
    format!("ssh-ed25519 {} cmux-team-ca", b64(&blob))
}

pub fn snapshot(krl_version: u64, generation: u64) -> Snapshot {
    Snapshot {
        generation,
        trusted_ca_keys: vec![ca_line(generation as u8)],
        krl: b64(&krl(krl_version)),
        krl_version,
    }
}

/// An ed25519 user (or host, `cert_type` 2) certificate blob; fields after
/// the key id are left out (the parser stops there).
pub fn cert_blob(serial: u64, cert_type: u32, key_id: &str) -> Vec<u8> {
    let mut blob = Vec::new();
    string(&mut blob, b"ssh-ed25519-cert-v01@openssh.com");
    string(&mut blob, &[7; 32]); // nonce
    string(&mut blob, &[9; 32]); // public key
    blob.extend_from_slice(&serial.to_be_bytes());
    blob.extend_from_slice(&cert_type.to_be_bytes());
    string(&mut blob, key_id.as_bytes());
    blob
}
