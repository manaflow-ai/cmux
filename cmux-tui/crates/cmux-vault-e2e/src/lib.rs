//! cmux vault (vault-v1): the person's secrets and env values, synced to their own devices end to end encrypted,
//! and delivered to their Cloud machines sealed to each machine's daemon key (cmuxterm-hq
//! docs/design/e2e-vault.md). The server (cmux-platform `SealedVaultRoute.ts`) stores ciphertext only.
//!
//! - [`crypto`]: items, wraps, deliveries, safety codes.
//! - [`dotenv`]: "import from this .env".
//! - [`plan`]: which values a machine gets.
//! - [`client`]: every person operation over an [`client::Http`] and a [`client::DeviceStore`], without I/O of its
//!   own, shared by the `cmux vault` CLI, the daemon, the iPhone and the tests.
//! - [`machine`]: the machine's side (cmux-host): open its deliveries, keep revisions monotonic, write
//!   `machine-secrets.env`.
//!
//! A value is never in a `Debug`, an error, a log line or an answer meant for display: [`mask`] is what shows.

pub mod client;
pub mod crypto;
pub mod dotenv;
pub mod machine;
pub mod plan;

#[cfg(test)]
mod tests;

/// What every surface shows for a value.
pub fn mask(_value: &str) -> &'static str {
    "••••••••"
}

/// The environment-name rule secrets follow (the machine config's, `cmux cloud secret`'s): `[A-Za-z_][A-Za-z0-9_]*`,
/// at most 128 bytes, not a name the shell, libc or cmux owns.
pub fn valid_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    let plain = name.len() <= 128
        && bytes.next().is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
        && bytes.all(|b| b.is_ascii_alphanumeric() || b == b'_');
    let upper = name.to_ascii_uppercase();
    plain
        && !RESERVED.contains(&upper.as_str())
        && !RESERVED_PREFIXES.iter().any(|p| upper.starts_with(p))
        && !REFUSED.contains(&upper.as_str())
}

/// Names the shell, the loader or cmux own (the machine config applier's list, short form).
#[rustfmt::skip]
const RESERVED: &[&str] = &[
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "IFS", "ENV", "BASH_ENV", "PROMPT_COMMAND", "PWD", "OLDPWD", "TERM",
    "HOSTNAME", "SHLVL", "TMPDIR", "LANG", "PS1", "PS2", "PS4", "CDPATH",
];
const RESERVED_PREFIXES: &[&str] = &["CMUX_", "ACPMUX_", "LD_", "DYLD_", "BASH_FUNC_"];
/// Never in the vault: a Claude subscription login is signed in per machine; base URLs reroute every agent.
const REFUSED: &[&str] = &["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL", "OPENAI_BASE_URL"];

/// Where a value goes.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Scope {
    /// Every machine.
    All,
    /// Machines set up from `owner/name` (lowercased).
    Repo(String),
    /// One machine, `vm_…`.
    Machine(String),
}

impl Scope {
    pub fn parse(text: &str) -> Option<Scope> {
        if text == "*" {
            return Some(Scope::All);
        }
        if let Some(repo) = text.strip_prefix("repo:") {
            let parts: Vec<&str> = repo.split('/').collect();
            let plain = |p: &&str| {
                !p.is_empty()
                    && p.len() <= 100
                    && *p != "."
                    && *p != ".."
                    && p.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
            };
            return (parts.len() == 2 && parts.iter().all(plain))
                .then(|| Scope::Repo(repo.to_ascii_lowercase()));
        }
        if let Some(vm) = text.strip_prefix("machine:") {
            return is_vm(vm).then(|| Scope::Machine(vm.to_owned()));
        }
        None
    }

    pub fn wire(&self) -> String {
        match self {
            Scope::All => "*".to_owned(),
            Scope::Repo(repo) => format!("repo:{repo}"),
            Scope::Machine(vm) => format!("machine:{vm}"),
        }
    }

    /// For display: `every machine`, `repo owner/name`, `machine vm_…`.
    pub fn label(&self) -> String {
        match self {
            Scope::All => "every machine".to_owned(),
            Scope::Repo(repo) => format!("repo {repo}"),
            Scope::Machine(vm) => format!("machine {vm}"),
        }
    }

    /// Higher wins for one name on one machine.
    pub fn rank(&self) -> u8 {
        match self {
            Scope::All => 0,
            Scope::Repo(_) => 1,
            Scope::Machine(_) => 2,
        }
    }
}

pub fn is_vm(id: &str) -> bool {
    id.len() == 23
        && id.starts_with("vm_")
        && id.bytes().skip(3).all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}

/// base64url without padding, the wire's form; decoding also takes padded and standard base64.
pub mod b64 {
    use base64::Engine as _;
    use base64::engine::general_purpose::{STANDARD, URL_SAFE, URL_SAFE_NO_PAD};

    pub fn encode(bytes: &[u8]) -> String {
        URL_SAFE_NO_PAD.encode(bytes)
    }

    pub fn decode(text: &str) -> Option<Vec<u8>> {
        URL_SAFE_NO_PAD
            .decode(text)
            .or_else(|_| URL_SAFE.decode(text))
            .or_else(|_| STANDARD.decode(text))
            .ok()
    }
}
