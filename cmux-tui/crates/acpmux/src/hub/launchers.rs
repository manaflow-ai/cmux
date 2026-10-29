//! Part of `Hub`; see `hub/mod.rs`. `npx -y PACKAGE` harness launches
//! resolved to the package's installed bin, once per package, so no
//! session spawn or model probe waits on npx.

use super::*;
use crate::no_panic::LockExt;

impl Hub {
    /// Resolve `argv`'s `npx -y PACKAGE` launch when it has one and it is
    /// not cached yet (or its cached bin is gone).
    pub(super) async fn resolve_launcher(&self, argv: &[String]) {
        let Some((npx, package)) = crate::config::adapter_package_launch(argv) else { return };
        let key = (npx.to_owned(), package.to_owned());
        let cached = self.launchers.lock_or_recover().get(&key).cloned();
        if let Some(bin) = cached
            && tokio::fs::metadata(&bin).await.is_ok_and(|m| m.is_file())
        {
            return;
        }
        match crate::config::resolve_adapter_package_bin(npx, package).await {
            Some(bin) => {
                tracing::info!(package, bin = %bin, "npx launch resolved");
                self.launchers.lock_or_recover().insert(key, bin);
            }
            None => tracing::warn!(package, "npx launch could not be resolved; spawns use npx"),
        }
    }

    /// `argv` with a resolved `npx -y PACKAGE` prefix replaced by its bin.
    pub(super) fn resolved_launcher_argv(&self, argv: Vec<String>) -> Vec<String> {
        let bin = crate::config::adapter_package_launch(&argv).and_then(|(npx, package)| {
            self.launchers.lock_or_recover().get(&(npx.to_owned(), package.to_owned())).cloned()
        });
        match bin.filter(|b| cmux_blocking::fs::metadata(b).is_ok_and(|m| m.is_file())) {
            Some(bin) => std::iter::once(bin).chain(argv.into_iter().skip(3)).collect(),
            None => argv,
        }
    }
}
