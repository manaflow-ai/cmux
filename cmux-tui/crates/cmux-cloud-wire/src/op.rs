//! The [`Op`] trait every generated op marker implements, and the op error
//! code enums ([`WireError`]).

use serde::Serialize;
use serde::de::DeserializeOwned;
use std::fmt::Debug;

/// Where an op goes: reads to `/v1/read`, mutations to `/v1/ops`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WireClass {
    Read,
    Mutation,
}

impl WireClass {
    /// The catalog's `class` value.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Mutation => "mutation",
        }
    }

    /// The request path of this class (`transport.http.path`).
    pub fn http_path(self) -> &'static str {
        match self {
            Self::Read => "/v1/read",
            Self::Mutation => "/v1/ops",
        }
    }
}

/// The catalog's `idempotency` rule for an op's `idempotency_key`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WireIdempotency {
    /// A mutation: the request carries a key; a retry with the same key
    /// replays the first answer.
    Required,
    /// A read: the request carries no key.
    Forbidden,
    /// A mutation that refuses a key (it never replays, for example a
    /// one-time credential).
    None,
}

impl WireIdempotency {
    /// The catalog's `idempotency` value.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Required => "required",
            Self::Forbidden => "forbidden",
            Self::None => "none",
        }
    }
}

/// Who may call an op (the catalog's `principals`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WirePrincipal {
    /// A Stack session token (a person).
    Session,
    /// A cmux install token (a device or VM).
    Install,
}

impl WirePrincipal {
    /// The catalog's principal value.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Session => "session",
            Self::Install => "install",
        }
    }
}

/// The error codes one op declares, plus `Unknown` for a code this build
/// does not know (a newer backend may add one; it decodes, it does not fail).
/// The caller can tell a declared code from a new one with
/// [`WireError::is_declared`].
pub trait WireError: Clone + Debug + PartialEq + Sized + 'static {
    /// Every declared code, sorted as in the catalog.
    const CODES: &'static [&'static str];
    /// The wire code of this error.
    fn code(&self) -> &str;
    /// The error of a wire code; `Unknown` for a code the op does not declare.
    fn from_code(code: &str) -> Self;
    /// `false` for `Unknown`.
    fn is_declared(&self) -> bool;
}

/// One catalog op. Implemented by the generated marker types.
pub trait Op {
    /// The op name on the wire (`op`).
    const NAME: &'static str;
    const CLASS: WireClass;
    const IDEMPOTENCY: WireIdempotency;
    /// The owner that runs the op (for example `cloud:TeamDO`).
    const OWNER: &'static str;
    /// The catalog's risk class (for example `mutate-shared`).
    const RISK: &'static str;
    const PRINCIPALS: &'static [WirePrincipal];
    /// `params` of the request. `expected_revision` is not part of it: it
    /// travels in the envelope ([`crate::OpRequest`]).
    type Params: Serialize + DeserializeOwned + Debug + Clone + PartialEq;
    /// The answer's `value`.
    type Result: Serialize + DeserializeOwned + Debug + Clone + PartialEq;
    type Error: WireError;
}

/// Runs generic code for an op found by name ([`crate::visit_op`]).
pub trait OpVisitor {
    type Output;
    fn visit<O: Op>(self) -> Self::Output;
}

pub(crate) fn serialize_error<E: WireError, S: serde::Serializer>(
    error: &E,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(error.code())
}

pub(crate) fn deserialize_error<'de, E: WireError, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<E, D::Error> {
    let code = <String as serde::Deserialize>::deserialize(deserializer)?;
    Ok(E::from_code(&code))
}
