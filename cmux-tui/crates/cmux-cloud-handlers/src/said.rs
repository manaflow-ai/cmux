//! What the app says: a key into its localized strings, with the values the
//! text names, or text that is not localized (a server's words).

use serde::Serialize;

/// A refusal or a message, for the app to put in words.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Said {
    /// The app's string (`filePathRequired`), or `text` for [`Said::text`].
    pub key: &'static str,
    /// The values the text names, in order.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    /// The refusal is of a thing that is not there (`not_found`) or a bad target
    /// (`invalid_target`); else it is the action's own refusal.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<&'static str>,
}

impl Said {
    /// The app's string `key`, naming nothing.
    pub fn key(key: &'static str) -> Self {
        Self { key, args: Vec::new(), kind: None }
    }

    /// The app's string `key`, naming `args`.
    pub fn with(key: &'static str, args: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self { key, args: args.into_iter().map(Into::into).collect(), kind: None }
    }

    /// Words that are not the app's (a server's reason): said as they are.
    pub fn text(text: impl Into<String>) -> Self {
        Self::with("text", [text.into()])
    }

    /// The same, as a refusal of a thing that is not there.
    pub fn not_found(mut self) -> Self {
        self.kind = Some("not_found");
        self
    }

    /// The same, as a refusal of a bad target.
    pub fn invalid_target(mut self) -> Self {
        self.kind = Some("invalid_target");
        self
    }
}
