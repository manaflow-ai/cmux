//! Add a machine to the user's own tailnet: an AutoCloud VM, a Mac, a phone.
//!
//! Opt-in and off until the user asks. The user brings the credential (a Tailscale auth key, an
//! OAuth client secret, or a key from their Headscale server) and picks the options: the device
//! name, ACL tags (only ones their policy already lets that credential use; cmux never edits an
//! ACL), Tailscale SSH, Serve or Funnel for preview ports, and an ephemeral node for a throwaway
//! VM. Nothing here changes routes, exit nodes or `accept-routes`: a machine that is already on a
//! tailnet is reported, never switched or reconfigured silently.
//!
//! Pure: [`vm_join_script`] and [`vm_leave_script`] are shell text the caller runs as root on the
//! machine (the Cloud exec API); the credential never appears in that text, in an argv or in a
//! log. The caller writes it to [`KEY_FILE`] (mode 0600, through the Cloud file API) and the
//! script hands it to `tailscale` as `--auth-key=file:` and deletes it whatever happens.
//! [`parse_joined`] reads the script's last line. A Mac or phone joins through the embedded node
//! instead ([`embedded_options`]).

use std::fmt;

pub mod handoff;

pub mod mint;

use serde::{Deserialize, Serialize};

/// Where the join script finds the credential: a tmpfs file, written 0600 by the caller, deleted
/// by the script on every exit path.
pub const KEY_FILE: &str = "/run/cmux-tailnet/authkey";

/// The longest a join may wait for the control server (a Headscale behind a slow link included).
pub const JOIN_TIMEOUT_SECS: u32 = 90;

/// A credential. Its text never leaves through `Debug`, `Display` or serialization.
#[derive(Clone, PartialEq, Eq, Deserialize)]
#[serde(transparent)]
pub struct Secret(String);

impl Secret {
    pub fn new(text: impl Into<String>) -> Self {
        Self(text.into())
    }

    /// The text, for the one write to [`KEY_FILE`] (or the embedded node's config).
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(<redacted>)")
    }
}

impl Serialize for Secret {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str("<redacted>")
    }
}

/// How the machine signs in to the tailnet.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Credential {
    /// A pre-auth key: Tailscale's `tskey-auth-…`, or a Headscale key.
    AuthKey { key: Secret },
    /// A Tailscale OAuth client secret (`tskey-client-…`) with the `auth_keys` scope. The node is
    /// tagged (Tailscale requires tags for it) and pre-authorized.
    OauthClient { secret: Secret },
}

/// One preview port shown on the tailnet.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServePort {
    /// The port on the machine's loopback the preview listens on.
    pub local_port: u16,
    /// The HTTPS port on the tailnet name (443 by default).
    #[serde(default = "default_https_port")]
    pub https_port: u16,
    /// Also on the public internet through Funnel. Only when the user turned it on for this port.
    #[serde(default)]
    pub funnel: bool,
}

fn default_https_port() -> u16 {
    443
}

/// What the user asked for.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JoinRequest {
    pub credential: Credential,
    /// A Headscale (or other) coordination server; `None` is Tailscale's.
    #[serde(default)]
    pub control_url: Option<String>,
    /// The device name and first MagicDNS label; `None` keeps the machine's host name.
    #[serde(default)]
    pub hostname: Option<String>,
    /// ACL tags, each `tag:name`, that the user's policy lets this credential use.
    #[serde(default)]
    pub tags: Vec<String>,
    /// Turn on Tailscale SSH on the machine (who may use it is the user's ACL).
    #[serde(default)]
    pub ssh: bool,
    /// The node leaves the tailnet when it goes offline (a throwaway VM).
    #[serde(default)]
    pub ephemeral: bool,
    #[serde(default)]
    pub serve: Vec<ServePort>,
    /// Join even though the machine is signed in to another tailnet: `tailscale login` adds a
    /// profile and switches to it. Only after the user said so for this machine.
    #[serde(default)]
    pub switch_from_other_tailnet: bool,
    /// The user chose plain `http://` for this login server, knowing the key crosses unencrypted.
    /// Never inferred from the address.
    #[serde(default)]
    pub allow_http: bool,
}

/// Why a request is refused, in words for the user.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Invalid(pub String);

impl fmt::Display for Invalid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Invalid {}

fn invalid<T>(text: impl Into<String>) -> Result<T, Invalid> {
    Err(Invalid(text.into()))
}

/// A request that passed [`JoinRequest::check`]: every value the scripts interpolate is known safe
/// (names and tags are `[a-z0-9-]`, the URL has no shell or space characters).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Checked {
    request: JoinRequest,
}

