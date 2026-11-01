//! Durable chat attachments and synced Mac catalog, in the daemon's existing
//! versioned projection store. CAS avoids dropping a concurrent chat's repo.
use super::{Failure, Repo};
use crate::{Actor, Mux, WorkspaceMutation};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::path::{Component, Path};
const FRONTEND: &str = "cloud-repos";
const SUBJECT: &str = "catalog";

fn failure() -> Failure {
    Failure::new(
        "seed.clone_failed",
        "The repository record could not be saved. Retry Add repository to record the completed clone.",
    )
}
fn load(mux: &Mux) -> Result<(Value, u64), Failure> {
    match mux.get_frontend_projection(FRONTEND, "session", SUBJECT).map_err(|_| failure())? {
        Some(stored) if stored.schema_version == 1 => {
            let doc = &stored.projection;
            if !doc["local"].is_array()
                || !doc["recent"].is_array()
                || !doc["chats"].is_object()
                || !doc["jobs"].is_object()
            {
                return Err(failure());
            }
            Ok((stored.projection, stored.projection_revision))
        }
        Some(_) => Err(Failure::new(
            "seed.bad_request",
            "Use the matching machine CLI to read this version of its repository records.",
        )),
        None => Ok((json!({"local":[], "chats":{}, "recent":[], "jobs":{}}), 0)),
    }
}
fn change(mux: &Mux, apply: impl Fn(&mut Value)) -> Result<(), Failure> {
    for _ in 0..8 {
        let (mut value, revision) = load(mux)?;
        apply(&mut value);
        let mutation = WorkspaceMutation::new(
            format!("cloud-repo-{}", crate::workspace_registry::new_uuid_v4()),
            "cloud.repo",
            Actor::local_user(),
        )
        .map_err(|_| failure())?;
        match mux.put_frontend_projection(
            &mutation,
            FRONTEND,
            "session",
            SUBJECT,
            1,
            Some(revision),
            &value,
        ) {
            Ok(_) => return Ok(()),
            Err(e) if e.to_string().contains("projection revision conflict") => continue,
            Err(_) => return Err(failure()),
        }
    }
    Err(failure())
}
pub(super) fn sources(mux: &Mux) -> Result<Vec<Repo>, Failure> {
    let (doc, _) = load(mux)?;
    let mut repos: Vec<Repo> =
        serde_json::from_value(doc["local"].clone()).map_err(|_| failure())?;
    repos
        .extend(serde_json::from_value::<Vec<Repo>>(doc["recent"].clone()).map_err(|_| failure())?);
    Ok(repos)
}
pub(super) fn attached(mux: &Mux, session: &str) -> Result<Vec<Value>, Failure> {
    let (doc, _) = load(mux)?;
    Ok(doc["chats"][session].as_array().cloned().unwrap_or_default())
}
pub(super) fn sync(mux: &Mux, args: &Value) -> Result<Value, Failure> {
    if args.get("complete").is_some_and(|v| v != true) {
        return Err(Failure::new(
            "seed.bad_request",
            "Wait for the Mac's project scan to finish, then retry repository discovery.",
        ));
    }
    let mut repos: Vec<Repo> = serde_json::from_value(args["repos"].clone()).map_err(|_| {
        Failure::new("seed.bad_request", "Refresh the Mac's repository list and retry.")
    })?;
    if repos.len() > 10_000 || repos.iter().any(|r| !super::engine::valid_repo(&r.full_name)) {
        return Err(Failure::new(
            "seed.bad_request",
            "Refresh the Mac's valid GitHub repositories and retry.",
        ));
    }
    for repo in &mut repos {
        repo.source = "local".into();
    }
    let mut recent: Vec<Repo> = match args.get("recent") {
        Some(value) => serde_json::from_value(value.clone()).map_err(|_| {
            Failure::new("seed.bad_request", "Refresh the Mac's recent repositories and retry.")
        })?,
        None => Vec::new(),
    };
    if recent.len() > 10_000 || recent.iter().any(|r| !super::engine::valid_repo(&r.full_name)) {
        return Err(Failure::new(
            "seed.bad_request",
            "Refresh the Mac's valid recent GitHub repositories and retry.",
        ));
    }
    for repo in &mut recent {
        repo.source = "recent".into();
    }
    let install_url = args["install_url"].as_str().filter(|s| {
        url::Url::parse(s).is_ok_and(|u| {
            u.scheme() == "https"
                && u.host_str() == Some("github.com")
                && u.username().is_empty()
                && u.password().is_none()
        })
    });
    if args.get("install_url").is_some() && install_url.is_none() {
        return Err(Failure::new(
            "seed.bad_request",
            "Refresh the GitHub installation link on the Mac and retry.",
        ));
    }
    change(mux, |doc| {
        doc.set("local", json!(repos));
        let existing = doc["recent"].as_array().cloned().unwrap_or_default();
        doc.set("recent", json!(merge_recent(existing, recent.iter().map(|r| json!(r)))));
        if let Some(url) = install_url {
            doc.set("install_url", json!(url));
        }
    })?;
    Ok(json!({"synced":repos.len()}))
}
/// The Mac remembers a machine's completed attachment without replacing its
/// local project catalog. Only normalized attachment fields are persisted.
pub(super) fn remember(mux: &Mux, args: &Value) -> Result<Value, Failure> {
    let invalid = || {
        Failure::new(
            "seed.bad_request",
            "Refresh this Cloud chat's attached repositories, then retry remembering the repository.",
        )
    };
    let session =
        args["session"].as_str().filter(|s| super::engine::valid_name(s)).ok_or_else(invalid)?;
    let attachment = &args["attachment"];
    let repo =
        attachment["repo"].as_str().filter(|s| super::engine::valid_repo(s)).ok_or_else(invalid)?;
    let folder = attachment["folder"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 4096 && !s.chars().any(char::is_control))
        .ok_or_else(invalid)?;
    let head = attachment["head"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 64 && s.bytes().all(|c| c.is_ascii_hexdigit()))
        .ok_or_else(invalid)?;
    let name = repo.split_once('/').map(|(_, name)| name).ok_or_else(invalid)?;
    let path = Path::new(folder);
    let suffix = Path::new("chats").join(session).join(name);
    if attachment["state"] != "done"
        || !path.is_absolute()
        || !path.ends_with(suffix)
        || path.components().any(|part| matches!(part, Component::ParentDir | Component::CurDir))
    {
        return Err(invalid());
    }
    let attachment = json!({"state":"done","repo":repo,"folder":folder,"head":head});
    record(mux, session, &attachment)?;
    Ok(json!({"remembered":true}))
}

