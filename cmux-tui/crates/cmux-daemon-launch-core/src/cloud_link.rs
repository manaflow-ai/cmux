//! This Mac's `cmux link` process as the app starts it (`cmux-tui link
//! ensure|stop|archive`): the command lines, the environment and the answer.
//! The Cloud side (the credential relay the link asks, the session that
//! decides when it runs) stays with the Cloud code.

use crate::ensure::split_lines;
use crate::{Env, join};
use serde::{Deserialize, Serialize};

/// The variables the link may get from the app's environment; nothing else
/// (no `CMUX_NEXT_*`, no `DYLD_*`, no credentials) reaches it.
pub const INHERITED_KEYS: [&str; 7] =
    ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "SHELL"];

/// One launcher's settings.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Link {
    /// The daemon state root (`CMUX_TUI_STATE_DIR`); none: cmux-tui's default.
    #[serde(default)]
    pub state_root: Option<String>,
    /// The private credential socket the link asks.
    #[serde(default)]
    pub credential_socket: Option<String>,
    /// The build has its own state: any free UDP port and its own `server.json`.
    #[serde(default)]
    pub tagged: bool,
}

impl Link {
    /// The link's state directory.
    pub fn state_directory(&self) -> Option<String> {
        self.state_root.as_deref().map(|root| join(root, "link"))
    }

    /// `link ensure`; `--handoff` goes only with an explicit `--state-dir`.
    pub fn ensure_arguments(&self, install: &str) -> Vec<String> {
        let mut args: Vec<String> =
            vec!["link".into(), "ensure".into(), "--install".into(), install.into()];
        let Some(state) = self.state_directory() else { return args };
        args.extend(["--handoff".into(), "--state-dir".into(), state]);
        if let Some(socket) = &self.credential_socket {
            args.extend(["--credential-socket".into(), socket.clone()]);
        }
        if self.tagged
            && let Some(root) = &self.state_root
        {
            args.extend([
                "--port".into(),
                "0".into(),
                "--server-config".into(),
                join(root, "server.json"),
            ]);
        }
        args
    }

    /// `link stop` or `link archive` (`verb`).
    pub fn verb_arguments(&self, verb: &str) -> Vec<String> {
        let mut args = vec!["link".to_string(), verb.to_string()];
        if let Some(state) = self.state_directory() {
            args.extend(["--state-dir".into(), state]);
        }
        args
    }

    /// The link's environment: the allow-listed variables of `base`, the
    /// state root and the fixed runtime base.
    pub fn environment(&self, base: &Env, runtime_base: &str) -> Env {
        let mut env: Env = base
            .iter()
            .filter(|(k, _)| INHERITED_KEYS.contains(&k.as_str()))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        if let Some(root) = &self.state_root {
            env.insert("CMUX_TUI_STATE_DIR".into(), root.clone());
        }
        env.insert("TMPDIR".into(), runtime_base.into());
        env
    }
}

/// What `link ensure` answered.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ensured {
    /// `running`, `started` or `restarted`.
    pub status: String,
    #[serde(default)]
    pub pid: Option<i32>,
    #[serde(default)]
    pub socket: Option<String>,
}

/// The last line of a stream (empty without one).
pub fn last_line(text: &str) -> &str {
    split_lines(text).next_back().unwrap_or_default()
}

/// Reads `link ensure`'s stdout: its last line's answer, or why it is not
/// one. A launcher with a credential socket needs the link's pid (the
/// socket admits only that process).
pub fn parse_ensure(stdout: &str, needs_pid: bool) -> Result<Ensured, &'static str> {
    let ensured: Ensured = serde_json::from_str(last_line(stdout)).map_err(|_| "bad_answer")?;
    if needs_pid && ensured.pid.is_none() {
        return Err("link did not report a pid");
    }
    Ok(ensured)
}

/// The link's state root: the app daemon's own state directory when the
/// build has one (`own`), else cmux-tui's default root, because the daemon
/// finds the link only through `link.json` in its own state directory.
pub fn state_root(own: Option<&str>, default_root: Option<&str>) -> Option<(String, bool)> {
    match own {
        Some(dir) => Some((dir.into(), true)),
        None => default_root.map(|root| (root.into(), false)),
    }
}
