//! The public shared tier's publish side (hq `docs/design/cold-storage-and-shared-tier.md`, P1).
//!
//! Content enters only when its bytes match a checksum its public source states: a crates.io
//! `cksum`, an npm `integrity`, a PyPI sha256, a rustup channel-manifest hash, a Node
//! `SHASUMS256.txt` line, or the hash our own build records for a base image. The archive is
//! checked whole before one file of it is read; a mismatch publishes nothing. What passes is cut
//! with the store's FastCDC and named by public ids (`Id::of`, plain BLAKE3), so the same bytes
//! have the same id for every tenant, and is written to a local [`Store`] plus one manifest per
//! artifact. Nothing here talks to a network and nothing is uploaded: the directory is the
//! thing P2 later seeds. Private data has no way in: there is no entry point that takes bytes
//! without a checksum to prove them against.
//!
//! [`PublicIndex`] is what the cold pass asks: is this file's every chunk public? If so the cold
//! manifest stores a ref to the public chunks ([`crate::cold`]).

use crate::manifest::{Chunk, Manifest};
use crate::store::write_atomic;
use crate::{Id, Result, Store};
use serde::{Deserialize, Serialize};
use sha2::Digest as _;
use std::collections::{BTreeMap, HashSet};
use std::io::Read as _;
use std::path::PathBuf;

/// The digest a public source states.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Algo {
    Sha256,
    Sha512,
}

/// A checksum a public source states for the artifact's bytes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Checksum {
    pub algo: Algo,
    /// Lowercase hex.
    pub hex: String,
}

impl Checksum {
    /// A checksum from its hex digits (any case), refused unless it is the digest's length.
    pub fn new(algo: Algo, hex: &str) -> Result<Self> {
        let want = match algo {
            Algo::Sha256 => 64,
            Algo::Sha512 => 128,
        };
        let hex = hex.trim().to_ascii_lowercase();
        if hex.len() != want || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(format!("{algo:?} checksum must be {want} hex digits").into());
        }
        Ok(Self { algo, hex })
    }

    fn digest(&self, bytes: &[u8]) -> String {
        match self.algo {
            Algo::Sha256 => hex_of(&sha2::Sha256::digest(bytes)),
            Algo::Sha512 => hex_of(&sha2::Sha512::digest(bytes)),
        }
    }

    /// Whether `bytes` are what the source states.
    pub fn matches(&self, bytes: &[u8]) -> bool {
        self.digest(bytes) == self.hex
    }
}

fn hex_of(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len().saturating_mul(2));
    for b in bytes {
        s.extend(char::from_digit(u32::from(b >> 4), 16));
        s.extend(char::from_digit(u32::from(b & 15), 16));
    }
    s
}

/// What kind of public artifact it is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    Crate,
    Npm,
    Pypi,
    Toolchain,
    BaseImage,
}

impl std::str::FromStr for Kind {
    type Err = String;
    fn from_str(s: &str) -> std::result::Result<Self, String> {
        Ok(match s {
            "crate" => Self::Crate,
            "npm" => Self::Npm,
            "pypi" => Self::Pypi,
            "toolchain" => Self::Toolchain,
            "base-image" => Self::BaseImage,
            other => return Err(format!("unknown kind {other:?}")),
        })
    }
}

/// Where the bytes come from and the checksum that proves them.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Source {
    pub kind: Kind,
    pub name: String,
    pub version: String,
    pub checksum: Checksum,
}

/// One published artifact: its source and its manifest's id.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub source: Source,
    pub manifest: Id,
}

/// A directory holding the public tier: `chunks/` ([`Store`]), `manifests/<id>.json`, `index.json`.
#[derive(Clone, Debug)]
pub struct Public {
    root: PathBuf,
    store: Store,
}

/// What one publish did.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Published {
    pub manifest: String,
    pub files: u64,
    pub bytes: u64,
    /// Chunks written now; the rest were already public.
    pub new_chunks: u64,
    pub already_published: bool,
}

