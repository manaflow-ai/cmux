//! Change rules (the schema author's view) and their compiled operations.
//!
//! Every [`Change`] describes one step from revision `r - 1` to revision `r`
//! ("upgrade"). Each change also has an exact inverse ("downgrade"), so one
//! rule list serves both an old peer talking to a new one and a new peer
//! talking to an old one.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::CompatError;
use crate::pointer::{self, WILDCARD};

/// One API change on a JSON pointer, written in upgrade direction.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Change {
    /// The member at `path` is now called `to` (same parent object). It
    /// replaces any member already called `to`.
    Rename { path: String, to: String },
    /// The value at `from` now lives at `path`. Missing parents of `path` are created.
    Move { from: String, path: String },
    /// A new member. Upgrading inserts `default` when the member is missing;
    /// downgrading removes it.
    Add { path: String, default: Value },
    /// A removed member. Upgrading deletes it; downgrading inserts `default`
    /// for old peers that still need it.
    Remove { path: String, default: Value },
    /// The value at `path` changed type.
    Retype { path: String, up: Conversion, down: Conversion },
    /// An enum value (or any literal) changed: `from` is now written `to`.
    RenameValue { path: String, from: Value, to: Value },
    /// A member's presence changed: when it is missing, insert `default`, but
    /// only in `direction`. `up` = the member became required (old writers
    /// omit it); `down` = it became optional (old readers still need it).
    Fill { path: String, default: Value, direction: Direction },
}

/// Which translation direction a [`Change::Fill`] acts in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    /// Old to new only.
    Up,
    /// New to old only.
    Down,
    /// Both ways.
    Both,
}

/// A value conversion used by [`Change::Retype`].
///
/// A conversion whose input has the wrong type leaves the value unchanged.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Conversion {
    /// `12` -> `"12"`.
    NumberToString,
    /// `"12"` -> `12` (strings that are not JSON numbers stay strings).
    StringToNumber,
    /// `true` -> `1`.
    BoolToNumber,
    /// `0` -> `false`, any other number -> `true`.
    NumberToBool,
    /// `x` -> `[x]`.
    Wrap,
    /// `[x, ...]` -> `x`; `[]` -> `null`.
    Unwrap,
    /// `x` -> `{key: x}`.
    Nest { key: String },
    /// `{key: x, ...}` -> `x`.
    Unnest { key: String },
    /// `from` -> `to`; any other value is unchanged.
    MapValue { from: Value, to: Value },
}

impl Conversion {
    pub(crate) fn apply(&self, value: &mut Value) {
        match self {
            Self::NumberToString => {
                if let Value::Number(n) = value {
                    *value = Value::String(n.to_string());
                }
            }
            Self::StringToNumber => {
                if let Value::String(s) = value
                    && let Ok(n) = serde_json::from_str::<serde_json::Number>(s)
                {
                    *value = Value::Number(n);
                }
            }
            Self::BoolToNumber => {
                if let Value::Bool(b) = value {
                    *value = Value::from(u8::from(*b));
                }
            }
            Self::NumberToBool => {
                if let Value::Number(n) = value {
                    *value = Value::Bool(n.as_f64().is_some_and(|f| f != 0.0));
                }
            }
            Self::Wrap => *value = Value::Array(vec![value.take()]),
            Self::Unwrap => {
                if let Value::Array(items) = value {
                    *value = if items.is_empty() { Value::Null } else { items.swap_remove(0) };
                }
            }
            Self::Nest { key } => {
                let mut map = Map::new();
                map.insert(key.clone(), value.take());
                *value = Value::Object(map);
            }
            Self::Unnest { key } => {
                if let Value::Object(map) = value
                    && let Some(inner) = map.remove(key)
                {
                    *value = inner;
                }
            }
            Self::MapValue { from, to } => {
                if value == from {
                    *value = to.clone();
                }
            }
        }
    }
}