/// The policy lines a person pastes into their tailnet policy file so the cmux node can be minted
/// and reached (RFD 0169): the tag exists and their admins own it, their own devices reach it, and
/// Tailscale SSH accepts them on it. cmux never edits a policy; the node itself reaches nothing of
/// theirs until they add a line saying so.
pub fn acl_snippet(tag: &str) -> Result<String, Invalid> {
    let tag = check_tag(tag)?;
    Ok(format!(
        "\"tagOwners\": {{\"{tag}\": [\"autogroup:admin\"]}},\n\
         \"grants\": [{{\"src\": [\"autogroup:member\"], \"dst\": [\"{tag}\"], \"ip\": [\"*\"]}}],\n\
         \"ssh\": [{{\"action\": \"accept\", \"src\": [\"autogroup:member\"], \"dst\": [\"{tag}\"], \"users\": [\"root\", \"autogroup:nonroot\"]}}],"
    ))
}

impl Checked {
    pub fn request(&self) -> &JoinRequest {
        &self.request
    }
}

impl JoinRequest {
    pub fn check(mut self) -> Result<Checked, Invalid> {
        let secret = match &self.credential {
            Credential::AuthKey { key } => key,
            Credential::OauthClient { secret } => secret,
        };
        let text = secret.expose();
        if text.is_empty() || text.len() > 512 || text.chars().any(|c| !c.is_ascii_graphic()) {
            return invalid("The key is empty or has spaces or other characters a key never has.");
        }
        if let Some(url) = &self.control_url {
            self.control_url = Some(check_control_url(url, self.allow_http)?);
        }
        let on_tailscale = self.control_url.is_none();
        match &self.credential {
            Credential::AuthKey { .. } if on_tailscale && !text.starts_with("tskey-auth-") => {
                return invalid(
                    "A Tailscale auth key starts with tskey-auth-. For a Headscale key, set its server URL.",
                );
            }
            Credential::OauthClient { .. } if !on_tailscale => {
                return invalid("OAuth clients are Tailscale's; Headscale takes an auth key.");
            }
            Credential::OauthClient { .. } if !text.starts_with("tskey-client-") => {
                return invalid("A Tailscale OAuth client secret starts with tskey-client-.");
            }
            Credential::OauthClient { .. } if self.tags.is_empty() => {
                return invalid(
                    "A machine joined with an OAuth client must carry at least one tag your policy gives that client.",
                );
            }
            _ => {}
        }
        if let Some(name) = &self.hostname {
            self.hostname = Some(check_hostname(name)?);
        }
        let mut tags = Vec::new();
        for tag in &self.tags {
            let tag = check_tag(tag)?;
            if !tags.contains(&tag) {
                tags.push(tag);
            }
        }
        self.tags = tags;
        let mut seen = Vec::new();
        for port in &self.serve {
            if port.local_port == 0 {
                return invalid("A preview port must be 1-65535.");
            }
            if port.funnel && self.control_url.is_some() {
                return invalid(
                    "Funnel is Tailscale's; a Headscale tailnet has no public ingress.",
                );
            }
            if port.funnel && ![443, 8443, 10000].contains(&port.https_port) {
                return invalid("Funnel serves only on 443, 8443 or 10000.");
            }
            if seen.contains(&port.https_port) {
                return invalid(format!("Two previews ask for tailnet port {}.", port.https_port));
            }
            seen.push(port.https_port);
        }
        Ok(Checked { request: self })
    }
}

fn check_control_url(url: &str, allow_http: bool) -> Result<String, Invalid> {
    let url = url.trim().trim_end_matches('/');
    let rest = if let Some(rest) = url.strip_prefix("https://") {
        rest
    } else if let Some(rest) = url.strip_prefix("http://") {
        // A key over plain HTTP is readable on the way, on any network: only when the user chose
        // it for this server, never guessed from the address.
        if !allow_http {
            return invalid(
                "The server URL must be https://. Plain http:// sends the key unencrypted; choose it explicitly (--allow-http) only for a server you trust the path to.",
            );
        }
        rest
    } else {
        return invalid("The server URL must start with https://.");
    };
    let host = rest.split(['/', ':']).next().unwrap_or_default();
    if host.is_empty()
        || url.len() > 2048
        || !url.chars().all(|c| c.is_ascii_alphanumeric() || "-._~:/%[]".contains(c))
    {
        return invalid("The server URL is not a plain https://host[:port][/path] address.");
    }
    Ok(url.to_owned())
}

