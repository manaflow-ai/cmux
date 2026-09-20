//! Durable identity for the one Cloud starter workspace and terminal.

use super::*;

const KEY: &str = "cloud_initial_bootstrap_v1";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct CloudBootstrap {
    pub workspace_key: String,
    pub terminal_id: String,
    pub finished: bool,
}

impl WorkspaceRegistry {
    /// Reserve only at the fresh registry boundary. Revisions include deleted
    /// workspaces, so deleting or renaming a workspace never grants first use.
    pub(crate) fn reserve_cloud_bootstrap(
        &self,
        workspace_key: &str,
        terminal_id: &str,
    ) -> anyhow::Result<Option<CloudBootstrap>> {
        if let Some(value) = meta_value(&self.connection, KEY)? {
            return serde_json::from_str(&value).context("read Cloud bootstrap identity");
        }
        let fresh = ["revision", "terminal_revision", "resource_revision"].iter().try_fold(
            true,
            |fresh, key| -> anyhow::Result<bool> {
                Ok(fresh && meta_value(&self.connection, key)?.as_deref() == Some("0"))
            },
        )?;
        let bootstrap = fresh.then(|| CloudBootstrap {
            workspace_key: workspace_key.to_owned(),
            terminal_id: terminal_id.to_owned(),
            finished: false,
        });
        self.connection.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)",
            params![KEY, serde_json::to_string(&bootstrap)?],
        )?;
        Ok(bootstrap)
    }

    pub(crate) fn cloud_bootstrap(&self) -> anyhow::Result<Option<CloudBootstrap>> {
        meta_value(&self.connection, KEY)?
            .map(|value| serde_json::from_str(&value))
            .transpose()
            .map(Option::flatten)
            .context("read Cloud bootstrap identity")
    }

    pub(crate) fn cloud_bootstrap_workspace_created(&self, key: &str) -> anyhow::Result<bool> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM workspaces WHERE workspace_key = ?1)",
            [key],
            |row| row.get(0),
        )?)
    }

    pub(crate) fn cloud_bootstrap_has_other_terminal(
        &self,
        entry: &CloudBootstrap,
    ) -> anyhow::Result<bool> {
        Ok(self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM terminal_hosts WHERE workspace_key = ?1 AND terminal_id != ?2)",
            params![entry.workspace_key, entry.terminal_id], |row| row.get(0),
        )?)
    }

    pub(crate) fn finish_cloud_bootstrap(
        &self,
        mut bootstrap: CloudBootstrap,
    ) -> anyhow::Result<()> {
        bootstrap.finished = true;
        self.connection.execute(
            "UPDATE meta SET value = ?2 WHERE key = ?1",
            params![KEY, serde_json::to_string(&Some(bootstrap))?],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cloud_bootstrap_identity_survives_daemon_restart() {
        let root = std::env::temp_dir().join(format!("cmux-cloud-bootstrap-{}", new_uuid_v4()));
        let workspace = new_uuid_v4();
        let terminal = "00000000000040008000000000000001";
        {
            let registry = WorkspaceRegistry::open(&root, "cloud").unwrap();
            let pending = registry.reserve_cloud_bootstrap(&workspace, terminal).unwrap().unwrap();
            assert!(!pending.finished);
        }
        {
            let registry = WorkspaceRegistry::open(&root, "cloud").unwrap();
            let pending =
                registry.reserve_cloud_bootstrap(&new_uuid_v4(), "different").unwrap().unwrap();
            assert_eq!(pending.workspace_key, workspace);
            assert_eq!(pending.terminal_id, terminal);
            registry.finish_cloud_bootstrap(pending).unwrap();
        }
        {
            let registry = WorkspaceRegistry::open(&root, "cloud").unwrap();
            assert!(registry.cloud_bootstrap().unwrap().unwrap().finished);
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}
