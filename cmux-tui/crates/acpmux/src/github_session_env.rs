//! What an agent session on a machine a Mac lends GitHub gets (remote-integrations slice 2): git
//! asks `acpmux __github credential` for github.com (`GIT_CONFIG_COUNT`, command scope, after
//! the person's own helpers), and a `gh` shim first on PATH runs `gh --auto` through it
//! (`github_lane_mint.rs`). The person's own auth still wins: their helper answers git first,
//! and `--auto` hands gh their own login or `GH_TOKEN` untouched.
//!
//! Nothing here holds a token: the shim is a two-line script, and each run asks for one.

use std::path::{Path, PathBuf};

const HELPER_KEY: &str = "credential.https://github.com.helper";
const PATH_KEY: &str = "credential.https://github.com.useHttpPath";
/// The shim's folder under acpmux's home.
const SHIM_DIR: &str = "github-shim";

/// Whether this daemon's sessions get GitHub from a Mac: one lent it GitHub since it started,
/// and it is no cmux Cloud machine (whose image wires its own Cloud agent).
pub fn lent() -> bool {
    crate::github_broker::lent_here() && !crate::cloud_repo_mcp::is_cloud_machine()
}

/// The variables to set on a session whose environment is `env`: git's helper entries after
/// any the environment has, and PATH with `shim_dir` first when there is a shim.
pub fn entries(
    env: &[(String, String)],
    acpmux: &Path,
    shim_dir: Option<&Path>,
) -> Vec<(String, String)> {
    let get = |k: &str| env.iter().find(|(key, _)| key == k).map(|(_, v)| v.as_str());
    let start: usize = get("GIT_CONFIG_COUNT").and_then(|n| n.trim().parse().ok()).unwrap_or(0);
    let quoted = acpmux.display().to_string().replace('\'', r"'\''");
    let mut out = Vec::new();
    for (i, (key, value)) in [
        (HELPER_KEY, format!("!'{quoted}' {} credential", crate::github_lane_mint::CLI_ARG)),
        (PATH_KEY, "true".to_owned()),
    ]
    .into_iter()
    .enumerate()
    {
        out.push((format!("GIT_CONFIG_KEY_{}", start + i), key.to_owned()));
        out.push((format!("GIT_CONFIG_VALUE_{}", start + i), value));
    }
    out.push(("GIT_CONFIG_COUNT".to_owned(), (start + 2).to_string()));
    if let Some(dir) = shim_dir {
        let path = match get("PATH").filter(|p| !p.is_empty()) {
            Some(p) => format!("{}:{p}", dir.display()),
            None => dir.display().to_string(),
        };
        out.push(("PATH".to_owned(), path));
    }
    out
}

/// The real `gh` on `path`, past the shim's own folder.
pub fn real_gh(path: &str, shim_dir: &Path) -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    std::env::split_paths(path).filter(|d| d != shim_dir && d.is_absolute()).find_map(|d| {
        let gh = d.join("gh");
        let meta = std::fs::metadata(&gh).ok()?;
        (meta.is_file() && meta.permissions().mode() & 0o111 != 0).then_some(gh)
    })
}

/// The shim's text: `gh --auto` through `acpmux`, running `real` as gh.
pub fn shim_text(acpmux: &Path, real: &Path) -> String {
    let q = |p: &Path| p.display().to_string().replace('\'', r"'\''");
    format!(
        "#!/bin/sh\n# cmux: gh with a GitHub token from the Mac that lends this machine GitHub.\n\
         CMUX_GITHUB_GH_REAL='{}'\nexport CMUX_GITHUB_GH_REAL\nexec '{}' {} gh --auto -- \"$@\"\n",
        q(real),
        q(acpmux),
        crate::github_lane_mint::CLI_ARG
    )
}

/// Writes `dir/gh` (0755) when its text changed: whole or not at all.
pub fn write_shim(dir: &Path, text: &str) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let gh = dir.join("gh");
    if std::fs::read_to_string(&gh).is_ok_and(|t| t == text) {
        return Ok(());
    }
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".gh.{}", std::process::id()));
    std::fs::write(&tmp, text)?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
    std::fs::rename(&tmp, &gh)
}

/// Sets [`entries`] on a session's command whose environment is `env`. With no own acpmux
/// path it sets nothing; with no real gh, or a shim it cannot write, only git's helper.
pub fn apply(cmd: &mut tokio::process::Command, env: &[(String, String)]) {
    let Some(acpmux) = crate::cli_caller::own_bin() else { return };
    let dir = crate::config::home().join(SHIM_DIR);
    let path = env.iter().find(|(k, _)| k == "PATH").map(|(_, v)| v.as_str()).unwrap_or("");
    let shim =
        real_gh(path, &dir).and_then(|real| match write_shim(&dir, &shim_text(&acpmux, &real)) {
            Ok(()) => Some(dir.clone()),
            Err(e) => {
                tracing::warn!(error = %e, "github shim not written; gh runs without a cmux token");
                None
            }
        });
    cmd.envs(entries(env, &acpmux, shim.as_deref()));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn git_gets_the_helper_after_the_entries_it_has() {
        let got = entries(
            &env(&[("GIT_CONFIG_COUNT", "1"), ("PATH", "/usr/bin")]),
            Path::new("/opt/it's/acpmux"),
            Some(Path::new("/h/github-shim")),
        );
        let get = |k: &str| got.iter().find(|(key, _)| key == k).map(|(_, v)| v.clone());
        assert_eq!(get("GIT_CONFIG_COUNT").as_deref(), Some("3"));
        assert_eq!(get("GIT_CONFIG_KEY_1").as_deref(), Some(HELPER_KEY));
        assert_eq!(
            get("GIT_CONFIG_VALUE_1").as_deref(),
            Some(r"!'/opt/it'\''s/acpmux' __github credential")
        );
        assert_eq!(get("GIT_CONFIG_KEY_2").as_deref(), Some(PATH_KEY));
        assert_eq!(get("GIT_CONFIG_VALUE_2").as_deref(), Some("true"));
        assert_eq!(get("PATH").as_deref(), Some("/h/github-shim:/usr/bin"));
        assert!(get("GIT_CONFIG_KEY_0").is_none(), "the entry it had stays");
    }

    #[test]
    fn with_no_shim_path_stays_and_no_token_is_anywhere() {
        let got = entries(&env(&[("GIT_CONFIG_COUNT", "x")]), Path::new("/a"), None);
        assert!(got.iter().all(|(k, _)| k != "PATH"));
        assert!(got.iter().any(|(k, v)| k == "GIT_CONFIG_COUNT" && v == "2"));
        assert!(got.iter().all(|(_, v)| !v.contains("ghs_")));
    }

    #[test]
    fn the_shim_runs_the_real_gh_and_never_itself() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let shim = root.path().join("github-shim");
        let bin = root.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let real = bin.join("gh");
        std::fs::write(&real, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o755)).unwrap();
        write_shim(&shim, &shim_text(Path::new("/a/acpmux"), &real)).unwrap();
        let path = format!("{}:{}", shim.display(), bin.display());
        assert_eq!(real_gh(&path, &shim), Some(real.clone()));
        assert_eq!(real_gh(&shim.display().to_string(), &shim), None);
        let text = std::fs::read_to_string(shim.join("gh")).unwrap();
        assert!(text.contains("exec '/a/acpmux' __github gh --auto -- \"$@\""));
        assert!(text.contains(&format!("CMUX_GITHUB_GH_REAL='{}'", real.display())));
        let mode = std::fs::metadata(shim.join("gh")).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o755);
    }
}
