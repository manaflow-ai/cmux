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
//! Interface gaps (the Cloud API cannot do them; each answers `unsupported`
//! instead of pretending): `list` cursors (the route answers one batch),
//! `read` ranges, `write` with a base revision (the route has no revision),
//! and `watch` (no change feed).

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

/// The written file's revision. Always `None`: the route has no revision.
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

/// The provider view of the server, borrowed for one call (the server stays
/// the only caller of the Cloud API).
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
            return Err(unsupported(
                "The cmux Cloud API file route answers one batch; it has no list cursor",
            ));
        }
        let path = GuestPath::parse(path)?;
        files::list(&mut self.server.ctx("cloud.fs.list", None), root.machine(), &path)
    }

    fn stat(&mut self, root: &Root, path: &str) -> Result<Entry, CloudError> {
        let path = GuestPath::parse(path)?;
        files::stat(&mut self.server.ctx("cloud.fs.stat", None), root.machine(), &path)
    }

    fn read(
        &mut self,
        root: &Root,
        path: &str,
        range: Option<(u64, u64)>,
    ) -> Result<Vec<u8>, CloudError> {
        if range.is_some() {
            return Err(unsupported(
                "The cmux Cloud API file route reads whole files; it has no read range",
            ));
        }
        let path = GuestPath::parse(path)?;
        files::read(&mut self.server.ctx("cloud.fs.read", None), root.machine(), &path)
    }

    fn write(
        &mut self,
        root: &Root,
        path: &str,
        bytes: &[u8],
        base_revision: Option<&str>,
    ) -> Result<Revision, CloudError> {
        if base_revision.is_some() {
            return Err(unsupported(
                "The cmux Cloud API file route has no revision, so a base revision cannot be checked",
            ));
        }
        let path = GuestPath::parse(path)?;
        let mut ctx = self.server.ctx("cloud.fs.write", None);
        files::write(&mut ctx, root.machine(), &path, bytes, None)?;
        Ok(None)
    }
}
