//! The `chief_home` area's ops: where each Chief's home lives and how it moves, one rule for every build and
//! platform. Moved from CmuxNextHomeEngine (`ChiefHome.swift`, `ChiefHome+NamedChief.swift`,
//! `ChiefHomeDirectory.swift`). The files, locks and SQLite reads stay in Swift; it hands these ops what it
//! read and does what they decide.

mod build;
pub mod home;
mod path;

use crate::ops::{OpError, parse, reply};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;

/// This area's op names (without the `chief_home.` prefix).
pub const OPS: &[&str] = &[
    "brain_home",
    "chief_root",
    "component",
    "describe",
    "has_own_home",
    "named_chief",
    "resolve",
    "session_name",
    "tab_host",
    "uses_app_acpmux",
];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DescribeRequest {
    #[serde(flatten)]
    home: home::Home,
    #[serde(default)]
    own_acpmux: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BundleRequest {
    #[serde(default, rename = "bundleID")]
    bundle_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RootRequest {
    #[serde(default)]
    environment: BTreeMap<String, String>,
    user_home: String,
}

#[derive(Deserialize)]
struct RawRequest {
    raw: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PathRequest {
    path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BrainHomeRequest {
    mux_home: String,
    #[serde(default)]
    chief: Option<String>,
}

#[derive(Deserialize)]
struct ParticipantsRequest {
    participants: Vec<home::Participant>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppAcpmuxRequest {
    #[serde(default)]
    isolated: bool,
    #[serde(default, rename = "buildID")]
    build_id: Option<String>,
    #[serde(default)]
    own_acpmux: Option<bool>,
    #[serde(default)]
    environment: BTreeMap<String, String>,
}

/// Runs `chief_home.NAME`.
pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        // ChiefHome.swift
        "resolve" => {
            let request: home::ResolveRequest = parse(request)?;
            let resolved = home::resolve(&request);
            reply(&home::describe(&resolved, home::own_acpmux(&request.environment)))
        }
        "describe" => {
            let request: DescribeRequest = parse(request)?;
            reply(&home::describe(&request.home, request.own_acpmux))
        }
        "has_own_home" => {
            let request: BundleRequest = parse(request)?;
            Ok(json!({ "ownHome": home::has_own_home(request.bundle_id.as_deref()) }))
        }
        "uses_app_acpmux" => {
            let request: AppAcpmuxRequest = parse(request)?;
            let own = request.own_acpmux.unwrap_or_else(|| home::own_acpmux(&request.environment));
            Ok(json!({
                "ownAcpmux": own,
                "usesAppAcpmux": home::uses_app_acpmux(request.isolated, request.build_id.as_deref(), own),
            }))
        }
        "chief_root" => {
            let request: RootRequest = parse(request)?;
            Ok(json!({ "root": home::chief_root(&request.environment, &request.user_home) }))
        }
        "component" => {
            let request: RawRequest = parse(request)?;
            Ok(json!({ "component": home::component(&request.raw) }))
        }
        "tab_host" => {
            let request: PathRequest = parse(request)?;
            Ok(json!({ "tabHost": home::tab_host(&request.path) }))
        }
        "session_name" => {
            let request: PathRequest = parse(request)?;
            Ok(json!({ "session": home::session_name(&request.path) }))
        }
        // ChiefHome+NamedChief.swift
        "brain_home" => {
            let request: BrainHomeRequest = parse(request)?;
            Ok(
                json!({ "brainHome": home::brain_home(&request.mux_home, request.chief.as_deref()) }),
            )
        }
        "named_chief" => {
            let request: ParticipantsRequest = parse(request)?;
            Ok(json!({ "chief": home::named_chief(&request.participants) }))
        }
        _ => Err(OpError::Unknown),
    }
}
