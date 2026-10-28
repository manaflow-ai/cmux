//! Where a module comes from (a git host, an owner, a repository) and what it
//! is pinned to (a full commit SHA or a tag). Branches are never installed.

use super::Refusal;

/// The only two transports a module may be fetched over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    Https,
    Ssh,
}

/// A git repository reference after validation. Fields are private so the
/// only way to get one is [`GitSource::parse`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitSource {
    transport: Transport,
    host: String,
    path: String,
}

impl GitSource {
    pub fn parse(_input: &str) -> Result<Self, Refusal> {
        Err(Refusal::new("not.implemented", "source parsing"))
    }

    pub fn transport(&self) -> Transport {
        self.transport
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    /// The lower-case first path segment: the publisher a module must claim.
    pub fn owner(&self) -> &str {
        ""
    }

    /// Identity of the module source: `host/path`, lower-cased, no `.git`.
    pub fn key(&self) -> String {
        String::new()
    }

    /// `https://host/path` as the user typed the path (never credentials).
    pub fn display_url(&self) -> String {
        String::new()
    }

    /// The URL git connects to.
    pub fn clone_url(&self) -> String {
        String::new()
    }

    /// GitHub, GitLab, Codeberg or Bitbucket: shown with a recognised label.
    pub fn is_known_forge(&self) -> bool {
        false
    }
}

/// What a module is pinned to. A tag is resolved to a commit at review time
/// and the approval records that commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pin {
    /// Lower-case hex, 40 characters (SHA-1) or 64 (SHA-256).
    Commit(String),
    /// A git tag name.
    Tag(String),
}

impl Pin {
    pub fn parse(_input: &str) -> Result<Self, Refusal> {
        Err(Refusal::new("not.implemented", "pin parsing"))
    }

    pub fn as_str(&self) -> &str {
        match self {
            Pin::Commit(c) | Pin::Tag(c) => c.as_str(),
        }
    }
}

/// Splits `<source>#<pin>`. A pin is required.
pub fn parse_install_spec(_input: &str) -> Result<(GitSource, Pin), Refusal> {
    Err(Refusal::new("not.implemented", "install spec"))
}

/// Whether a host name may be contacted from a module: a public DNS name with
/// a dot, not an IP literal and not a local, private or test name.
pub fn is_public_host(_host: &str) -> bool {
    false
}
