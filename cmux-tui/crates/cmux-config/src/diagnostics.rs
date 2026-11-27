//! Problems the owner reports beside the effective settings (Swift
//! `SettingsDiagnostic`, the kinds the config layer produces).

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticKind {
    /// cmux.json is not valid JSONC; the last good document applies.
    UnreadableFile,
    /// A value the schema (or a policy key's type) refuses; its default applies.
    InvalidValue,
    /// The file sets a key a managed layer overrides; the file's value is ignored.
    ManagedOverride,
    /// An MDM forced value and the team's enforced value differ; MDM wins.
    ManagedConflict,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
pub struct Diagnostic {
    pub kind: DiagnosticKind,
    /// Dotted key of the offending entry ("" for the whole file).
    pub path: String,
    pub message: String,
}

impl Diagnostic {
    pub fn new(kind: DiagnosticKind, path: &str, message: &str) -> Diagnostic {
        Diagnostic { kind, path: path.to_string(), message: message.to_string() }
    }
}
