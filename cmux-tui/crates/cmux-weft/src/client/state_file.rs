//! The device's state file: its keys and identity. Written mode 0600.
//!
//! [`StateFile::load`] and [`StateFile::save`] are async: the file work runs
//! as a `cmux_blocking::spawn_blocking` task (Chrome's `MayBlock()` task,
//! base/task/task_traits.h), so the node's tokio workers never wait on the
//! disk, `rotate`'s fsync under the `apply` lock included.

use std::io::Write;
use std::net::Ipv6Addr;
use std::path::Path;

use anyhow::Context;
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
pub struct StateFile {
    pub coord: String,
    pub tailnet: String,
    pub node_id: String,
    pub name: String,
    pub address: Ipv6Addr,
    /// Ed25519 machine key seed, standard base64.
    pub machine_seed: String,
    /// X25519 WireGuard private key, standard base64.
    pub node_private: String,
}

impl StateFile {
    /// The state at `path`, or `None` when the file does not exist.
    pub async fn load(path: &Path) -> anyhow::Result<Option<Self>> {
        let path = path.to_owned();
        cmux_blocking::spawn_blocking(move || Self::load_blocking(&path))
            .await
            .context("state file load task")?
    }

    /// Write atomically (temp file + rename), owner read/write only.
    pub async fn save(&self, path: &Path) -> anyhow::Result<()> {
        let text = serde_json::to_vec_pretty(self)?;
        let path = path.to_owned();
        cmux_blocking::spawn_blocking(move || save_blocking(&text, &path))
            .await
            .context("state file save task")?
    }

    fn load_blocking(path: &Path) -> anyhow::Result<Option<Self>> {
        match cmux_blocking::fs::read(path) {
            Ok(bytes) => Ok(Some(
                serde_json::from_slice(&bytes)
                    .with_context(|| format!("parse {}", path.display()))?,
            )),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error).with_context(|| format!("read {}", path.display())),
        }
    }
}

fn save_blocking(text: &[u8], path: &Path) -> anyhow::Result<()> {
    let temp = path.with_extension("tmp");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = cmux_threads::checked::fs::open_with(&options, &temp)
        .with_context(|| format!("write {}", temp.display()))?;
    file.write_all(text)?;
    cmux_threads::checked::fs::sync_all(&file)?;
    cmux_blocking::fs::rename(&temp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> StateFile {
        StateFile {
            coord: "https://coord.example".into(),
            tailnet: "tn".into(),
            node_id: "n1".into(),
            name: "device".into(),
            address: Ipv6Addr::LOCALHOST,
            machine_seed: "seed".into(),
            node_private: "private".into(),
        }
    }

    /// `join` and `rotate` load and save the state file from async code (rotate
    /// under the `apply` lock): the read, write, fsync and rename run on the
    /// blocking pool, not on the thread driving the runtime (cmux_blocking's
    /// block_on disallows blocking there; a file call left there panics in
    /// debug and counts as stalled).
    #[test]
    fn load_and_save_keep_file_work_off_the_runtime_thread() {
        let runtime = cmux_blocking::runtime::current_thread().build().unwrap();
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("state.json");
        let stalled = cmux_blocking::counts().stalled;

        let (missing, loaded) = cmux_blocking::runtime::block_on(&runtime, async {
            let missing = StateFile::load(&path).await.unwrap();
            state().save(&path).await.unwrap();
            (missing, StateFile::load(&path).await.unwrap())
        });

        assert_eq!(cmux_blocking::counts().stalled, stalled);
        assert!(missing.is_none());
        let loaded = loaded.unwrap();
        assert_eq!((loaded.node_id.as_str(), loaded.node_private.as_str()), ("n1", "private"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600, "state file mode {mode:o}");
        }
    }
}
