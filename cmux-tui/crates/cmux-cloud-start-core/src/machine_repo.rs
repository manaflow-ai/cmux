//! `cloud new-machine --repo OWNER/NAME[@REF]` (or any https git URL): the repository the new
//! machine clones into `~/work/NAME` before its bootstrap script runs (moved from the app's
//! `CloudMachineRepo`). Parsed and checked on the Mac; the machine gets `repo.json` (a record, no
//! secret) and the repo step ([`Repo::step`]) with these values in it.
//!
//! The step writes no token. On GitHub it uses the first path the machine already has: the lane
//! broker's `lane-gh-credential` when it is git's helper (lane VMs), else `cmux github credential`
//! when the machine's Cloud agent socket is there (it mints a short repo-scoped token in memory),
//! else no credential at all (public repositories). Every other helper, a stored gh login's
//! included, is reset for its git commands. A private repository with none of these ends
//! `needs_github`. A repository on another host (GitLab, Codeberg, a company server: any
//! `https://HOST/GROUP/.../NAME`) uses `cmux gitlab credential` when the person's token for that
//! host was sealed to the machine (`~/.config/cmux/git-hosts/HOST`, written by its daemon), else no
//! credential; the GitHub paths are never offered to another host, and one that does not clone
//! ends `failed`, never `needs_github`: connecting GitHub would not help it. A checkout cloned
//! through a cmux helper keeps that helper in its own config, so the agent's push works there.
//!
//! The default branch is cloned head first when the machine's cmux has `repo hold`: the step
//! clones one commit's trees with the root files and harness folders, and fills the rest in the
//! background under the repository sync barrier (`cmux repo hold`, cmux-tui
//! `cli/repo_hold.rs`), so a Claude start goes ahead at the head while every tool waits for the
//! whole tree. `repo-status.json` says how in `fill`: `background`, `done` (filled in the step
//! when the background start failed) or `none` (a whole clone, or an update).
//!
//! Prior art: #21028's `cmux vm clone` spec parser and its idempotent clone-or-fetch.

use serde::{Deserialize, Serialize};

use crate::machine_bootstrap::NEEDS_GITHUB_EXIT;

pub const GITHUB: &str = "github.com";

/// A repository a machine clones.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Repo {
    /// On GitHub, the owner; elsewhere the group path (`group/subgroup` on GitLab).
    pub owner: String,
    pub name: String,
    /// A branch, tag or commit; none keeps the remote's default branch.
    #[serde(default)]
    pub r#ref: Option<String>,
    /// The git host, lowercased: `github.com`, or the host of an https URL.
    #[serde(default = "github")]
    pub host: String,
}

fn github() -> String {
    GITHUB.to_owned()
}

/// Why a spec names no repository.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Invalid {
    /// Not a GitHub repository or an https git URL in one of the accepted forms.
    Unrecognized,
    /// A token or password in the URL: it would land in the machine's git config.
    #[serde(rename = "credentialsInURL")]
    CredentialsInUrl,
    InvalidRef,
}

impl Repo {
    pub fn new(owner: &str, name: &str) -> Self {
        Self { owner: owner.into(), name: name.into(), r#ref: None, host: github() }
    }

    pub fn is_github(&self) -> bool {
        self.host == GITHUB
    }

    pub fn url(&self) -> String {
        format!("https://{}/{}/{}.git", self.host, self.owner, self.name)
    }

    /// Relative to the machine user's home.
    pub fn directory(&self) -> String {
        format!("work/{}", self.name)
    }

    /// `OWNER/NAME` (the group path on another host), for a person reading why it failed.
    pub fn display(&self) -> String {
        format!("{}/{}", self.owner, self.name)
    }

    /// The spec that parses back to this repository.
    pub fn spec(&self) -> String {
        let base = if self.is_github() {
            self.display()
        } else {
            format!("https://{}/{}/{}", self.host, self.owner, self.name)
        };
        match &self.r#ref {
            Some(r) => format!("{base}@{r}"),
            None => base,
        }
    }

