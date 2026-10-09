//! Browser command handlers: browser provider registration, lookup and
//! unregistration, presented frames, and navigate/back/forward/reload/
//! activate. Each function is one `Command` arm of
//! `handle_command_with_cancellation`.

use super::GUARDED_BROWSER_POINTER_CAPABILITY;
use crate::browser_provider::BrowserProviderAuthentication;
use crate::browser_provider::BrowserProviderRegistration;
use crate::browser_provider::BrowserProviderSnapshot;
use crate::resource::TabPublicId;
use anyhow::Context;
use std::collections::BTreeMap;

use super::BrowserProviderTargetRequest;
use super::browser_host_command;
use super::get_surface;
use super::require_browser;
use crate::Mux;
use crate::SurfaceId;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(super) fn browser_host_provider(mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
    browser_host_command::run(mux, client)
}

pub(super) fn register_browser_provider(
    mux: &Arc<Mux>,
    client: u64,
    provider_id: String,
    endpoint: String,
    authentication: String,
    bearer_token: Option<String>,
    targets: Vec<BrowserProviderTargetRequest>,
) -> anyhow::Result<Value> {
    if !mux.control_clients.is_unix(client) {
        anyhow::bail!("browser provider registration requires a trusted local connection");
    }
    let registration = browser_provider_registration(
        provider_id,
        endpoint,
        authentication,
        bearer_token,
        targets,
    )?;
    let snapshot = mux.register_browser_provider(client, registration)?;
    Ok(browser_provider_json(Some(snapshot)))
}

pub(super) fn get_browser_provider(mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
    if !mux.control_clients.is_unix(client) {
        anyhow::bail!("browser provider discovery requires a trusted local connection");
    }
    Ok(browser_provider_json(mux.browser_provider_snapshot()))
}

pub(super) fn unregister_browser_provider(mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
    if !mux.control_clients.is_unix(client) {
        anyhow::bail!("browser provider registration requires a trusted local connection");
    }
    Ok(json!({"removed":mux.unregister_browser_provider(client)}))
}

pub(super) fn browser_frame_presented(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    frame_seq: u64,
) -> anyhow::Result<Value> {
    handle_browser_frame_presented(mux, client, surface, frame_seq)
}

pub(super) fn browser_navigate(
    mux: &Arc<Mux>,
    surface: SurfaceId,
    url: String,
) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_browser(mux, &surface)?;
    mux.navigate_browser_surface(&surface, &url)?;
    Ok(json!({}))
}

pub(super) fn browser_back(mux: &Arc<Mux>, surface: SurfaceId) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_browser(mux, &surface)?;
    surface.browser_back()?;
    Ok(json!({}))
}

pub(super) fn browser_forward(mux: &Arc<Mux>, surface: SurfaceId) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_browser(mux, &surface)?;
    surface.browser_forward()?;
    Ok(json!({}))
}

pub(super) fn browser_reload(mux: &Arc<Mux>, surface: SurfaceId) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_browser(mux, &surface)?;
    surface.browser_reload()?;
    Ok(json!({}))
}

pub(super) fn browser_activate(mux: &Arc<Mux>, surface: SurfaceId) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_browser(mux, &surface)?;
    surface.browser_activate()?;
    Ok(json!({}))
}

fn browser_provider_json(snapshot: Option<BrowserProviderSnapshot>) -> Value {
    let Some(snapshot) = snapshot else {
        return json!({"available":false,"revision":0,"targets":[]});
    };
    let targets = snapshot
        .targets
        .into_iter()
        .map(|(tab_id, target_id)| json!({"tab_id":tab_id,"target_id":target_id}))
        .collect::<Vec<_>>();
    json!({
        "available":true,
        "provider_id":snapshot.provider_id,
        "endpoint":snapshot.endpoint,
        "authentication":snapshot.authentication.name(),
        "revision":snapshot.revision,
        "clients":snapshot.clients,
        "targets":targets,
    })
}

