//! Wire values the catalog's type language needs beyond plain serde.

use serde::de::{Error, Unexpected};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A catalog number that may be non-finite: the union of `float64` and the
/// strings `"Infinity"`, `"-Infinity"` and `"NaN"` (how the backend's schema
/// encodes a JSON number). A finite value goes on the wire as a number.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd, Default)]
pub struct WireNumber(pub f64);

impl Serialize for WireNumber {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let value = self.0;
        if value.is_nan() {
            serializer.serialize_str("NaN")
        } else if value == f64::INFINITY {
            serializer.serialize_str("Infinity")
        } else if value == f64::NEG_INFINITY {
            serializer.serialize_str("-Infinity")
        } else {
            serializer.serialize_f64(value)
        }
    }
}

impl<'de> Deserialize<'de> for WireNumber {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Raw {
            Number(f64),
            Text(String),
        }
        match Raw::deserialize(deserializer)? {
            Raw::Number(value) => Ok(Self(value)),
            Raw::Text(text) => match text.as_str() {
                "Infinity" => Ok(Self(f64::INFINITY)),
                "-Infinity" => Ok(Self(f64::NEG_INFINITY)),
                "NaN" => Ok(Self(f64::NAN)),
                _ => Err(D::Error::invalid_value(Unexpected::Str(&text), &"a number")),
            },
        }
    }
}

/// A boolean literal (a single-value boolean enum of the catalog): it
/// decodes only from `V`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct BoolLit<const V: bool>;

impl<const V: bool> Serialize for BoolLit<V> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_bool(V)
    }
}

impl<'de, const V: bool> Deserialize<'de> for BoolLit<V> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = bool::deserialize(deserializer)?;
        if value == V {
            Ok(Self)
        } else {
            Err(D::Error::invalid_value(Unexpected::Bool(value), &if V { "true" } else { "false" }))
        }
    }
}

/// `#[serde(with)]` for a field that is optional AND may hold `null` (or any
/// JSON value): a present field is `Some`, also when it is `null`, and an
/// absent one is `None` (with `default` and `skip_serializing_if`).
pub mod present {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<T: Serialize, S: Serializer>(
        value: &Option<T>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        match value {
            Some(value) => value.serialize(serializer),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, T: Deserialize<'de>, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Option<T>, D::Error> {
        T::deserialize(deserializer).map(Some)
    }
}
