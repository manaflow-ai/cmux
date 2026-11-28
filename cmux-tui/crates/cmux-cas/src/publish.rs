//! The publisher's half of `cas/1` over plain HTTPS (RFD 0166, the R2 floor): one tree becomes
//! a manifest, one pack of its chunk files and the pack's index, laid out under a prefix as
//! the reader ([`crate::fetch`]) asks for them:
//!
//! - `m/<manifest id>`: the manifest's bytes (BLAKE3 of them is the id);
//! - `p/<pack id>.pack`: every distinct chunk file, in manifest order;
//! - `p/<pack id>.idx`: the pack's [`Index`] as JSON.
//!
//! - `d/...`: per-file patches against the trees published before, when asked for
//!   ([`publish_with_bases`], [`crate::patch`]).
//!
//! Every name is a content id, so every object is write-once and cacheable for good; what is
//! current is said only by the signed pointer that names the manifest and the pack.

use crate::manifest::{Manifest, read_tree};
use crate::pack::{Index, Writer};
use crate::store::{self, write_atomic};
use crate::{Id, Result, patch};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

/// What [`publish`] wrote.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Published {
    /// The manifest's id.
    pub manifest: Id,
    /// The pack's id.
    pub pack: Id,
    /// The tree's bytes.
    pub tree_bytes: u64,
    /// The pack's bytes.
    pub pack_bytes: u64,
    /// Patches written against the base trees.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub patches: Option<usize>,
    /// Their bytes.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub patch_bytes: Option<u64>,
}

/// The object path of a manifest.
pub fn manifest_path(id: &Id) -> String {
    format!("m/{id}")
}

/// The object path of a pack.
pub fn pack_path(id: &Id) -> String {
    format!("p/{id}.pack")
}

/// The object path of a pack's index.
pub fn index_path(id: &Id) -> String {
    format!("p/{id}.idx")
}

/// Write `tree`'s manifest, pack and index under `out`.
pub fn publish(tree: &Path, out: &Path) -> Result<Published> {
    publish_with_bases(tree, &[], out)
}

/// [`publish`], and with `bases` (trees published before, which clients may hold) a patch for
/// each changed file against the file it pairs with in each base, and their list.
pub fn publish_with_bases(tree: &Path, bases: &[&Path], out: &Path) -> Result<Published> {
    let read = read_tree(tree)?;
    let mut files: HashMap<Id, Vec<u8>> = HashMap::new();
    let manifest = Manifest::build(&read, |id, bytes| {
        if let std::collections::hash_map::Entry::Vacant(e) = files.entry(id) {
            e.insert(store::encode(bytes, store::LEVEL)?);
        }
        Ok(())
    })?;
    let mut w = Writer::default();
    for c in manifest.distinct_chunks() {
        let bytes = files.get(&c.id).ok_or("every distinct chunk was encoded")?;
        w.push(c.id, bytes)?;
    }
    let (pack, index) = w.finish();
    let pack_id = index.pack.ok_or("a finished pack has an id")?;
    let manifest_id = manifest.id()?;
    std::fs::create_dir_all(out.join("m"))?;
    std::fs::create_dir_all(out.join("p"))?;
    write_atomic(out, &out.join(pack_path(&pack_id)), &pack)?;
    write_atomic(out, &out.join(index_path(&pack_id)), &serde_json::to_vec(&index)?)?;
    write_atomic(out, &out.join(manifest_path(&manifest_id)), &manifest.to_bytes()?)?;
    let (mut patches, mut patch_bytes) = (None, None);
    if !bases.is_empty() {
        let new: BTreeMap<String, Vec<u8>> = read.into_iter().map(|(p, (b, _))| (p, b)).collect();
        let mut olds = Vec::with_capacity(bases.len());
        for base in bases {
            olds.push(read_tree(base)?.into_iter().map(|(p, (b, _))| (p, b)).collect());
        }
        let list = patch::publish(&new, &olds, out)?;
        patch::write_list(&list, &manifest_id, out)?;
        patches = Some(list.patches.len());
        patch_bytes = Some(list.patches.iter().map(|p| p.len).sum());
    }
    Ok(Published {
        manifest: manifest_id,
        pack: pack_id,
        tree_bytes: manifest.size(),
        pack_bytes: pack.len() as u64,
        patches,
        patch_bytes,
    })
}

/// Parse an index fetched for `pack`, refusing one that names another pack.
pub fn parse_index(bytes: &[u8], pack: &Id) -> Result<Index> {
    let index: Index = serde_json::from_slice(bytes)?;
    if index.pack.as_ref() != Some(pack) {
        return Err(format!("the index of pack {pack} names {:?}", index.pack).into());
    }
    let mut end = 0u64;
    for e in &index.entries {
        if e.offset != end {
            return Err(format!("pack {pack}'s index has a hole or overlap at {}", e.offset).into());
        }
        end += u64::from(e.len);
    }
    Ok(index)
}