impl Public {
    /// The tier at `root` (made on first publish).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        let root = root.into();
        let store = Store::new(root.join("chunks"));
        Self { root, store }
    }

    /// Its chunk store.
    pub fn store(&self) -> &Store {
        &self.store
    }

    fn index_path(&self) -> PathBuf {
        self.root.join("index.json")
    }

    fn manifest_path(&self, id: &Id) -> PathBuf {
        self.root.join("manifests").join(format!("{id}.json"))
    }

    /// The published entries (none when nothing was published yet).
    pub fn entries(&self) -> Result<Vec<Entry>> {
        match std::fs::read(self.index_path()) {
            Ok(b) => Ok(serde_json::from_slice(&b)?),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(e) => Err(e.into()),
        }
    }

    /// Publish one file whose bytes `source.checksum` states. `path` is its path in the tree.
    pub fn publish_file(
        &self,
        source: &Source,
        path: &str,
        bytes: &[u8],
        exec: bool,
    ) -> Result<Published> {
        if !source.checksum.matches(bytes) {
            return Err(format!("{}: bytes do not match the stated checksum", source.name).into());
        }
        let mut files = BTreeMap::new();
        files.insert(path.to_string(), (bytes.to_vec(), exec));
        self.publish_verified(source, &files)
    }

    /// Publish the files of a `.tar.gz` or `.tar.xz` (`xz` is read through the system `xz -dc`)
    /// whose bytes `source.checksum` states. `strip` leading path components are dropped from
    /// every entry (a crate's `name-1.0/` is kept at 0; a rustup component's two at 2).
    /// Symlinks, directories and special files are skipped, as [`Manifest::of_dir`] does.
    pub fn publish_archive(
        &self,
        source: &Source,
        archive: &[u8],
        strip: usize,
    ) -> Result<Published> {
        if !source.checksum.matches(archive) {
            return Err(
                format!("{}: archive does not match the stated checksum", source.name).into()
            );
        }
        let files = unpack(archive, strip)?;
        if files.is_empty() {
            return Err(format!("{}: the archive holds no regular file", source.name).into());
        }
        self.publish_verified(source, &files)
    }

    /// Only reached with bytes already proven against `source.checksum`.
    fn publish_verified(
        &self,
        source: &Source,
        files: &BTreeMap<String, (Vec<u8>, bool)>,
    ) -> Result<Published> {
        let mut fresh = Vec::new();
        let manifest = Manifest::build(files, |id, piece| {
            if !self.store.has(&id) {
                self.store.put(&id, piece)?;
                fresh.push(id);
            }
            Ok(())
        })?;
        // Read every chunk written now back before the index names it.
        for id in &fresh {
            self.store.get(id)?;
        }
        let bytes = manifest.to_bytes()?;
        let id = Id::of(&bytes);
        let dir = self.root.join("manifests");
        std::fs::create_dir_all(&dir)?;
        write_atomic(&dir, &self.manifest_path(&id), &bytes)?;
        Manifest::from_bytes(&std::fs::read(self.manifest_path(&id))?, &id)?;
        let mut entries = self.entries()?;
        let entry = Entry { source: source.clone(), manifest: id };
        let already = entries.contains(&entry);
        if !already {
            entries.push(entry);
            std::fs::create_dir_all(&self.root)?;
            write_atomic(&self.root, &self.index_path(), &serde_json::to_vec_pretty(&entries)?)?;
        }
        Ok(Published {
            manifest: id.hex(),
            files: manifest.files.len() as u64,
            bytes: manifest.size(),
            new_chunks: fresh.len() as u64,
            already_published: already,
        })
    }

    /// A published manifest's bytes, checked against `id`.
    pub fn manifest_bytes(&self, id: &Id) -> Result<Vec<u8>> {
        let bytes = std::fs::read(self.manifest_path(id))?;
        Manifest::from_bytes(&bytes, id)?;
        Ok(bytes)
    }

    /// Takes in an entry fetched from peers or the floor ([`crate::seed::fetch`]): `manifest`
    /// must be the entry's id and every chunk it names must be held and read back, so the tier
    /// then serves it like one it published. `entry` must come from an index the caller trusts.
    pub fn adopt(&self, entry: &Entry, manifest: &[u8]) -> Result<()> {
        let parsed = Manifest::from_bytes(manifest, &entry.manifest)?;
        for c in parsed.distinct_chunks() {
            self.store.get(&c.id)?;
        }
        let dir = self.root.join("manifests");
        std::fs::create_dir_all(&dir)?;
        let path = self.manifest_path(&entry.manifest);
        write_atomic(&dir, &path, manifest)?;
        Manifest::from_bytes(&std::fs::read(&path)?, &entry.manifest)?;
        let mut entries = self.entries()?;
        if !entries.contains(entry) {
            entries.push(entry.clone());
            write_atomic(&self.root, &self.index_path(), &serde_json::to_vec_pretty(&entries)?)?;
        }
        Ok(())
    }

    /// The lookup the cold pass uses.
    pub fn index(&self) -> Result<PublicIndex> {
        let mut chunks = HashSet::new();
        for e in self.entries()? {
            let bytes = std::fs::read(self.manifest_path(&e.manifest))?;
            let m = Manifest::from_bytes(&bytes, &e.manifest)?;
            chunks.extend(m.files.iter().flat_map(|f| f.chunks.iter().map(|c| c.id)));
        }
        Ok(PublicIndex { chunks })
    }
}

