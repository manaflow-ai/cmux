//! No-checkout chats: a chat reads and writes a GitHub repository with nothing cloned.
//!
//! Leo, 2026-11-17: "what other assistants do ... they do these very funky, like, workflow
//! materializations of patches and diffs ... they don't fetch the entire repository. They just do
//! it all through the GitHub MCP connection".
//!
//! A chat gets one of three tiers per task ([`tier::choose`], the Auto rule):
//!
//! - **No checkout** ([`remote::Remote`]): the base is one branch read (`GET .../branches/B`,
//!   the commit and its tree), the file list one recursive tree read, and a file's bytes one blob
//!   read on first use. Edits stay in memory. A patch becomes a commit through the git data API
//!   (blobs, a tree on the base tree, a commit, the branch ref) and then a pull request, so the
//!   bytes that cross the network are the files read and the files changed, never the repository.
//!   When a command must run (a targeted test), only the paths it names are written to disk, with
//!   the edits applied, in a temporary folder that is deleted when the command ends
//!   ([`remote::Remote::project`]); nothing is left on the machine.
//! - **Projection** (RFD 0007, `cmux link project`, crate `cmux-projection`): a folder on the
//!   person's Mac mounted on the machine from a stat-only manifest, its bytes read on first use.
//! - **Full checkout**: a clone, or today's copy of the folder.
//!
//! The token is the GitHub App installation token cmux already mints for one repository (on a
//! cmux Cloud machine, the Cloud agent's `POST /v1/integrations/github/token` through
//! `cmux github`), handed in as a [`github::Token`]; it lives in memory only.

pub mod github;
#[cfg(all(unix, feature = "mock"))]
pub mod mock;
#[cfg(unix)]
pub mod patch;
#[cfg(unix)]
pub mod remote;
pub mod tier;

pub use github::{GitHub, GitWriter, Meter, Token};
#[cfg(unix)]
pub use remote::{Projected, Remote};
pub use tier::{Choice, Folder, Run, Task, Tier, choose};