    /// `repo.json`: what the machine was asked to clone, for a person or a tool reading the
    /// machine. Sorted keys, and `/` written `\/`, byte for byte as the app always wrote it.
    pub fn record(&self) -> String {
        let mut object = serde_json::Map::new();
        object.insert("dir".into(), format!("~/{}", self.directory()).into());
        if !self.is_github() {
            object.insert("host".into(), self.host.clone().into());
        }
        object.insert("name".into(), self.name.clone().into());
        object.insert("owner".into(), self.owner.clone().into());
        if let Some(r) = &self.r#ref {
            object.insert("ref".into(), r.clone().into());
        }
        object.insert("url".into(), self.url().into());
        serde_json::Value::Object(object).to_string().replace('/', "\\/")
    }

    /// The repo step (`~/.cmux/bootstrap/repo`). Every value in it passed [`parse`]'s checks, so
    /// none needs quoting. It writes `repo-status.json` beside itself, which the runner puts in
    /// `status.json` as `repo`. Each path the machine has is tried in order, and every git command
    /// of the step (a checkout of a blobless clone fetches too) runs with the other helpers,
    /// askpass and prompts off.
    pub fn step(&self) -> String {
        let step = STEP.strip_suffix('\n').unwrap_or(STEP);
        step.replace("@URL@", &self.url())
            .replace("@REF@", self.r#ref.as_deref().unwrap_or(""))
            .replace("@DIRECTORY@", &self.directory())
            .replace("@GITHUB@", if self.is_github() { "1" } else { "0" })
            .replace("@HOST@", &self.host)
            .replace("@NEEDS_GITHUB_EXIT@", &NEEDS_GITHUB_EXIT.to_string())
    }
}

const STEP: &str = include_str!("machine_repo/step.sh");

/// Characters a URL may hold (RFC 3986's unreserved, reserved and `%`): any other one makes the
/// spec no URL at all.
fn is_url_character(c: char) -> bool {
    c.is_ascii_alphanumeric() || "-._~:/?#[]@!$&'()*+,;=%".contains(c)
}

/// `%XX` decoded; none when an escape is broken or the bytes are not UTF-8.
fn percent_decoded(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while let Some(&byte) = bytes.get(at) {
        if byte == b'%' {
            let hex = text.get(at.saturating_add(1)..at.saturating_add(3))?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            at = at.saturating_add(3);
        } else {
            out.push(byte);
            at = at.saturating_add(1);
        }
    }
    String::from_utf8(out).ok()
}

/// An absolute URL's parts, as the app's `URLComponents` read them.
struct Url {
    scheme: String,
    user: Option<String>,
    password: Option<String>,
    host: String,
    port: bool,
    path: String,
    query: bool,
    fragment: bool,
}

fn split_url(text: &str) -> Option<Url> {
    if !text.chars().all(is_url_character) {
        return None;
    }
    let (scheme, rest) = text.split_once("://")?;
    let (rest, fragment) = match rest.split_once('#') {
        Some((rest, _)) => (rest, true),
        None => (rest, false),
    };
    let (rest, query) = match rest.split_once('?') {
        Some((rest, _)) => (rest, true),
        None => (rest, false),
    };
    let (authority, path) = match rest.find('/') {
        Some(at) => rest.split_at(at),
        None => (rest, ""),
    };
    let (login, host_port) = match authority.rsplit_once('@') {
        Some((login, host)) => (Some(login), host),
        None => (None, authority),
    };
    let (user, password) = match login {
        Some(login) => match login.split_once(':') {
            Some((user, password)) => (Some(user.to_owned()), Some(password.to_owned())),
            None => (Some(login.to_owned()), None),
        },
        None => (None, None),
    };
    // The port follows the last `:` outside an IPv6 literal's brackets.
    let (host, port) = match host_port.rsplit_once(':') {
        Some((host, port)) if !port.contains(']') => {
            if !port.chars().all(|c| c.is_ascii_digit()) {
                return None;
            }
            (host, !port.is_empty())
        }
        _ => (host_port, false),
    };
    Some(Url {
        scheme: scheme.to_ascii_lowercase(),
        user: user.map(|u| percent_decoded(&u)).transpose_none()?,
        password: password.map(|p| percent_decoded(&p)).transpose_none()?,
        host: percent_decoded(host)?,
        port,
        path: percent_decoded(path)?,
        query,
        fragment,
    })
}

