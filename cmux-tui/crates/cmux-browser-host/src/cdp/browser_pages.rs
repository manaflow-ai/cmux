//! Browser pages (chrome://, chrome-extension://, chrome-untrusted://,
//! devtools://) hold saved passwords, settings and extensions. The relay
//! never lets an agent open one, return to one through history, stay on one
//! after a redirect, or run script in or read a tab that shows one. A user
//! can still open them in the app; the agent only can leave them.

use super::driver::{Inner, Session};
use crate::policy::is_browser_page;
use crate::protocol::{DriverError, ErrorCode};
use serde_json::{Value, json};
use std::time::Instant;

/// Driver methods that run script in a tab or read or drive its content.
const PAGE_ACCESS: &[&str] = &[
    "frames.list",
    "frame.evaluate",
    "frame.observe",
    "frame.contentFrame",
    "frame.contentFrames",
    "frame.ownerBox",
    "input.mouse",
    "input.key",
    "input.insertText",
    "tab.screenshot",
    "tab.reload",
    "cdp",
];

fn refused(what: &str, url: &str) -> DriverError {
    DriverError::new(
        ErrorCode::Forbidden,
        format!("{what}: {url} is a browser page, not available to agents"),
    )
}

impl Inner {
    /// Refuses `method` before it reaches Chromium when it opens a browser
    /// page or touches a tab that shows one.
    pub(super) fn browser_page_refusal(
        &self,
        method: &str,
        params: &Value,
    ) -> Result<(), DriverError> {
        if matches!(method, "tab.navigate" | "tabs.open") {
            if let Some(url) =
                params.get("url").and_then(Value::as_str).filter(|url| is_browser_page(url))
            {
                return Err(refused(method, url));
            }
            return Ok(());
        }
        if !PAGE_ACCESS.contains(&method) {
            return Ok(());
        }
        let Some(target) = params.get("targetId").and_then(Value::as_str) else {
            return Ok(());
        };
        // The pending URL, the committed document and the addressed frame
        // must all be web pages: a pending navigation away does not unlock
        // the document that is still committed.
        let frame = params.get("frameId").and_then(Value::as_str);
        let state = self.lock();
        let Some(tab) = state.tabs.get(target) else {
            return Ok(());
        };
        let frame_url = frame.and_then(|frame| tab.frame_urls.get(frame));
        let shown = [Some(&tab.url), Some(&tab.committed_url), frame_url];
        match shown.into_iter().flatten().find(|url| is_browser_page(url)) {
            Some(url) => Err(refused(method, url)),
            None => Ok(()),
        }
    }

    /// True when the tab shows a browser page now.
    pub(super) fn shows_browser_page(&self, target_id: &str) -> bool {
        self.lock()
            .tabs
            .get(target_id)
            .is_some_and(|tab| is_browser_page(&tab.url) || is_browser_page(&tab.committed_url))
    }

    /// A navigation landed on a browser page (a redirect): go to the blank
    /// page and refuse the call that led there.
    pub(super) fn leave_browser_page(&self, session: &Session, deadline: Instant) -> DriverError {
        let url =
            self.lock().tabs.get(&session.target_id).map(|tab| tab.url.clone()).unwrap_or_default();
        let _ = self.send_until(session, "Page.navigate", json!({"url": "about:blank"}), deadline);
        let target = session.target_id.clone();
        let _ = self.wait_for(&target, deadline, "the blank page", |tab| {
            (!is_browser_page(&tab.url)).then_some(Ok(()))
        });
        refused("navigation", &url)
    }
}
