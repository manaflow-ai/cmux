//! Handlers for CDP page and target events routed to a BrowserSurface:
//! frame navigation, same-document navigation, dialogs, target creation.

use super::*;

pub(super) fn handle_frame_navigated(
    browser: &BrowserSurface,
    params: serde_json::Value,
    frame_epoch: u64,
) {
    let frame = params.get("frame").unwrap_or(&params);
    if frame.get("parentId").is_some() {
        return;
    }
    if !browser.observe_navigation_frame_epoch(frame_epoch) {
        return;
    }
    if let Some(url) = frame.get("url").and_then(|v| v.as_str()).filter(|url| !url.is_empty()) {
        browser.set_url(url.to_string());
        let title = frame
            .get("name")
            .and_then(|v| v.as_str())
            .filter(|title| !title.is_empty())
            .unwrap_or(url);
        let _ = browser.set_title(title.to_string());
    }
}

pub(super) fn handle_same_document_navigated(
    browser: &BrowserSurface,
    params: &serde_json::Value,
    frame_epoch: u64,
) -> Option<String> {
    browser.observe_same_document_frame_epoch(frame_epoch);
    let url = params.get("url").and_then(|value| value.as_str())?.to_string();
    if !url.is_empty() {
        browser.set_url(url.clone());
        let _ = browser.set_title(url.clone());
    }
    Some(url)
}

pub(super) fn dialog_response(params: &serde_json::Value) -> (bool, String) {
    let kind = params.get("type").and_then(|v| v.as_str()).unwrap_or("dialog");
    let message = params.get("message").and_then(|v| v.as_str()).unwrap_or_default();
    let accept = kind == "beforeunload";
    let action = if accept { "accepted" } else { "dismissed" };
    let text = if message.is_empty() {
        format!("browser {kind} dialog {action}")
    } else {
        format!("browser {kind} dialog {action}: {message}")
    };
    (accept, text)
}

pub(super) fn handle_target_created(
    browser: &BrowserSurface,
    created: &TargetCreated,
    mux: &Weak<Mux>,
    runtime: &Weak<BrowserRuntime>,
    opener_surface: SurfaceId,
) {
    if created.target_type != "page" {
        return;
    }
    let Some(session) = browser.session.lock().unwrap().clone() else {
        if let Some(runtime) = runtime.upgrade() {
            let _ = runtime.client.close_target(&created.target_id);
        }
        return;
    };
    // cmux-browser owns popup materialization and commits its canonical tab
    // before publishing a target lease. CDP is only the rendering/input data
    // plane in provider mode, so adopting this event here would create a
    // second tab and race the browser's journal mutation.
    if session.runtime.source() == BrowserSource::Provider {
        return;
    }
    if created.opener_id.as_deref() != Some(session.target_id.as_str()) {
        return;
    }
    let Some(mux) = mux.upgrade() else {
        let _ = session.runtime.client.close_target(&created.target_id);
        return;
    };
    let adopted = mux.adopt_browser_target(
        opener_surface,
        created.target_id.clone(),
        if created.url.is_empty() { "about:blank".to_string() } else { created.url.clone() },
        session.runtime.clone(),
    );
    if !matches!(adopted, Ok(true)) {
        let _ = session.runtime.client.close_target(&created.target_id);
        if let Err(error) = adopted {
            mux.emit(MuxEvent::Status(format!("browser target adoption failed: {error}")));
        }
    }
}
