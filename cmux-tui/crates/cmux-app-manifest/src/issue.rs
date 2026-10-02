use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warning,
}

/// One finding, addressed by a JSON pointer into the manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Issue {
    pub severity: Severity,
    pub path: String,
    pub code: &'static str,
    pub message: String,
}

impl Issue {
    pub fn error(path: impl Into<String>, code: &'static str, message: impl Into<String>) -> Self {
        Self { severity: Severity::Error, path: path.into(), code, message: message.into() }
    }

    pub fn warning(path: impl Into<String>, code: &'static str, message: impl Into<String>) -> Self {
        Self { severity: Severity::Warning, path: path.into(), code, message: message.into() }
    }

    /// The `cmux apps validate --json` shape: `{path, code, message}`.
    pub fn to_json(&self) -> Value {
        json!({ "path": self.path, "code": self.code, "message": self.message })
    }
}

/// JSON pointer escaping for one key.
pub(crate) fn escape(key: &str) -> String {
    key.replace('~', "~0").replace('/', "~1")
}