/// A device name: one DNS label, lowercased.
pub fn check_hostname(name: &str) -> Result<String, Invalid> {
    let name = name.trim().to_ascii_lowercase();
    if name.is_empty()
        || name.len() > 63
        || name.starts_with('-')
        || name.ends_with('-')
        || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return invalid(format!(
            "\"{name}\" is not a device name: use 1-63 letters, digits and dashes, not starting or ending with a dash."
        ));
    }
    Ok(name)
}

/// An ACL tag, `tag:` and a name of letters, digits and dashes starting with a letter.
pub fn check_tag(tag: &str) -> Result<String, Invalid> {
    let tag = tag.trim();
    let tag = if tag.starts_with("tag:") { tag.to_owned() } else { format!("tag:{tag}") };
    let name = tag.strip_prefix("tag:").unwrap_or_default();
    let ok = name.len() <= 63
        && name.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    if !ok {
        return invalid(format!(
            "\"{tag}\" is not an ACL tag: tag: and a name of letters, digits and dashes."
        ));
    }
    Ok(tag)
}

impl Checked {
    /// The credential as `tailscale` takes it: an OAuth client secret carries what the node is
    /// (`ephemeral`, pre-authorized) as its query, since there is no key to mint those into.
    pub fn key_file_contents(&self) -> String {
        match &self.request.credential {
            Credential::AuthKey { key } => key.expose().to_owned(),
            Credential::OauthClient { secret } => format!(
                "{}?ephemeral={}&preauthorized=true",
                secret.expose(),
                self.request.ephemeral
            ),
        }
    }

    /// The `tailscale login` flags, without the credential.
    pub fn login_flags(&self) -> Vec<String> {
        let r = &self.request;
        let mut flags = vec![format!("--auth-key=file:{KEY_FILE}")];
        if let Some(url) = &r.control_url {
            flags.push(format!("--login-server={url}"));
        }
        if let Some(name) = &r.hostname {
            flags.push(format!("--hostname={name}"));
        }
        if !r.tags.is_empty() {
            flags.push(format!("--advertise-tags={}", r.tags.join(",")));
        }
        flags.push(format!("--timeout={JOIN_TIMEOUT_SECS}s"));
        flags
    }

    /// Notes the UI shows beside the result: what the request cannot promise by itself.
    pub fn notes(&self) -> Vec<String> {
        let r = &self.request;
        let mut notes = Vec::new();
        if r.ephemeral && matches!(r.credential, Credential::AuthKey { .. }) {
            notes.push(
                "Whether the node is ephemeral is set on the auth key itself: use an ephemeral key for a throwaway machine."
                    .to_owned(),
            );
        }
        if r.serve.iter().any(|p| p.funnel) {
            notes.push(
                "Funnel makes the preview reachable by anyone on the internet who has its URL."
                    .to_owned(),
            );
        }
        notes
    }
}

