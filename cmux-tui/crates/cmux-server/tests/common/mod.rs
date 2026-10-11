//! Shared fixtures: a signing key, manifests, package archives, an
//! in-memory fetcher and temporary layouts.

#![allow(dead_code)]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::Mutex;

use cmux_server::error::{Error, Result};
use cmux_server::store::fetch::Fetch;
use cmux_server_core::layout::{Layout, LayoutEnv, layout};
use cmux_server_core::manifest::TrustedKey;
use cmux_server_core::{InstallMode, Platform};
use ring::signature::{Ed25519KeyPair, KeyPair};
use sha2::{Digest, Sha256};

pub const NOW_MS: u64 = 1_790_978_474_000; // 2026-10-02T22:01:14Z

pub struct Signer {
    pair: Ed25519KeyPair,
}

impl Signer {
    pub fn new(seed: u8) -> Signer {
        Signer { pair: Ed25519KeyPair::from_seed_unchecked(&[seed; 32]).unwrap() }
    }

    pub fn key(&self, id: &str) -> TrustedKey {
        let mut public_key = [0u8; 32];
        public_key.copy_from_slice(self.pair.public_key().as_ref());
        TrustedKey { id: id.to_owned(), public_key }
    }

    pub fn sign(&self, bytes: &[u8]) -> Vec<u8> {
        self.pair.sign(bytes).as_ref().to_vec()
    }
}

pub fn sha_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// A package archive: `bin/<name>` with `body`, gzip-compressed tar.
pub fn bin_package(name: &str, body: &[u8]) -> Vec<u8> {
    let mut builder = tar::Builder::new(Vec::new());
    let mut header = tar::Header::new_gnu();
    header.set_size(body.len() as u64);
    header.set_mode(0o755);
    header.set_entry_type(tar::EntryType::Regular);
    header.set_cksum();
    builder.append_data(&mut header, format!("bin/{name}"), body).unwrap();
    let tar = builder.into_inner().unwrap();
    gzip(&tar)
}

/// A package archive with executable `bin/<name>` files.
pub fn files_package(files: &[(&str, &[u8])]) -> Vec<u8> {
    let mut builder = tar::Builder::new(Vec::new());
    for (name, body) in files {
        let mut header = tar::Header::new_gnu();
        header.set_size(body.len() as u64);
        header.set_mode(0o755);
        header.set_entry_type(tar::EntryType::Regular);
        header.set_cksum();
        builder.append_data(&mut header, format!("bin/{name}"), *body).unwrap();
    }
    gzip(&builder.into_inner().unwrap())
}

pub fn gzip(bytes: &[u8]) -> Vec<u8> {
    let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    enc.write_all(bytes).unwrap();
    enc.finish().unwrap()
}

/// A raw tar entry whose name and link name bypass the builder's checks.
pub fn raw_entry(name: &[u8], kind: tar::EntryType, link: &[u8], body: &[u8]) -> Vec<u8> {
    let mut header = tar::Header::new_gnu();
    {
        let gnu = header.as_gnu_mut().unwrap();
        gnu.name[..name.len()].copy_from_slice(name);
        gnu.linkname[..link.len()].copy_from_slice(link);
    }
    header.set_size(body.len() as u64);
    header.set_mode(0o644);
    header.set_entry_type(kind);
    header.set_cksum();
    let mut out = header.as_bytes().to_vec();
    out.extend_from_slice(body);
    out.resize(out.len().div_ceil(512) * 512, 0);
    out
}

/// A tar stream from raw entries plus the two zero end blocks.
pub fn raw_tar(entries: &[Vec<u8>]) -> Vec<u8> {
    let mut out: Vec<u8> = entries.concat();
    out.extend_from_slice(&[0u8; 1024]);
    out
}

pub struct Pkg {
    pub name: &'static str,
    pub version: &'static str,
    pub archive: Vec<u8>,
}

impl Pkg {
    pub fn url(&self) -> String {
        format!("https://files.example.test/{}/{}.tar.gz", self.name, sha_hex(&self.archive))
    }
}

/// Manifest JSON for `packages` (every package for role `all`).
pub fn manifest(sequence: u64, expires_at: &str, min_cmux: &str, packages: &[&Pkg]) -> Vec<u8> {
    let pkgs: Vec<serde_json::Value> = packages
        .iter()
        .map(|p| {
            serde_json::json!({
                "name": p.name, "version": p.version, "url": p.url(),
                "sha256": sha_hex(&p.archive), "size": p.archive.len(), "roles": ["all"],
            })
        })
        .collect();
    serde_json::to_vec(&serde_json::json!({
        "schema": 1, "channel": "stable", "sequence": sequence, "expires_at": expires_at,
        "min_cmux_version": min_cmux, "packages": pkgs,
    }))
    .unwrap()
}

/// Serves URLs from memory and counts requests.
#[derive(Default)]
pub struct MapFetcher {
    pub files: Mutex<HashMap<String, Vec<u8>>>,
    pub hits: Mutex<Vec<String>>,
}

impl MapFetcher {
    pub fn put(&self, url: &str, bytes: Vec<u8>) {
        self.files.lock().unwrap().insert(url.to_owned(), bytes);
    }

    pub fn serve(&self, pkg: &Pkg) {
        self.put(&pkg.url(), pkg.archive.clone());
    }

    pub fn hit_count(&self) -> usize {
        self.hits.lock().unwrap().len()
    }
}

impl Fetch for MapFetcher {
    fn open(&self, url: &str) -> Result<Box<dyn Read + Send>> {
        self.hits.lock().unwrap().push(url.to_owned());
        let bytes = self
            .files
            .lock()
            .unwrap()
            .get(url)
            .cloned()
            .ok_or_else(|| Error::not_found(format!("404 {url}")))?;
        Ok(Box::new(std::io::Cursor::new(bytes)))
    }
}

pub fn uid() -> u32 {
    cmux_server::sys::uid()
}

pub fn env_for(home: &Path) -> LayoutEnv {
    LayoutEnv {
        home: Some(home.to_str().unwrap().to_owned()),
        uid: Some(uid()),
        ..LayoutEnv::default()
    }
}

/// A user-mode layout for `platform` under `home`.
pub fn layout_at(home: &Path, platform: Platform) -> Layout {
    layout(InstallMode::User, platform, &env_for(home)).unwrap()
}
