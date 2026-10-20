//! A local route from the verified parent, bound to its current credential scope, never authority.
use super::RelayError;
use serde_json::Value;
use std::path::{Component, PathBuf};

/// The parent's selected-team Native hub. Absence of a socket never permits a global fallback.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NativeLink {
    Unavailable,
    Ready(PathBuf),
}

impl NativeLink {
    pub(crate) fn decode(
        value: Option<&Value>,
        scope: Option<&str>,
    ) -> Result<Option<Self>, RelayError> {
        let Some(value) = value else { return Ok(None) };
        let invalid =
            || RelayError::Unavailable("the parent's Native link binding is invalid".into());
        let object = value.as_object().ok_or_else(invalid)?;
        let scope = scope
            .filter(|s| {
                s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
            .ok_or_else(invalid)?;
        if object.len() != 3 || value["version"] != 1 || value["scope"].as_str() != Some(scope) {
            return Err(invalid());
        }
        let socket = object.get("socket").ok_or_else(invalid)?;
        if socket.is_null() {
            return Ok(Some(Self::Unavailable));
        }
        let text = socket.as_str().ok_or_else(invalid)?;
        let path = PathBuf::from(text);
        if !path.is_absolute()
            || text.len() > 103
            || text.chars().any(char::is_control)
            || path.components().any(|part| matches!(part, Component::ParentDir))
        {
            return Err(invalid());
        }
        Ok(Some(Self::Ready(path)))
    }
}
