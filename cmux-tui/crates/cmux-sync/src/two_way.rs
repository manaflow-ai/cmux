//! Two-way folder sync between a Mac and a VM (or a laptop and a personal box) on the three-tree
//! rule ([`crate::three_tree`]), for herefs (cmuxterm-hq RFD 0007) and RFD 0140 section 5.
//!
//! One [`round`] takes three trees, each a map from path to content hash: **local** (the Mac's
//! folder now), **remote** (the VM's folder now) and **synced** (the revision both last agreed
//! on). It returns what to do on each side and the next synced tree. Applying the ops to both
//! sides leaves both folders equal to that tree, whichever order the edits came in:
//!
//! - one side changed: the change goes to the other side (a delete included);
//! - both reached the same content: only synced moves;
//! - both changed a text file differently: merged three-way against synced, written to both;
//! - the merge overlaps, or the file is not text: the remote's version stays at the path on both
//!   sides and the local's is kept beside it as `NAME.cmux-sync-conflict` (RFD 0007's name), on
//!   both sides, so nobody's edit is lost;
//! - one side deleted and the other edited: the edit is restored on the side that deleted it.
//!   A delete never wins over an edit.
//!
//! **The synced tree is a revision in the store, not a record on one machine.** RFD 0007 lists the
//! gap: a synced base kept only in one daemon's memory or state folder is gone after a restart or
//! on the other machine, and then every file looks changed on both sides. Here a [`Revision`] is
//! content-addressed (its id is the SHA-256 of its canonical bytes) and kept in a [`Store`] that
//! both sides read, with a head per folder pair. [`commit`] writes the revision before it moves
//! the head, so a crash between the two leaves the old head, and the next round from the old head
//! converges: whatever ops already landed read as "both sides the same" and only move synced.
//!
//! Pure: the caller hashes files, moves bytes, does the line merge ([`Content`]) and persists the
//! store's bytes.

use std::collections::BTreeMap;

use sha2::{Digest as _, Sha256};

use crate::three_tree::{self, Conflict, Decision, Resolution};

/// The suffix of a conflict's kept-aside copy (RFD 0007).
pub const CONFLICT_SUFFIX: &str = ".cmux-sync-conflict";

/// A folder as path to content hash.
pub type Tree = BTreeMap<String, String>;

/// One change to make on one side.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Op {
    /// Put the content with this hash at the path.
    Write { path: String, hash: String },
    /// Remove the path.
    Delete { path: String },
}

/// What the caller knows about content: which files are text, and the line merge.
pub trait Content {
    /// Whether the content with this hash is text (merged by line).
    fn is_text(&self, hash: &str) -> bool;
    /// Merges `local` and `remote` against `base` (`None` when both created the file). Returns the
    /// merged content's hash, stored so the caller can write it, or `None` when edits overlap.
    fn merge(&mut self, base: Option<&str>, local: &str, remote: &str) -> Option<String>;
}

/// One round's outcome.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Round {
    /// Ops for the local side (the Mac).
    pub local_ops: Vec<Op>,
    /// Ops for the remote side (the VM).
    pub remote_ops: Vec<Op>,
    /// The tree both sides hold after the ops: the next synced revision.
    pub synced: Tree,
    /// Paths both sides changed that merged cleanly by line.
    pub merged: Vec<String>,
    /// Paths that were a conflict: a conflict file was written beside them, or an edit was kept
    /// over a delete.
    pub conflicts: Vec<String>,
}

/// The name of `path`'s conflict copy that no tree uses yet: `NAME.cmux-sync-conflict`, then
/// `NAME.cmux-sync-conflict-2` and on.
fn conflict_name(path: &str, taken: impl Fn(&str) -> bool) -> String {
    let first = format!("{path}{CONFLICT_SUFFIX}");
    if !taken(&first) {
        return first;
    }
    let mut n: u64 = 2;
    loop {
        let name = format!("{first}-{n}");
        if !taken(&name) {
            return name;
        }
        n += 1;
    }
}

