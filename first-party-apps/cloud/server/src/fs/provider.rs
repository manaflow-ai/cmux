//! `cmux.fs.provider/1` for the scheme `cloud-vm` (interface file
//! `cmux-tui/crates/cmux-app-host/interfaces/cmux.fs.provider/1.json`,
//! status draft).
//!
//! LOCAL MIRROR: the interface file has no Rust trait yet. This trait copies
//! its methods (`list`, `stat`, `read`, `write`; `watch` is not served) in
//! the synchronous shape of the rest of this server. A root is the
//! supervisor's `root_…` handle; until handles reach app servers, a root is
//! the scheme plus the machine id.
//!
//! Every method is one daemon `fs.*` op on the link behind the `fs-v1`
//! gate (super::link_files). Gaps (each answers `unsupported` instead of
//! pretending): `list` cursors (one batch) and `watch` (not served yet).

use super::files::{self, Entry};
use super::path::GuestPath;
use crate::api::{CloudError, ControlPlane, args, codes};
use crate::ops::Server;
use serde_json::{Map, json};

pub const FS_PROVIDER_INTERFACE: &str = "cmux.fs.provider/1";
pub const SCHEME: &str = "cloud-vm";

/// A root: the scheme and the machine whose file system it is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Root {
    machine: String,
}

impl Root {
    /// Refuses any scheme other than `cloud-vm` and any bad machine id.
    pub fn new(scheme: &str, machine: &str) -> Result<Self, CloudError> {
        if scheme != SCHEME {
            return Err(CloudError::invalid(format!(
                "scheme {scheme} is not served by cmux/cloud"
            )));
        }
        let map = Map::from_iter([("machine".to_owned(), json!(machine))]);
        Ok(Self { machine: args::id(&map, "machine")?.to_owned() })
    }

    pub fn machine(&self) -> &str {
        &self.machine
    }
}

/// The written file's revision, when the daemon reports one.
pub type Revision = Option<String>;

pub trait FsProvider {
    fn schemes(&self) -> &'static [&'static str] {
        &[SCHEME]
    }
    fn list(
        &mut self,
        root: &Root,
        path: &str,
        cursor: Option<&str>,
    ) -> Result<Vec<Entry>, CloudError>;
    fn stat(&mut self, root: &Root, path: &str) -> Result<Entry, CloudError>;
    fn read(
        &mut self,
        root: &Root,
        path: &str,
        range: Option<(u64, u64)>,
    ) -> Result<Vec<u8>, CloudError>;
    fn write(
        &mut self,
        root: &Root,
        path: &str,
        bytes: &[u8],
        base_revision: Option<&str>,
    ) -> Result<Revision, CloudError>;
}

/// The provider view of the server, borrowed for one call.
pub struct CloudFs<'a, C> {
    server: &'a mut Server<C>,
}

impl<C> Server<C> {
    /// The `cmux.fs.provider/1` view of this server.
    pub fn fs_provider(&mut self) -> CloudFs<'_, C> {
        CloudFs { server: self }
    }
}

fn unsupported(why: &str) -> CloudError {
    CloudError::new(codes::UNSUPPORTED, why)
}

impl<C: ControlPlane> FsProvider for CloudFs<'_, C> {
    fn list(
        &mut self,
        root: &Root,
        path: &str,
        cursor: Option<&str>,
    ) -> Result<Vec<Entry>, CloudError> {
        if cursor.is_some() {
            return Err(unsupported("cmux/cloud answers one listing batch; it has no list cursor"));
        }
        let path = GuestPath::parse(path)?;
        files::list(&super::link_files::daemon(self.server, root.machine())?, &path)
    }

    fn stat(&mut self, root: &Root, path: &str) -> Result<Entry, CloudError> {
        let path = GuestPath::parse(path)?;
        files::stat(&super::link_files::daemon(self.server, root.machine())?, &path)
    }

    fn read(
        &mut self,
        root: &Root,
        path: &str,
        range: Option<(u64, u64)>,
    ) -> Result<Vec<u8>, CloudError> {
        let path = GuestPath::parse(path)?;
        let Some((offset, length)) = range else {
            return files::read(&super::link_files::daemon(self.server, root.machine())?, &path);
        };
        let limit = length.min(super::MAX_READ_BYTES as u64);
        if limit == 0 {
            return Ok(Vec::new());
        }
        let d = super::link_files::daemon(self.server, root.machine())?;
        files::read_range(&d, &path, offset, limit).map(|(bytes, _)| bytes)
    }

    fn write(
        &mut self,
        root: &Root,
        path: &str,
        bytes: &[u8],
        base_revision: Option<&str>,
    ) -> Result<Revision, CloudError> {
        let path = GuestPath::parse(path)?;
        files::write(
            &super::link_files::daemon(self.server, root.machine())?,
            &path,
            bytes,
            base_revision,
        )
    }
}
