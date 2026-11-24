//! The device's state file: its keys and identity. Written mode 0600.

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
    pub fn load(path: &Path) -> anyhow::Result<Option<Self>> {
        match std::fs::read(path) {
            Ok(bytes) => {
                let state: Self = serde_json::from_slice(&bytes)
                    .with_context(|| format!("parse {}", path.display()))?;
                // The person named this host (the enrolled --coord, saved in the state file); a
                // redirect off it is still checked.
                cmux_egress::allow_named(&state.coord);
                Ok(Some(state))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error).with_context(|| format!("read {}", path.display())),
        }
    }

    /// Write atomically (temp file + rename), owner read/write only.
    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        let text = serde_json::to_vec_pretty(self)?;
        let temp = path.with_extension("tmp");
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temp).with_context(|| format!("write {}", temp.display()))?;
        file.write_all(&text)?;
        file.sync_all()?;
        std::fs::rename(&temp, path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_saved_coord_passes_the_egress_gate_and_nothing_else_does() {
        cmux_egress::set_mode(cmux_egress::Mode::Enforce);
        let dir = std::env::temp_dir().join(format!("weft-state-file-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.json");
        let saved = StateFile {
            coord: "https://weft-state-named-test.org".into(),
            tailnet: "t".into(),
            node_id: "n".into(),
            name: "device".into(),
            address: Ipv6Addr::LOCALHOST,
            machine_seed: String::new(),
            node_private: String::new(),
        };
        // Saved with the egress gate untouched: only the load names the host.
        std::fs::write(&path, serde_json::to_vec(&saved).unwrap()).unwrap();
        let loaded = StateFile::load(&path).unwrap().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(loaded.coord, "https://weft-state-named-test.org");
        assert!(cmux_egress::check("weft-state-named-test.org", "test").is_ok());
        assert!(cmux_egress::check("unrelated-weft-state-test.org", "test").is_err());
    }
}
