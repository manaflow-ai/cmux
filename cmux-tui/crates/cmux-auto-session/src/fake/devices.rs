//! Which install a chat's `device:` holders belong to: the real store's `devices.ts`
//! (security review of cmux#52931, item 1).
//!
//! A laptop names its own device id, not its install id, so the store binds them per chat: the
//! first install that names a device in a chat claims it there, and another install of the
//! owner that names it later is refused `auto.wrong_device`. An install that never holds a
//! chat (a phone, a browser session) makes no holder write at all: `auto.not_a_laptop`. A
//! machine is held to its own `vm:<machine>` holder by the lease rules.

use super::store::{Caller, Store};
use crate::cloud::{AutoCloudError, CloudResult};
use crate::wire::Holder;

/// The owner's install a handle calls as.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Install {
    /// One that holds chats (the Mac app, the CLI or its daemon), by install id.
    Laptop(String),
    /// One that never holds a chat: a phone or a browser session.
    Phone,
}

fn not_a_laptop() -> AutoCloudError {
    let message = "only a laptop's cmux (the Mac app, the CLI or its daemon) holds an Auto chat; \
                   this install reads it and sends it messages";
    AutoCloudError::http(403, "auto.not_a_laptop", message)
}

impl Store {
    /// A holder write from an owner's install that holds no chat is refused before its body is
    /// read, as the real routes refuse it.
    pub fn laptop_only(&self, caller: &Caller, install: &Install) -> CloudResult<()> {
        match (caller, install) {
            (Caller::Owner, Install::Phone) => Err(not_a_laptop()),
            _ => Ok(()),
        }
    }

    /// Ok when `install` may write as `holder` in chat `id`; a first naming binds the device
    /// to it. A write to a chat that does not exist binds nothing (the route answers 404),
    /// except the PUT that makes it (`making`).
    pub fn claim(
        &mut self,
        caller: &Caller,
        install: &Install,
        id: &str,
        holder: &Holder,
        making: bool,
    ) -> CloudResult<()> {
        self.laptop_only(caller, install)?;
        let (Caller::Owner, Install::Laptop(install), Holder::Device(_)) =
            (caller, install, holder)
        else {
            return Ok(());
        };
        if !making && !self.chats.contains_key(id) {
            return Ok(());
        }
        let key = (id.to_owned(), holder.to_string());
        let bound = self.devices.entry(key).or_insert_with(|| install.clone());
        if bound == install {
            return Ok(());
        }
        let message =
            "another of your installs holds this chat as that device; write as your own device id";
        Err(AutoCloudError::http(403, "auto.wrong_device", message))
    }
}
