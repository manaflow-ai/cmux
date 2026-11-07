//! `cloud new-machine --repo OWNER/NAME[@REF]` (or an https git URL): the repository a new
//! machine clones. Every value here passed these checks, so the machine's `repo` step needs no
//! quoting, and a URL with a login or token in it is refused: it would land in the machine's
//! git config.

use serde::{Deserialize, Serialize};

use crate::Said;

const GITHUB: &str = "github.com";

/// A parsed repository spec.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MachineRepo {
    /// On GitHub, the owner; elsewhere the group path (`group/subgroup`).
    pub owner: String,
    pub name: String,
    /// A branch, tag or commit; none keeps the remote's default branch.
    #[serde(rename = "ref")]
    pub reference: Option<String>,
    /// The git host, lowercased.
    pub host: String,
    /// The spec in its normal form (`owner/name[@ref]`, or the https URL off GitHub).
    pub spec: String,
    /// `https://HOST/OWNER/NAME.git`.
    pub url: String,
    /// Relative to the machine user's home.
    pub directory: String,
}

fn unrecognized() -> Said {
    Said::key("repoUnrecognized")
}

fn credentials() -> Said {
    Said::key("repoCredentialsInURL")
}

fn invalid_ref() -> Said {
    Said::key("repoInvalidRef")
}

impl MachineRepo {
    fn new(owner: String, name: String, reference: Option<String>, host: String) -> Self {
        let base = if host == GITHUB {
            format!("{owner}/{name}")
        } else {
            format!("https://{host}/{owner}/{name}")
        };
        let spec = match &reference {
            Some(reference) => format!("{base}@{reference}"),
            None => base,
        };
        Self {
            url: format!("https://{host}/{owner}/{name}.git"),
            directory: format!("work/{name}"),
            spec,
            owner,
            name,
            reference,
            host,
        }
    }
}

/// `@REF` is the first `@` in the path: a URL's or the scp form's login comes before it.
fn split_ref(text: &str) -> (String, Option<String>) {
    if let Some((scheme, rest)) = text.split_once("://") {
        if let Some((authority, path)) = rest.split_once('/') {
            if let Some((path, reference)) = path.split_once('@') {
                return (format!("{scheme}://{authority}/{path}"), Some(reference.to_owned()));
            }
        }
        return (text.to_owned(), None);
    }
    if let Some((authority, path)) = text.split_once(':') {
        if let Some((path, reference)) = path.split_once('@') {
            return (format!("{authority}:{path}"), Some(reference.to_owned()));
        }
        return (text.to_owned(), None);
    }
    match text.split_once('@') {
        Some((path, reference)) => (path.to_owned(), Some(reference.to_owned())),
        None => (text.to_owned(), None),
    }
}

fn without_git(name: &str) -> &str {
    let lower = name.to_ascii_lowercase();
    if lower.ends_with(".git") {
        name.get(..name.len().saturating_sub(4)).unwrap_or(name)
    } else {
        name
    }
}