/// The shell script, run as root on a Linux VM, that joins it. Facts it prints:
/// `cmux-tailnet: other-tailnet NAME` (refused, nothing changed) and a last line
/// `cmux-tailnet-joined {json}` that [`parse_joined`] reads.
pub fn vm_join_script(checked: &Checked) -> String {
    let r = &checked.request;
    let mut s = String::new();
    s.push_str("#!/bin/sh\n# cmux: join this machine to the user's tailnet (cmux-tailnet-join).\nset -eu\n");
    s.push_str(&format!("k={KEY_FILE}\ntrap 'rm -f \"$k\" 2>/dev/null || true' EXIT INT TERM\n"));
    s.push_str("if [ -L \"$k\" ] || [ ! -f \"$k\" ]; then echo 'cmux-tailnet: the key file is missing or a symlink' >&2; exit 3; fi\n");
    s.push_str("[ -f \"$k\" ] || { echo 'cmux-tailnet: no key file' >&2; exit 2; }\n");
    s.push_str(
        "if ! command -v tailscale >/dev/null 2>&1; then\n  curl -fsSL https://tailscale.com/install.sh | sh >&2\nfi\n",
    );
    s.push_str(
        "if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then systemctl enable --now tailscaled >&2; fi\n",
    );
    // Wait for the daemon's socket (a fresh install starts it a moment later).
    s.push_str("i=0; until tailscale status --json >/dev/null 2>&1 || tailscale status 2>&1 | grep -qi 'logged out\\|needslogin\\|stopped'; do i=$((i+1)); [ $i -gt 30 ] && { echo 'cmux-tailnet: tailscaled not answering' >&2; exit 3; }; sleep 1; done\n");
    // Respect a machine already on a tailnet: same server and signed in is a no-op join; another
    // tailnet is refused unless the user chose to switch.
    s.push_str("st=$(tailscale status --json 2>/dev/null || true)\n");
    s.push_str("state=$(printf '%s' \"$st\" | tr -d '\\n' | sed -n 's/.*\"BackendState\": *\"\\([A-Za-z]*\\)\".*/\\1/p')\n");
    if !r.switch_from_other_tailnet {
        s.push_str("if [ \"$state\" = Running ]; then\n");
        s.push_str("  cur=$(tailscale debug prefs 2>/dev/null | sed -n 's/.*\"ControlURL\": *\"\\([^\"]*\\)\".*/\\1/p' | head -n1)\n");
        let want = r
            .control_url
            .clone()
            .unwrap_or_else(|| "https://controlplane.tailscale.com".to_owned());
        s.push_str(&format!(
            "  if [ -n \"$cur\" ] && [ \"${{cur%/}}\" != {} ]; then echo \"cmux-tailnet: other-tailnet $cur\"; exit 4; fi\n",
            shell_quote(&want)
        ));
        s.push_str("fi\n");
    }
    s.push_str(&format!("tailscale login {} >&2\n", login_args(checked)));
    if r.ssh {
        s.push_str("tailscale set --ssh=true >&2\n");
    }
    // Tailscale's control server issues the node an HTTPS certificate; Headscale cannot, so
    // there the preview is plain HTTP inside the tailnet (still WireGuard end to end).
    let scheme = if r.control_url.is_none() { "https" } else { "http" };
    for port in &r.serve {
        let verb = if port.funnel { "funnel" } else { "serve" };
        s.push_str(&format!(
            "tailscale {verb} --bg --{scheme}={} http://127.0.0.1:{} >&2\n",
            port.https_port, port.local_port
        ));
    }
    s.push_str("printf 'cmux-tailnet-joined '; tailscale status --json --peers=false | tr -d '\\n'; echo\n");
    s
}

fn login_args(checked: &Checked) -> String {
    checked.login_flags().iter().map(|f| shell_quote(f)).collect::<Vec<_>>().join(" ")
}

/// The shell script, run as root before a VM is deleted: stop Serve and Funnel and sign out, which
/// removes an ephemeral node at once and expires a kept one. Never fails the delete.
pub fn vm_leave_script() -> String {
    "#!/bin/sh\n# cmux: leave the user's tailnet before this machine is deleted (cmux-tailnet-join).\n\
     command -v tailscale >/dev/null 2>&1 || exit 0\n\
     tailscale serve reset >/dev/null 2>&1 || true\n\
     tailscale funnel reset >/dev/null 2>&1 || true\n\
     timeout 12 tailscale logout >&2 || true\n\
     echo cmux-tailnet-left\n"
        .to_owned()
}

fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// The folder the join's files live in on a VM (tmpfs: gone at reboot).
pub const RUN_DIR: &str = "/run/cmux-tailnet";
/// The join script's path on a VM.
pub const SCRIPT_FILE: &str = "/run/cmux-tailnet/join.sh";
/// The transient unit a join runs in (`systemctl status cmux-tailnet-join`).
pub const UNIT: &str = "cmux-tailnet-join";

const ROOT: &str = r#"root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }"#;

/// A VM's exec has a short limit (about 20 s), and a join that installs Tailscale takes longer, so
/// a join is steps: [`prepare_command`], two file writes ([`KEY_FILE`] 0600 with
/// [`Checked::key_file_contents`], [`SCRIPT_FILE`] 0700 with [`vm_join_script`]), [`start_command`],
/// then [`read_command`] until [`read_answer`] says it ended.
///
/// `user` is the account the file API writes as; the folder is made its own, 0700.
pub fn prepare_command(user: &str) -> String {
    format!(
        "{ROOT}; u={}; if [ -L {RUN_DIR} ]; then echo 'cmux-tailnet: run dir is a symlink' >&2; exit 3; fi; root mkdir -p {RUN_DIR} && root chown -h \"$u\" {RUN_DIR} && root chmod 700 {RUN_DIR} && root rm -f {KEY_FILE} {RUN_DIR}/out {RUN_DIR}/err {RUN_DIR}/rc && echo prepared",
        shell_quote(user)
    )
}