/// One sync round over the three trees.
pub fn round(synced: &Tree, local: &Tree, remote: &Tree, content: &mut impl Content) -> Round {
    let mut out = Round { synced: synced.clone(), ..Round::default() };
    // Writes to one path on both sides: only the side that does not already hold it gets an op.
    fn put(out: &mut Round, local: &Tree, remote: &Tree, path: &str, hash: &str) {
        if local.get(path).map(String::as_str) != Some(hash) {
            out.local_ops.push(Op::Write { path: path.to_owned(), hash: hash.to_owned() });
        }
        if remote.get(path).map(String::as_str) != Some(hash) {
            out.remote_ops.push(Op::Write { path: path.to_owned(), hash: hash.to_owned() });
        }
        out.synced.insert(path.to_owned(), hash.to_owned());
    }
    let decisions = three_tree::decide_tree(synced, local, remote);
    for (path, decision) in &decisions {
        match decision {
            Decision::Nothing => {}
            Decision::Push(Some(hash)) => {
                out.remote_ops.push(Op::Write { path: path.clone(), hash: hash.clone() });
                out.synced.insert(path.clone(), hash.clone());
            }
            Decision::Push(None) => {
                out.remote_ops.push(Op::Delete { path: path.clone() });
                out.synced.remove(path);
            }
            Decision::Apply(Some(hash)) => {
                out.local_ops.push(Op::Write { path: path.clone(), hash: hash.clone() });
                out.synced.insert(path.clone(), hash.clone());
            }
            Decision::Apply(None) => {
                out.local_ops.push(Op::Delete { path: path.clone() });
                out.synced.remove(path);
            }
            Decision::RecordSynced(Some(hash)) => {
                out.synced.insert(path.clone(), hash.clone());
            }
            Decision::RecordSynced(None) => {
                out.synced.remove(path);
            }
            Decision::Conflict(conflict) => {
                let text = match conflict {
                    Conflict::Content { local, remote } => {
                        content.is_text(local)
                            && content.is_text(remote)
                            && synced.get(path).is_none_or(|base| content.is_text(base))
                    }
                    _ => false,
                };
                // A conflict file: `keep` at the path, `aside` under the first unused conflict name.
                let conflict_file = |out: &mut Round, keep: &str, aside: &str| {
                    put(out, local, remote, path, keep);
                    let name = conflict_name(path, |name| {
                        local.contains_key(name)
                            || remote.contains_key(name)
                            || out.synced.contains_key(name)
                            || decisions.contains_key(name)
                    });
                    put(out, local, remote, &name, aside);
                };
                match three_tree::resolve(synced.get(path), conflict, text) {
                    Resolution::ThreeWay { base, local: l, remote: r } => {
                        match content.merge(base.as_deref(), &l, &r) {
                            Some(merged) => {
                                put(&mut out, local, remote, path, &merged);
                                out.merged.push(path.clone());
                                continue;
                            }
                            None => conflict_file(&mut out, &r, &l),
                        }
                    }
                    Resolution::ConflictFile { keep, aside } => {
                        conflict_file(&mut out, &keep, &aside);
                    }
                    Resolution::KeepEdit(hash) => put(&mut out, local, remote, path, &hash),
                }
                out.conflicts.push(path.clone());
            }
        }
    }
    out
}

/// Applies ops to a tree (a test or a dry run of one side).
pub fn apply(tree: &mut Tree, ops: &[Op]) {
    for op in ops {
        match op {
            Op::Write { path, hash } => {
                tree.insert(path.clone(), hash.clone());
            }
            Op::Delete { path } => {
                tree.remove(path);
            }
        }
    }
}

/// A synced tree as content-addressed bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Revision {
    pub tree: Tree,
}

const REVISION_MAGIC: &str = "cmux-sync-revision-v1\n";

/// Bytes that do not decode as a revision, or whose id is not their hash.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BadRevision(pub &'static str);

impl std::fmt::Display for BadRevision {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "bad sync revision: {}", self.0)
    }
}

impl std::error::Error for BadRevision {}

