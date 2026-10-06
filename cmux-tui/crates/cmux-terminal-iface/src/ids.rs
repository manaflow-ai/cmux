//! Local ids, registry ids and the `options.kinds` rules.

use std::fmt;

use crate::error::BackendError;

/// Longest local id (the `{0,63}` of the pattern plus the first letter).
pub const MAX_LOCAL_ID: usize = 64;

/// Most kinds one implementation declares (`options.kinds.maxItems`).
const MAX_KINDS: usize = 16;

/// A local id (`options.kinds` entry), the interface schema's pattern
/// `^[a-z][a-zA-Z0-9-]{0,63}$`: at most 64 ASCII characters.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LocalId(String);

impl LocalId {
    pub fn new(value: &str) -> Result<Self, BackendError> {
        let mut chars = value.chars();
        let ok = chars.next().is_some_and(|c| c.is_ascii_lowercase())
            && chars.all(|c| c.is_ascii_alphanumeric() || c == '-')
            && value.len() <= MAX_LOCAL_ID;
        if ok {
            Ok(Self(value.to_owned()))
        } else {
            Err(BackendError::invalid(format!("{value:?} is not a local id")))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for LocalId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// A registry id: `local-pty` (built in) or `app:<app id>/<kind>`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct BackendId(String);

impl BackendId {
    /// The built-in PTY backend.
    pub const LOCAL_PTY: &'static str = "local-pty";

    pub fn app(app: &str, kind: &LocalId) -> Self {
        Self(format!("app:{app}/{kind}"))
    }

    pub fn local_pty() -> Self {
        Self(Self::LOCAL_PTY.to_owned())
    }

    /// The app id and kind of an `app:<app id>/<kind>` id (`None` for a
    /// built-in id). The app id itself contains a `/` (`cmux/cloud`).
    pub fn app_parts(&self) -> Option<(&str, &str)> {
        let rest = self.0.strip_prefix("app:")?;
        let (app, kind) = rest.rsplit_once('/')?;
        (!app.is_empty() && LocalId::new(kind).is_ok()).then_some((app, kind))
    }

    /// Parses a registry id; anything that is neither `local-pty` nor a
    /// well-formed app id is `invalid`.
    pub fn parse(value: &str) -> Result<Self, BackendError> {
        let id = Self(value.to_owned());
        if value == Self::LOCAL_PTY || id.app_parts().is_some() {
            Ok(id)
        } else {
            Err(BackendError::invalid(format!("{value:?} is not a terminal backend id")))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for BackendId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// `options.kinds`: 1 to 16 unique local ids. Anything else is refused.
pub fn check_kinds(kinds: &[LocalId]) -> Result<(), BackendError> {
    for (i, kind) in kinds.iter().enumerate() {
        if kinds[..i].contains(kind) {
            return Err(BackendError::invalid(format!("kind {kind} is declared twice")));
        }
    }
    if (1..=MAX_KINDS).contains(&kinds.len()) {
        Ok(())
    } else {
        Err(BackendError::invalid("options.kinds needs 1 to 16 kinds"))
    }
}

/// Default deny: `kind` must be one of `kinds`.
pub fn allow_kind(kinds: &[LocalId], kind: &str) -> Result<(), BackendError> {
    if kinds.iter().any(|k| k.as_str() == kind) {
        Ok(())
    } else {
        Err(BackendError::Denied { reason: format!("kind {kind:?} is not served here") })
    }
}
