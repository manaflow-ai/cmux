//! A small, independent STUN/TURN codec for the tests: builds the messages a
//! TURN server sends and reads the ones the client sends.

#![allow(dead_code)]

use hmac::{Hmac, Mac};
use md5::{Digest, Md5};
use sha1::Sha1;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

pub const COOKIE: [u8; 4] = [0x21, 0x12, 0xA4, 0x42];

pub const ALLOCATE: u16 = 0x0003;
pub const REFRESH: u16 = 0x0004;
pub const CREATE_PERMISSION: u16 = 0x0008;
pub const CHANNEL_BIND: u16 = 0x0009;
pub const SEND_INDICATION: u16 = 0x0016;
pub const DATA_INDICATION: u16 = 0x0017;
pub const SUCCESS: u16 = 0x0100;
pub const ERROR: u16 = 0x0110;

pub const USERNAME: u16 = 0x0006;
pub const MESSAGE_INTEGRITY: u16 = 0x0008;
pub const ERROR_CODE: u16 = 0x0009;
pub const CHANNEL_NUMBER: u16 = 0x000C;
pub const LIFETIME: u16 = 0x000D;
pub const XOR_PEER_ADDRESS: u16 = 0x0012;
pub const DATA: u16 = 0x0013;
pub const REALM: u16 = 0x0014;
pub const NONCE: u16 = 0x0015;
pub const XOR_RELAYED_ADDRESS: u16 = 0x0016;
pub const XOR_MAPPED_ADDRESS: u16 = 0x0020;

pub type Tx = [u8; 12];

pub struct Msg {
    pub kind: u16,
    pub tx: Tx,
    pub attrs: Vec<(u16, Vec<u8>)>,
    /// Offset of MESSAGE-INTEGRITY in the raw message.
    pub integrity: Option<usize>,
}

impl Msg {
    pub fn get(&self, kind: u16) -> Option<&[u8]> {
        self.attrs.iter().find(|(k, _)| *k == kind).map(|(_, v)| v.as_slice())
    }
}

pub fn parse(raw: &[u8]) -> Option<Msg> {
    if raw.len() < 20 || raw[4..8] != COOKIE {
        return None;
    }
    let kind = u16::from_be_bytes([raw[0], raw[1]]);
    let len = usize::from(u16::from_be_bytes([raw[2], raw[3]]));
    if 20 + len != raw.len() {
        return None;
    }
    let tx: Tx = raw[8..20].try_into().ok()?;
    let mut attrs = Vec::new();
    let mut integrity = None;
    let mut at = 20;
    while at + 4 <= raw.len() {
        let k = u16::from_be_bytes([raw[at], raw[at + 1]]);
        let l = usize::from(u16::from_be_bytes([raw[at + 2], raw[at + 3]]));
        let value = raw.get(at + 4..at + 4 + l)?.to_vec();
        if k == MESSAGE_INTEGRITY {
            integrity = Some(at);
        }
        attrs.push((k, value));
        at += 4 + l.next_multiple_of(4);
    }
    Some(Msg { kind, tx, attrs, integrity })
}

pub fn key(username: &str, realm: &str, password: &str) -> [u8; 16] {
    Md5::digest(format!("{username}:{realm}:{password}").as_bytes()).into()
}

fn hmac(key: &[u8], parts: &[&[u8]]) -> Vec<u8> {
    let mut mac = Hmac::<Sha1>::new_from_slice(key).unwrap();
    for p in parts {
        mac.update(p);
    }
    mac.finalize().into_bytes().to_vec()
}

/// Whether the MESSAGE-INTEGRITY of `raw` (at `offset`) is right for `key`.
pub fn integrity_ok(raw: &[u8], offset: usize, key: &[u8; 16]) -> bool {
    let length = u16::try_from(offset + 24 - 20).unwrap().to_be_bytes();
    let tag = hmac(key, &[&raw[..2], &length, &raw[4..offset]]);
    raw.get(offset + 4..offset + 24) == Some(tag.as_slice())
}

pub fn build(kind: u16, tx: Tx, attrs: &[(u16, Vec<u8>)], key: Option<&[u8; 16]>) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&kind.to_be_bytes());
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(&COOKIE);
    out.extend_from_slice(&tx);
    for (k, v) in attrs {
        push_attr(&mut out, *k, v);
    }
    if let Some(key) = key {
        let length = u16::try_from(out.len() - 20 + 24).unwrap();
        out[2..4].copy_from_slice(&length.to_be_bytes());
        let tag = hmac(key, &[&out]);
        push_attr(&mut out, MESSAGE_INTEGRITY, &tag);
    }
    let length = u16::try_from(out.len() - 20).unwrap();
    out[2..4].copy_from_slice(&length.to_be_bytes());
    out
}