/// A compiled operation with parsed pointers.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Op {
    Rename {
        parent: Vec<String>,
        from: String,
        to: String,
    },
    Delete {
        parent: Vec<String>,
        key: String,
    },
    Insert {
        parent: Vec<String>,
        key: String,
        value: Value,
    },
    Convert {
        path: Vec<String>,
        conv: Conversion,
    },
    /// A move whose ends do not share a parent; `lca` is their common prefix.
    Move {
        lca: Vec<String>,
        from: Vec<String>,
        to: Vec<String>,
    },
}

/// Where an operation acts, relative to the node it is applied to.
pub(crate) enum Head<'a> {
    /// The operation acts on this node itself.
    Local,
    /// The operation acts below the child `token`; `rest` is relative to it.
    Descend { token: &'a str, rest: Op },
}

impl Op {
    pub(crate) fn head(&self) -> Head<'_> {
        let prefix = match self {
            Self::Rename { parent, .. }
            | Self::Delete { parent, .. }
            | Self::Insert { parent, .. } => parent,
            Self::Convert { path, .. } => path,
            Self::Move { lca, .. } => lca,
        };
        let Some(token) = prefix.first() else {
            return Head::Local;
        };
        let mut rest = self.clone();
        match &mut rest {
            Self::Rename { parent, .. }
            | Self::Delete { parent, .. }
            | Self::Insert { parent, .. } => {
                parent.remove(0);
            }
            Self::Convert { path, .. } => {
                path.remove(0);
            }
            Self::Move { lca, .. } => {
                lca.remove(0);
            }
        }
        Head::Descend { token, rest }
    }
}

impl Op {
    /// The paths (relative to the node the op is applied at) this op reads or writes.
    fn touched(&self) -> [Vec<String>; 2] {
        let join = |a: &[String], b: &[String]| [a, b].concat();
        match self {
            Self::Rename { parent, from, to } => {
                [join(parent, std::slice::from_ref(from)), join(parent, std::slice::from_ref(to))]
            }
            Self::Delete { parent, key } | Self::Insert { parent, key, .. } => {
                let path = join(parent, std::slice::from_ref(key));
                [path.clone(), path]
            }
            Self::Convert { path, .. } => [path.clone(), path.clone()],
            Self::Move { lca, from, to } => [join(lca, from), join(lca, to)],
        }
    }

    /// The parent path a move creates when it is missing.
    fn created_parent(&self) -> Option<Vec<String>> {
        match self {
            Self::Move { lca, to, .. } => Some([lca.as_slice(), &to[..to.len() - 1]].concat()),
            _ => None,
        }
    }

    /// The path that must exist for this op to act (it does nothing otherwise).
    fn needs_existing(&self) -> Option<&[String]> {
        match self {
            Self::Insert { parent, .. } => Some(parent),
            Self::Convert { path, .. } => Some(path),
            _ => None,
        }
    }

    /// True when applying `self` and `other` in either order gives the same
    /// result: no path one touches is a prefix of (or equal to) a path the
    /// other touches, with `*` matching any token.
    pub(crate) fn commutes_with(&self, other: &Op) -> bool {
        let overlaps = |a: &[String], b: &[String]| {
            a.iter().zip(b).all(|(x, y)| x == y || x == WILDCARD || y == WILDCARD)
        };
        // A move can create a parent that an insert or a retype needs.
        let creates_for = |a: &Op, b: &Op| match (a.created_parent(), b.needs_existing()) {
            (Some(created), Some(needed)) => {
                needed.len() <= created.len() && overlaps(needed, &created)
            }
            _ => false,
        };
        if creates_for(self, other) || creates_for(other, self) {
            return false;
        }
        let theirs = other.touched();
        !self.touched().iter().any(|p| theirs.iter().any(|q| overlaps(p, q)))
    }
}

