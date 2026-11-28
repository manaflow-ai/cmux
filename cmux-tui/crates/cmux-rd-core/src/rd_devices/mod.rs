//! The Mac app's device rules, moved out of Swift (`CmuxNextMacScreen`): Set Up cmux and Start cmux runs
//! (`setup`), the device hub link's decisions (`hub`), Settings > Devices' history and relay rules
//! (`settings`), and the home page's Your Devices (`home`). Served as `rd_devices_*` ops (`ops`). Platform
//! work (the hub client, the keychain, relay checks, dates) stays in Swift; text comes back as `Words`.

pub mod home;
pub mod hub;
pub mod ops;
pub mod settings;
pub mod setup;

use serde::{Deserialize, Serialize};

/// Text for the person: the app's localization key (in `table`, else the app's own) and its English,
/// each `%@` filled from `args` in order (`String(format: L.t(key, text), args...)`, an arg localized the
/// same way), or words that are not localized (`key` None).
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Words {
    pub key: Option<String>,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub table: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<Words>,
}

impl Words {
    pub fn t(key: &str, text: &str) -> Self {
        Words { key: Some(key.to_owned()), text: text.to_owned(), table: None, args: Vec::new() }
    }

    pub fn with(key: &str, text: &str, arg: Words) -> Self {
        Words { args: vec![arg], ..Self::t(key, text) }
    }

    pub fn in_table(table: &str, key: &str, text: &str) -> Self {
        Words { table: Some(table.to_owned()), ..Self::t(key, text) }
    }

    pub fn said(text: impl Into<String>) -> Self {
        Words { key: None, text: text.into(), table: None, args: Vec::new() }
    }

    /// The English as shown (each `%@` takes the next arg's English).
    pub fn english(&self) -> String {
        let mut out = String::new();
        let mut args = self.args.iter();
        let mut rest = self.text.as_str();
        while let Some(at) = rest.find("%@") {
            out.push_str(&rest[..at]);
            match args.next() {
                Some(arg) => out.push_str(&arg.english()),
                None => out.push_str("%@"),
            }
            rest = &rest[at + 2..];
        }
        out.push_str(rest);
        out
    }
}