impl Revision {
    /// Canonical bytes: the magic line, then each path and hash length-prefixed, in path order, so
    /// any path (newlines included) round-trips and equal trees have equal bytes.
    pub fn encode(&self) -> Vec<u8> {
        let mut bytes = REVISION_MAGIC.as_bytes().to_vec();
        for (path, hash) in &self.tree {
            for field in [path, hash] {
                bytes.extend_from_slice(field.len().to_string().as_bytes());
                bytes.push(b':');
                bytes.extend_from_slice(field.as_bytes());
            }
        }
        bytes
    }

    /// Reads canonical bytes back.
    pub fn decode(bytes: &[u8]) -> Result<Self, BadRevision> {
        let mut rest = bytes.strip_prefix(REVISION_MAGIC.as_bytes()).ok_or(BadRevision("magic"))?;
        let mut field = || -> Result<Option<String>, BadRevision> {
            if rest.is_empty() {
                return Ok(None);
            }
            let colon = rest.iter().position(|&b| b == b':').ok_or(BadRevision("length"))?;
            let len: usize = std::str::from_utf8(&rest[..colon])
                .ok()
                .and_then(|s| s.parse().ok())
                .ok_or(BadRevision("length"))?;
            let body = rest.get(colon + 1..colon + 1 + len).ok_or(BadRevision("truncated"))?;
            let text = String::from_utf8(body.to_vec()).map_err(|_| BadRevision("utf-8"))?;
            rest = &rest[colon + 1 + len..];
            Ok(Some(text))
        };
        let mut tree = Tree::new();
        let mut last: Option<String> = None;
        while let Some(path) = field()? {
            let hash = field()?.ok_or(BadRevision("path without hash"))?;
            if last.as_ref().is_some_and(|last| *last >= path) {
                return Err(BadRevision("paths out of order"));
            }
            last = Some(path.clone());
            tree.insert(path, hash);
        }
        Ok(Self { tree })
    }

    /// The revision's id: the SHA-256 of its canonical bytes, hex.
    pub fn id(&self) -> String {
        hex(&Sha256::digest(self.encode()))
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Where synced revisions live: content-addressed blobs plus one head per folder pair. Both sides
/// read the same store (the herefs store), so neither machine's restart loses the base.
pub trait Store {
    fn put(&mut self, id: &str, bytes: Vec<u8>);
    fn get(&self, id: &str) -> Option<Vec<u8>>;
    fn head(&self, pair: &str) -> Option<String>;
    fn set_head(&mut self, pair: &str, id: &str);
}

/// The synced tree for a folder pair: empty before the first sync. A head whose revision is
/// missing or does not hash to its id is an error, never an empty tree: an empty base would make
/// every file read as created on both sides.
pub fn load(store: &impl Store, pair: &str) -> Result<Tree, BadRevision> {
    let Some(id) = store.head(pair) else { return Ok(Tree::new()) };
    let bytes = store.get(&id).ok_or(BadRevision("head names a missing revision"))?;
    let revision = Revision::decode(&bytes)?;
    if revision.id() != id {
        return Err(BadRevision("revision does not hash to its id"));
    }
    Ok(revision.tree)
}

/// Records `tree` as the pair's synced revision: the revision first, then the head, so a crash in
/// between leaves the old head pointing at a whole revision. Returns the id.
pub fn commit(store: &mut impl Store, pair: &str, tree: &Tree) -> String {
    let revision = Revision { tree: tree.clone() };
    let id = revision.id();
    store.put(&id, revision.encode());
    store.set_head(pair, &id);
    id
}

/// A store in memory (tests, and a host that persists the map itself).
#[derive(Clone, Debug, Default)]
pub struct MemStore {
    pub blobs: BTreeMap<String, Vec<u8>>,
    pub heads: BTreeMap<String, String>,
}

impl Store for MemStore {
    fn put(&mut self, id: &str, bytes: Vec<u8>) {
        self.blobs.insert(id.to_owned(), bytes);
    }
    fn get(&self, id: &str) -> Option<Vec<u8>> {
        self.blobs.get(id).cloned()
    }
    fn head(&self, pair: &str) -> Option<String> {
        self.heads.get(pair).cloned()
    }
    fn set_head(&mut self, pair: &str, id: &str) {
        self.heads.insert(pair.to_owned(), id.to_owned());
    }
}