/// Every chunk id the public tier holds.
#[derive(Clone, Debug, Default)]
pub struct PublicIndex {
    chunks: HashSet<Id>,
}

impl PublicIndex {
    /// An index of exactly `chunks` (tests, and callers holding the ids already).
    pub fn from_chunks(chunks: impl IntoIterator<Item = Id>) -> Self {
        Self { chunks: chunks.into_iter().collect() }
    }

    /// Whether the public tier holds chunk `id`.
    pub fn has(&self, id: &Id) -> bool {
        self.chunks.contains(id)
    }

    /// Distinct public chunks.
    pub fn len(&self) -> usize {
        self.chunks.len()
    }

    /// Whether it holds none.
    pub fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }

    /// Whether a file of `chunks` is all public: at least one chunk, every one held. Such a file
    /// is stored as a ref, not a copy. An empty file says nothing and is not a ref.
    pub fn covers(&self, chunks: &[Chunk]) -> bool {
        !chunks.is_empty() && chunks.iter().all(|c| self.has(&c.id))
    }

    /// The ids 16-byte prefixes, for [`crate::dedup`] whose measurement keys are truncated.
    pub fn prefixes(&self) -> HashSet<[u8; 16]> {
        self.chunks.iter().filter_map(|id| id.0.first_chunk::<16>().copied()).collect()
    }
}

fn unpack(archive: &[u8], strip: usize) -> Result<BTreeMap<String, (Vec<u8>, bool)>> {
    let xz = archive.starts_with(&[0xfd, b'7', b'z', b'X', b'Z', 0]);
    if xz {
        let mut child = cmux_process::Command::new("xz")
            .args(["-dc"])
            .stdin(cmux_process::Stdio::piped())
            .stdout(cmux_process::Stdio::piped())
            .spawn()?;
        let mut stdin = child.stdin.take().ok_or("xz has no stdin")?;
        let stdout = child.stdout.take().ok_or("xz has no stdout")?;
        let (out, fed) = std::thread::scope(|s| {
            let feeder = s.spawn(move || {
                use std::io::Write as _;
                stdin.write_all(archive)
            });
            let out = read_tar(stdout, strip);
            (out, feeder.join())
        });
        fed.map_err(|_| "xz feeder panicked")??;
        let status = child.wait()?;
        if !status.success() {
            return Err("xz could not decompress the archive".into());
        }
        out
    } else if archive.starts_with(&[0x1f, 0x8b]) {
        read_tar(flate2::read::GzDecoder::new(archive), strip)
    } else {
        read_tar(archive, strip)
    }
}

fn read_tar(r: impl std::io::Read, strip: usize) -> Result<BTreeMap<String, (Vec<u8>, bool)>> {
    let mut files = BTreeMap::new();
    let mut ar = tar::Archive::new(r);
    for entry in ar.entries()? {
        let mut entry = entry?;
        if !entry.header().entry_type().is_file() {
            continue;
        }
        let path = entry.path()?.to_string_lossy().replace('\\', "/");
        let kept: Vec<&str> = path.split('/').filter(|p| !p.is_empty() && *p != ".").collect();
        let Some(rest) = kept.get(strip..).filter(|r| !r.is_empty()) else { continue };
        let rel = rest.join("/");
        if rel.split('/').any(|p| p == "..") {
            return Err(format!("archive path {path:?} leaves the tree").into());
        }
        let exec = entry.header().mode().is_ok_and(|m| m & 0o111 != 0);
        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes)?;
        files.insert(rel, (bytes, exec));
    }
    Ok(files)
}

/// The `[[package]]` entries of a `Cargo.lock` that state a registry checksum: `(name, version,
/// sha256 hex)`. Path and git dependencies state none and are not public by this route.
pub fn cargo_lock_checksums(lock: &str) -> Vec<(String, String, String)> {
    let mut out = Vec::new();
    let (mut name, mut version, mut sum) = (None, None, None);
    let mut flush =
        |name: &mut Option<String>, version: &mut Option<String>, sum: &mut Option<String>| {
            if let (Some(n), Some(v), Some(c)) = (name.take(), version.take(), sum.take()) {
                out.push((n, v, c));
            }
            *name = None;
            *version = None;
            *sum = None;
        };
    for line in lock.lines() {
        let line = line.trim();
        if line == "[[package]]" {
            flush(&mut name, &mut version, &mut sum);
        } else if let Some((k, v)) = line.split_once(" = ") {
            let v = v.trim().trim_matches('"').to_string();
            match k {
                "name" => name = Some(v),
                "version" => version = Some(v),
                "checksum" => sum = Some(v),
                _ => {}
            }
        }
    }
    flush(&mut name, &mut version, &mut sum);
    out
}