fn handle_browser_frame_presented(
    mux: &Mux,
    client: u64,
    surface: SurfaceId,
    frame_seq: u64,
) -> anyhow::Result<Value> {
    if !mux.control_clients.supports_capability(client, GUARDED_BROWSER_POINTER_CAPABILITY) {
        anyhow::bail!(
            "browser frame presentation requires client capability \
             {GUARDED_BROWSER_POINTER_CAPABILITY}"
        );
    }
    let surface = get_surface(mux, surface)?;
    require_browser(mux, &surface)?;
    let owner = mux.control_clients.browser_pointer_owner(client)?;
    let accepted = surface.browser_acknowledge_pointer_frame_from(owner, frame_seq);
    Ok(json!({ "accepted": accepted }))
}

pub(super) fn browser_provider_registration(
    provider_id: String,
    endpoint: String,
    authentication: String,
    bearer_token: Option<String>,
    targets: Vec<BrowserProviderTargetRequest>,
) -> anyhow::Result<BrowserProviderRegistration> {
    anyhow::ensure!(
        !provider_id.is_empty()
            && provider_id.len() <= 128
            && provider_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-._:".contains(&byte)),
        "browser provider id must contain 1..128 ASCII identifier characters"
    );
    anyhow::ensure!(endpoint.len() <= 2_048, "browser provider endpoint is too long");
    let parsed = url::Url::parse(&endpoint).context("invalid browser provider endpoint")?;
    anyhow::ensure!(parsed.scheme() == "ws", "browser provider endpoint must use ws://");
    anyhow::ensure!(
        parsed.username().is_empty() && parsed.password().is_none(),
        "browser provider endpoint must not contain URL credentials"
    );
    anyhow::ensure!(parsed.port().is_some(), "browser provider endpoint must include a port");
    anyhow::ensure!(
        parsed.fragment().is_none(),
        "browser provider endpoint must not have a fragment"
    );
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("browser provider endpoint must include a host"))?;
    let loopback = host.eq_ignore_ascii_case("localhost")
        || host.parse::<std::net::IpAddr>().is_ok_and(|address| address.is_loopback());
    anyhow::ensure!(
        loopback,
        "browser provider endpoint must be loopback; use an authenticated local gateway"
    );

    let authentication = match authentication.as_str() {
        "none" => {
            anyhow::ensure!(
                bearer_token.is_none(),
                "bearer_token is only valid with bearer authentication"
            );
            BrowserProviderAuthentication::None
        }
        "bearer" => {
            let token = bearer_token
                .filter(|token| !token.is_empty())
                .ok_or_else(|| anyhow::anyhow!("bearer authentication requires bearer_token"))?;
            anyhow::ensure!(
                token.len() <= 4_096 && token.bytes().all(|byte| byte.is_ascii_graphic()),
                "browser provider bearer token must contain 1..4096 visible ASCII characters"
            );
            BrowserProviderAuthentication::Bearer(token)
        }
        other => anyhow::bail!("unsupported browser provider authentication {other:?}"),
    };

    anyhow::ensure!(targets.len() <= 16_384, "too many browser provider targets");
    let mut parsed_targets = BTreeMap::new();
    for target in targets {
        let tab_id =
            TabPublicId::parse(target.tab_id).context("invalid browser provider tab_id")?;
        anyhow::ensure!(
            !target.target_id.is_empty()
                && target.target_id.len() <= 512
                && !target.target_id.chars().any(char::is_control),
            "browser provider target_id must contain 1..512 non-control characters"
        );
        anyhow::ensure!(
            parsed_targets.insert(tab_id, target.target_id).is_none(),
            "duplicate browser provider tab_id"
        );
    }
    Ok(BrowserProviderRegistration {
        provider_id,
        endpoint: parsed.to_string(),
        authentication,
        targets: parsed_targets,
    })
}
