use cmux_json::JsonSet as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashSet;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) struct Repo {
    #[serde(rename = "fullName")]
    pub full_name: String,
    pub private: bool,
    pub source: String,
}

#[derive(Default)]
pub(crate) struct Catalog {
    pub repos: Vec<Repo>,
    pub install_url: Option<String>,
    /// Installation state is independent of whether a safe recovery URL
    /// was supplied. A missing/invalid URL must never imply connected.
    pub disconnected: bool,
}

#[derive(Clone, Debug)]
pub(crate) struct Failure(pub Value);
impl Failure {
    pub fn new(code: &str, message: &str) -> Self {
        Self(json!({"code":code,"message":message}))
    }
    pub fn needs_github(url: &str) -> Self {
        if !valid_install_url(url) {
            return install_link_required();
        }
        Self(
            json!({"code":"repo.needs_github", "message":"Connect GitHub in the card. This add will retry automatically when connected; no new message is needed.", "install_url":url}),
        )
    }
}

/// All installation-link sources share this origin check. URL parsing strips
/// some controls, so reject them before parsing rather than trusting its output.
pub(super) fn valid_install_url(value: &str) -> bool {
    value.trim() == value
        && !value.chars().any(char::is_control)
        && value.split_once("://").is_some_and(|(_, rest)| {
            !rest.split(['/', '?', '#']).next().unwrap_or_default().contains('@')
        })
        && url::Url::parse(value).is_ok_and(|url| {
            url.scheme() == "https"
                && url.host_str() == Some("github.com")
                && url.username().is_empty()
                && url.password().is_none()
                && url.port().is_none()
        })
}

pub(super) fn install_link_required() -> Failure {
    Failure::new(
        "seed.bad_request",
        "Open Add repository on your Mac to refresh the GitHub installation link, then retry.",
    )
}

pub(crate) trait Backend {
    fn sources(&self) -> Result<Vec<Repo>, Failure>;
    fn connector(&self, query: Option<&str>) -> Result<Catalog, Failure>;
    fn attached(&self, session: &str) -> Result<Vec<Value>, Failure>;
    fn clone_repo(
        &self,
        session: &str,
        repo: &str,
        reference: Option<&str>,
    ) -> Result<Value, Failure>;
    fn record(&self, session: &str, attached: &Value) -> Result<(), Failure>;
}

pub(crate) fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 100
        && name != "."
        && name != ".."
        && name.bytes().all(|c| c.is_ascii_alphanumeric() || b"-._".contains(&c))
}

pub(crate) fn valid_repo(repo: &str) -> bool {
    repo.split_once('/').is_some_and(|(owner, name)| {
        !owner.is_empty()
            && owner.len() <= 39
            && owner.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
            && valid_name(name)
    })
}

/// URLs are normalized without passing credentials, options or arbitrary hosts to git.
pub(crate) fn normalize(input: &str) -> Result<String, Failure> {
    let input = input.trim();
    let candidate = if let Some(path) = input.strip_prefix("git@github.com:") {
        path.trim_end_matches('/')
            .strip_suffix(".git")
            .unwrap_or(path.trim_end_matches('/'))
            .to_owned()
    } else if input.contains("://") {
        let url = url::Url::parse(input).map_err(|_| {
            Failure::new("seed.bad_request", "Choose a valid GitHub repository URL.")
        })?;
        if url.host_str() != Some("github.com") || !matches!(url.scheme(), "https" | "ssh") {
            return Err(Failure::new(
                "repo.not_github",
                "Use the project copy action to copy this non-GitHub repository to the machine.",
            ));
        }
        if url.password().is_some()
            || url.port().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || !(url.username().is_empty() || (url.scheme() == "ssh" && url.username() == "git"))
        {
            return Err(Failure::new(
                "seed.bad_request",
                "Choose a GitHub URL without credentials, a port, query or fragment.",
            ));
        }
        url.path()
            .trim_matches('/')
            .strip_suffix(".git")
            .unwrap_or(url.path().trim_matches('/'))
            .to_owned()
    } else {
        if input.contains('@') || input.contains(':') {
            return Err(Failure::new(
                "repo.not_github",
                "Use the project copy action for this non-GitHub remote.",
            ));
        }
        input.to_owned()
    };
    if valid_repo(&candidate) || valid_name(&candidate) {
        Ok(candidate)
    } else {
        Err(Failure::new(
            "seed.bad_request",
            "Choose a repository name or a GitHub repository URL.",
        ))
    }
}

fn matches_query(repo: &Repo, query: Option<&str>) -> bool {
    query.is_none_or(|q| repo.full_name.to_ascii_lowercase().contains(&q.to_ascii_lowercase()))
}
fn merge(repos: impl IntoIterator<Item = Repo>, query: Option<&str>) -> Vec<Repo> {
    let mut seen = HashSet::new();
    repos
        .into_iter()
        .filter(|r| {
            valid_repo(&r.full_name)
                && matches_query(r, query)
                && seen.insert(r.full_name.to_ascii_lowercase())
        })
        .collect()
}

pub(crate) fn list(backend: &impl Backend, query: Option<&str>) -> Result<Value, Failure> {
    let sources = backend.sources()?;
    let catalog = backend.connector(query)?;
    let mut result = json!({"repos":merge(sources.into_iter().chain(catalog.repos), query)});
    if let Some(url) = catalog.install_url.filter(|url| valid_install_url(url)) {
        result.set("connect", json!({"install_url":url}));
    }
    Ok(result)
}

