//! The compiled form of a change chain: a trie keyed by JSON path tokens.
//!
//! A whole chain (one rule or ten thousand) folds into one trie, so a message
//! is rewritten in a single forward pass whatever the chain length. Each node
//! describes what happens to the members of the object (or the elements of the
//! array) at its path, in *input* coordinates:
//!
//! - `members`: specific input keys, each with its output name (`None` =
//!   deleted), its own sub-trie, and an optional default emitted when the key
//!   is absent from the input.
//! - `wild`: the sub-trie for every array element and every object member
//!   without a specific entry.
//! - `slow`: operations the trie cannot express in streaming form (type
//!   changes, moves across parents). A node with slow operations is
//!   materialized: its subtree is parsed, edited, and re-serialized. Every
//!   other byte of the message is copied as-is.

use std::collections::HashMap;

use serde_json::Value;

use crate::change::{Head, Op, apply_op};
use crate::pointer::WILDCARD;

#[derive(Clone, Debug, Default)]
pub(crate) struct Node {
    pub(crate) members: Vec<Member>,
    by_input: HashMap<String, usize>,
    by_output: HashMap<String, usize>,
    pub(crate) wild: Option<Box<Node>>,
    pub(crate) slow: Vec<Op>,
    /// Set by `finish`: some member carries a default.
    pub(crate) has_defaults: bool,
}

#[derive(Clone, Debug)]
pub(crate) struct Member {
    /// The input key this member matches; `None` for a pure insertion whose
    /// input key was renamed or deleted earlier in the chain.
    pub(crate) input: Option<String>,
    /// The output key; `None` means the member is dropped.
    pub(crate) output: Option<String>,
    pub(crate) node: Node,
    /// Emitted (already in output form) when the input lacks the member.
    pub(crate) default: Option<Value>,
    /// Set by `finish`: `"output":` as JSON bytes.
    pub(crate) output_json: Vec<u8>,
}

impl Member {
    fn new(input: Option<String>, output: Option<String>, node: Node) -> Self {
        Self { input, output, node, default: None, output_json: Vec::new() }
    }
}

impl Node {
    /// True when the node changes nothing (its subtree can be copied raw).
    pub(crate) fn is_identity(&self) -> bool {
        self.members.is_empty() && self.wild.is_none() && self.slow.is_empty()
    }

    /// Adds one operation (in chain order) to the trie.
    pub(crate) fn apply(&mut self, op: Op) {
        if !self.slow.is_empty() {
            // Once a node is materialized, later rules run on the value, in order.
            self.slow.push(op);
            return;
        }
        match op.head() {
            Head::Local => self.apply_local(op),
            Head::Descend { token, rest } => {
                if token == WILDCARD {
                    self.wild.get_or_insert_default().apply(rest.clone());
                    for member in self.members.iter_mut().filter(|m| m.output.is_some()) {
                        member.node.apply(rest.clone());
                        if let Some(default) = &mut member.default {
                            apply_op(default, &rest);
                        }
                    }
                } else {
                    let token = token.to_owned();
                    if let Some(index) = self.live_member(&token) {
                        let member = &mut self.members[index];
                        if let Some(default) = &mut member.default {
                            apply_op(default, &rest);
                        }
                        member.node.apply(rest);
                    }
                }
            }
        }
    }

    /// The member that currently produces output key `key`, created as a
    /// pass-through when the input key has not been touched yet. `None` when
    /// `key` cannot appear in the output (renamed away or deleted).
    fn live_member(&mut self, key: &str) -> Option<usize> {
        if let Some(&index) = self.by_output.get(key) {
            return Some(index);
        }
        if self.by_input.contains_key(key) {
            return None;
        }
        Some(self.push_member(Member::new(
            Some(key.to_owned()),
            Some(key.to_owned()),
            self.wild_clone(),
        )))
    }

    fn wild_clone(&self) -> Node {
        self.wild.as_deref().cloned().unwrap_or_default()
    }

    fn push_member(&mut self, member: Member) -> usize {
        let index = self.members.len();
        if let Some(input) = &member.input {
            self.by_input.insert(input.clone(), index);
        }
        if let Some(output) = &member.output {
            self.by_output.insert(output.clone(), index);
        }
        self.members.push(member);
        index
    }