fn split_last(path: &str) -> Result<(Vec<String>, String), CompatError> {
    let mut tokens = pointer::parse(path)?;
    let Some(last) = tokens.pop() else {
        return Err(CompatError::InvalidChange(format!(
            "`{path}` must name a member, not the root"
        )));
    };
    if last == WILDCARD {
        return Err(CompatError::InvalidChange(format!(
            "`{path}` must end in a member name, not `*`"
        )));
    }
    Ok((tokens, last))
}

fn make_move(from: &str, to: &str) -> Result<Op, CompatError> {
    let from_tokens = pointer::parse(from)?;
    let to_tokens = pointer::parse(to)?;
    for (tokens, path) in [(&from_tokens, from), (&to_tokens, to)] {
        match tokens.last() {
            None => {
                return Err(CompatError::InvalidChange(format!("move end `{path}` is the root")));
            }
            Some(last) if last == WILDCARD => {
                return Err(CompatError::InvalidChange(format!("move end `{path}` ends in `*`")));
            }
            Some(_) => {}
        }
    }
    let common = from_tokens.iter().zip(&to_tokens).take_while(|(a, b)| a == b).count();
    if common == from_tokens.len() || common == to_tokens.len() {
        return Err(CompatError::InvalidChange(format!(
            "move `{from}` -> `{to}` nests one end in the other"
        )));
    }
    let lca = from_tokens[..common].to_vec();
    let from_rel = from_tokens[common..].to_vec();
    let to_rel = to_tokens[common..].to_vec();
    if from_rel.iter().chain(&to_rel).any(|t| t == WILDCARD) {
        return Err(CompatError::InvalidChange(format!(
            "move `{from}` -> `{to}` has `*` below the shared prefix"
        )));
    }
    if from_rel.len() == 1 && to_rel.len() == 1 {
        return Ok(Op::Rename { parent: lca, from: from_rel[0].clone(), to: to_rel[0].clone() });
    }
    Ok(Op::Move { lca, from: from_rel, to: to_rel })
}

impl Change {
    /// The pointer this change is about (used by the coverage check).
    pub fn path(&self) -> &str {
        match self {
            Self::Rename { path, .. }
            | Self::Move { path, .. }
            | Self::Add { path, .. }
            | Self::Remove { path, .. }
            | Self::Retype { path, .. }
            | Self::RenameValue { path, .. }
            | Self::Fill { path, .. } => path,
        }
    }

    /// Compiles this change in upgrade (`up == true`) or downgrade direction.
    /// `None` when the change does nothing in that direction.
    pub(crate) fn to_op(&self, up: bool) -> Result<Option<Op>, CompatError> {
        if let Self::Fill { path, default, direction } = self {
            let (parent, key) = split_last(path)?;
            let acts = match direction {
                Direction::Up => up,
                Direction::Down => !up,
                Direction::Both => true,
            };
            return Ok(acts.then(|| Op::Insert { parent, key, value: default.clone() }));
        }
        self.to_op_both(up).map(Some)
    }

    fn to_op_both(&self, up: bool) -> Result<Op, CompatError> {
        match self {
            Self::Rename { path, to } => {
                let (parent, from) = split_last(path)?;
                if to == &from {
                    return Err(CompatError::InvalidChange(format!(
                        "rename of `{path}` to itself"
                    )));
                }
                if to == WILDCARD {
                    return Err(CompatError::InvalidChange(format!("rename of `{path}` to `*`")));
                }
                Ok(if up {
                    Op::Rename { parent, from, to: to.clone() }
                } else {
                    Op::Rename { parent, from: to.clone(), to: from }
                })
            }
            Self::Move { from, path } => {
                if up {
                    make_move(from, path)
                } else {
                    make_move(path, from)
                }
            }
            Self::Add { path, default } | Self::Remove { path, default } => {
                let (parent, key) = split_last(path)?;
                let inserts = matches!(self, Self::Add { .. }) == up;
                Ok(if inserts {
                    Op::Insert { parent, key, value: default.clone() }
                } else {
                    Op::Delete { parent, key }
                })
            }
            Self::Retype { path, up: u, down } => Ok(Op::Convert {
                path: pointer::parse(path)?,
                conv: if up { u.clone() } else { down.clone() },
            }),
            Self::RenameValue { path, from, to } => {
                let (from, to) = if up { (from, to) } else { (to, from) };
                Ok(Op::Convert {
                    path: pointer::parse(path)?,
                    conv: Conversion::MapValue { from: from.clone(), to: to.clone() },
                })
            }
            Self::Fill { .. } => {
                Err(CompatError::InvalidChange("a fill compiles in to_op, not here".to_string()))
            }
        }
    }
}

