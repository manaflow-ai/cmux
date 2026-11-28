//! Where one build's Chief lives (CmuxNextHomeEngine `ChiefHome.swift`, `ChiefHome+NamedChief.swift`).

use super::build::{Identity, fnv1a32, key_component};
use super::path::{join, standardized};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// NIGHTLY, the one build that keeps the home every build shared before.
pub const NIGHTLY_BUNDLE_ID: &str = "com.cmuxterm.app.nightly";
/// The id of the mux Chief (`HomeChiefName.muxID`).
pub const MUX_ID: &str = "agent_mux";
/// Every Chief home's agent tab host starts with it.
pub const TAB_HOST_PREFIX: &str = "chief:";

/// A build the caller already knows (`BuildIdentity(bundleID:bundledTag:)`).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildRequest {
    #[serde(default, rename = "bundleID")]
    pub bundle_id: Option<String>,
    #[serde(default)]
    pub tag: Option<String>,
}

/// `chief_home.resolve`'s request (`ChiefHome.resolve`).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveRequest {
    #[serde(default)]
    pub tag: Option<String>,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    pub user_home: String,
    #[serde(default, rename = "bundleID")]
    pub bundle_id: Option<String>,
    /// The app's build when `bundleID` is this process's own (`BuildStatePaths.current.build`).
    #[serde(default)]
    pub app_build: Option<BuildRequest>,
    #[serde(default)]
    pub is_debug_build: bool,
}

/// A resolved home: `ChiefHome(root:isolated:buildID:)`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Home {
    pub root: String,
    #[serde(default)]
    pub isolated: bool,
    #[serde(default, rename = "buildID")]
    pub build_id: Option<String>,
}

/// A home and every path and rule `ChiefHome` derives from it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Described {
    pub root: String,
    pub isolated: bool,
    #[serde(rename = "buildID")]
    pub build_id: Option<String>,
    pub mux_home: String,
    pub daemon_state_directory: String,
    pub shutdown_marker: String,
    pub settle_status_file: String,
    pub acpmux_home: String,
    pub host_lock: String,
    pub session: String,
    pub tab_host: String,
    pub imports_old_chiefs: bool,
    pub uses_app_acpmux: bool,
}

/// `ChiefHome.hasOwnHome(bundleID:)`: every build but NIGHTLY (and no bundle) has its own home.
pub fn has_own_home(bundle_id: Option<&str>) -> bool {
    bundle_id.is_some_and(|id| !id.trim().is_empty() && id != NIGHTLY_BUNDLE_ID)
}

/// `ChiefHome.ownAcpmux(_:)`.
pub fn own_acpmux(environment: &BTreeMap<String, String>) -> bool {
    environment.get("CMUX_CHIEF_OWN_ACPMUX").map(String::as_str) == Some("1")
}

/// `ChiefHome.usesAppAcpmux(isolated:buildID:ownAcpmux:)`.
pub fn uses_app_acpmux(isolated: bool, build_id: Option<&str>, own_acpmux: bool) -> bool {
    !isolated && build_id == Some(NIGHTLY_BUNDLE_ID) && !own_acpmux
}

/// `ChiefHome.chiefRoot(environment:userHome:)`.
pub fn chief_root(environment: &BTreeMap<String, String>, user_home: &str) -> String {
    match environment.get("CMUX_NEXT_CHIEF_ROOT").filter(|value| !value.is_empty()) {
        Some(root) => standardized(root),
        None => join(user_home, ".cmux/chief"),
    }
}

/// `ChiefHome.component(of:)`.
pub fn component(raw: &str) -> Option<String> {
    key_component(raw)
}

/// `ChiefHome.tabHost(muxHome:)`: `chief:<FNV-1a 32 of the path>`.
pub fn tab_host(mux_home: &str) -> String {
    format!("{TAB_HOST_PREFIX}{:08x}", fnv1a32(mux_home.as_bytes()))
}

/// `ChiefHome.sessionName(root:)`: `cmux-chief-<FNV-1a 32 of the standardized root>`.
pub fn session_name(root: &str) -> String {
    format!("cmux-chief-{:08x}", fnv1a32(standardized(root).as_bytes()))
}

/// `ChiefHome.folderName(of:appBuild:bundleID:tag:)`.
fn folder_name(
    build: &str,
    app_build: Option<&BuildRequest>,
    bundle_id: Option<&str>,
    tag: Option<&str>,
) -> Option<String> {
    let identity = match app_build {
        Some(app) => Identity::new(app.bundle_id.as_deref(), app.tag.as_deref()),
        None => Identity::new(bundle_id, tag),
    };
    match identity.state_folder_name(Some(build)) {
        Some(folder) if folder != build => Some(folder),
        _ => component(build),
    }
}

