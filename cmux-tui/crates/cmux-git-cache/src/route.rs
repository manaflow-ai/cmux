//! `/github.com/OWNER/REPO[.git]/<info/refs|git-upload-pack|git-receive-pack>`.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    InfoRefs,
    UploadPack,
    ReceivePack,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Route {
    pub owner: String,
    pub repo: String,
    pub action: Action,
}

fn valid(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 100
        && !s.starts_with('.')
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
}

pub fn parse(path: &str) -> Option<Route> {
    let rest = path.strip_prefix("/github.com/")?;
    let mut parts = rest.splitn(3, '/');
    let (owner, repo, tail) = (parts.next()?, parts.next()?, parts.next()?);
    let repo = repo.strip_suffix(".git").unwrap_or(repo);
    if !valid(owner) || !valid(repo) {
        return None;
    }
    let action = match tail {
        "info/refs" => Action::InfoRefs,
        "git-upload-pack" => Action::UploadPack,
        "git-receive-pack" => Action::ReceivePack,
        _ => return None,
    };
    Some(Route { owner: owner.to_owned(), repo: repo.to_owned(), action })
}

impl Route {
    /// The cache and authorization key: GitHub names are case-insensitive.
    pub fn key(&self) -> String {
        format!("{}/{}", self.owner.to_ascii_lowercase(), self.repo.to_ascii_lowercase())
    }

    /// `<base>/OWNER/REPO.git/<tail>`.
    pub fn url(&self, base: &str, tail: &str) -> String {
        format!("{}/{}/{}.git{tail}", base.trim_end_matches('/'), self.owner, self.repo)
    }
}

#[cfg(test)]
#[path = "route_tests.rs"]
mod tests;
