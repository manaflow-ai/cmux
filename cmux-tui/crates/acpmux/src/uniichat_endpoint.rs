//! Where `acpmux uniichat-agent` (`cli::uniichat_agent`, which re-exports these) finds its
//! UniiChat server and this computer's sign-in for it; the harness health check reads the same.

use anyhow::Result;
use std::path::PathBuf;

/// The hosted UniiChat, used when neither `--url` nor `$UNII_URL` names one.
pub const HOSTED: &str = "https://uniichat.com";

/// The command that signs this computer in to UniiChat with no `unii`
/// program: cmux's own (`uniichat-agent login`, through the harness's ACP
/// terminal sign-in), on PATH in every cmux terminal (first-run finding 2).
pub const LOGIN: &str = "cmux harness login unii";

/// How to sign in, shown when the adapter has no sign-in to use.
pub const SETUP: &str =
    "Sign in from Settings > Agents, or run `cmux harness login unii` in a cmux terminal";

/// The adapter's command line flags.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Options {
    /// The server (`https://uniichat.com`, `http://127.0.0.1:8788`); none:
    /// `$UNII_URL`, else the hosted one.
    pub url: Option<String>,
    /// Where `unii` keeps its sign-ins; none: `$UNII_HOME`, else `~/.unii`.
    pub home: Option<PathBuf>,
    /// Send every text block of a prompt, not only the last one.
    pub whole_prompt: bool,
}

/// One UniiChat server and the sign-in this computer holds for it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Endpoint {
    /// `http(s)://host[:port]`, no trailing slash.
    pub base: String,
    /// The WebSocket origin (`ws(s)://host[:port]`).
    pub ws: String,
    /// `host[:port]`, the folder `unii` keeps this server's token in.
    pub host: String,
    /// The token file `unii login` and `uniichat-agent login` write.
    pub token_file: PathBuf,
}

impl Endpoint {
    /// The server and token file from the flags, then the environment
    /// values given (`UNII_URL`, `UNII_HOME`, the home folder), the way the
    /// `unii` terminal finds them (Term.ts `SERVER`, `TOKEN`).
    pub fn resolve(
        options: &Options,
        env_url: Option<String>,
        env_home: Option<String>,
        user_home: Option<PathBuf>,
    ) -> Result<Endpoint, String> {
        let url = options
            .url
            .clone()
            .or(env_url.filter(|u| !u.trim().is_empty()))
            .unwrap_or_else(|| HOSTED.to_owned());
        let base = url.trim().trim_end_matches('/').to_owned();
        let (scheme, rest) = base
            .split_once("://")
            .ok_or_else(|| format!("UniiChat url {base} needs http:// or https://"))?;
        let ws_scheme = match scheme {
            "https" => "wss",
            "http" => "ws",
            _ => return Err(format!("UniiChat url {base} needs http:// or https://")),
        };
        let host = rest.split(['/', '?', '#']).next().unwrap_or("").to_owned();
        if host.is_empty() {
            return Err(format!("UniiChat url {base} has no host"));
        }
        let base = format!("{scheme}://{host}");
        let home = options
            .home
            .clone()
            .or(env_home.filter(|h| !h.trim().is_empty()).map(PathBuf::from))
            .or(user_home.map(|h| h.join(".unii")))
            .ok_or("no home folder for the UniiChat sign-in")?;
        Ok(Endpoint {
            ws: format!("{ws_scheme}://{host}"),
            token_file: home.join(&host).join("token"),
            host,
            base,
        })
    }

    /// The sign-in token, or the setup steps when there is none.
    pub fn token(&self) -> Result<String, String> {
        match std::fs::read_to_string(&self.token_file) {
            Ok(t) if !t.trim().is_empty() => Ok(t.trim().to_owned()),
            _ => Err(format!(
                "UniiChat: this computer is not signed in to {}. {SETUP}{}.",
                self.host,
                self.login_suffix()
            )),
        }
    }

    /// The setup steps for a sign-in the server refused.
    pub fn signed_out(&self) -> String {
        format!(
            "UniiChat: {} refused this computer's sign-in (signed out or expired). Sign in again with `{LOGIN}`{}.",
            self.host,
            self.login_suffix()
        )
    }

    /// For a server other than uniichat.com: the harness's `UNII_URL` must name it.
    fn login_suffix(&self) -> String {
        if self.base == HOSTED {
            String::new()
        } else {
            format!(" (with UNII_URL={} in the unii harness)", self.base)
        }
    }
}
