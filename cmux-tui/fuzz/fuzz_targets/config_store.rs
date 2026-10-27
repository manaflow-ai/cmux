//! The settings owner's reducer (`cmux_config::apply`) on an op stream over a
//! fuzz cmux.json: set, reset, reset all, domains, team policy and external
//! reloads, with idempotency keys and `if_revision`.
//!
//! Checked: the revision never goes back and grows by one per visible change;
//! a write leaves a file that parses; a stale `if_revision` is refused; an op
//! repeated with its idempotency key replays without a change.
//!
//! Input: a length byte, four times that many bytes of initial cmux.json,
//! then ops, each a selector byte (`selector % 8`: 0, 1 and 6 set, 2 reset,
//! 3 reset all, 4 domains, 5 team policy, 7 reload) and its fields. A row is
//! picked by a little-endian u16 index.
#![no_main]

use std::collections::BTreeMap;

use cmux_config::managed::TeamPolicyLayer;
use cmux_config::store::FileRead;
use cmux_config::{
    Domains, ManagedPreferences, Op, Origin, Refusal, Schema, State, Target, WriteMeta, apply,
};
use libfuzzer_sys::fuzz_target;
use serde_json::{Value, json};

const ORIGINS: [Origin; 6] =
    [Origin::User, Origin::Cli, Origin::Mcp, Origin::Script, Origin::Remote, Origin::App];

struct Bytes<'a>(&'a [u8]);

impl<'a> Bytes<'a> {
    fn byte(&mut self) -> Option<u8> {
        let (&first, rest) = self.0.split_first()?;
        self.0 = rest;
        Some(first)
    }

    fn take(&mut self, len: usize) -> &'a [u8] {
        let (head, rest) = self.0.split_at(len.min(self.0.len()));
        self.0 = rest;
        head
    }

    /// A row of `schema` by a little-endian u16 index, so all of its rows
    /// (more than 256) are reachable.
    fn row<'s>(&mut self, schema: &'s Schema) -> Option<&'s cmux_config::schema::Row> {
        let index = u16::from_le_bytes([self.byte()?, self.byte()?]);
        Some(&schema.rows[usize::from(index) % schema.rows.len()])
    }

    fn text(&mut self) -> Option<String> {
        let len = usize::from(self.byte()?);
        Some(String::from_utf8_lossy(self.take(len)).into_owned())
    }
}

fn value(input: &mut Bytes<'_>, schema: &Schema) -> Option<Value> {
    Some(match input.byte()? % 8 {
        0 => Value::Bool(input.byte()? & 1 == 1),
        1 => json!(input.byte()? as i8),
        2 => json!(f64::from(input.byte()?) / 4.0),
        3 => Value::String(input.text()?),
        4 => Value::Null,
        // A value one of the schema's rows lists as accepted or refused.
        5 => {
            let row = input.row(schema)?;
            let samples = [row.accepts.as_slice(), row.refuses.as_slice()].concat();
            let pick = usize::from(input.byte()?);
            samples.get(pick % samples.len().max(1)).cloned().unwrap_or(Value::Null)
        }
        _ => serde_json::from_str(&input.text()?).unwrap_or(Value::Null),
    })
}

fn target(input: &mut Bytes<'_>, schema: &Schema) -> Option<Target> {
    let selector = input.byte()?;
    let row = input.row(schema)?;
    Some(match selector % 4 {
        0 | 1 => Target::Key(row.key.clone()),
        2 => Target::Path(row.path.clone()),
        _ => Target::Key(input.text()?),
    })
}

fn meta(input: &mut Bytes<'_>, revision: u64) -> Option<WriteMeta> {
    let flags = input.byte()?;
    let origin = ORIGINS[usize::from(flags % 8) % ORIGINS.len()];
    let idempotency_key =
        (flags & 0x10 != 0).then(|| format!("k{}", input.byte().unwrap_or(0) % 8));
    let if_revision = (flags & 0x20 != 0).then(|| match flags & 0x40 {
        0 => revision,
        _ => revision.wrapping_add(1),
    });
    Some(WriteMeta { origin, idempotency_key, if_revision })
}

fn map(input: &mut Bytes<'_>, schema: &Schema) -> Option<BTreeMap<String, Value>> {
    let mut values = BTreeMap::new();
    for _ in 0..input.byte()? % 4 {
        let key = match input.byte()? & 1 {
            0 => input.row(schema)?.key.clone(),
            _ => input.text()?,
        };
        values.insert(key, value(input, schema)?);
    }
    Some(values)
}

