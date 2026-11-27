//! The runtime: lazy per-(message, from, to) compilation, chain interning,
//! and broadcast translation.

use std::borrow::Cow;
use std::collections::HashMap;
use std::sync::{Arc, PoisonError, RwLock};

use serde_json::Value;

use crate::CompatError;
use crate::change::{Op, apply_op};
use crate::schema::Schema;
use crate::stream;
use crate::trie::Node;

/// One step of a chain: a change (by global index) in one direction.
type Step = (u32, bool);

/// A compiled change chain for one message kind and one revision pair.
///
/// Built lazily the first time a message of that kind crosses that pair, then
/// cached. Equal chains share one `Program` (see [`Compat::program`]).
#[derive(Debug)]
pub struct Program {
    root: Node,
    ops: Vec<Op>,
}

impl Program {
    fn compile(ops: Vec<Op>) -> Self {
        let mut root = Node::default();
        for op in &ops {
            root.apply(op.clone());
        }
        root.finish();
        Self { root, ops }
    }

    /// True when the program never changes a message.
    pub fn is_identity(&self) -> bool {
        self.root.is_identity()
    }

    /// Number of trie nodes the chain compiled into.
    pub fn trie_size(&self) -> usize {
        self.root.size()
    }

    /// Number of operations in the chain.
    pub fn chain_len(&self) -> usize {
        self.ops.len()
    }

    /// Rewrites one message. Borrows the input when nothing changes.
    pub fn rewrite<'a>(&self, input: &'a [u8]) -> Result<Cow<'a, [u8]>, CompatError> {
        if self.is_identity() {
            return Ok(Cow::Borrowed(input));
        }
        let mut out = Vec::with_capacity(input.len() + 64);
        stream::rewrite(&self.root, input, &mut out)?;
        Ok(Cow::Owned(out))
    }

    /// Rewrites one message into `out` (appending).
    pub fn rewrite_into(&self, input: &[u8], out: &mut Vec<u8>) -> Result<(), CompatError> {
        if self.is_identity() {
            out.extend_from_slice(input);
            return Ok(());
        }
        stream::rewrite(&self.root, input, out)
    }

    /// Reference result: applies the chain rule by rule to a parsed value.
    /// Slow; tests compare [`Program::rewrite`] against it.
    pub fn apply_reference(&self, value: &mut Value) {
        for op in &self.ops {
            apply_op(value, op);
        }
    }
}

struct Kind {
    /// `(rev, global change index)`, ascending by revision then order.
    changes: Vec<(u32, u32)>,
    cache: RwLock<HashMap<(u32, u32), Arc<Program>>>,
}

/// Translates messages between any two revisions of one protocol.
///
/// Thread-safe; share one `Compat` per process (inject it, no global).
pub struct Compat {
    schema: Schema,
    kinds: HashMap<String, Kind>,
    /// Global change list, indexed by `Step.0`.
    changes: Vec<crate::change::Change>,
    interned: RwLock<HashMap<Vec<Step>, Arc<Program>>>,
    identity: Arc<Program>,
}

impl Compat {
    /// Builds the runtime for a validated schema. Nothing is compiled yet.
    pub fn new(schema: Schema) -> Result<Self, CompatError> {
        schema.validate()?;
        let mut kinds: HashMap<String, Kind> = HashMap::new();
        let mut changes = Vec::new();
        for revision in &schema.revisions {
            for message_change in &revision.changes {
                let index = u32::try_from(changes.len()).map_err(|_| {
                    CompatError::InvalidSchema("more than 2^32 changes".to_string())
                })?;
                changes.push(message_change.change.clone());
                kinds
                    .entry(message_change.message.clone())
                    .or_insert_with(|| Kind { changes: Vec::new(), cache: RwLock::default() })
                    .changes
                    .push((revision.rev, index));
            }
        }
        Ok(Self {
            schema,
            kinds,
            changes,
            interned: RwLock::default(),
            identity: Arc::new(Program::compile(Vec::new())),
        })
    }

    /// The schema this runtime was built from.
    pub fn schema(&self) -> &Schema {
        &self.schema
    }

    /// The newest revision (what this build speaks natively).
    pub fn current(&self) -> u32 {
        self.schema.current()
    }

    /// True when this build can talk to a peer at `rev` (it knows every
    /// revision between them).
    pub fn supports(&self, rev: u32) -> bool {
        (self.schema.base..=self.current()).contains(&rev)
    }

