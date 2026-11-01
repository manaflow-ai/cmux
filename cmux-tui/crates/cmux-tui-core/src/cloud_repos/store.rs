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
            if !doc.get("local").is_some_and(Value::is_array)
                || !doc.get("recent").is_some_and(Value::is_array)
                || !doc.get("chats").is_some_and(Value::is_object)
                || !doc.get("jobs").is_some_and(Value::is_object)
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
        serde_json::from_value(doc.get("local").cloned().unwrap_or_default())
            .map_err(|_| failure())?;
    repos.extend(
        serde_json::from_value::<Vec<Repo>>(doc.get("recent").cloned().unwrap_or_default())
            .map_err(|_| failure())?,
    );
    Ok(repos)
}
pub(super) fn attached(mux: &Mux, session: &str) -> Result<Vec<Value>, Failure> {
    let (doc, _) = load(mux)?;
    Ok(chat_repos(&doc, session))
}
/// A chat's attached repositories; none when the record has no list for it.
fn chat_repos(doc: &Value, session: &str) -> Vec<Value> {
    doc.get("chats")
        .and_then(|chats| chats.get(session))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}
fn recent_repos(doc: &Value) -> Vec<Value> {
    doc.get("recent").and_then(Value::as_array).cloned().unwrap_or_default()
}
pub(super) fn pending(mux: &Mux, session: &str) -> Result<Vec<Value>, Failure> {
    let (doc, _) = load(mux)?;
    Ok(doc
        .get("jobs")
        .and_then(|jobs| jobs.get(session))
        .and_then(Value::as_object)
        .into_iter()
        .flat_map(|jobs| jobs.values())
        .filter(|job| job.get("state").and_then(Value::as_str) == Some("running"))
        .map(|job| {
            let mut result = json!({"repo":job.get("repo"),"state":"running"});
            for key in ["phase", "progress", "notes"] {
                if let Some(value) = job.get(key) {
                    result.set(key, value.clone());
                }
            }
            result
        })
        .collect())
}
pub(super) fn sync(mux: &Mux, args: &Value) -> Result<Value, Failure> {
    if args.get("complete").is_some_and(|v| v != true) {
        return Err(Failure::new(
            "seed.bad_request",
            "Wait for the Mac's project scan to finish, then retry repository discovery.",
        ));
    }
    let mut repos: Vec<Repo> =
        serde_json::from_value(args.get("repos").cloned().unwrap_or_default()).map_err(|_| {
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
    let install_url = args.get("install_url").and_then(Value::as_str).filter(|s| {
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
        let existing = recent_repos(doc);
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
    let session = args
        .get("session")
        .and_then(Value::as_str)
        .filter(|s| super::engine::valid_name(s))
        .ok_or_else(invalid)?;
    let attachment = args.get("attachment").unwrap_or(&Value::Null);
    let repo = attachment
        .get("repo")
        .and_then(Value::as_str)
        .filter(|s| super::engine::valid_repo(s))
        .ok_or_else(invalid)?;
    let folder = attachment
        .get("folder")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty() && s.len() <= 4096 && !s.chars().any(char::is_control))
        .ok_or_else(invalid)?;
    let head = attachment
        .get("head")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty() && s.len() <= 64 && s.bytes().all(|c| c.is_ascii_hexdigit()))
        .ok_or_else(invalid)?;
    let name = repo.split_once('/').map(|(_, name)| name).ok_or_else(invalid)?;
    let path = Path::new(folder);
    let suffix = Path::new("chats").join(session).join(name);
    if attachment.get("state").and_then(Value::as_str) != Some("done")
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
            let name = repo.get("fullName").and_then(Value::as_str)?;
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
        let name = repo.get("repo").and_then(Value::as_str);
        let mut attached = chat_repos(doc, session);
        attached.retain(|r| {
            !r.get("repo")
                .and_then(Value::as_str)
                .zip(name)
                .is_some_and(|(a, b)| a.eq_ignore_ascii_case(b))
        });
        attached.push(repo.clone());
        doc.set_path(&["chats", session], json!(attached));
        let mut recent = recent_repos(doc);
        recent.retain(|r| {
            !r.get("fullName")
                .and_then(Value::as_str)
                .zip(name)
                .is_some_and(|(a, b)| a.eq_ignore_ascii_case(b))
        });
        recent.insert(0, json!({"fullName":repo.get("repo"),"private":true,"source":"recent"}));
        recent.truncate(1000);
        doc.set("recent", json!(recent));
    })
}

pub(super) fn job(mux: &Mux, session: &str, name: &str) -> Result<Option<Value>, Failure> {
    let (doc, _) = load(mux)?;
    Ok(doc
        .get("jobs")
        .and_then(|jobs| jobs.get(session))
        .and_then(|jobs| jobs.get(name))
        .filter(|job| job.is_object())
        .cloned())
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
    Ok(load(mux)?.0.get("install_url").and_then(Value::as_str).map(str::to_owned))
}

#[cfg(test)]
#[path = "store_tests.rs"]
mod tests;