    fn apply_local(&mut self, op: Op) {
        match op {
            Op::Rename { from, to, .. } => {
                if let Some(index) = self.by_output.remove(&from) {
                    self.members[index].output = Some(to.clone());
                    self.by_output.insert(to, index);
                } else if !self.by_input.contains_key(&from) {
                    self.push_member(Member::new(Some(from), Some(to), self.wild_clone()));
                }
            }
            Op::Delete { key, .. } => {
                if let Some(index) = self.by_output.remove(&key) {
                    let member = &mut self.members[index];
                    member.output = None;
                    member.default = None;
                    member.node = Node::default();
                } else if !self.by_input.contains_key(&key) {
                    self.push_member(Member::new(Some(key), None, Node::default()));
                }
            }
            Op::Insert { key, value, .. } => {
                if let Some(&index) = self.by_output.get(&key) {
                    let member = &mut self.members[index];
                    // A pure insertion is always present already; otherwise fill the gap.
                    if member.input.is_some() && member.default.is_none() {
                        member.default = Some(value);
                    }
                } else if self.by_input.contains_key(&key) {
                    let mut member = Member::new(None, Some(key), Node::default());
                    member.default = Some(value);
                    self.push_member(member);
                } else {
                    let mut member = Member::new(Some(key.clone()), Some(key), self.wild_clone());
                    member.default = Some(value);
                    self.push_member(member);
                }
            }
            Op::Convert { .. } | Op::Move { .. } => self.slow.push(op),
        }
    }

    /// Drops no-op entries and precomputes output bytes. Run once after the
    /// whole chain is applied.
    pub(crate) fn finish(&mut self) {
        if let Some(wild) = &mut self.wild {
            wild.finish();
            if wild.is_identity() {
                self.wild = None;
            }
        }
        let wild_is_none = self.wild.is_none();
        for member in &mut self.members {
            member.node.finish();
        }
        let before = self.members.len();
        self.members.retain(|m| {
            !(wild_is_none
                && m.input.is_some()
                && m.output == m.input
                && m.default.is_none()
                && m.node.is_identity())
        });
        if self.members.len() != before {
            self.by_input.clear();
            self.by_output.clear();
            for (index, member) in self.members.iter().enumerate() {
                if let Some(input) = &member.input {
                    self.by_input.insert(input.clone(), index);
                }
                if let Some(output) = &member.output {
                    self.by_output.insert(output.clone(), index);
                }
            }
        }
        for member in &mut self.members {
            if let Some(output) = &member.output {
                member.output_json = serde_json::to_vec(output).expect("strings serialize");
                member.output_json.push(b':');
            }
        }
        self.has_defaults = self.members.iter().any(|m| m.default.is_some() && m.output.is_some());
        // Lookups on small nodes scan `members`; only big nodes keep the map.
        if self.members.len() <= LINEAR_LOOKUP_MAX {
            self.by_input = HashMap::new();
        }
        self.by_output = HashMap::new();
    }

    /// The member for input key `key`, if any. Valid after `finish`.
    #[inline]
    pub(crate) fn lookup(&self, key: &str) -> Option<usize> {
        if self.members.len() <= LINEAR_LOOKUP_MAX {
            self.members.iter().position(|m| m.input.as_deref() == Some(key))
        } else {
            self.by_input.get(key).copied()
        }
    }

    /// Applies this node to a parsed value (used for materialized subtrees).
    pub(crate) fn apply_value(&self, value: &mut Value) {
        match value {
            Value::Object(map) if !self.members.is_empty() || self.wild.is_some() => {
                let old = std::mem::take(map);
                let mut seen = vec![false; self.members.len()];
                for (key, mut inner) in old {
                    match self.lookup(&key) {
                        Some(index) => {
                            seen[index] = true;
                            let member = &self.members[index];
                            if let Some(output) = &member.output {
                                member.node.apply_value(&mut inner);
                                map.insert(output.clone(), inner);
                            }
                        }
                        None => {
                            if let Some(wild) = &self.wild {
                                wild.apply_value(&mut inner);
                            }
                            map.insert(key, inner);
                        }
                    }
                }
                for (member, seen) in self.members.iter().zip(seen) {
                    if !seen
                        && let (Some(output), Some(default)) = (&member.output, &member.default)
                    {
                        map.insert(output.clone(), default.clone());
                    }
                }
            }
            Value::Array(items) => {
                if let Some(wild) = &self.wild {
                    items.iter_mut().for_each(|item| wild.apply_value(item));
                }
            }
            _ => {}
        }
        for op in &self.slow {
            apply_op(value, op);
        }
    }

    /// Number of trie nodes (for diagnostics and benches).
    pub(crate) fn size(&self) -> usize {
        1 + self.wild.as_ref().map_or(0, |w| w.size())
            + self.members.iter().map(|m| m.node.size()).sum::<usize>()
    }
}

const LINEAR_LOOKUP_MAX: usize = 8;
