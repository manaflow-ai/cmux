//! A session's domain policy on the app's WebKit tabs, as content rule
//! lists (crate::policy webkit_rules): the host sends them to the app with
//! `tab.setContentRules {targetId, session, lists}` for each WebKit tab the
//! session drives, before the session's first call on it, again when the
//! policy changes, and `lists: null` when it clears or the session ends.
//! The app installs them on the tab's web view under the session's
//! identifiers, so two sessions on one tab keep both their lists (a request
//! either list blocks does not load). An app that does not support them
//! answers `unsupported`; the session's calls then fail closed.

use crate::protocol::{DriverError, ErrorCode};
use crate::provider_link::ProviderDriver;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, PoisonError};

/// One session's lists and the WebKit tabs that hold them.
pub struct SessionRules {
    /// The rule lists with the session's identifiers.
    lists: Value,
    /// The session's name in the app's identifiers.
    label: String,
    tabs: HashSet<String>,
}

/// Sessions' content rules by subscription id.
#[derive(Default)]
pub struct ContentRules(Mutex<HashMap<u64, SessionRules>>);

/// The session's name as an identifier part (letters, digits, `-`, `_`).
fn identifier_part(label: &str) -> String {
    label
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .take(80)
        .collect()
}

/// `lists` with each identifier prefixed by the session's.
fn named(label: &str, lists: &Value) -> Value {
    let mut lists = lists.clone();
    for list in lists.as_array_mut().into_iter().flatten() {
        let layer = list["identifier"].as_str().unwrap_or("layer").to_owned();
        list["identifier"] = json!(format!("cmux-policy-{label}-{layer}"));
    }
    lists
}

fn send(
    driver: &ProviderDriver,
    label: &str,
    target_id: &str,
    lists: &Value,
) -> Result<(), DriverError> {
    crate::driver::Driver::call(
        driver,
        "tab.setContentRules",
        &json!({"targetId": target_id, "session": label, "lists": lists}),
    )
    .map(|_| ())
}

/// The refusal of a call whose tab could not take the session's rules.
fn not_applied(error: DriverError) -> DriverError {
    let why = if error.code == ErrorCode::Unsupported {
        "this app build cannot apply a domain policy to WebKit tabs".to_owned()
    } else {
        error.message
    };
    DriverError::new(
        ErrorCode::Forbidden,
        format!(
            "the domain policy could not be applied to the tab ({why}); clear the policy or use engine \"headless\""
        ),
    )
}

impl ContentRules {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<u64, SessionRules>> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Sets (or with `None` clears) a session's lists, and sends them to the
    /// tabs that hold its earlier ones. False when a tab refused them.
    pub fn set(
        &self,
        driver: &ProviderDriver,
        session: u64,
        label: &str,
        lists: Option<Value>,
    ) -> bool {
        let label = identifier_part(label);
        let (tabs, sent) = {
            let mut sessions = self.lock();
            let tabs: Vec<String> = sessions
                .get(&session)
                .map(|s| s.tabs.iter().cloned().collect())
                .unwrap_or_default();
            match &lists {
                Some(lists) => {
                    let lists = named(&label, lists);
                    let entry = sessions.entry(session).or_insert_with(|| SessionRules {
                        lists: Value::Null,
                        label: label.clone(),
                        tabs: HashSet::new(),
                    });
                    entry.lists = lists.clone();
                    (tabs, lists)
                }
                None => {
                    sessions.remove(&session);
                    (tabs, Value::Null)
                }
            }
        };
        let mut applied = true;
        for tab in tabs {
            if send(driver, &label, &tab, &sent).is_err() {
                applied = false;
                if let Some(rules) = self.lock().get_mut(&session) {
                    rules.tabs.remove(&tab);
                }
            }
        }
        applied
    }

    /// Before a session's call on a WebKit tab: the tab gets the session's
    /// lists once. A tab that cannot take them refuses the call.
    pub fn drive(
        &self,
        driver: &ProviderDriver,
        session: u64,
        target_id: &str,
    ) -> Result<(), DriverError> {
        let pending = {
            let sessions = self.lock();
            match sessions.get(&session) {
                Some(rules) if !rules.tabs.contains(target_id) => {
                    Some((rules.label.clone(), rules.lists.clone()))
                }
                _ => None,
            }
        };
        let Some((label, lists)) = pending else { return Ok(()) };
        send(driver, &label, target_id, &lists).map_err(not_applied)?;
        if let Some(rules) = self.lock().get_mut(&session) {
            rules.tabs.insert(target_id.to_owned());
        }
        Ok(())
    }

    /// The session ended: its lists leave its tabs.
    pub fn ended(&self, driver: &ProviderDriver, session: u64) {
        let Some(rules) = self.lock().remove(&session) else { return };
        for tab in rules.tabs {
            let _ = send(driver, &rules.label, &tab, &Value::Null);
        }
    }
}