/// The op `selector % 8` names: 0, 1 and 6 set, 2 reset, 3 reset all,
/// 4 domains, 5 team policy (7, a reload, is read by the caller).
fn op(selector: u8, input: &mut Bytes<'_>, state: &State) -> Option<Op> {
    let schema = state.schema();
    Some(match selector % 8 {
        0 | 1 | 6 => Op::Set {
            target: target(input, schema)?,
            value: value(input, schema)?,
            meta: meta(input, state.revision())?,
        },
        2 => Op::Reset { target: target(input, schema)?, meta: meta(input, state.revision())? },
        3 => Op::ResetAll { meta: meta(input, state.revision())? },
        4 => {
            let names = |input: &mut Bytes<'_>| -> Option<Vec<String>> {
                (0..input.byte()? % 3).map(|_| input.text()).collect()
            };
            Op::DomainsPublish {
                themes: names(input)?,
                font_families: names(input)?,
                sounds: names(input)?,
            }
        }
        _ => Op::TeamPolicySet {
            layer: TeamPolicyLayer {
                team_name: input.text()?,
                defaults: map(input, schema)?,
                enforced: map(input, schema)?,
                team_id: format!("team{}", input.byte()? % 2),
                version: i64::from(input.byte()? as i8),
            },
        },
    })
}

fn check_write(applied: &cmux_config::store::Applied) {
    if let Some(text) = &applied.write {
        assert_eq!(applied.state.source(), text, "the state does not hold the text it wrote");
        assert!(applied.state.file_problem().is_none(), "a write left a file that does not parse");
    }
}

fuzz_target!(|data: &[u8]| {
    let mut input = Bytes(data);
    let Some(len) = input.byte() else {
        return;
    };
    let initial = String::from_utf8_lossy(input.take(usize::from(len) * 4)).into_owned();
    let schema = Schema::embedded();
    let mut state = State::new(
        schema,
        FileRead::Text(initial),
        ManagedPreferences::default(),
        TeamPolicyLayer::default(),
        Domains::default(),
        0,
    );
    while let Some(selector) = input.byte() {
        if selector % 8 == 7 {
            // The file changed on disk, or could not be read.
            let file = match input.byte() {
                Some(byte) if byte & 1 == 0 => FileRead::Text(input.text().unwrap_or_default()),
                Some(_) => FileRead::Unreadable("fuzz: unreadable".into()),
                None => break,
            };
            let managed = ManagedPreferences {
                forced: map(&mut input, schema).unwrap_or_default(),
                recommended: BTreeMap::new(),
            };
            let (next, change) = state.reload(file, managed);
            let expected = state.revision() + u64::from(change.is_some());
            assert_eq!(next.revision(), expected, "a reload moved the revision wrongly");
            state = next;
            continue;
        }
        let Some(op) = op(selector, &mut input, &state) else {
            break;
        };
        let stale = match &op {
            Op::Set { meta, .. } | Op::Reset { meta, .. } | Op::ResetAll { meta } => {
                meta.if_revision.filter(|expected| *expected != state.revision())
            }
            _ => None,
        };
        let keyed = matches!(
            &op,
            Op::Set { meta, .. } | Op::Reset { meta, .. } | Op::ResetAll { meta }
                if meta.idempotency_key.is_some()
        );
        match apply(&state, op.clone()) {
            Ok(applied) => {
                check_write(&applied);
                let next = applied.state.revision();
                assert!(next >= state.revision(), "the revision went back");
                assert!(next <= state.revision() + 1, "one op moved the revision more than once");
                assert_eq!(applied.changes.is_empty(), next == state.revision());
                if stale.is_some() {
                    assert!(applied.outcome.replayed, "a stale if_revision applied");
                }
                if keyed {
                    // The same request again is a replay of what committed.
                    let replay = apply(&applied.state, op).expect("a keyed op replays");
                    assert!(replay.outcome.replayed, "a repeated idempotency key applied again");
                    assert_eq!(replay.outcome.revision, applied.outcome.revision);
                    assert!(replay.write.is_none() && replay.changes.is_empty());
                }
                state = applied.state;
            }
            Err(Refusal::RevisionConflict { expected, actual }) => {
                assert_eq!(Some(expected), stale, "a revision conflict on a current revision");
                assert_eq!(actual, state.revision());
            }
            Err(_) => {
                assert!(stale.is_none() || keyed, "a stale if_revision was not refused first")
            }
        }
    }
});