fn merge_recent(existing: Vec<Value>, incoming: impl IntoIterator<Item = Value>) -> Vec<Value> {
    let mut seen = HashSet::new();
    existing
        .into_iter()
        .chain(incoming)
        .filter_map(|mut repo| {
            let name = repo["fullName"].as_str()?;
            if !seen.insert(name.to_ascii_lowercase()) {
                return None;
            }
            repo.set("source", json!("recent"));
            Some(repo)
        })
        .take(1000)
        .collect()
}

pub(super) fn record(mux: &Mux, session: &str, repo: &Value) -> Result<(), Failure> {
    change(mux, |doc| {
        let mut attached = doc["chats"][session].as_array().cloned().unwrap_or_default();
        attached.retain(|r| {
            !r["repo"]
                .as_str()
                .zip(repo["repo"].as_str())
                .is_some_and(|(a, b)| a.eq_ignore_ascii_case(b))
        });
        attached.push(repo.clone());
        doc.set_path(&["chats", session], json!(attached));
        let mut recent = doc["recent"].as_array().cloned().unwrap_or_default();
        recent.retain(|r| {
            !r["fullName"]
                .as_str()
                .zip(repo["repo"].as_str())
                .is_some_and(|(a, b)| a.eq_ignore_ascii_case(b))
        });
        recent.insert(0, json!({"fullName":repo["repo"],"private":true,"source":"recent"}));
        recent.truncate(1000);
        doc.set("recent", json!(recent));
    })
}

pub(super) fn job(mux: &Mux, session: &str, name: &str) -> Result<Option<Value>, Failure> {
    let (doc, _) = load(mux)?;
    Ok(doc["jobs"][session][name].is_object().then(|| doc["jobs"][session][name].clone()))
}
pub(super) fn set_job(
    mux: &Mux,
    session: &str,
    name: &str,
    job: Option<&Value>,
) -> Result<(), Failure> {
    change(mux, |doc| doc.set_path(&["jobs", session, name], json!(job)))
}

pub(super) fn install_url(mux: &Mux) -> Result<Option<String>, Failure> {
    Ok(load(mux)?.0["install_url"].as_str().map(str::to_owned))
}

#[cfg(test)]
#[path = "store_tests.rs"]
mod tests;