/// Reference semantics: applies one operation to a whole document. The
/// streaming rewriter must produce exactly this result; tests check it.
pub(crate) fn apply_op(value: &mut Value, op: &Op) {
    match op {
        // A rename replaces its target, even when the source is missing, so
        // the streaming trie never has to look ahead for the source.
        Op::Rename { parent, from, to } => for_each_mut(value, parent, &mut |v| {
            if let Value::Object(map) = v
                && from != to
            {
                let moved = map.remove(from);
                map.remove(to);
                if let Some(inner) = moved {
                    map.insert(to.clone(), inner);
                }
            }
        }),
        Op::Delete { parent, key } => for_each_mut(value, parent, &mut |v| {
            if let Value::Object(map) = v {
                map.remove(key);
            }
        }),
        Op::Insert { parent, key, value: default } => for_each_mut(value, parent, &mut |v| {
            if let Value::Object(map) = v
                && !map.contains_key(key)
            {
                map.insert(key.clone(), default.clone());
            }
        }),
        Op::Convert { path, conv } => for_each_mut(value, path, &mut |v| conv.apply(v)),
        Op::Move { lca, from, to } => for_each_mut(value, lca, &mut |v| move_within(v, from, to)),
    }
}

fn for_each_mut(value: &mut Value, tokens: &[String], f: &mut dyn FnMut(&mut Value)) {
    let Some((token, rest)) = tokens.split_first() else {
        f(value);
        return;
    };
    if token == WILDCARD {
        match value {
            Value::Array(items) => items.iter_mut().for_each(|v| for_each_mut(v, rest, f)),
            Value::Object(map) => map.values_mut().for_each(|v| for_each_mut(v, rest, f)),
            _ => {}
        }
    } else if let Value::Object(map) = value
        && let Some(child) = map.get_mut(token)
    {
        for_each_mut(child, rest, f);
    }
}

fn move_within(value: &mut Value, from: &[String], to: &[String]) {
    // Refuse before touching the source when the destination cannot be built.
    if !destination_buildable(value, &to[..to.len() - 1]) {
        return;
    }
    let Some(taken) = take_at(value, from) else { return };
    let mut cursor = value;
    for token in &to[..to.len() - 1] {
        let Value::Object(map) = cursor else { return };
        cursor = map.entry(token.clone()).or_insert_with(|| Value::Object(Map::new()));
    }
    if let Value::Object(map) = cursor {
        map.insert(to[to.len() - 1].clone(), taken);
    }
}

/// True when every existing parent on the way is an object (missing ones get created).
fn destination_buildable(value: &Value, parents: &[String]) -> bool {
    let mut cursor = value;
    for token in parents {
        let Value::Object(map) = cursor else { return false };
        match map.get(token) {
            Some(next) => cursor = next,
            None => return true,
        }
    }
    cursor.is_object()
}

fn take_at(value: &mut Value, path: &[String]) -> Option<Value> {
    let (last, parents) = path.split_last()?;
    let mut cursor = value;
    for token in parents {
        cursor = cursor.as_object_mut()?.get_mut(token)?;
    }
    cursor.as_object_mut()?.remove(last)
}