/// `Option<Option<T>>` as "absent, or present and decoded": none when present but not decoded.
trait TransposeNone<T> {
    fn transpose_none(self) -> Option<Option<T>>;
}

impl<T> TransposeNone<T> for Option<Option<T>> {
    fn transpose_none(self) -> Option<Option<T>> {
        match self {
            None => Some(None),
            Some(Some(value)) => Some(Some(value)),
            Some(None) => None,
        }
    }
}

fn segments(path: &str) -> Vec<String> {
    path.split('/').filter(|s| !s.is_empty()).map(str::to_owned).collect()
}

fn strip_git(name: &str) -> String {
    let lower = name.to_ascii_lowercase();
    if lower.ends_with(".git") {
        name.chars().take(name.chars().count().saturating_sub(4)).collect()
    } else {
        name.to_owned()
    }
}

/// `owner/name`, `https://github.com/owner/name[.git][/tree/BRANCH]`, `git@github.com:owner/name.git`
/// or `ssh://git@github.com/owner/name.git`, each with an optional `@REF` at the end (it wins over
/// a `/tree/BRANCH`). Any other host takes an https URL only,
/// `https://HOST/GROUP[/SUBGROUP...]/NAME[.git][/-/tree/BRANCH]` (GitLab's form), with the same
/// `@REF`.
pub fn parse(raw: &str) -> Result<Repo, Invalid> {
    let mut text = raw.trim_matches(|c: char| c.is_whitespace()).to_owned();
    let mut r#ref: Option<String> = None;
    // `@REF` is the first `@` in the path: a URL's or scp form's login comes before it.
    let path_start = match text.find("://") {
        Some(at) => {
            let after = at.saturating_add(3);
            text.get(after..).and_then(|rest| rest.find('/')).map(|p| after.saturating_add(p))
        }
        None => Some(text.find(':').unwrap_or(0)),
    };
    if let Some(start) = path_start
        && let Some(at) =
            text.get(start..).and_then(|rest| rest.find('@')).map(|p| start.saturating_add(p))
    {
        r#ref = text.get(at.saturating_add(1)..).map(str::to_owned);
        text.truncate(at);
    }
    let parts: Vec<String>;
    if text.contains("://") {
        let url = split_url(&text).ok_or(Invalid::Unrecognized)?;
        if !["https", "http", "ssh"].contains(&url.scheme.as_str()) {
            return Err(Invalid::Unrecognized);
        }
        if url.password.is_some() {
            return Err(Invalid::CredentialsInUrl);
        }
        if let Some(user) = &url.user
            && !(user == "git" && url.scheme == "ssh")
        {
            return Err(Invalid::CredentialsInUrl);
        }
        if url.port || url.query || url.fragment {
            return Err(Invalid::Unrecognized);
        }
        let host = url.host.to_ascii_lowercase();
        if host != "github.com" && host != "www.github.com" {
            if url.scheme != "https" || url.user.is_some() {
                return Err(Invalid::Unrecognized);
            }
            return other(&host, segments(&url.path), r#ref);
        }
        parts = segments(&url.path);
    } else if let Some((authority, rest)) = text.split_once(':') {
        // git's scp-like form; only GitHub's own login is not a credential.
        let lower = authority.to_lowercase();
        if !lower.ends_with("github.com") {
            return Err(Invalid::Unrecognized);
        }
        if lower != "git@github.com" {
            return Err(if authority.contains('@') {
                Invalid::CredentialsInUrl
            } else {
                Invalid::Unrecognized
            });
        }
        parts = segments(rest);
    } else {
        parts = text.split('/').map(str::to_owned).collect();
        if parts.len() != 2 {
            return Err(Invalid::Unrecognized);
        }
    }
    let (owner, name, tail) = match parts.as_slice() {
        [owner, name] => (owner, name, None),
        [owner, name, tree, tail @ ..] if tree == "tree" && !tail.is_empty() => {
            (owner, name, Some(tail))
        }
        _ => return Err(Invalid::Unrecognized),
    };
    let name = strip_git(name);
    if !is_path_component(owner) || !is_path_component(&name) {
        return Err(Invalid::Unrecognized);
    }
    if r#ref.is_none() {
        r#ref = tail.map(|t| t.join("/"));
    }
    if let Some(r) = &r#ref
        && !is_ref(r)
    {
        return Err(Invalid::InvalidRef);
    }
    Ok(Repo { owner: owner.clone(), name, r#ref, host: github() })
}

/// A repository on a host other than GitHub: every group segment and the name are path
/// components, a `/-/tree/BRANCH` tail is the ref (an `@REF` wins over it), and the host is a
/// plain DNS name.
fn other(host: &str, mut path: Vec<String>, mut r#ref: Option<String>) -> Result<Repo, Invalid> {
    if !is_host(host) {
        return Err(Invalid::Unrecognized);
    }
    if let Some(dash) = path.iter().position(|part| part == "-") {
        let tail = path.split_off(dash);
        match tail.as_slice() {
            [_, tree, rest @ ..] if tree == "tree" && !rest.is_empty() => {
                if r#ref.is_none() {
                    r#ref = Some(rest.join("/"));
                }
            }
            _ => return Err(Invalid::Unrecognized),
        }
    }
    let Some((last, groups)) = path.split_last() else { return Err(Invalid::Unrecognized) };
    if groups.is_empty() {
        return Err(Invalid::Unrecognized);
    }
    let name = strip_git(last);
    if !is_path_component(&name) || !groups.iter().all(|g| is_path_component(g)) {
        return Err(Invalid::Unrecognized);
    }
    if let Some(r) = &r#ref
        && !is_ref(r)
    {
        return Err(Invalid::InvalidRef);
    }
    Ok(Repo { owner: groups.join("/"), name, r#ref, host: host.to_owned() })
}

/// A DNS name: labels of letters, digits and `-`, at least two, none starting or ending with `-`,
/// and a top-level label with a letter in it (so never an IP address).
pub fn is_host(value: &str) -> bool {
    let labels: Vec<&str> = value.split('.').collect();
    value.chars().count() <= 253
        && labels.len() >= 2
        && labels.last().is_some_and(|l| l.chars().any(|c| c.is_ascii_alphabetic()))
        && labels.iter().all(|label| {
            !label.is_empty()
                && label.chars().count() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        })
}

/// Letters, digits, `.`, `_`, `-`; not starting with `.` or `-` (it becomes a directory).
pub fn is_path_component(value: &str) -> bool {
    !value.is_empty()
        && value.chars().count() <= 100
        && !value.starts_with('.')
        && !value.starts_with('-')
        && value.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

/// A safe subset of `git check-ref-format --branch`: letters, digits, `.`, `_`, `-`, `/`, so it
/// needs no quoting in shell or JSON. `HEAD` names no branch (leave the ref out for the default);
/// no part starts with `.` or ends with `.lock`.
pub fn is_ref(value: &str) -> bool {
    !value.is_empty()
        && value != "HEAD"
        && !value.starts_with("HEAD/")
        && value
            .split('/')
            .filter(|part| !part.is_empty())
            .all(|part| !part.starts_with('.') && !part.ends_with(".lock"))
        && value.chars().count() <= 255
        && !value.starts_with('-')
        && !value.starts_with('/')
        && !value.ends_with('/')
        && !value.ends_with('.')
        && !value.ends_with(".lock")
        && !value.contains("..")
        && !value.contains("//")
        && value.chars().all(|c| c.is_ascii_alphanumeric() || "._-/".contains(c))
}

/// Everything the app shows or sends of a repository.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Description {
    #[serde(flatten)]
    pub repo: Repo,
    pub is_git_hub: bool,
    pub url: String,
    pub directory: String,
    pub spec: String,
    pub record: String,
    pub step: String,
}

pub fn describe(repo: &Repo) -> Description {
    Description {
        repo: repo.clone(),
        is_git_hub: repo.is_github(),
        url: repo.url(),
        directory: repo.directory(),
        spec: repo.spec(),
        record: repo.record(),
        step: repo.step(),
    }
}

#[cfg(test)]
mod tests;
