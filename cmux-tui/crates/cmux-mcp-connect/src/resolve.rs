//! What the person named, as the agent passed it: a known server, a remote
//! URL or a local command (design section 2a).

use crate::Refusal;
use crate::command::{CommandTarget, check_command, split};
use crate::registry::{Entry, Registry};
use crate::target::{RemoteTarget, check_url};

/// The result of resolving an input.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolved {
    /// A registry server: the card shows "Verified". The entry is boxed: it is the largest
    /// variant by far.
    Known { entry: Box<Entry>, target: RemoteTarget },
    /// A remote URL that is not exactly a registry URL: "Unverified".
    Remote { target: RemoteTarget },
    /// A local command.
    Local { command: CommandTarget },
    /// Nothing matched: no card; `near` are registry names close to it.
    Unknown { near: Vec<String> },
}

impl Resolved {
    /// Whether the card may show the Verified badge.
    pub fn verified(&self) -> bool {
        matches!(self, Resolved::Known { target, .. } if !target.idn)
    }
}

/// Resolves `input` (`linear`, `https://...`, `npx -y pkg`, `-- prog args`).
/// A refusal means no card is shown and the agent is told why.
pub fn resolve(input: &str, registry: &Registry) -> Result<Resolved, Refusal> {
    let text = input.trim();
    if text.is_empty() {
        return Err(Refusal::new("name a server, a URL or a command"));
    }
    if let Some(rest) = text.strip_prefix("-- ") {
        return Ok(Resolved::Local { command: check_command(&split(rest))? });
    }
    if text.contains("://") {
        let target = check_url(text)?;
        return Ok(match registry.by_url(&target.url) {
            Some(entry) if !target.idn => {
                Resolved::Known { entry: Box::new(entry.clone()), target }
            }
            _ => Resolved::Remote { target },
        });
    }
    if let Some(entry) = registry.find(text) {
        let target = check_url(&entry.url)?;
        return Ok(Resolved::Known { entry: Box::new(entry.clone()), target });
    }
    let argv = split(text);
    if argv.len() > 1 || text.starts_with('/') || text.starts_with("./") {
        return Ok(Resolved::Local { command: check_command(&argv)? });
    }
    Ok(Resolved::Unknown { near: registry.near(text) })
}
