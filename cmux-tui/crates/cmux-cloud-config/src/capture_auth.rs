//! Lease-bound capture auth policy. The app executes only the returned platform
//! operation; this reducer owns namespaces, ordering, ownership and proofs.
use serde::{Deserialize, Serialize};

use crate::config::{LegacyStore, StorageNames};

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub phase: String,
    pub preflight: bool,
    pub lease_id: String,
    pub bundle_id: String,
    pub configured_bundle_id: Option<String>,
    pub home: String,
    pub storage: StorageNames,
    pub legacy: Option<LegacyStore>,
    pub stack_project_id: String,
    #[serde(default)]
    pub facts: Vec<Fact>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Fact {
    pub status: String,
    pub text: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Action {
    ReadMarker { path: String },
    ProbeFile { path: String },
    RemoveFile { path: String },
    WriteMarker { path: String, text: String },
    ReadKeychain { service: String, account: String, protected: bool },
    RemoveKeychain { service: String, account: String, protected: bool },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Proof {
    pub ok: bool,
    pub code: String,
    pub keychain_absent: bool,
    pub files_absent: bool,
    pub verified_absent: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    pub preflight_complete: bool,
    pub action: Option<Action>,
    pub result: Option<Proof>,
}

fn refusal(code: &str) -> Reply {
    Reply {
        preflight_complete: false,
        action: None,
        result: Some(Proof {
            ok: false,
            code: code.into(),
            keychain_absent: false,
            files_absent: false,
            verified_absent: false,
        }),
    }
}

struct Replay<'a> {
    facts: &'a [Fact],
    index: usize,
}
impl<'a> Replay<'a> {
    fn ask(&mut self, action: Action) -> Result<&'a Fact, Reply> {
        let Some(fact) = self.facts.get(self.index) else {
            return Err(Reply { preflight_complete: false, action: Some(action), result: None });
        };
        self.index += 1;
        Ok(fact)
    }
}

fn directory(home: &str, parts: &[String]) -> Option<String> {
    if !home.starts_with('/')
        || parts.is_empty()
        || parts
            .iter()
            .any(|p| p.is_empty() || p == "." || p == ".." || p.contains('/') || p.contains('\0'))
    {
        return None;
    }
    Some(format!("{}/{}", home.trim_end_matches('/'), parts.join("/")))
}

pub fn next(request: &Request) -> Reply {
    match advance(request) {
        Ok(reply) | Err(reply) => reply,
    }
}

fn advance(r: &Request) -> Result<Reply, Reply> {
    if r.lease_id.len() != 24
        || !r.lease_id.bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        return Err(refusal("invalid_lease"));
    }
    if r.bundle_id.is_empty() || r.configured_bundle_id.as_deref() != Some(&r.bundle_id) {
        return Err(refusal("bundle_mismatch"));
    }
    let cleanup = match r.phase.as_str() {
        "prepare" => false,
        "cleanup" => true,
        _ => return Err(refusal("invalid_lease")),
    };
    let current = directory(&r.home, &r.storage.credentials_subpath)
        .ok_or_else(|| refusal("invalid_lease"))?;
    let marker = format!("{current}/capture-auth-lease");
    let expected = format!("{}\n{}", r.lease_id, r.bundle_id);
    let mut replay = Replay { facts: &r.facts, index: 0 };
    if cleanup || !r.preflight {
        let fact = replay.ask(Action::ReadMarker { path: marker.clone() })?;
        if cleanup {
            if fact.status != "present" {
                return Err(refusal("ownership_missing"));
            }
            if fact.text.as_deref() != Some(&expected) {
                return Err(refusal("ownership_mismatch"));
            }
        } else if fact.status != "absent" {
            return Err(refusal("marker_present"));
        }
    }
    if r.preflight {
        return Ok(Reply { preflight_complete: true, action: None, result: None });
    }
    let mut files = vec![format!("{current}/credentials.json")];
    if let Some(legacy) = &r.legacy {
        let dir = directory(&r.home, &legacy.credentials_subpath)
            .ok_or_else(|| refusal("invalid_lease"))?;
        files.push(format!("{dir}/credentials.json"));
    }
    if !cleanup {
        for path in &files {
            if replay.ask(Action::ProbeFile { path: path.clone() })?.status != "absent" {
                return Err(refusal("file_store_present"));
            }
        }
    }
    let mut items = Vec::new();
    for service in std::iter::once(&r.storage.keychain_service)
        .chain(r.legacy.iter().map(|l| &l.keychain_service))
    {
        for account in ["cmux-auth-access-token", "cmux-auth-refresh-token"] {
            items.push((service.clone(), account.to_string(), true));
        }
    }
    for prefix in ["stack-auth-access-", "stack-auth-refresh-"] {
        items.push((String::new(), format!("{prefix}{}", r.stack_project_id), false));
    }
    for (service, account, protected) in &items {
        let read = Action::ReadKeychain {
            service: service.clone(),
            account: account.clone(),
            protected: *protected,
        };
        let fact = replay.ask(read.clone())?;
        match fact.status.as_str() {
            "absent" => continue,
            "unavailable" => return Err(refusal("keychain_store_unavailable")),
            "present" => {}
            _ => return Err(refusal("keychain_read_failed")),
        }
        if !cleanup {
            return Err(refusal("keychain_item_present"));
        }
        let remove = Action::RemoveKeychain {
            service: service.clone(),
            account: account.clone(),
            protected: *protected,
        };
        if !["ok", "absent"].contains(&replay.ask(remove)?.status.as_str()) {
            return Err(refusal("keychain_read_failed"));
        }
        if replay.ask(read)?.status != "absent" {
            return Err(refusal("keychain_read_failed"));
        }
    }
    if cleanup {
        // Recheck every namespace, including items absent before other deletions.
        for (service, account, protected) in items {
            if replay.ask(Action::ReadKeychain { service, account, protected })?.status != "absent"
            {
                return Err(refusal("keychain_item_present"));
            }
        }
        for path in &files {
            match replay.ask(Action::ProbeFile { path: path.clone() })?.status.as_str() {
                "absent" => {}
                "present" => {
                    if replay.ask(Action::RemoveFile { path: path.clone() })?.status != "ok" {
                        return Err(refusal("file_delete_failed"));
                    }
                }
                _ => return Err(refusal("file_delete_failed")),
            }
            if replay.ask(Action::ProbeFile { path: path.clone() })?.status != "absent" {
                return Err(refusal("file_delete_failed"));
            }
        }
        if replay.ask(Action::RemoveFile { path: marker.clone() })?.status != "ok" {
            return Err(refusal("marker_write_failed"));
        }
        if replay.ask(Action::ReadMarker { path: marker })?.status != "absent" {
            return Err(refusal("marker_verification_failed"));
        }
    } else {
        if replay.ask(Action::WriteMarker { path: marker.clone(), text: expected.clone() })?.status
            != "ok"
        {
            return Err(refusal("marker_write_failed"));
        }
        let fact = replay.ask(Action::ReadMarker { path: marker })?;
        if fact.status != "present" || fact.text.as_deref() != Some(&expected) {
            return Err(refusal("marker_verification_failed"));
        }
    }
    if replay.index != r.facts.len() {
        return Err(refusal("invalid_lease"));
    }
    Ok(Reply {
        preflight_complete: false,
        action: None,
        result: Some(Proof {
            ok: true,
            code: "ok".into(),
            keychain_absent: true,
            files_absent: true,
            verified_absent: true,
        }),
    })
}

#[cfg(test)]
#[path = "capture_auth_tests.rs"]
mod tests;
