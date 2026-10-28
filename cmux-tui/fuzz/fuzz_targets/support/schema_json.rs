//! The schema-structured JSON generator (p05-ipc-182): walks a request shape
//! of `cmux_ipc::request_shapes` and draws a value from the fuzzer's bytes,
//! the way MojoLPM turns libprotobuf-mutator messages into typed mojom calls
//! (chromium mojo/public/tools/fuzzers/mojolpm.h). Most values are what the
//! schema allows, so the fuzzer gets past the decode's member and type
//! checks; `stray` of every 256 values is any JSON instead, so it also
//! reaches the refusals.

use arbitrary::{Result, Unstructured};
use cmux_ipc::request_shapes::{Literal, RequestShapes, Shape};
use serde_json::{Map, Number, Value, json};

/// Deeper than this, an object gets only its required members and an array
/// its minimum length, so recursive shapes end.
const DEPTH: u32 = 8;
/// Past this depth a value is `null`, whatever the shape.
const MAX_DEPTH: u32 = 16;
/// Longest generated string and array, unless the schema bounds it lower.
const MAX_TEXT: usize = 64;
const MAX_ITEMS: u64 = 6;

pub struct Generator<'u, 'd> {
    pub u: &'u mut Unstructured<'d>,
    pub shapes: &'static RequestShapes,
    /// Out of 256: how often a value ignores its shape.
    pub stray: u8,
}

impl Generator<'_, '_> {
    /// A value of the shape at `index`.
    pub fn value(&mut self, index: u32, depth: u32) -> Result<Value> {
        if depth > MAX_DEPTH {
            return Ok(Value::Null);
        }
        if self.u.arbitrary::<u8>()? < self.stray {
            return self.any(depth);
        }
        let Some(shape) = self.shapes.shape(index) else {
            return self.any(depth);
        };
        Ok(match *shape {
            Shape::Any => self.any(depth)?,
            Shape::Bool => Value::Bool(self.u.arbitrary()?),
            Shape::Unsigned { min, max } => json!(self.u.int_in_range(min..=max)?),
            Shape::Signed { min, max } => json!(self.u.int_in_range(min..=max)?),
            Shape::Float => {
                Number::from_f64(self.u.arbitrary::<f64>()?).map_or(json!(0.5), Value::Number)
            }
            Shape::Text { max_bytes } => Value::String(self.text(max_bytes)?),
            Shape::Literal(Literal::Bool(value)) => Value::Bool(value),
            Shape::Literal(Literal::Int(value)) => json!(value),
            Shape::Literal(Literal::Text(value)) => Value::String(value.to_owned()),
            Shape::Enum(values) if values.is_empty() => Value::String(self.text(None)?),
            Shape::Enum(values) => Value::String((*self.u.choose(values)?).to_owned()),
            Shape::Array { items, min, max } => {
                let max = max.unwrap_or(u64::MAX).min(min.saturating_add(MAX_ITEMS)).max(min);
                let len = if depth >= DEPTH { min } else { self.u.int_in_range(min..=max)? };
                let mut array = Vec::new();
                for _ in 0..len {
                    array.push(self.value(items, depth + 1)?);
                }
                Value::Array(array)
            }
            Shape::Map { values } => {
                let mut map = Map::new();
                if depth < DEPTH {
                    for _ in 0..self.u.int_in_range(0..=3u8)? {
                        let key = self.text(None)?;
                        map.insert(key, self.value(values, depth + 1)?);
                    }
                }
                Value::Object(map)
            }
            Shape::Object { fields, open } => {
                let mut map = Map::new();
                for field in fields {
                    let present =
                        field.required || (depth < DEPTH && self.u.arbitrary::<bool>()?);
                    if !present {
                        continue;
                    }
                    let value = if field.nullable && self.u.ratio(1u8, 8u8)? {
                        Value::Null
                    } else {
                        self.value(field.shape, depth + 1)?
                    };
                    map.insert(field.name.to_owned(), value);
                }
                if open && depth < DEPTH && self.u.arbitrary::<bool>()? {
                    let key = self.text(None)?;
                    let value = self.any(depth + 1)?;
                    map.insert(key, value);
                }
                Value::Object(map)
            }
            Shape::OneOf(variants) if variants.is_empty() => self.any(depth)?,
            Shape::OneOf(variants) => {
                let variant = *self.u.choose(variants)?;
                self.value(variant, depth)?
            }
        })
    }

    /// Any JSON value, small.
    pub fn any(&mut self, depth: u32) -> Result<Value> {
        let kind = if depth >= DEPTH {
            self.u.int_in_range(0..=3u8)?
        } else {
            self.u.int_in_range(0..=5u8)?
        };
        Ok(match kind {
            0 => Value::Null,
            1 => Value::Bool(self.u.arbitrary()?),
            2 => match self.u.int_in_range(0..=2u8)? {
                0 => json!(self.u.arbitrary::<i64>()?),
                1 => json!(self.u.arbitrary::<u64>()?),
                _ => Number::from_f64(self.u.arbitrary()?).map_or(Value::Null, Value::Number),
            },
            3 => Value::String(self.text(None)?),
            4 => {
                let mut array = Vec::new();
                for _ in 0..self.u.int_in_range(0..=3u8)? {
                    array.push(self.any(depth + 1)?);
                }
                Value::Array(array)
            }
            _ => {
                let mut map = Map::new();
                for _ in 0..self.u.int_in_range(0..=3u8)? {
                    let key = self.text(None)?;
                    map.insert(key, self.any(depth + 1)?);
                }
                Value::Object(map)
            }
        })
    }

    /// A string of at most `max_bytes` UTF-8 bytes (and `MAX_TEXT` chars).
    pub fn text(&mut self, max_bytes: Option<u64>) -> Result<String> {
        let drawn: String = self.u.arbitrary()?;
        let limit = max_bytes.map_or(usize::MAX, |max| usize::try_from(max).unwrap_or(usize::MAX));
        let mut text = String::new();
        for ch in drawn.chars().take(MAX_TEXT) {
            if text.len() + ch.len_utf8() > limit {
                break;
            }
            text.push(ch);
        }
        Ok(text)
    }
}