fn resolve(backend: &impl Backend, input: &str) -> Result<String, Failure> {
    let name = normalize(input)?;
    if valid_repo(&name) {
        return Ok(name);
    } // Public explicit repos need no credential.
    let sources = backend.sources()?;
    for source in ["local", "recent"] {
        let matches = merge(
            sources
                .iter()
                .filter(|r| {
                    r.source == source
                        && r.full_name
                            .rsplit('/')
                            .next()
                            .is_some_and(|n| n.eq_ignore_ascii_case(&name))
                })
                .cloned(),
            None,
        );
        if !matches.is_empty() {
            return choose(matches);
        }
    }
    let catalog = backend.connector(Some(&name))?;
    let matches = merge(
        catalog.repos.into_iter().filter(|r| {
            r.full_name.rsplit('/').next().is_some_and(|n| n.eq_ignore_ascii_case(&name))
        }),
        None,
    );
    if !matches.is_empty() {
        return choose(matches);
    }
    if catalog.disconnected {
        return Err(catalog
            .install_url
            .as_deref()
            .map(Failure::needs_github)
            .unwrap_or_else(install_link_required));
    }
    Err(Failure::new(
        "repo.not_found",
        "Choose another repository from Add repository, or install GitHub access for the repository's organization.",
    ))
}

fn choose(matches: Vec<Repo>) -> Result<String, Failure> {
    if let [only] = matches.as_slice() {
        return Ok(only.full_name.clone());
    }
    Err(Failure(
        json!({"code":"repo.ambiguous", "message":"Choose one of these repositories to attach it.", "choices":matches}),
    ))
}

pub(crate) fn add(backend: &impl Backend, args: &Value) -> Result<Value, Failure> {
    let session =
        args.get("session").and_then(Value::as_str).filter(|s| valid_name(s)).ok_or_else(|| {
            Failure::new("seed.bad_request", "Open a Cloud chat and retry with its chat ID.")
        })?;
    let input = args
        .get("repo")
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::new("seed.bad_request", "Choose a repository to add."))?;
    let reference = match args.get("ref") {
        None | Some(Value::Null) => None,
        Some(Value::String(r))
            if !r.is_empty()
                && r.len() <= 1024
                && !r.starts_with('-')
                && !r.chars().any(char::is_control) =>
        {
            Some(r.as_str())
        }
        _ => {
            return Err(Failure::new(
                "seed.bad_request",
                "Choose a valid branch, tag or commit and retry.",
            ));
        }
    };
    let result = (|| {
        let repo = resolve(backend, input)?;
        if let Some(existing) = backend.attached(session)?.into_iter().find(|r| {
            r.get("repo").and_then(Value::as_str).is_some_and(|n| n.eq_ignore_ascii_case(&repo))
        }) {
            return Ok(existing);
        }
        let attached = backend.clone_repo(session, &repo, reference).map_err(|mut failure| {
            if failure.0.get("code").and_then(Value::as_str) == Some("repo.no_access") {
                failure.0.set("org", json!(repo.split('/').next().unwrap_or_default()));
            }
            failure
        })?;
        backend.record(session, &attached)?;
        Ok(attached)
    })();
    result.map_err(|mut failure: Failure| {
        if failure.0.get("code").and_then(Value::as_str) == Some("repo.needs_github") {
            let mut retry_args = json!({"session":session,"repo":input});
            if let Some(reference) = reference { retry_args.set("ref", json!(reference)); }
            failure.0.set("retry", json!({"action":"cloud.repo.add", "args":retry_args, "wait_action":"cloud.repo.wait_github"}));
        }
        if failure.0.get("code").and_then(Value::as_str) == Some("repo.no_access")
            && let Ok(name) = normalize(input)
            && let Some((org, _)) = name.split_once('/')
        {
            failure.0.set("org", json!(org));
        }
        failure
    })
}

pub(crate) fn seed_failure(value: &Value) -> Failure {
    let code = value
        .get("error_code")
        .and_then(Value::as_str)
        .or_else(|| value.get("code").and_then(Value::as_str))
        .unwrap_or("seed.clone_failed");
    if code == "seed.needs_github" || code == "repo.needs_github" {
        return Failure::needs_github(
            value.get("install_url").and_then(Value::as_str).unwrap_or(""),
        );
    }
    if code == "repo.no_access" || code == "seed.no_access" {
        let mut result = Failure::new(
            "repo.no_access",
            "Install GitHub access for this organization, or request access from its owner, then retry Add repository.",
        );
        if let Some(org) = value.get("org").and_then(Value::as_str) {
            result.0.set("org", json!(org));
        }
        if let Some(url) =
            value.get("install_url").and_then(Value::as_str).filter(|url| valid_install_url(url))
        {
            result.0.set("install_url", json!(url));
        }
        return result;
    }
    let message = match code {
        "seed.folder_not_empty" => {
            "Choose a different chat or move the existing folder, then retry Add repository."
        }
        "seed.disk_full" => "Free disk space on this Cloud machine, then retry Add repository.",
        "seed.bad_request" => {
            "Choose a valid GitHub repository and branch, then retry Add repository."
        }
        "seed.checkout_failed" => {
            "Choose an existing branch, tag or full commit SHA, then retry Add repository."
        }
        "seed.unknown_job" => "Retry Add repository to start a new clone job.",
        "seed.unavailable" => "Open a chat on a Cloud machine, then retry Add repository.",
        _ => {
            "Retry Add repository. If cloning still fails, check repository access and the machine's network."
        }
    };
    Failure::new(if code.starts_with("seed.") { code } else { "seed.clone_failed" }, message)
}
