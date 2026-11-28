//! A driven tab's console, its JavaScript dialogs, and the cookie backup key's Keychain answers
//! (`PageConsole.swift`, `DialogBroker.swift`, `CookieBackupKeys.swift`).
//!
//! Stays in Swift: the document-start script that wraps the console and its message handler,
//! the Observation watch of a tab's `pendingPrompts` and answering the prompt object, and the
//! Keychain calls (`SecItemCopyMatching`, `SecItemAdd`), the 32 random bytes and the DEBUG key
//! file's write. The app reads the facts, asks the op, and applies the answer.

use crate::driver::DriverParams;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

/// A driver event: its name and payload.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct DriverEvent {
    pub name: String,
    pub payload: Map<String, Value>,
}

/// The driver event for a console handler message (`PageConsole.event`): `console {type, text}`
/// or `pageerror {message, stack}` (stack defaults to the message). Anything else is None.
pub fn console_event(body: &Value) -> Option<DriverEvent> {
    let body = body.as_object()?;
    let text = |key: &str| body.get(key).and_then(Value::as_str);
    let (name, payload) = match text("kind")? {
        "console" => ("console", json!({"type": text("type")?, "text": text("text")?})),
        "pageerror" => {
            let message = text("message")?;
            ("pageerror", json!({"message": message, "stack": text("stack").unwrap_or(message)}))
        }
        _ => return None,
    };
    let Value::Object(payload) = payload else { return None };
    Some(DriverEvent { name: name.to_owned(), payload })
}

/// A browser prompt's kind (`BrowserPromptKind`). The kinds an agent never answers carry no
/// fields here: permission and HTTP credential prompts, opening another app, saving a password,
/// an email's verification code, and a page's "Leave site?".
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PromptKind {
    Alert {
        message: String,
    },
    Confirm {
        message: String,
    },
    TextInput {
        message: String,
        #[serde(default, rename = "defaultText")]
        default_text: Option<String>,
    },
    #[serde(other)]
    PersonOnly,
}

/// What `dialog.opened` says of a prompt (`DialogBroker.describe`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DialogOpened {
    #[serde(rename = "type")]
    pub kind: &'static str,
    pub message: String,
    pub default_value: String,
}

/// The `dialog.opened` description of a prompt, or None for one that stays the person's.
pub fn describe(kind: &PromptKind) -> Option<DialogOpened> {
    let (kind, message, default_value) = match kind {
        PromptKind::Alert { message } => ("alert", message, None),
        PromptKind::Confirm { message } => ("confirm", message, None),
        PromptKind::TextInput { message, default_text } => {
            ("prompt", message, default_text.as_ref())
        }
        PromptKind::PersonOnly => return None,
    };
    Some(DialogOpened {
        kind,
        message: message.clone(),
        default_value: default_value.cloned().unwrap_or_default(),
    })
}

/// The answer a prompt gets (`BrowserPromptResponse`).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PromptAnswer {
    Accept,
    Cancel,
    Text { text: String },
}

/// Why `dialog.respond` failed: `code` is the driver error code.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct DriverFailure {
    pub code: &'static str,
    pub message: String,
}

impl DriverFailure {
    fn invalid(message: String) -> Self {
        Self { code: "invalid", message }
    }
}

/// The outcome of `dialog.respond` (`DialogBroker.respond`). `held` is the open dialog the
/// broker holds under the call's `dialogId` and whether it is already resolved, or None when
/// it holds none. Swift drops the held dialog before reading `accept`, so it is gone after any
/// call that got past the id.
pub fn respond(
    params: &Value,
    held: Option<(&PromptKind, bool)>,
) -> Result<PromptAnswer, DriverFailure> {
    let params = DriverParams::new("dialog.respond", params).map_err(DriverFailure::invalid)?;
    let id = params.string("dialogId").map_err(DriverFailure::invalid)?;
    let Some((kind, false)) = held else {
        return Err(DriverFailure { code: "not_found", message: format!("Dialog {id} is gone") });
    };
    let accept = params.bool("accept", false).map_err(DriverFailure::invalid)?;
    Ok(match kind {
        PromptKind::TextInput { default_text, .. } if accept => {
            let typed = params.optional_string("promptText").map_err(DriverFailure::invalid)?;
            PromptAnswer::Text { text: typed.or_else(|| default_text.clone()).unwrap_or_default() }
        }
        _ if accept => PromptAnswer::Accept,
        _ => PromptAnswer::Cancel,
    })
}

/// `errSecSuccess`.
pub const SEC_SUCCESS: i32 = 0;
/// `errSecItemNotFound`.
pub const SEC_ITEM_NOT_FOUND: i32 = -25300;
/// `errSecDuplicateItem`.
pub const SEC_DUPLICATE_ITEM: i32 = -25299;
/// The key's length in bytes (256 bits).
pub const KEY_BYTES: usize = 32;

/// What a Keychain read of the key found (`KeychainCookieBackupKey.read`): the key, none
/// (make one), or an error text. `length` is the returned data's byte count, None when it
/// returned no data.
pub fn key_read(status: i32, length: Option<usize>) -> Result<bool, String> {
    if status == SEC_ITEM_NOT_FOUND {
        return Ok(false);
    }
    if status == SEC_SUCCESS && length == Some(KEY_BYTES) {
        return Ok(true);
    }
    Err(format!("the cookie backup key could not be read from the Keychain (status {status})"))
}

/// What to do after adding a fresh key (`KeychainCookieBackupKey.key`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum KeyAdd {
    /// Stored: use the fresh key.
    UseFresh,
    /// Another process made it first: read that one and use it.
    ReadExisting,
}

/// The next step after `SecItemAdd` answered `status`, or the error text. When the step is
/// `ReadExisting` and that read finds no key, the error is this same text.
pub fn key_add(status: i32) -> Result<KeyAdd, String> {
    match status {
        SEC_SUCCESS => Ok(KeyAdd::UseFresh),
        SEC_DUPLICATE_ITEM => Ok(KeyAdd::ReadExisting),
        _ => Err(key_store_error(status)),
    }
}

/// The error when the key could not be stored.
pub fn key_store_error(status: i32) -> String {
    format!("the cookie backup key could not be stored in the Keychain (status {status})")
}

/// Whether the DEBUG key file's contents are the key (`FileCookieBackupKey.key`): exactly 32
/// bytes. `length` is None when the file does not open; otherwise a fresh key is written.
pub fn key_file_usable(length: Option<usize>) -> bool {
    length == Some(KEY_BYTES)
}