/// Starts the join detached (under systemd when the machine has it) and answers `started`.
pub fn start_command() -> String {
    let body = format!("sh {SCRIPT_FILE} >{RUN_DIR}/out 2>{RUN_DIR}/err; echo $? >{RUN_DIR}/rc");
    format!(
        "{ROOT}; if command -v systemd-run >/dev/null 2>&1 && [ -d /run/systemd/system ]; then root systemctl reset-failed {UNIT} >/dev/null 2>&1; root systemd-run --quiet --collect --unit={UNIT} /bin/sh -c {} || exit 1; else root setsid /bin/sh -c {} </dev/null >/dev/null 2>&1 & fi; echo started",
        shell_quote(&body),
        shell_quote(&body)
    )
}

/// Reads where a join is: `rc=N` (or `rc=`), then the script's stdout, then its stderr's end.
pub fn read_command() -> String {
    format!(
        "{ROOT}; printf 'rc=%s\\n' \"$(root cat {RUN_DIR}/rc 2>/dev/null)\"; root cat {RUN_DIR}/out 2>/dev/null; echo cmux-tailnet-stderr; root tail -n 8 {RUN_DIR}/err 2>/dev/null; true"
    )
}

/// What one [`read_command`] answer says.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Progress {
    Running,
    Ended(Outcome),
}

pub fn read_answer(stdout: &str) -> Progress {
    let mut lines = stdout.splitn(2, '\n');
    let rc = lines
        .next()
        .unwrap_or_default()
        .trim()
        .strip_prefix("rc=")
        .unwrap_or_default()
        .trim()
        .to_owned();
    if rc.is_empty() {
        return Progress::Running;
    }
    let rest = lines.next().unwrap_or_default();
    let (out, err) = rest.split_once("cmux-tailnet-stderr\n").unwrap_or((rest, ""));
    match parse_joined(out) {
        Outcome::Failed(why) if rc != "0" => {
            let err = err.trim();
            Progress::Ended(Outcome::Failed(if err.is_empty() {
                format!("the join exited {rc}: {why}")
            } else {
                format!("the join exited {rc}: {err}")
            }))
        }
        outcome => Progress::Ended(outcome),
    }
}

/// The machine on the tailnet after a join.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Joined {
    /// The MagicDNS name without the trailing dot.
    pub dns_name: String,
    pub ips: Vec<String>,
    pub tags: Vec<String>,
    pub online: bool,
}

/// What the join script ended with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    Joined(Joined),
    /// The machine is on another tailnet and the user did not choose to switch; nothing changed.
    OtherTailnet {
        control_url: String,
    },
    Failed(String),
}

/// Reads the join script's output (stdout).
pub fn parse_joined(stdout: &str) -> Outcome {
    for line in stdout.lines().rev() {
        if let Some(url) = line.strip_prefix("cmux-tailnet: other-tailnet ") {
            return Outcome::OtherTailnet { control_url: url.trim().to_owned() };
        }
        let Some(json) = line.strip_prefix("cmux-tailnet-joined ") else { continue };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(json) else {
            return Outcome::Failed("tailscale status did not answer JSON".to_owned());
        };
        let state = value.get("BackendState").and_then(serde_json::Value::as_str);
        if state != Some("Running") {
            return Outcome::Failed(format!(
                "the node is {} after sign-in",
                state.unwrap_or("in an unknown state")
            ));
        }
        let null = serde_json::Value::Null;
        let me = value.get("Self").unwrap_or(&null);
        let strings = |v: &serde_json::Value| -> Vec<String> {
            v.as_array()
                .map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_owned)).collect())
                .unwrap_or_default()
        };
        return Outcome::Joined(Joined {
            dns_name: me
                .get("DNSName")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .trim_end_matches('.')
                .to_owned(),
            ips: me.get("TailscaleIPs").map(strings).unwrap_or_default(),
            tags: me.get("Tags").map(strings).unwrap_or_default(),
            online: me.get("Online").and_then(serde_json::Value::as_bool).unwrap_or(false),
        });
    }
    Outcome::Failed("the join script ended without a result".to_owned())
}

/// What the embedded node (`cmux-tailnet` `NodeConfig`) takes for a Mac or phone join. Tags, SSH and
/// Serve are system-Tailscale features; the embedded node is the app's own device.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EmbeddedOptions {
    pub hostname: Option<String>,
    pub auth_key: Secret,
    pub control_url: Option<String>,
    pub ephemeral: bool,
}

pub fn embedded_options(checked: &Checked) -> EmbeddedOptions {
    let r = &checked.request;
    EmbeddedOptions {
        hostname: r.hostname.clone(),
        auth_key: Secret::new(checked.key_file_contents()),
        control_url: r.control_url.clone(),
        ephemeral: r.ephemeral,
    }
}

#[cfg(test)]
mod tests;
