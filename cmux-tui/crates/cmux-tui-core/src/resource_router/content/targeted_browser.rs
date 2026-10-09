//! The targeted projection of one browser's metadata (moved out of content.rs).

use super::*;

pub(super) fn targeted_browser_effect_projection(
    registry: &WorkspaceRegistry,
    state: &State,
    browser_id: &BrowserPublicId,
    returns_browser: bool,
) -> anyhow::Result<ResourceEffectProjection> {
    let topology = registry.resource_topology_snapshot()?;
    let mut browser = topology
        .browsers
        .iter()
        .find(|candidate| &candidate.public_id == browser_id)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("browser has no durable metadata"))?;
    let mut matching_tabs = topology
        .tabs
        .iter()
        .filter(|tab| tab.content_id == ContentPublicId::Browser(browser_id.clone()));
    let mut tab = matching_tabs
        .next()
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("browser has no durable tab"))?;
    anyhow::ensure!(matching_tabs.next().is_none(), "browser has multiple durable tabs");
    let content_id = ContentPublicId::Browser(browser_id.clone());
    let surface_id = state
        .single_placement_of_content(&content_id)
        .ok_or_else(|| anyhow::anyhow!("browser must have exactly one live surface slot"))?;
    let surface = state
        .surfaces
        .get(&surface_id)
        .filter(|surface| surface.kind() == SurfaceKind::Browser)
        .ok_or_else(|| anyhow::anyhow!("browser has no live browser surface"))?;

    let url = surface.browser_url().unwrap_or_else(|| browser.url.clone());
    let source = surface.browser_source();
    let status =
        surface.browser_status().ok_or_else(|| anyhow::anyhow!("browser surface has no status"))?;
    let (cols, rows) = surface.size();
    browser.url = url.clone();
    browser.cols = cols.max(1);
    browser.rows = rows.max(1);
    if let Some(source) = source {
        browser.source = match source {
            BrowserSource::External => RegistryBrowserSource::External,
            BrowserSource::Launched => RegistryBrowserSource::Launched,
            BrowserSource::Provider => RegistryBrowserSource::External,
        };
    }
    browser.status = match &status {
        BrowserStatus::Starting => RegistryBrowserStatus::Starting,
        BrowserStatus::Live => RegistryBrowserStatus::Live,
        BrowserStatus::Failed(_) => RegistryBrowserStatus::Failed,
    };
    tab.browser_url = Some(url.clone());

    let source_name = source.map(BrowserSource::as_str).unwrap_or_else(|| match browser.source {
        RegistryBrowserSource::External => "external",
        RegistryBrowserSource::Launched => "launched",
        RegistryBrowserSource::Unknown => match browser.launch {
            RegistryBrowserLaunch::Create => "launched",
            RegistryBrowserLaunch::Adopted => "external",
        },
    });
    let status_name = status.as_str();
    let value = json!({
        "id":browser_id,
        "tab_id":tab.public_id,
        "url":url,
        "title":surface.title(),
        "loading":status_name == "starting",
        "source":source_name,
        "status":status_name,
        "error":status.error(),
        "frames_stalled":surface.browser_frames_stalled().unwrap_or(false),
        "size":{
            "cols":cols.max(1),
            "rows":rows.max(1),
        },
    });
    Ok(ResourceEffectProjection {
        patch: ResourcePatch {
            changes: vec![ResourceChange::UpsertBrowser(browser), ResourceChange::UpsertTab(tab)],
        },
        changes: upsert_change("browser", browser_id.as_str(), value.clone()),
        result: if returns_browser { value } else { json!({}) },
        restates_all: false,
    })
}

#[cfg(test)]
mod tests;