/// `owner/name`, `https://github.com/owner/name[.git][/tree/BRANCH]`, `git@github.com:owner/name.git`
/// or `ssh://git@github.com/owner/name.git`, each with an optional `@REF` at the end (it wins over
/// a `/tree/BRANCH`). Any other host takes an https URL only,
/// `https://HOST/GROUP[/SUBGROUP...]/NAME[.git][/-/tree/BRANCH]`, with the same `@REF`.
pub fn parse(raw: &str) -> Result<MachineRepo, Said> {
    let (text, mut reference) = split_ref(raw.trim());
    let segments: Vec<&str> = if let Some((scheme, rest)) = text.split_once("://") {
        let scheme = scheme.to_ascii_lowercase();
        if !["https", "http", "ssh"].contains(&scheme.as_str()) {
            return Err(unrecognized());
        }
        let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
        let (login, host) = match authority.rsplit_once('@') {
            Some((login, host)) => (Some(login), host),
            None => (None, authority),
        };
        if let Some(login) = login {
            let (user, password) = match login.split_once(':') {
                Some((user, password)) => (user, Some(password)),
                None => (login, None),
            };
            if password.is_some() || !(user == "git" && scheme == "ssh") {
                return Err(credentials());
            }
        }
        if host.is_empty() || host.contains([':', '?', '#']) || path.contains(['?', '#']) {
            return Err(unrecognized());
        }
        let host = host.to_ascii_lowercase();
        let segments = path.split('/').filter(|part| !part.is_empty()).collect();
        if host != GITHUB && host != "www.github.com" {
            if scheme != "https" || login.is_some() {
                return Err(unrecognized());
            }
            return other(host, segments, reference);
        }
        segments
    } else if let Some((authority, path)) = text.split_once(':') {
        // git's scp-like form; only GitHub's own login is not a credential.
        let lower = authority.to_ascii_lowercase();
        if !lower.ends_with(GITHUB) {
            return Err(unrecognized());
        }
        if lower != "git@github.com" {
            return Err(if authority.contains('@') { credentials() } else { unrecognized() });
        }
        path.split('/').filter(|part| !part.is_empty()).collect()
    } else {
        let segments: Vec<&str> = text.split('/').collect();
        if segments.len() != 2 {
            return Err(unrecognized());
        }
        segments
    };
    let (owner, name, tail) = match segments.as_slice() {
        [owner, name] => (*owner, *name, None),
        [owner, name, "tree", tail @ ..] if !tail.is_empty() => (*owner, *name, Some(tail)),
        _ => return Err(unrecognized()),
    };
    let name = without_git(name);
    if !is_path_component(owner) || !is_path_component(name) {
        return Err(unrecognized());
    }
    if reference.is_none() {
        reference = tail.map(|tail| tail.join("/"));
    }
    check_ref(reference.as_deref())?;
    Ok(MachineRepo::new(owner.to_owned(), name.to_owned(), reference, GITHUB.to_owned()))
}

fn check_ref(reference: Option<&str>) -> Result<(), Said> {
    match reference {
        Some(reference) if !is_ref(reference) => Err(invalid_ref()),
        _ => Ok(()),
    }
}

/// A repository on a host other than GitHub: every group segment and the name are path
/// components, a `/-/tree/BRANCH` tail is the ref (an `@REF` wins over it), and the host is a
/// plain DNS name.
fn other(host: String, path: Vec<&str>, reference: Option<String>) -> Result<MachineRepo, Said> {
    if !is_host(&host) {
        return Err(unrecognized());
    }
    let mut reference = reference;
    let mut path = path;
    if let Some(dash) = path.iter().position(|part| *part == "-") {
        let tail = path.split_off(dash);
        match tail.as_slice() {
            ["-", "tree", branch @ ..] if !branch.is_empty() => {
                if reference.is_none() {
                    reference = Some(branch.join("/"));
                }
            }
            _ => return Err(unrecognized()),
        }
    }
    let Some((last, groups)) = path.split_last() else {
        return Err(unrecognized());
    };
    let name = without_git(last);
    if groups.is_empty()
        || !is_path_component(name)
        || !groups.iter().all(|group| is_path_component(group))
    {
        return Err(unrecognized());
    }
    check_ref(reference.as_deref())?;
    Ok(MachineRepo::new(groups.join("/"), name.to_owned(), reference, host))
}

/// A DNS name: labels of letters, digits and `-`, at least two, none starting or ending with
/// `-`, and a top-level label with a letter in it (so never an IP address).
fn is_host(value: &str) -> bool {
    let labels: Vec<&str> = value.split('.').collect();
    value.len() <= 253
        && labels.len() >= 2
        && labels.last().is_some_and(|top| top.chars().any(|c| c.is_ascii_alphabetic()))
        && labels.iter().all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        })
}

/// Letters, digits, `.`, `_`, `-`; not starting with `.` or `-` (it becomes a directory).
fn is_path_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 100
        && !value.starts_with(['.', '-'])
        && value.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

/// A safe subset of `git check-ref-format --branch`: letters, digits, `.`, `_`, `-`, `/`, so it
/// needs no quoting in shell or JSON. `HEAD` names no branch; no part starts with `.` or ends
/// with `.lock`.
fn is_ref(value: &str) -> bool {
    !value.is_empty()
        && value != "HEAD"
        && !value.starts_with("HEAD/")
        && value.split('/').all(|part| !part.starts_with('.') && !part.ends_with(".lock"))
        && value.len() <= 255
        && !value.starts_with(['-', '/'])
        && !value.ends_with(['/', '.'])
        && !value.contains("..")
        && !value.contains("//")
        && value.chars().all(|c| c.is_ascii_alphanumeric() || "._-/".contains(c))
}

#[cfg(test)]
#[path = "repo/tests.rs"]
mod tests;