/// `ChiefHome.resolve`: the explicit home, an isolated launch's, else the build's own (or NIGHTLY's shared one).
pub fn resolve(request: &ResolveRequest) -> Home {
    let value = |key: &str| {
        request.environment.get(key).filter(|value| !value.is_empty()).map(String::as_str)
    };
    if let Some(explicit) = value("CMUX_NEXT_CHIEF_HOME").or_else(|| value("CMUX_NEXT_MUX_HOME")) {
        return Home { root: standardized(explicit), isolated: false, build_id: None };
    }
    let root_override = value("CMUX_NEXT_CHIEF_ROOT");
    let base = chief_root(&request.environment, &request.user_home);
    let isolated_launch = value("CMUX_NEXT_CHIEF_ISOLATED") == Some("1")
        || value("CMUX_NEXT_NO_ACTIVATE") == Some("1")
        || value("CMUX_NEXT_SHOWCASE") == Some("1")
        || value("CMUX_NEXT_TEST_WINDOW_FRAME").is_some()
        || value("CMUX_NEXT_TEST_WINDOW_SCREEN").is_some();
    if isolated_launch && root_override.is_none() {
        let name = request.tag.as_deref().and_then(component).unwrap_or_else(|| "untagged".into());
        return Home {
            root: join(&base, &format!("isolated/{name}")),
            isolated: true,
            build_id: None,
        };
    }
    let account =
        value("CMUX_NEXT_CHIEF_ACCOUNT").and_then(component).unwrap_or_else(|| "default".into());
    let build = if request.is_debug_build {
        value("CMUX_NEXT_CHIEF_BUILD_ID").map(str::to_owned)
    } else {
        None
    }
    .or_else(|| request.bundle_id.clone());
    let name = build.as_deref().filter(|build| has_own_home(Some(build))).and_then(|build| {
        folder_name(
            build,
            request.app_build.as_ref(),
            request.bundle_id.as_deref(),
            request.tag.as_deref(),
        )
    });
    let Some(name) = name else {
        return Home { root: join(&base, &account), isolated: false, build_id: build };
    };
    let folder = if account == "default" { name } else { format!("{name}.{account}") };
    Home { root: join(&base, &folder), isolated: false, build_id: build }
}

/// Every path and rule of `home` (`muxHome`, `daemonStateDirectory`, `acpmuxHome`, `session`, ...).
pub fn describe(home: &Home, own_acpmux: bool) -> Described {
    let root = &home.root;
    Described {
        root: root.clone(),
        isolated: home.isolated,
        build_id: home.build_id.clone(),
        mux_home: root.clone(),
        daemon_state_directory: join(root, "tui"),
        shutdown_marker: join(root, "state/shutdown"),
        settle_status_file: join(root, "state/settle.json"),
        acpmux_home: join(root, "acpmux"),
        host_lock: join(root, "state/host.lock"),
        session: session_name(root),
        tab_host: tab_host(root),
        imports_old_chiefs: !home.isolated && home.build_id.as_deref() == Some(NIGHTLY_BUNDLE_ID),
        uses_app_acpmux: uses_app_acpmux(home.isolated, home.build_id.as_deref(), own_acpmux),
    }
}

/// `ChiefHome.brainHome(muxHome:chief:)`: a named Chief's brain lives in `c/<last 8 of its id>`.
pub fn brain_home(mux_home: &str, chief: Option<&str>) -> String {
    let Some(chief) = chief else { return mux_home.to_owned() };
    let skip = chief.chars().count().saturating_sub(8);
    let tail: String = chief.chars().skip(skip).collect();
    join(&join(mux_home, "c"), &tail.to_lowercase())
}

/// A conversation participant as `namedChief` reads it.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Participant {
    pub id: String,
    #[serde(default)]
    pub is_chief: bool,
}

/// `ChiefHome.namedChief(in:)`: the one Chief among `participants`, unless it is the mux Chief.
pub fn named_chief(participants: &[Participant]) -> Option<String> {
    let chiefs: Vec<&str> =
        participants.iter().filter(|p| p.is_chief).map(|p| p.id.as_str()).collect();
    match chiefs.as_slice() {
        [id] if *id != MUX_ID => Some((*id).to_owned()),
        _ => None,
    }
}