fn push_attr(out: &mut Vec<u8>, kind: u16, value: &[u8]) {
    out.extend_from_slice(&kind.to_be_bytes());
    out.extend_from_slice(&u16::try_from(value.len()).unwrap().to_be_bytes());
    out.extend_from_slice(value);
    out.resize(out.len().next_multiple_of(4), 0);
}

pub fn xor_addr(addr: SocketAddr, tx: &Tx) -> Vec<u8> {
    let mask: Vec<u8> = COOKIE.iter().chain(tx.iter()).copied().collect();
    let port = addr.port() ^ 0x2112;
    let mut v = vec![0];
    match addr.ip() {
        IpAddr::V4(ip) => {
            v.push(1);
            v.extend_from_slice(&port.to_be_bytes());
            v.extend(ip.octets().iter().zip(&mask).map(|(a, m)| a ^ m));
        }
        IpAddr::V6(ip) => {
            v.push(2);
            v.extend_from_slice(&port.to_be_bytes());
            v.extend(ip.octets().iter().zip(&mask).map(|(a, m)| a ^ m));
        }
    }
    v
}

pub fn unxor_addr(v: &[u8], tx: &Tx) -> Option<SocketAddr> {
    let mask: Vec<u8> = COOKIE.iter().chain(tx.iter()).copied().collect();
    let port = u16::from_be_bytes([*v.get(2)?, *v.get(3)?]) ^ 0x2112;
    let ip = match (v.get(1)?, v.len()) {
        (1, 8) => {
            let o: Vec<u8> = v[4..8].iter().zip(&mask).map(|(a, m)| a ^ m).collect();
            IpAddr::V4(Ipv4Addr::new(o[0], o[1], o[2], o[3]))
        }
        (2, 20) => {
            let o: Vec<u8> = v[4..20].iter().zip(&mask).map(|(a, m)| a ^ m).collect();
            let o: [u8; 16] = o.try_into().ok()?;
            IpAddr::V6(Ipv6Addr::from(o))
        }
        _ => return None,
    };
    Some(SocketAddr::new(ip, port))
}

pub fn error_code(code: u16, reason: &str) -> Vec<u8> {
    let mut v = vec![0, 0, (code / 100) as u8, (code % 100) as u8];
    v.extend_from_slice(reason.as_bytes());
    v
}

pub fn channel_data(number: u16, payload: &[u8]) -> Vec<u8> {
    let mut out = number.to_be_bytes().to_vec();
    out.extend_from_slice(&u16::try_from(payload.len()).unwrap().to_be_bytes());
    out.extend_from_slice(payload);
    out
}

/// A tiny deterministic generator for mutation tests.
pub struct Rng(pub u64);

impl Rng {
    pub fn step(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    pub fn below(&mut self, n: usize) -> usize {
        (self.step() % n.max(1) as u64) as usize
    }

    /// A hostile variant of `base`: flipped bytes, a cut, a bogus length or junk.
    pub fn mutate(&mut self, base: &[u8]) -> Vec<u8> {
        let mut p = base.to_vec();
        match self.below(6) {
            0 => {
                for _ in 0..=self.below(4) {
                    if !p.is_empty() {
                        let i = self.below(p.len());
                        p[i] ^= 1u8 << self.below(8);
                    }
                }
            }
            1 => p.truncate(self.below(p.len() + 1)),
            2 if p.len() >= 4 => {
                // A length field that lies.
                let l = (self.step() & 0xFFFF) as u16;
                p[2..4].copy_from_slice(&l.to_be_bytes());
            }
            3 if p.len() > 24 => {
                // An attribute length that lies.
                let i = 20 + 2 + 4 * self.below((p.len() - 24) / 4);
                let l = (self.step() & 0xFFFF) as u16;
                p[i..i + 2].copy_from_slice(&l.to_be_bytes());
            }
            4 => {
                let extra = self.below(64);
                p.extend((0..extra).map(|_| self.step() as u8));
            }
            _ => {
                p = (0..self.below(80)).map(|_| self.step() as u8).collect();
                if let Some(first) = p.first_mut() {
                    *first = [0x00, 0x01, 0x40, 0x4F][self.below(4)];
                }
            }
        }
        p
    }
}
