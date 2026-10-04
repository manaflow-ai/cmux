//! Part of `Hub`; see `hub/mod.rs`. The harness command line a session
//! spawns with: its profile, its preset's env, args and system prompt file.

use super::*;

use crate::config::check_preset_args;

impl Hub {
    /// The profile as it is spawned for this session: family and profile
    /// default env underneath the profile's own, the preset's env on top,
    /// then `${cwd}`, `${home}`, `${model}` and a leading `~/` expanded in
    /// every env value and argv word. The preset's args (checked against the
    /// allowlist again) and its system prompt file (checked against its
    /// recorded sha256) are appended here, at every spawn; a remote-origin
    /// session never gets either.
    pub(super) async fn spawn_profile(
        &self,
        session: &Session,
        profile: &HarnessProfile,
        defaults_env: &std::collections::BTreeMap<String, String>,
    ) -> Result<HarnessProfile, RpcError> {
        let meta = session.meta();
        let mut p = profile.clone();
        for (k, v) in defaults_env {
            p.env.entry(k.clone()).or_insert_with(|| v.clone());
        }
        let mut prompt_file = None;
        {
            let cfg = self.config.read().await;
            if let Some(name) = &meta.preset
                && let Some(preset) = cfg.presets.get(name)
            {
                if meta.remote_origin && preset.shapes_command() {
                    return Err(RpcError::invalid_params(format!(
                        "preset {name:?} now carries harness args or a system prompt, which a remote-origin session never starts with"
                    )));
                }
                check_preset_args(profile.kind, &preset.args).map_err(RpcError::invalid_params)?;
                for (k, v) in &preset.env {
                    p.env.insert(k.clone(), v.clone());
                }
                p.argv.extend(preset.args.iter().cloned());
                if let Some(sha) = &preset.system_prompt_sha256 {
                    if profile.kind != crate::config::HarnessKind::ClaudeStdio {
                        return Err(RpcError::invalid_params(format!(
                            "preset {name:?} has a system prompt, which only Claude Code harnesses take"
                        )));
                    }
                    let dir = cfg.presets_dir().ok_or_else(|| {
                        RpcError::invalid_params(format!(
                            "preset {name:?} has a system prompt, but this daemon has no state directory"
                        ))
                    })?;
                    prompt_file = Some(
                        crate::config::checked_system_prompt(&dir, name, sha)
                            .map_err(RpcError::invalid_params)?,
                    );
                }
            }
        }
        let home = dirs::home_dir().unwrap_or_default();
        let model = meta.model_request.clone().unwrap_or_default();
        for v in p.env.values_mut() {
            *v = expand_env_value(v, &meta.cwd, &home, &model);
        }
        for a in p.argv.iter_mut() {
            *a = expand_env_value(a, &meta.cwd, &home, &model);
        }
        // After expansion: the path is acpmux's own, never expanded.
        if let Some(file) = prompt_file {
            p.argv.push("--system-prompt-file".into());
            p.argv.push(file.to_string_lossy().into_owned());
        }
        Ok(p)
    }
}

/// `${cwd}`, `${home}`, `${model}` and a leading `~/` in a profile env value or argv word.
pub fn expand_env_value(
    value: &str,
    cwd: &std::path::Path,
    home: &std::path::Path,
    model: &str,
) -> String {
    let mut out = value
        .replace("${cwd}", &cwd.to_string_lossy())
        .replace("${home}", &home.to_string_lossy())
        .replace("${model}", model);
    if let Some(rest) = out.strip_prefix("~/") {
        out = format!("{}/{rest}", home.to_string_lossy());
    }
    out
}

#[cfg(test)]
mod env_tests {
    #[test]
    fn expands_cwd_and_home() {
        let cwd = std::path::Path::new("/work/proj");
        let home = std::path::Path::new("/Users/me");
        assert_eq!(super::expand_env_value("${cwd}/.codex", cwd, home, ""), "/work/proj/.codex");
        assert_eq!(super::expand_env_value("~/.omp", cwd, home, ""), "/Users/me/.omp");
        assert_eq!(
            super::expand_env_value("${home}/x:${cwd}", cwd, home, ""),
            "/Users/me/x:/work/proj"
        );
        assert_eq!(
            super::expand_env_value("--model=${model}", cwd, home, "gpt-5.5"),
            "--model=gpt-5.5"
        );
        assert_eq!(super::expand_env_value("plain", cwd, home, ""), "plain");
    }
}
