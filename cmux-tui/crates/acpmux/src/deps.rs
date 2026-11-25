//! Dependency caches for Cloud machines: `acpmux machine deps warm|key`.
//!
//! Folder sync to a machine leaves `node_modules`, Cargo's registry and the
//! other installed dependencies behind, so every new machine installed them
//! cold. `warm` restores an archive of them, keyed by the lockfile, from the
//! person's (or the team's) cache on the platform, runs the project's normal
//! install (then nearly a no-op), and after a cold install uploads one.
//!
//! - The key is `<ecosystem>-<sha256>` over the lockfile's bytes, the package
//!   manager and runtime versions, the OS, architecture and libc, and the
//!   archive codec (`detect.rs`). The platform never sees a lockfile.
//! - What is packed: a project's `node_modules` (bun, yarn), or a package
//!   manager's own download cache (npm `_cacache`, the pnpm store, uv's
//!   cache, Cargo's registry index and `.crate` files and git databases,
//!   never `target/`). Credentials files are never packed or unpacked
//!   (`archive.rs` `DENIED`): `.npmrc`, `.yarnrc*`, `.netrc`, `.env*`,
//!   `credentials*` and the like.
//! - The bearer is this machine's join credential (`acpmux machine join`),
//!   sent only to its own hub (`remote.rs`). Archives go up in 64 MiB parts,
//!   each SHA-256 checked, and a download is verified before it is unpacked.
//! - A restore runs only when it is expected to beat a cold install on this
//!   machine (`stats.rs`), and after a cold install the archive is packed and
//!   uploaded by a detached `machine deps upload`, so a miss costs no wait.

pub mod archive;
pub mod detect;
pub mod remote;
pub mod stats;
pub mod warm;
