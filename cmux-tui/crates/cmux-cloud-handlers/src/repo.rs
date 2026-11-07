//! `cloud new-machine --repo OWNER/NAME[@REF]` (or an https git URL): the repository a new
//! machine clones. The one parser is `cmux-cloud-start-core`'s [`machine_repo`] (the machine
//! bootstrap's); here its answer becomes the request's facts and its refusal a [`Said`]. A URL
//! with a login or token in it is refused: it would land in the machine's git config.

use cmux_cloud_start_core::machine_repo::{self, Invalid};
use serde::{Deserialize, Serialize};

use crate::Said;

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

/// The spec's repository, or why it names none (`repoUnrecognized`, `repoCredentialsInURL`,
/// `repoInvalidRef`).
pub fn parse(raw: &str) -> Result<MachineRepo, Said> {
    let repo = machine_repo::parse(raw).map_err(|invalid| {
        Said::key(match invalid {
            Invalid::Unrecognized => "repoUnrecognized",
            Invalid::CredentialsInUrl => "repoCredentialsInURL",
            Invalid::InvalidRef => "repoInvalidRef",
        })
    })?;
    Ok(MachineRepo {
        spec: repo.spec(),
        url: repo.url(),
        directory: repo.directory(),
        owner: repo.owner,
        name: repo.name,
        reference: repo.r#ref,
        host: repo.host,
    })
}

#[cfg(test)]
#[path = "repo/tests.rs"]
mod tests;
