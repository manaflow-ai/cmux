//! Repo references: where a setup (or an extension it lists) lives.

use serde::{Deserialize, Serialize};

use crate::Error;

/// A repo reference: `[https://]HOST/OWNER/REPO[/PATH][@REF]`, also
/// `https://HOST/OWNER/REPO.git` and `https://github.com/OWNER/REPO/tree/REF/PATH`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reference {
    pub host: String,
    pub owner: String,
    pub repo: String,
    /// The folder holding the root file; empty for the repo root.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub path: String,
    /// A branch, tag or 40-hex commit; `None` is the default branch.
    #[serde(default, rename = "ref", skip_serializing_if = "Option::is_none")]
    pub git_ref: Option<String>,
}

impl Reference {
    pub fn parse(text: &str) -> Result<Reference, Error> {
        let bad = |why: &str| {
            Error::Setup(format!(
                "{text:?} is not a repo reference ({why}); use HOST/OWNER/REPO[@REF], like github.com/manaflow-ai/cmux-setup-sample"
            ))
        };
        let text = text.trim();
        let rest = text
            .strip_prefix("https://")
            .or_else(|| text.strip_prefix("http://"))
            .unwrap_or(text)
            .trim_end_matches('/');
        let (rest, mut git_ref) = match rest.rsplit_once('@') {
            Some((rest, git_ref)) => (rest, Some(git_ref.to_owned())),
            None => (rest, None),
        };
        let mut pieces: Vec<&str> = rest.split('/').collect();
        if pieces.len() < 3 {
            return Err(bad("it needs a host, an owner and a repo"));
        }
        let host = pieces.remove(0).to_ascii_lowercase();
        let owner = pieces.remove(0).to_owned();
        let repo = pieces.remove(0).trim_end_matches(".git").to_owned();
        // `github.com/OWNER/REPO/tree/REF/PATH` (a browser's address).
        if pieces.first() == Some(&"tree") && pieces.len() >= 2 && git_ref.is_none() {
            git_ref = pieces.get(1).map(|piece| (*piece).to_owned());
            pieces.drain(..2);
        }
        let path = pieces.join("/");
        if !host.contains('.')
            || !host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
        {
            return Err(bad("the host is not a domain name"));
        }
        for piece in [owner.as_str(), repo.as_str()]
            .into_iter()
            .chain(path.split('/').filter(|p| !p.is_empty()))
        {
            if !plain(piece) {
                return Err(bad("a name may hold letters, digits, '.', '-' and '_'"));
            }
        }
        if let Some(git_ref) = &git_ref
            && (git_ref.is_empty()
                || git_ref.starts_with('-')
                || git_ref.contains("..")
                || !git_ref.bytes().all(|b| b.is_ascii_alphanumeric() || b"._/-+".contains(&b)))
        {
            return Err(bad("the ref is not a branch, tag or commit"));
        }
        Ok(Reference { host, owner, repo, path, git_ref })
    }

    /// `HOST/OWNER/REPO[/PATH]`, without the ref: what a receipt is keyed by.
    pub fn key(&self) -> String {
        let mut key = format!("{}/{}/{}", self.host, self.owner, self.repo);
        if !self.path.is_empty() {
            key.push('/');
            key.push_str(&self.path);
        }
        key
    }

    /// The canonical https URL of the repo.
    pub fn repository(&self) -> String {
        format!("https://{}/{}/{}", self.host, self.owner, self.repo)
    }

    /// What `git fetch` reads.
    pub fn clone_url(&self) -> String {
        format!("{}.git", self.repository())
    }

    /// Its page on cmux.com (GitHub keeps the short form).
    pub fn page_url(&self) -> String {
        let mut url = if self.host == "github.com" {
            format!("https://cmux.com/setups/{}/{}", self.owner, self.repo)
        } else {
            format!("https://cmux.com/setups/{}/{}/{}", self.host, self.owner, self.repo)
        };
        if !self.path.is_empty() {
            url.push('/');
            url.push_str(&self.path);
        }
        url
    }

    /// The same repo at another ref.
    pub fn at(&self, git_ref: Option<&str>) -> Reference {
        Reference { git_ref: git_ref.map(str::to_owned), ..self.clone() }
    }
}

impl std::fmt::Display for Reference {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.key())?;
        if let Some(git_ref) = &self.git_ref {
            write!(f, "@{git_ref}")?;
        }
        Ok(())
    }
}

pub(super) fn plain(piece: &str) -> bool {
    !piece.is_empty()
        && piece != "."
        && piece != ".."
        && piece.len() <= 100
        && piece.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}
