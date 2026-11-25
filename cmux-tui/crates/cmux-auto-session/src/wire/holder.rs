//! Who runs a chat: `device:<id>` (a laptop), `vm:<machine>` (a Cloud machine) or `parked`.

use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};

/// A chat's holder. It runs the agent; everyone else views.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub enum Holder {
    /// A laptop, by its device id.
    Device(String),
    /// A Cloud machine, by its machine id.
    Vm(String),
    /// Nobody. The next message picks a holder.
    Parked,
}

impl Holder {
    pub fn device(id: impl Into<String>) -> Holder {
        Holder::Device(id.into())
    }

    pub fn vm(machine: impl Into<String>) -> Holder {
        Holder::Vm(machine.into())
    }

    pub fn is_device(&self) -> bool {
        matches!(self, Holder::Device(_))
    }

    pub fn is_vm(&self) -> bool {
        matches!(self, Holder::Vm(_))
    }

    pub fn is_parked(&self) -> bool {
        matches!(self, Holder::Parked)
    }
}

impl fmt::Display for Holder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Holder::Device(id) => write!(f, "device:{id}"),
            Holder::Vm(machine) => write!(f, "vm:{machine}"),
            Holder::Parked => f.write_str("parked"),
        }
    }
}

/// A holder string that is none of `device:<id>`, `vm:<machine>` and `parked`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HolderParseError(pub String);

impl fmt::Display for HolderParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "not a holder (device:<id>, vm:<machine> or parked): {:?}", self.0)
    }
}

impl std::error::Error for HolderParseError {}

/// An id is one or more characters with no space or control character.
fn is_id(text: &str) -> bool {
    !text.is_empty() && !text.chars().any(|c| c.is_whitespace() || c.is_control())
}

impl FromStr for Holder {
    type Err = HolderParseError;

    fn from_str(text: &str) -> Result<Holder, HolderParseError> {
        if text == "parked" {
            return Ok(Holder::Parked);
        }
        match text.split_once(':') {
            Some(("device", id)) if is_id(id) => Ok(Holder::Device(id.to_owned())),
            Some(("vm", machine)) if is_id(machine) => Ok(Holder::Vm(machine.to_owned())),
            _ => Err(HolderParseError(text.to_owned())),
        }
    }
}

impl TryFrom<String> for Holder {
    type Error = HolderParseError;

    fn try_from(text: String) -> Result<Holder, HolderParseError> {
        text.parse()
    }
}

impl From<Holder> for String {
    fn from(holder: Holder) -> String {
        holder.to_string()
    }
}
