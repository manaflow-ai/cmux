//! What `cmux app try <PR|branch|sha>` names, as one full commit: a full sha
//! as it is; a PR, a branch or a short sha through GitHub's public API
//! (unauthenticated, 60 reads an hour per address).

use serde_json::Value;

pub(super) const REPO: &str = "manaflow-ai/cmux";
/// Overrides `https://api.github.com` (a test server, a mirror).
pub(super) const API_ENV: &str = "CMUX_APP_TRY_GITHUB_API";
const API: &str = "https://api.github.com";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Spec {
    Commit(String),
    Pull(u64),
    Branch(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Unresolved {
    RateLimited,
    NotFound,
    Other(String),
}

/// `#123`, `123` (up to 6 digits) or a PR url is a PR; 7-40 hex digits a
/// commit; any other git-ref-shaped word a branch.
pub(super) fn classify(text: &str) -> Option<Spec> {
    let text = text.trim();
    let pull_url = format!("https://github.com/{REPO}/pull/");
    let number = text
        .strip_prefix('#')
        .or_else(|| text.strip_prefix(pull_url.as_str()).map(|rest| rest.trim_end_matches('/')));
    if let Some(number) = number {
        return number.parse::<u64>().ok().filter(|n| *n > 0).map(Spec::Pull);
    }
    if !text.is_empty() && text.len() <= 6 && text.bytes().all(|b| b.is_ascii_digit()) {
        return text.parse::<u64>().ok().filter(|n| *n > 0).map(Spec::Pull);
    }
    let lower = text.to_ascii_lowercase();
    if (7..=40).contains(&lower.len()) && lower.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Some(Spec::Commit(lower));
    }
    let shaped = !text.is_empty()
        && text.len() <= 255
        && !text.starts_with(['-', '/', '.'])
        && !text.ends_with(['/', '.'])
        && !text.contains("..")
        && !text.contains("//")
        && !text.ends_with(".lock")
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || b"._/-+".contains(&b));
    shaped.then(|| Spec::Branch(text.to_owned()))
}

/// The API path that answers `spec`'s commit; `None` for a full sha.
pub(super) fn api_path(spec: &Spec) -> Option<String> {
    match spec {
        Spec::Commit(sha) if sha.len() == 40 => None,
        Spec::Commit(sha) => Some(format!("/repos/{REPO}/commits/{sha}")),
        Spec::Pull(number) => Some(format!("/repos/{REPO}/pulls/{number}")),
        Spec::Branch(branch) => Some(format!("/repos/{REPO}/commits/{branch}")),
    }
}

/// The full commit in an API answer: a PR's `head.sha`, a commit's `sha`.
pub(super) fn commit_in(spec: &Spec, status: u16, body: &[u8]) -> Result<String, Unresolved> {
    let text = String::from_utf8_lossy(body);
    if matches!(status, 403 | 429) && text.to_ascii_lowercase().contains("rate limit") {
        return Err(Unresolved::RateLimited);
    }
    if matches!(status, 404 | 422) {
        return Err(Unresolved::NotFound);
    }
    if status != 200 {
        return Err(Unresolved::Other(format!("GitHub answered HTTP {status}")));
    }
    let value: Value = serde_json::from_slice(body)
        .map_err(|_| Unresolved::Other("GitHub's answer is not JSON".to_owned()))?;
    let sha = match spec {
        Spec::Pull(_) => value.pointer("/head/sha"),
        Spec::Commit(_) | Spec::Branch(_) => value.get("sha"),
    }
    .and_then(Value::as_str)
    .unwrap_or_default();
    if !cmux_host::updater::channel::lower_hex(sha, 40) {
        return Err(Unresolved::Other("GitHub's answer names no commit".to_owned()));
    }
    if let Spec::Commit(short) = spec
        && !sha.starts_with(short.as_str())
    {
        return Err(Unresolved::NotFound);
    }
    Ok(sha.to_owned())
}

/// `spec`'s full commit.
pub(super) fn resolve(spec: &Spec) -> Result<String, Unresolved> {
    let Some(path) = api_path(spec) else {
        return match spec {
            Spec::Commit(sha) => Ok(sha.clone()),
            Spec::Pull(_) | Spec::Branch(_) => Err(Unresolved::NotFound),
        };
    };
    let base = std::env::var(API_ENV)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| API.to_owned());
    let url = format!("{}{path}", base.trim_end_matches('/'));
    let headers = ["Accept: application/vnd.github+json", "X-GitHub-Api-Version: 2022-11-28"];
    let (status, body) =
        super::live::curl_get(&url, &headers, 4 << 20).map_err(Unresolved::Other)?;
    commit_in(spec, status, &body)
}
