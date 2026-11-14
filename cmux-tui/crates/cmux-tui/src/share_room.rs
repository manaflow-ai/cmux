//! The hosted room link shares are provisioned in (cmux-platform's `ChatShareRoom`, design
//! chat-multiplayer.md 4.3). `CMUX_SHARE_ROOM_URL` in the daemon's environment wins (empty turns
//! share links off); otherwise each build uses the room of the cmux API it signs in to: DEV the
//! development room, staging and classic NIGHTLY the staging room, release and RC production, each
//! at its short share host (`share.cmux.dev`), so the links it makes read cleanly.
//! NEXT app bundles use the runtime selection before these legacy defaults;
//! an empty override still disables sharing, but a URL cannot mix environments.
//! A standalone daemon (no app bundle) has none: its share links have no URL, as before the
//! bridge. The room ships inert: until an environment enables it, its `PUT` answers 404 and
//! create answers `share.room_refused`.
//!
//! The owner token create takes (`owner_token`) must come from the same environment's cmux API
//! as the room (an install token with a `kid`): the room verifies it against that API's keys.

use cmux_agent_pane_policy::build_identity::BuildKind;
use cmux_cloud_environment::{
    DEVELOPMENT_SHARE as DEVELOPMENT, PRODUCTION_SHARE as PRODUCTION, STAGING_SHARE as STAGING,
};

pub(crate) const ENV: &str = "CMUX_SHARE_ROOM_URL";

/// The room of this daemon's build.
pub(crate) fn url() -> Option<String> {
    if std::env::var(ENV).is_ok_and(|url| url.trim().is_empty()) {
        return Some(String::new());
    }
    // An app bundle resolves the same persisted selection as the native client.
    // A corrupt selection disables sharing rather than sending its credentials
    // to a room chosen from another environment.
    match crate::cloud_environment::current() {
        Ok(Some(selection)) => {
            // A declared deployment's room is used at its short share host whichever of its origins the
            // client-config names, so links read `share.cmux.dev/g/...`; builds that predate the host keep
            // using the origin the config names.
            let origin = selection.configuration.share_room_origin;
            let host = cmux_tui_core::cloud_conversations::platform::share_host(
                origin.trim_end_matches('/'),
            );
            return Some(host.map_or(origin, str::to_owned));
        }
        Err(error) => {
            eprintln!("Cloud environment is unavailable: {error}");
            return Some(String::new());
        }
        Ok(None) => {}
    }
    // Set, even empty, it is the room: an empty one reaches the bridge as `Some("")`, which
    // refuses link creation (`Bridge::configure`), rather than falling back to no room.
    if let Ok(url) = std::env::var(ENV) {
        return Some(url.trim().to_owned());
    }
    let exe = std::env::current_exe().ok();
    let identity =
        crate::app_identity::AppIdentity::detect(|key| std::env::var(key).ok(), exe.as_deref());
    default_for(identity.map_or(BuildKind::Unbundled, |identity| identity.build().kind()))
        .map(str::to_owned)
}

/// This daemon's app's URL scheme (the one its Info.plist registers, cmux-cloud-config `callback_scheme`), which
/// the links it makes name for the guest page; nil outside an app bundle.
pub(crate) fn app_scheme() -> Option<String> {
    let exe = std::env::current_exe().ok();
    let identity =
        crate::app_identity::AppIdentity::detect(|key| std::env::var(key).ok(), exe.as_deref())?;
    Some(scheme_of(&identity, std::env::var("CMUX_AUTH_CALLBACK_SCHEME").ok().as_deref()))
}

fn scheme_of(identity: &crate::app_identity::AppIdentity, configured: Option<&str>) -> String {
    const DEBUG: &str = "com.cmuxterm.app.debug";
    let bundle = identity.bundle_id.as_deref().unwrap_or(DEBUG);
    let debug = bundle == DEBUG || bundle.starts_with("com.cmuxterm.app.debug.");
    cmux_cloud_config::config::callback_scheme(configured, bundle, identity.tag.as_deref(), debug)
}

fn default_for(kind: BuildKind) -> Option<&'static str> {
    match kind {
        BuildKind::Release | BuildKind::Rc => Some(PRODUCTION),
        BuildKind::Nightly | BuildKind::Staging => Some(STAGING),
        BuildKind::Dev => Some(DEVELOPMENT),
        BuildKind::Unbundled => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_build_kind_has_its_room() {
        assert_eq!(default_for(BuildKind::Release), Some(PRODUCTION));
        assert_eq!(default_for(BuildKind::Rc), Some(PRODUCTION));
        assert_eq!(default_for(BuildKind::Nightly), Some(STAGING));
        assert_eq!(default_for(BuildKind::Staging), Some(STAGING));
        assert_eq!(default_for(BuildKind::Dev), Some(DEVELOPMENT));
        assert_eq!(default_for(BuildKind::Unbundled), None);
    }

    #[test]
    fn each_build_names_the_scheme_it_registers() {
        use crate::app_identity::AppIdentity;
        let app = |bundle: Option<&str>, tag: Option<&str>| AppIdentity {
            bundle_id: bundle.map(str::to_owned),
            tag: tag.map(str::to_owned),
            socket_override: None,
            shipped_tag: tag.map(str::to_owned),
        };
        let cases = [
            (app(Some("com.cmuxterm.app.nightly"), None), "cmux-nightly"),
            (app(Some("com.cmuxterm.app"), None), "cmux"),
            (app(Some("com.cmuxterm.app.rc"), None), "cmux-rc"),
            (app(Some("com.cmuxterm.app.debug.next"), None), "cmux-next-dev"),
            (app(Some("com.cmuxterm.app.debug"), None), "cmux-dev"),
            (
                app(Some("com.cmuxterm.app.debug.share.links"), Some("share-links")),
                "cmux-dev-share-links",
            ),
            (app(None, Some("share-links")), "cmux-dev-share-links"),
        ];
        for (identity, scheme) in cases {
            assert_eq!(scheme_of(&identity, None), scheme, "{identity:?}");
        }
        // The bundle's own setting wins (cmux NIGHTLY's LSEnvironment), unless it cannot be a scheme.
        let nightly = app(Some("com.cmuxterm.app.nightly"), None);
        assert_eq!(scheme_of(&nightly, Some("cmux-nightly")), "cmux-nightly");
        assert_eq!(scheme_of(&nightly, Some("1 bad")), "cmux-nightly");
    }
}
