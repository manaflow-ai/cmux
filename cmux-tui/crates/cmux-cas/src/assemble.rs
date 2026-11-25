//! Rebuild a manifest's tree from the store, bit-exact: every file is checked against its whole
//! hash before it is renamed into place, so a half-written or wrong tree is never seen.

use crate::manifest::Manifest;
use crate::store::{Store, write_atomic};
use crate::{Id, Result};
use std::path::Path;

/// Write `manifest`'s files under `dir` from `store`. Fails, writing nothing more, on the first
/// chunk the store lacks or a file whose bytes do not hash to its id.
pub fn assemble(store: &Store, manifest: &Manifest, dir: &Path) -> Result<()> {
    for f in &manifest.files {
        let mut bytes = Vec::with_capacity(usize::try_from(f.size)?);
        for c in &f.chunks {
            bytes.extend_from_slice(&store.get(&c.id)?);
        }
        if Id::of(&bytes) != f.hash {
            return Err(format!("{} does not hash to its manifest entry", f.path).into());
        }
        let path = dir.join(&f.path);
        let parent = path.parent().ok_or("a file has no parent")?;
        std::fs::create_dir_all(parent)?;
        write_atomic(parent, &path, &bytes)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = if f.exec { 0o755 } else { 0o644 };
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode))?;
        }
    }
    Ok(())
}