    /// The program that turns a `kind` message written at revision `from`
    /// into one a reader at revision `to` understands.
    ///
    /// Compiled on first use and cached per `(kind, from, to)`; programs for
    /// equal chains are interned, so two revision pairs with the same changes
    /// for `kind` return the same `Arc` (compare with `Arc::ptr_eq`).
    pub fn program(&self, kind: &str, from: u32, to: u32) -> Result<Arc<Program>, CompatError> {
        for rev in [from, to] {
            if !self.supports(rev) {
                return Err(CompatError::UnsupportedRevision {
                    rev,
                    base: self.schema.base,
                    current: self.current(),
                });
            }
        }
        let Some(entry) = self.kinds.get(kind) else {
            return Ok(self.identity.clone());
        };
        if let Some(program) =
            entry.cache.read().unwrap_or_else(PoisonError::into_inner).get(&(from, to))
        {
            return Ok(program.clone());
        }
        let steps = chain(&entry.changes, from, to);
        let program = if steps.is_empty() { self.identity.clone() } else { self.intern(steps)? };
        entry
            .cache
            .write()
            .unwrap_or_else(PoisonError::into_inner)
            .insert((from, to), program.clone());
        Ok(program)
    }

    fn intern(&self, steps: Vec<Step>) -> Result<Arc<Program>, CompatError> {
        if let Some(program) =
            self.interned.read().unwrap_or_else(PoisonError::into_inner).get(&steps)
        {
            return Ok(program.clone());
        }
        let ops = steps
            .iter()
            .map(|&(index, up)| self.changes[index as usize].to_op(up))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .flatten()
            .collect();
        let program = Arc::new(Program::compile(ops));
        Ok(self
            .interned
            .write()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(steps)
            .or_insert(program)
            .clone())
    }

    /// Translates one message. Borrows the input when nothing changes.
    pub fn translate<'a>(
        &self,
        kind: &str,
        from: u32,
        to: u32,
        input: &'a [u8],
    ) -> Result<Cow<'a, [u8]>, CompatError> {
        if from == to {
            return Ok(Cow::Borrowed(input));
        }
        self.program(kind, from, to)?.rewrite(input)
    }

    /// Starts a broadcast of one message written at `from`: each distinct
    /// chain is translated once, however many peers share it.
    pub fn broadcast<'c, 'a>(
        &'c self,
        kind: &'c str,
        from: u32,
        input: &'a [u8],
    ) -> Broadcast<'c, 'a> {
        Broadcast { compat: self, kind, from, input, done: Vec::new(), translations: 0 }
    }
}

/// The steps for `kind` between two revisions, in application order.
fn chain(changes: &[(u32, u32)], from: u32, to: u32) -> Vec<Step> {
    if from < to {
        let lo = changes.partition_point(|&(rev, _)| rev <= from);
        let hi = changes.partition_point(|&(rev, _)| rev <= to);
        changes[lo..hi].iter().map(|&(_, index)| (index, true)).collect()
    } else {
        let lo = changes.partition_point(|&(rev, _)| rev <= to);
        let hi = changes.partition_point(|&(rev, _)| rev <= from);
        changes[lo..hi].iter().rev().map(|&(_, index)| (index, false)).collect()
    }
}

/// One message on its way to many peers. See [`Compat::broadcast`].
pub struct Broadcast<'c, 'a> {
    compat: &'c Compat,
    kind: &'c str,
    from: u32,
    input: &'a [u8],
    done: Vec<(Arc<Program>, Arc<[u8]>)>,
    translations: usize,
}

impl Broadcast<'_, '_> {
    /// The bytes for a peer at revision `to`.
    pub fn for_peer(&mut self, to: u32) -> Result<Arc<[u8]>, CompatError> {
        let program = self.compat.program(self.kind, self.from, to)?;
        if let Some((_, bytes)) = self.done.iter().find(|(p, _)| Arc::ptr_eq(p, &program)) {
            return Ok(bytes.clone());
        }
        let bytes: Arc<[u8]> = Arc::from(program.rewrite(self.input)?.as_ref());
        if !program.is_identity() {
            self.translations += 1;
        }
        self.done.push((program, bytes.clone()));
        Ok(bytes)
    }

    /// How many rewrites ran so far (one per distinct non-identity chain).
    pub fn translations(&self) -> usize {
        self.translations
    }
}
