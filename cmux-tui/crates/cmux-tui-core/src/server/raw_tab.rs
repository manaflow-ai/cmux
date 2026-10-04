//! The kind and browser fields of a raw tree tab, kept out of the tab's main
//! `json!` literal (which stays under the macro recursion limit).

use std::sync::Arc;

use serde_json::{Value, json};

use super::conversation_tabs_wire::raw_tab_kind;
use crate::state::app_screens_store::{APP_KIND, AppTabRecord};
use crate::state::conversation_tabs_store::ConversationTabRecord;
use crate::workspace_registry::FrontendBrowserRecord;
use crate::{Surface, SurfaceKind};

/// Add `kind`, `conversation`, the `browser_*` fields and `url` to `tab`;
/// an app tab (`app-screens-v1`) gets `kind: "app"` and its flat `app` and
/// `route` fields.
pub(super) fn merge_browser_fields(
    tab: &mut Value,
    surface: Option<&Arc<Surface>>,
    frontend_browser: Option<&FrontendBrowserRecord>,
    conversation: Option<&ConversationTabRecord>,
    app: Option<&AppTabRecord>,
) {
    let daemon_rendered = frontend_browser.is_none();
    let fields = json!({
        "kind": raw_tab_kind(
            surface.map(|s| s.kind().as_str()).unwrap_or("pty"),
            conversation.is_some(),
        ),
        "conversation": conversation.map(ConversationTabRecord::wire),
        "browser_source": surface.and_then(|s| s.browser_source().map(|source| source.as_str())),
        "browser_status": surface
            .filter(|_| daemon_rendered)
            .and_then(|s| s.browser_status().map(|status| status.as_str())),
        "browser_error": surface
            .filter(|_| daemon_rendered)
            .and_then(|s| s.browser_status().and_then(|status| status.error())),
        "browser_renderer": surface
            .filter(|surface| surface.kind() == SurfaceKind::Browser)
            .map(|_| if daemon_rendered { "daemon" } else { "frontend" }),
        "browser_engine": frontend_browser.map(|record| record.engine.as_str()),
        "favicon_url": frontend_browser.and_then(|record| record.favicon_url.as_deref()),
        "browser_profile_id": frontend_browser.and_then(|record| record.profile_id.as_deref()),
        "browser_owner": frontend_browser.and_then(|record| record.owner.as_deref()),
        "browser_frames_stalled": surface.and_then(|s| s.browser_frames_stalled()),
        "url": surface.and_then(|s| s.browser_url()),
    });
    if let (Some(tab), Value::Object(fields)) = (tab.as_object_mut(), fields) {
        tab.extend(fields);
        if let Some(app) = app {
            tab.insert("kind".into(), json!(APP_KIND));
            app.insert_wire(tab);
        }
    }
}
