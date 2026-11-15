//! Where a minted or stored value goes: a store spec (`--store`, `--to`) and its names.

use super::UsageError;

/// Where a minted value goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Store {
    GhSecret {
        repo: String,
        environment: Option<String>,
        prefix: String,
    },
    Keychain {
        scope: Option<String>,
        prefix: String,
    },
    /// This machine's kept keys (`acpmux machine vault keep NAME --env`): agents the daemon starts get the
    /// values. `--env`, not `--host`: an S3 pair signs requests locally (SigV4) and the secret never goes
    /// on the wire, so the egress proxy has no placeholder it could fill.
    Vault {
        prefix: String,
        /// The hosts a kept key is filled toward (`--host`, a `cmux-secret://` placeholder the
        /// egress proxy fills); none keeps it as a plain env value (`--env`).
        hosts: Vec<String>,
    },
}

impl Store {
    pub(super) fn parse(spec: &str) -> Result<Self, UsageError> {
        let bad = || {
            UsageError::new(format!(
                "--store {spec:?}: expected gh-secret:OWNER/REPO[@ENV]:PREFIX or keychain:[OWNER/REPO:]PREFIX"
            ))
        };
        if let Some(rest) = spec.strip_prefix("gh-secret:") {
            let (target, prefix) = rest.rsplit_once(':').ok_or_else(bad)?;
            let (repo, environment) = match target.split_once('@') {
                Some((repo, env)) if valid_environment(env) => (repo, Some(env.to_owned())),
                Some(_) => return Err(bad()),
                None => (target, None),
            };
            if !valid_repo(repo) || !valid_prefix(prefix) {
                return Err(bad());
            }
            return Ok(Self::GhSecret {
                repo: repo.to_owned(),
                environment,
                prefix: prefix.to_owned(),
            });
        }
        if let Some(rest) = spec.strip_prefix("keychain:") {
            let (scope, prefix) = match rest.rsplit_once(':') {
                Some((repo, prefix)) if valid_repo(repo) => {
                    (Some(repo.to_ascii_lowercase()), prefix)
                }
                Some(_) => return Err(bad()),
                None => (None, rest),
            };
            if !valid_prefix(prefix) {
                return Err(bad());
            }
            super::super::cloud_secret::check_name(&format!("{prefix}_ACCESS_KEY_ID"))?;
            return Ok(Self::Keychain { scope, prefix: prefix.to_owned() });
        }
        if let Some(prefix) = spec.strip_prefix("vault:") {
            if !valid_prefix(prefix) {
                return Err(bad());
            }
            return Ok(Self::Vault { prefix: prefix.to_owned(), hosts: Vec::new() });
        }
        Err(bad())
    }

    /// The store's full name of one value: `PREFIX_SUFFIX` where it lives.
    pub(super) fn label(&self, suffix: &str) -> String {
        self.place(&self.name(suffix))
    }

    /// Where the value named `name` lives in this store.
    pub(super) fn place(&self, name: &str) -> String {
        match self {
            Self::GhSecret { repo, environment: Some(env), .. } => {
                format!("gh-secret:{repo}@{env}:{name}")
            }
            Self::GhSecret { repo, environment: None, .. } => format!("gh-secret:{repo}:{name}"),
            Self::Keychain { scope, .. } => {
                format!("keychain:{}/{name}", scope.as_deref().unwrap_or("*"))
            }
            Self::Vault { .. } => format!("vault:{name}"),
        }
    }

    /// The place of the one value `cmux keys write` puts here: the spec's last part is its whole
    /// name, not a prefix.
    pub(super) fn spot(&self) -> String {
        self.place(self.prefix())
    }

    pub(super) fn prefix(&self) -> &str {
        match self {
            Self::GhSecret { prefix, .. }
            | Self::Keychain { prefix, .. }
            | Self::Vault { prefix, .. } => prefix,
        }
    }

    /// `PREFIX_SUFFIX`, or the bare prefix for an empty suffix (`cmux keys write`).
    pub(super) fn name(&self, suffix: &str) -> String {
        if suffix.is_empty() {
            return self.prefix().to_owned();
        }
        format!("{}_{suffix}", self.prefix())
    }

    /// This store, filling a kept key only toward `hosts` (a key's scope) when it has any.
    pub(super) fn with_hosts(self, hosts: &[String]) -> Self {
        match self {
            Self::Vault { prefix, .. } => Self::Vault { prefix, hosts: hosts.to_vec() },
            other => other,
        }
    }
}

fn valid_repo(repo: &str) -> bool {
    let part = |p: &str| {
        !p.is_empty()
            && p.len() <= 100
            && p != "."
            && p != ".."
            && p.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
    };
    matches!(repo.split_once('/'), Some((owner, name)) if part(owner) && part(name))
}

fn valid_environment(env: &str) -> bool {
    !env.is_empty()
        && env.len() <= 255
        && env.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
}

/// GitHub's secret names, upper case only: `[A-Z_][A-Z0-9_]*`, leaving room for the longest suffix.
fn valid_prefix(prefix: &str) -> bool {
    !prefix.is_empty()
        && prefix.len() <= 80
        && !prefix.starts_with("GITHUB_")
        && prefix.chars().next().is_some_and(|c| c.is_ascii_uppercase() || c == '_')
        && prefix.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
}
