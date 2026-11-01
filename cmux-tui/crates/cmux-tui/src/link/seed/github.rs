//! Which remote URLs are GitHub repositories, in the one https form the
//! machine clones.

/// A GitHub repository, `owner/name`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct GithubRepo {
    pub(super) owner: String,
    pub(super) name: String,
}

impl GithubRepo {
    /// `https://github.com/OWNER/NAME.git`.
    pub(super) fn url(&self) -> String {
        format!("https://github.com/{}/{}.git", self.owner, self.name)
    }

    /// `OWNER/NAME`.
    pub(super) fn slug(&self) -> String {
        format!("{}/{}", self.owner, self.name)
    }
}

/// The GitHub repository `url` names: `https://github.com/O/N(.git)`,
/// `git@github.com:O/N(.git)` or `ssh://git@github.com/O/N(.git)`. Any
/// login in an https URL is dropped. None for anything else.
pub(super) fn parse(url: &str) -> Option<GithubRepo> {
    let url = url.trim();
    let path = if let Some(rest) = strip_prefix_ignore_case(url, "https://") {
        // A login (`x-access-token:...@`) never goes further.
        let (authority, path) = rest.split_once('/')?;
        let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
        if !host.eq_ignore_ascii_case("github.com") {
            return None;
        }
        path
    } else if let Some(rest) = strip_prefix_ignore_case(url, "ssh://git@github.com/") {
        rest
    } else {
        strip_prefix_ignore_case(url, "git@github.com:")?
    };
    let path = path.strip_suffix('/').unwrap_or(path);
    let (owner, name) = path.split_once('/')?;
    let name = name.strip_suffix(".git").unwrap_or(name);
    if !valid_owner(owner) || !valid_name(name) {
        return None;
    }
    Some(GithubRepo { owner: owner.to_string(), name: name.to_string() })
}

/// `url` with any login between `://` and `@` left out, for messages.
pub(super) fn redact(url: &str) -> String {
    if let Some((scheme, rest)) = url.split_once("://") {
        let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
        if let Some((_, host)) = authority.rsplit_once('@') {
            return format!("{scheme}://{host}/{path}");
        }
    }
    url.to_string()
}

fn strip_prefix_ignore_case<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let (head, rest) = text.split_at_checked(prefix.len())?;
    head.eq_ignore_ascii_case(prefix).then_some(rest)
}

fn valid_owner(owner: &str) -> bool {
    !owner.is_empty()
        && !owner.starts_with('-')
        && owner.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slug(url: &str) -> Option<String> {
        parse(url).map(|repo| repo.slug())
    }

    #[test]
    fn github_forms_normalize_to_https() {
        for url in [
            "https://github.com/acme/widget",
            "https://github.com/acme/widget.git",
            "https://github.com/acme/widget/",
            "https://GitHub.com/acme/widget.git",
            "https://x-access-token:secret@github.com/acme/widget.git",
            "git@github.com:acme/widget.git",
            "git@github.com:acme/widget",
            "ssh://git@github.com/acme/widget.git",
            "ssh://git@github.com/acme/widget",
        ] {
            let repo = parse(url).unwrap_or_else(|| panic!("{url} is GitHub"));
            assert_eq!(repo.url(), "https://github.com/acme/widget.git", "{url}");
            assert_eq!(repo.slug(), "acme/widget");
        }
        assert_eq!(slug("https://github.com/a-b/c.d_e.git").as_deref(), Some("a-b/c.d_e"));
    }

    #[test]
    fn other_urls_are_not_github() {
        for url in [
            "https://gitlab.com/acme/widget.git",
            "https://github.com.evil.example/acme/widget.git",
            "https://evil.example/github.com/acme/widget.git",
            "http://github.com/acme/widget.git",
            "git@gitlab.com:acme/widget.git",
            "ssh://git@github.com:22/acme/widget.git",
            "file:///srv/acme/widget.git",
            "/srv/acme/widget.git",
            "https://github.com/acme",
            "https://github.com/acme/widget/tree/main",
            "https://github.com/-acme/widget",
            "https://github.com/acme/..",
            "",
        ] {
            assert_eq!(parse(url), None, "{url}");
        }
    }

    #[test]
    fn redact_drops_logins() {
        assert_eq!(
            redact("https://user:token@gitlab.com/acme/widget.git"),
            "https://gitlab.com/acme/widget.git"
        );
        assert_eq!(redact("git@gitlab.com:acme/widget.git"), "git@gitlab.com:acme/widget.git");
    }
}
