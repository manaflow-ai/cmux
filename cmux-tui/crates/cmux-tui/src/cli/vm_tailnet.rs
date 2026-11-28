//! `cmux vm tailnet join|leave VM`, `move FROM TO`: add a Cloud VM to the user's own tailnet, take
//! it off again, or hand its node to another VM (RFD 0169) (`cmux vm rm` does that first for a VM this machine joined). The plan, its checks and the
//! scripts are crate cmux-tailnet-join; this runs them over the VM API's file write and exec
//! (vm_bootstrap.rs's [`Guest`]). The key comes from a file or stdin, never an argument, and goes
//! to the VM only as a 0600 file the join deletes.

#[cfg(test)]
#[path = "vm_tailnet/tests.rs"]
mod tests;
#[path = "vm_tailnet/vault.rs"]
mod vault;

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_tailnet_join::mint::{self, Call, MintSource, MintSpec};
use cmux_tailnet_join::{
    Checked, Credential, JoinRequest, KEY_FILE, Outcome, Progress, SCRIPT_FILE, Secret, ServePort,
};
use serde_json::{Value, json};

use super::vm_bootstrap::Guest;

pub(super) const HELP: &str = "\
cmux vm tailnet connect VM (--key-file FILE | --key-stdin) [--hostname NAME] [options]
cmux vm tailnet join VM (--key-file FILE | --key-stdin) [options]
cmux vm tailnet leave VM
cmux vm tailnet move FROM TO [--timeout SECONDS]
cmux vm tailnet keep VM
cmux vm tailnet adopt VM [--take-over] [--timeout SECONDS]
cmux vm tailnet mint-key (--key-file FILE | --key-stdin) (--oauth | --headscale-api ...) --out FILE
cmux vm tailnet acl [--tag TAG]

Adds a Cloud VM to your own tailnet (Tailscale or Headscale), or takes it off.
`move` hands the node FROM holds to TO: same name, addresses and node key, no new
device and no key; FROM stops first and deletes its copy once TO is online.
Nothing changes your routes, exit nodes or ACLs.
`connect` makes your one stable cmux node: a join (Tailscale SSH on, never ephemeral, named
--hostname or YOU-cmux) that your vault keeps and VM holds, so `move`, `adopt` and `vm rm` carry
it from VM to VM. It needs you signed in to cmux and refuses while your vault keeps a node.

Signed in to cmux, your vault keeps your node (its state, encrypted to you) after a join
or move, so it outlives the VM: `keep` copies the node VM holds into the vault now,
`adopt` brings the vault's node up on VM (same name and addresses, no key), and
`cmux vm rm` of a VM joined here hands its node to the vault instead of signing it out.
The vault keeps one node; a join of another leaves it unless you run `keep`.
It also names the one VM that holds the node, so the node is never up twice: `adopt`
refuses while another VM holds it (`move` that VM instead, or `--take-over` if it is gone).

  --key-file FILE      your auth key (tskey-auth-…, or a Headscale key) or OAuth client secret
  --key-stdin          read it from stdin instead
  --oauth              the key is a Tailscale OAuth client secret (tskey-client-…); needs --tag.
                       This Mac mints a single-use key from it; only that key reaches the VM
  --headscale-api      the key is a Headscale API key for --login-server; this Mac mints a
                       single-use key from it for --headscale-user ID
  --headscale-user ID  the Headscale user (its id) the minted key belongs to
  --login-server URL   your Headscale (or other) server; default Tailscale's
  --hostname NAME      device name and MagicDNS label
  --tag TAG            an ACL tag your policy gives this key (repeatable)
  --ssh                turn on Tailscale SSH (who may use it is your ACL)
  --ephemeral          leave the tailnet when the VM goes offline
  --serve PORT[:HTTPS] show localhost:PORT on the tailnet over HTTPS (default 443)
  --funnel PORT[:HTTPS] the same, public on the internet through Funnel
  --allow-http         let --login-server be plain http:// (the key crosses unencrypted)
  --switch             join even if the VM is on another tailnet (adds a profile)
  --timeout SECONDS    how long to wait for the join (default 180)

mint-key takes --oauth or --headscale-api with --login-server, --headscale-user, --tag,
--ephemeral and --allow-http as above, and writes the minted key (single-use, pre-authorized,
10 minutes) to --out FILE, a new 0600 file.

acl prints the lines to paste into your tailnet policy for `connect`: TAG (default tag:cmux)
exists and your admins own it, your devices reach it, and Tailscale SSH lets you in.
";

#[derive(Debug, PartialEq, Eq)]
pub(super) enum KeySource {
    File(PathBuf),
    Stdin,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct JoinArgs {
    pub(super) vm_id: String,
    pub(super) key: KeySource,
    pub(super) oauth: bool,
    /// The key is a Headscale API key; minted keys belong to this user id.
    pub(super) headscale_user: Option<String>,
    pub(super) headscale_api: bool,
    pub(super) request: JoinRequest,
    pub(super) timeout: Duration,
}

/// `join`'s words after the VM id.
pub(super) fn parse_join(words: &[String]) -> Result<JoinArgs, String> {
    let mut words = words.iter();
    let vm_id = words
        .next()
        .filter(|w| !w.starts_with('-'))
        .cloned()
        .ok_or("cmux vm tailnet join needs a VM id")?;
    let mut key = None;
    let mut oauth = false;
    let mut headscale_api = false;
    let mut headscale_user = None;
    let mut request = JoinRequest {
        credential: Credential::AuthKey { key: Secret::new("") },
        control_url: None,
        hostname: None,
        tags: Vec::new(),
        ssh: false,
        ephemeral: false,
        serve: Vec::new(),
        switch_from_other_tailnet: false,
        allow_http: false,
    };
    let mut timeout = Duration::from_secs(180);
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        let mut value = || {
            inline.clone().or_else(|| words.next().cloned()).ok_or(format!("{flag} needs a value"))
        };
        match flag {
            "--key-file" => key = Some(KeySource::File(PathBuf::from(value()?))),
            "--key-stdin" => key = Some(KeySource::Stdin),
            "--oauth" => oauth = true,
            "--headscale-api" => headscale_api = true,
            "--headscale-user" => headscale_user = Some(value()?),
            "--login-server" => request.control_url = Some(value()?),
            "--hostname" => request.hostname = Some(value()?),
            "--tag" => request.tags.push(value()?),
            "--ssh" => request.ssh = true,
            "--ephemeral" => request.ephemeral = true,
            "--switch" => request.switch_from_other_tailnet = true,
            "--allow-http" => request.allow_http = true,
            "--serve" | "--funnel" => {
                request.serve.push(serve_port(&value()?, flag == "--funnel")?);
            }
            "--timeout" => {
                let secs: u64 =
                    value()?.parse().map_err(|_| "--timeout takes whole seconds".to_owned())?;
                timeout = Duration::from_secs(secs.clamp(10, 900));
            }
            "--auth-key" | "--key" => {
                return Err(
                    "a key on the command line ends up in shell history: use --key-file or --key-stdin"
                        .to_owned(),
                );
            }
            other => return Err(format!("unknown option {other} (cmux vm tailnet --help)")),
        }
    }
    let key = key.ok_or("cmux vm tailnet join needs --key-file FILE or --key-stdin")?;
    if oauth && headscale_api {
        return Err("--oauth and --headscale-api are two kinds of key; give one".to_owned());
    }
    if headscale_api && request.control_url.is_none() {
        return Err(
            "--headscale-api needs --login-server, the Headscale it is a key for".to_owned()
        );
    }
    if headscale_api && headscale_user.is_none() {
        return Err("--headscale-api needs --headscale-user ID (headscale users list)".to_owned());
    }
    Ok(JoinArgs { vm_id, key, oauth, headscale_user, headscale_api, request, timeout })
}

fn serve_port(text: &str, funnel: bool) -> Result<ServePort, String> {
    let bad = || format!("\"{text}\" is not PORT or PORT:HTTPS_PORT");
    let (local, https) = text.split_once(':').unwrap_or((text, "443"));
    Ok(ServePort {
        local_port: local.parse().map_err(|_| bad())?,
        https_port: https.parse().map_err(|_| bad())?,
        funnel,
    })
}

/// What `args` mints from, when the key is an admin credential rather than an auth key.
fn mint_source(args: &JoinArgs, secret: Secret) -> Result<MintSource, Secret> {
    if args.oauth {
        Ok(MintSource::TailscaleOauth { client_secret: secret })
    } else if args.headscale_api {
        Ok(MintSource::Headscale {
            server: args.request.control_url.clone().unwrap_or_default(),
            api_key: secret,
            user: args.headscale_user.clone().unwrap_or_default(),
        })
    } else {
        Err(secret)
    }
}

/// Reads the key and checks the request; the key is trimmed of its trailing newline. An OAuth
/// client or a Headscale API key is traded for a single-use key here (`mint_key`), so the join
/// only ever sends that key to the VM.
pub(super) fn checked(
    args: JoinArgs,
    read_key: impl FnOnce(&KeySource) -> Result<String, String>,
    mint_key: impl FnOnce(&MintSource, &MintSpec, bool) -> Result<Secret, String>,
) -> Result<Checked, String> {
    let text = read_key(&args.key)?;
    let secret = Secret::new(text.trim());
    let mut request = args.request.clone();
    let key = match mint_source(&args, secret) {
        Ok(source) => {
            if args.oauth {
                // The OAuth request's own checks (Tailscale only, tags) before any call.
                request.credential = Credential::OauthClient {
                    secret: match &source {
                        MintSource::TailscaleOauth { client_secret } => client_secret.clone(),
                        MintSource::Headscale { api_key, .. } => api_key.clone(),
                    },
                };
                request.clone().check().map_err(|e| e.0)?;
            }
            let spec = MintSpec { ephemeral: request.ephemeral, tags: request.tags.clone() };
            mint_key(&source, &spec, request.allow_http)?
        }
        Err(secret) => secret,
    };
    request.credential = Credential::AuthKey { key };
    request.check().map_err(|e| e.0)
}

/// Mints one key: checks the source, then the one or two HTTP calls.
pub(super) fn mint_key(
    source: &MintSource,
    spec: &MintSpec,
    allow_http: bool,
) -> Result<Secret, String> {
    let spec = mint::check_source(source, spec, allow_http).map_err(|e| e.0)?;
    match source {
        MintSource::TailscaleOauth { client_secret } => {
            let call = mint::tailscale_token_call(client_secret).map_err(|e| e.0)?;
            let token = mint::parse_token(&send(&call)?).map_err(|e| e.0)?;
            let answer = send(&mint::tailscale_key_call(&token, &spec))?;
            mint::parse_tailscale_key(&answer).map_err(|e| e.0)
        }
        MintSource::Headscale { server, api_key, user } => {
            cmux_egress::allow_named(server);
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs());
            let answer = send(&mint::headscale_key_call(server, api_key, user, &spec, now))?;
            mint::parse_headscale_key(&answer).map_err(|e| e.0)
        }
    }
}

/// Sends one mint call; answers the body of a 2xx, or words with the status. Never a redirect
/// (a key or token must not follow one).
fn send(call: &Call) -> Result<String, String> {
    let http = cmux_egress::client_builder("cmux_tui::vm_tailnet")
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| format!("making the HTTP client: {e}"))?;
    let mut request = http.post(&call.url);
    if let Some(bearer) = &call.bearer {
        let mut value =
            reqwest::header::HeaderValue::try_from(format!("Bearer {}", bearer.expose()))
                .map_err(|_| "the credential has characters a header cannot carry".to_owned())?;
        value.set_sensitive(true);
        request = request.header(reqwest::header::AUTHORIZATION, value);
    }
    if !call.form.is_empty() {
        let body: String = call
            .form
            .iter()
            .map(|(k, v)| format!("{k}={}", form_escape(v.expose())))
            .collect::<Vec<_>>()
            .join("&");
        request = request
            .header(reqwest::header::CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body(body);
    }
    if let Some(json) = &call.json {
        request = request.json(json);
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    let host = call.url.split('/').nth(2).unwrap_or_default().to_owned();
    runtime.block_on(async move {
        let answer = request.send().await.map_err(|e| format!("{host}: {e}"))?;
        let status = answer.status();
        let body = answer.text().await.map_err(|e| format!("{host}: {e}"))?;
        if status.is_success() {
            Ok(body)
        } else {
            let said: String = body.chars().take(200).collect();
            Err(format!("{host} answered {status}: {said}"))
        }
    })
}

fn form_escape(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// Writes `key` to a new file at `path`, 0600; an existing file or a symlink there is refused.
pub(super) fn write_new_key_file(path: &std::path::Path, key: &Secret) -> Result<(), String> {
    use std::io::Write as _;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|e| format!("creating {}: {e}", path.display()))?;
    file.write_all(key.expose().as_bytes())
        .and_then(|()| file.sync_all())
        .map_err(|e| format!("writing {}: {e}", path.display()))
}

/// `mint-key`'s words: the join's, with `--out FILE` in place of the VM id.
pub(super) fn parse_mint(words: &[String]) -> Result<(JoinArgs, PathBuf), String> {
    let mut out = None;
    let mut rest = vec!["mint".to_owned()];
    let mut words = words.iter();
    while let Some(word) = words.next() {
        if let Some(path) = word.strip_prefix("--out=") {
            out = Some(PathBuf::from(path));
        } else if word == "--out" {
            out = Some(PathBuf::from(words.next().ok_or("--out needs a value")?));
        } else {
            rest.push(word.clone());
        }
    }
    let out = out.ok_or("cmux vm tailnet mint-key needs --out FILE")?;
    let args = parse_join(&rest)?;
    if !args.oauth && !args.headscale_api {
        return Err("mint-key needs --oauth or --headscale-api".to_owned());
    }
    Ok((args, out))
}

fn read_key(source: &KeySource) -> Result<String, String> {
    use std::io::Read as _;
    let mut text = String::new();
    match source {
        KeySource::File(path) => std::fs::File::open(path)
            .and_then(|f| f.take(4096).read_to_string(&mut text))
            .map_err(|e| format!("reading {}: {e}", path.display()))?,
        KeySource::Stdin => std::io::stdin()
            .take(4096)
            .read_to_string(&mut text)
            .map_err(|e| format!("reading the key from stdin: {e}"))?,
    };
    Ok(text)
}

/// The join's steps on `guest`; `Ok` is the node's facts, `Err` why it did not join.
pub(super) fn join(
    guest: &mut dyn Guest,
    checked: &Checked,
    timeout: Duration,
) -> Result<Value, String> {
    let deadline = Instant::now() + timeout;
    let started = Instant::now();
    exec_ok(
        guest,
        &cmux_tailnet_join::prepare_command(cmux_cloud_start_core::machine_bootstrap::USER),
        "prepared",
    )?;
    guest
        .write(KEY_FILE, checked.key_file_contents().as_bytes(), 0o600)
        .map_err(|e| format!("writing the key file: {e}"))?;
    guest
        .write(SCRIPT_FILE, cmux_tailnet_join::vm_join_script(checked).as_bytes(), 0o700)
        .map_err(|e| format!("writing the join script: {e}"))?;
    exec_ok(guest, &cmux_tailnet_join::start_command(), "started")?;
    let (node, _) = await_detached(guest, deadline, timeout, Duration::from_secs(2), "join")?;
    Ok(json!({
        "dnsName": node.dns_name,
        "ips": node.ips,
        "tags": node.tags,
        "online": node.online,
        "elapsedMs": millis(started.elapsed()),
        "notes": checked.notes(),
    }))
}

fn millis(d: Duration) -> u64 {
    u64::try_from(d.as_millis()).unwrap_or(u64::MAX)
}

/// Reads a detached join or adopt run (`start_command`) every `poll` until it ends: the node, and
/// the run's last answer (for its clock lines).
fn await_detached(
    guest: &mut dyn Guest,
    deadline: Instant,
    timeout: Duration,
    poll: Duration,
    what: &str,
) -> Result<(cmux_tailnet_join::Joined, String), String> {
    let read = cmux_tailnet_join::read_command();
    let mut failures = 0;
    loop {
        if Instant::now() >= deadline {
            return Err(format!(
                "the {what} did not end in {} s (on the VM: systemctl status {})",
                timeout.as_secs(),
                cmux_tailnet_join::UNIT
            ));
        }
        guest.pause(poll);
        let answer = match guest.exec(&read) {
            Ok(answer) => answer,
            Err(error) => {
                failures += 1;
                if failures >= 3 {
                    return Err(format!("reading the {what}: {error}"));
                }
                continue;
            }
        };
        failures = 0;
        match cmux_tailnet_join::read_answer(&answer.stdout) {
            Progress::Running => continue,
            Progress::Ended(Outcome::Joined(node)) => return Ok((node, answer.stdout)),
            Progress::Ended(Outcome::OtherTailnet { control_url }) => {
                return Err(format!(
                    "the VM is already on another tailnet ({control_url}); nothing changed. Run again with --switch to add yours as a second profile."
                ));
            }
            Progress::Ended(Outcome::Failed(why)) => return Err(why),
        }
    }
}

// MARK: Move the node to another VM (RFD 0169 identity handoff)

/// `move`'s words: `FROM TO [--timeout SECONDS]`.
pub(super) fn parse_move(words: &[String]) -> Result<(String, String, Duration), String> {
    let mut ids = Vec::new();
    let mut timeout = Duration::from_secs(180);
    let mut it = words.iter();
    while let Some(word) = it.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        match flag {
            "--timeout" => {
                let value =
                    inline.or_else(|| it.next().cloned()).ok_or("--timeout needs seconds")?;
                let secs: u64 =
                    value.parse().map_err(|_| format!("--timeout {value} is not seconds"))?;
                timeout = Duration::from_secs(secs.max(1));
            }
            other if other.starts_with('-') => {
                return Err(format!("unknown option {other} (cmux vm tailnet --help)"));
            }
            id => ids.push(id.to_owned()),
        }
    }
    match ids.as_slice() {
        [from, to] if from != to => Ok((from.clone(), to.clone(), timeout)),
        [_, _] => Err("cmux vm tailnet move needs two different VMs".to_owned()),
        _ => Err("cmux vm tailnet move needs FROM and TO VM ids".to_owned()),
    }
}

/// Moves the node `from` holds to `to`: release, adopt, forget (restore on a failed adopt). `Ok`
/// is the node on `to` and the gap the user saw, measured on the machines.
pub(super) fn move_node(
    from: &mut dyn Guest,
    to: &mut dyn Guest,
    timeout: Duration,
) -> Result<Value, String> {
    use cmux_tailnet_join::handoff;
    let started = Instant::now();
    let deadline = started + timeout;
    // Ready the new holder first, so the gap holds only the swap.
    exec_ok(
        to,
        &cmux_tailnet_join::prepare_command(cmux_cloud_start_core::machine_bootstrap::USER),
        "prepared",
    )?;
    to.write(SCRIPT_FILE, handoff::vm_adopt_script().as_bytes(), 0o700)
        .map_err(|e| format!("writing the adopt script: {e}"))?;
    let released_answer = from.exec(&handoff::release_command())?;
    if released_answer.exit_code != 0 {
        let detail = released_answer.stderr.trim();
        return Err(format!(
            "the old VM did not release the node (exit {}): {detail}",
            released_answer.exit_code
        ));
    }
    let released = handoff::parse_released(&released_answer.stdout)?;
    let released_at = Instant::now();
    let adopted = (|| {
        to.write(handoff::STAGED_STATE_FILE, released.staged_contents().as_bytes(), 0o600)
            .map_err(|e| format!("writing the node state: {e}"))?;
        exec_ok(to, &cmux_tailnet_join::start_command(), "started")?;
        await_detached(to, deadline, timeout, Duration::from_millis(250), "move")
    })();
    let (node, answer) = match adopted {
        Ok(done) => done,
        Err(why) => {
            let back = match exec_ok(from, &handoff::restore_command(), "cmux-tailnet-restored") {
                Ok(()) => "the node is back on the old VM".to_owned(),
                Err(e) => format!("restarting it on the old VM failed too: {e}"),
            };
            return Err(format!("the new VM did not take the node ({why}); {back}"));
        }
    };
    let online_at = Instant::now();
    // The new holder is online: the old copy goes, so the node can never come up twice.
    let forgot = exec_ok(from, &handoff::forget_command(), "cmux-tailnet-forgot");
    let gap_ms = match (released.stopped_at_ms, handoff::online_at_ms(&answer)) {
        (Some(stop), Some(online)) => Some(online.saturating_sub(stop)),
        _ => None,
    };
    Ok(json!({
        "dnsName": node.dns_name,
        "ips": node.ips,
        "tags": node.tags,
        "online": node.online,
        "gapMs": gap_ms,
        "gapSeenMs": millis(online_at - released_at),
        "elapsedMs": millis(started.elapsed()),
        "oldCopyDeleted": forgot.is_ok(),
        "notes": forgot.err().map(|e| vec![format!("the old VM still holds a copy of the node state ({e}); delete {} there", handoff::STATE_FILE)]).unwrap_or_default(),
    }))
}

pub(super) fn leave(guest: &mut dyn Guest) -> Result<(), String> {
    let script = cmux_tailnet_join::vm_leave_script();
    let command = format!(
        "if [ \"$(id -u)\" = 0 ]; then sh -c {q}; else sudo -n sh -c {q}; fi",
        q = shell_quote(&script)
    );
    exec_ok(guest, &command, "cmux-tailnet-left")
}

fn exec_ok(guest: &mut dyn Guest, command: &str, said: &str) -> Result<(), String> {
    let ran = guest.exec(command)?;
    if ran.exit_code == 0 && ran.stdout.lines().any(|l| l.trim() == said) {
        return Ok(());
    }
    let detail = if ran.stderr.trim().is_empty() { ran.stdout.trim() } else { ran.stderr.trim() };
    Err(format!("exit {}: {detail}", ran.exit_code))
}

fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

// MARK: Which VMs this machine joined (so `vm rm` leaves first)

fn record_path(env: &dyn Fn(&str) -> Option<String>) -> Option<PathBuf> {
    let base =
        env("XDG_STATE_HOME").filter(|v| !v.is_empty()).map(PathBuf::from).or_else(|| {
            env("HOME").filter(|v| !v.is_empty()).map(|h| PathBuf::from(h).join(".local/state"))
        })?;
    Some(base.join("cmux/tailnet-joins.json"))
}

fn read_record(env: &dyn Fn(&str) -> Option<String>) -> BTreeMap<String, String> {
    record_path(env)
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

fn write_record(env: &dyn Fn(&str) -> Option<String>, record: &BTreeMap<String, String>) {
    let Some(path) = record_path(env) else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(path, serde_json::to_vec_pretty(record).unwrap_or_default());
}

/// True when this machine joined `vm_id` to a tailnet and it has not left.
pub(super) fn joined_here(env: &dyn Fn(&str) -> Option<String>, vm_id: &str) -> bool {
    read_record(env).contains_key(vm_id)
}

// MARK: The command

/// `cmux vm tailnet …`.
/// `acl`'s words: an optional `--tag TAG` (default `tag:cmux`, the tag `connect` asks for).
pub(super) fn parse_acl(words: &[String]) -> Result<String, String> {
    let mut tag = "tag:cmux".to_owned();
    let mut words = words.iter();
    while let Some(word) = words.next() {
        match word.split_once('=') {
            Some(("--tag", value)) => tag = value.to_owned(),
            _ if word == "--tag" => {
                tag = words.next().cloned().ok_or("--tag needs a value")?;
            }
            _ => return Err(format!("cmux vm tailnet acl: unknown argument {word}")),
        }
    }
    Ok(tag)
}

pub(super) fn run(
    words: &[String],
    json_output: bool,
    env: &dyn Fn(&str) -> Option<String>,
) -> i32 {
    let fail = |message: &str, code| {
        if json_output {
            println!("{}", json!({"ok": false, "error": message}));
        } else {
            eprintln!("cmux: {message}");
        }
        code
    };
    let (verb, tail) = match words.split_first() {
        Some((verb, tail)) if !matches!(verb.as_str(), "-h" | "--help" | "help") => {
            (verb.as_str(), tail)
        }
        _ => {
            print!("{HELP}");
            return 0;
        }
    };
    if tail.iter().any(|w| w == "-h" || w == "--help") {
        print!("{HELP}");
        return 0;
    }
    match verb {
        "join" => match parse_join(tail) {
            Ok(args) => join_verb(args, None, json_output, env, &fail),
            Err(message) => fail(&message, 2),
        },
        "connect" => {
            let args = match parse_connect(tail, env) {
                Ok(args) => args,
                Err(message) => return fail(&message, 2),
            };
            let vault = match vault::signed_in(env) {
                Ok(Some(vault)) => vault,
                Ok(None) => return fail(NOT_SIGNED_IN, 2),
                Err(message) => return fail(&message, 1),
            };
            if let Err(message) = may_connect(&vault, &args.vm_id) {
                return fail(&message, 2);
            }
            join_verb(args, Some(&vault as &dyn vault::NodeVault), json_output, env, &fail)
        }
        "leave" => {
            let Some(vm_id) = tail.first().filter(|w| !w.starts_with('-')) else {
                return fail("cmux vm tailnet leave needs a VM id", 2);
            };
            match with_guest(vm_id, env, leave) {
                Ok(()) => {
                    let mut record = read_record(env);
                    let name = record.remove(vm_id);
                    write_record(env, &record);
                    let note = name.and_then(|name| forget_signed_out(env, vm_id, &name));
                    if json_output {
                        println!(
                            "{}",
                            json!({"ok": true, "vm": vm_id, "notes": note.iter().collect::<Vec<_>>()})
                        );
                    } else {
                        println!("{vm_id} left your tailnet.");
                        if let Some(note) = note {
                            println!("Note: {note}");
                        }
                    }
                    0
                }
                Err(message) => fail(&message, 1),
            }
        }
        "move" => {
            let (from, to, timeout) = match parse_move(tail) {
                Ok(parsed) => parsed,
                Err(message) => return fail(&message, 2),
            };
            let result = with_guest(&from, env, |from_guest| {
                with_guest(&to, env, |to_guest| move_node(from_guest, to_guest, timeout))
            });
            match result {
                Ok(node) => {
                    let mut record = read_record(env);
                    let name = record.remove(&from).unwrap_or_else(|| {
                        node.get("dnsName").and_then(Value::as_str).unwrap_or_default().to_owned()
                    });
                    record.insert(to.clone(), name.clone());
                    write_record(env, &record);
                    let node = with_kept(node, auto_keep(&to, Some(&from), env, &name));
                    if json_output {
                        println!("{}", json!({"ok": true, "from": from, "vm": to, "node": node}));
                    } else {
                        println!(
                            "Moved {} from {from} to {to}.",
                            node.get("dnsName")
                                .and_then(Value::as_str)
                                .unwrap_or("your tailnet node")
                        );
                        match node.get("gapMs").and_then(Value::as_u64) {
                            Some(gap) => println!("Offline for {gap} ms (stop to online)."),
                            None => println!(
                                "Offline for about {} ms (seen from here).",
                                node.get("gapSeenMs").and_then(Value::as_u64).unwrap_or(0)
                            ),
                        }
                        for note in node
                            .get("notes")
                            .and_then(Value::as_array)
                            .into_iter()
                            .flatten()
                            .filter_map(Value::as_str)
                        {
                            println!("Note: {note}");
                        }
                    }
                    0
                }
                Err(message) => fail(&message, 1),
            }
        }
        "keep" => {
            let Some(vm_id) = tail.first().filter(|w| !w.starts_with('-')) else {
                return fail("cmux vm tailnet keep needs a VM id", 2);
            };
            let vault = match vault::signed_in(env) {
                Ok(Some(vault)) => vault,
                Ok(None) => return fail(NOT_SIGNED_IN, 2),
                Err(message) => return fail(&message, 1),
            };
            let Some(name) = read_record(env).get(vm_id.as_str()).cloned() else {
                return fail(
                    &format!("{vm_id} was not joined from here (cmux vm tailnet join {vm_id})"),
                    2,
                );
            };
            // Keeping a node on purpose makes this VM its holder, over any older lease.
            let kept = with_guest(vm_id, env, |guest| vault::keep(guest, &vault, &name))
                .and_then(|revision| vault::hold(&vault, vm_id, None, true).map(|_| revision));
            match kept {
                Ok(revision) => {
                    if json_output {
                        println!(
                            "{}",
                            json!({"ok": true, "vm": vm_id, "name": name, "revision": revision})
                        );
                    } else {
                        println!("Your vault keeps {name} (from {vm_id}).");
                    }
                    0
                }
                Err(message) => fail(&message, 1),
            }
        }
        "adopt" => {
            let (vm_id, take_over, timeout) = match parse_adopt(tail) {
                Ok(parsed) => parsed,
                Err(message) => return fail(&message, 2),
            };
            let vault = match vault::signed_in(env) {
                Ok(Some(vault)) => vault,
                Ok(None) => return fail(NOT_SIGNED_IN, 2),
                Err(message) => return fail(&message, 1),
            };
            let record = read_record(env);
            let refusal = refuse_second_holder(&record, &vault, &vm_id);
            if let Some(refusal) = refusal.filter(|_| !take_over) {
                return fail(&refusal, 2);
            }
            match with_guest(&vm_id, env, |guest| {
                vault::adopt(guest, &vault, &vm_id, take_over, timeout)
            }) {
                Ok((node, name)) => {
                    let mut record = read_record(env);
                    let dns = node.get("dnsName").and_then(Value::as_str).filter(|d| !d.is_empty());
                    record.insert(vm_id.clone(), dns.unwrap_or(&name).to_owned());
                    write_record(env, &record);
                    if json_output {
                        println!(
                            "{}",
                            json!({"ok": true, "vm": vm_id, "name": name, "node": node})
                        );
                    } else {
                        println!(
                            "{vm_id} is {} again, from your vault ({} ms).",
                            node.get("dnsName").and_then(Value::as_str).unwrap_or(&name),
                            node.get("elapsedMs").and_then(Value::as_u64).unwrap_or(0)
                        );
                    }
                    0
                }
                Err(message) => fail(&message, 1),
            }
        }
        "acl" => match parse_acl(tail) {
            Ok(tag) => match cmux_tailnet_join::acl_snippet(&tag) {
                Ok(acl) => {
                    if json_output {
                        println!("{}", json!({"ok": true, "tag": tag, "acl": acl}));
                    } else {
                        println!("{acl}");
                    }
                    0
                }
                Err(invalid) => fail(&invalid.to_string(), 2),
            },
            Err(message) => fail(&message, 2),
        },
        "mint-key" => {
            let (args, out) = match parse_mint(tail) {
                Ok(parsed) => parsed,
                Err(message) => return fail(&message, 2),
            };
            let ephemeral = args.request.ephemeral;
            let minted = checked(args, read_key, mint_key).and_then(|checked| {
                let Credential::AuthKey { key } = &checked.request().credential else {
                    return Err("the mint gave no key".to_owned());
                };
                write_new_key_file(&out, key)
            });
            match minted {
                Ok(()) => {
                    if json_output {
                        println!(
                            "{}",
                            json!({"ok": true, "out": out, "reusable": false, "preauthorized": true,
                                   "ephemeral": ephemeral, "expiresInSecs": mint::KEY_TTL_SECS})
                        );
                    } else {
                        println!(
                            "Wrote a single-use key to {} (expires in {} min).",
                            out.display(),
                            mint::KEY_TTL_SECS / 60
                        );
                    }
                    0
                }
                Err(message) => fail(&message, 1),
            }
        }
        other => fail(
            &format!(
                "unknown tailnet verb \"{other}\"; verbs: join, leave, move, keep, adopt, mint-key"
            ),
            2,
        ),
    }
}

/// Before `cmux vm rm VM`: leave the tailnet when this machine joined it. Never stops the delete.
/// The VM a `fork VM` or `snapshot create VM` copies, if the words are one.
pub(super) fn cloned_vm(rest: &[String]) -> Option<&str> {
    let id = match rest {
        [verb, id, ..] if verb == "fork" => id,
        [verb, sub, id, ..] if verb == "snapshot" && sub == "create" => id,
        _ => return None,
    };
    (!id.starts_with('-')).then_some(id.as_str())
}

/// A copy of a VM on the user's tailnet carries its node key (`tailscaled.state`): the copy
/// would come up as the same node and the two would fight. Refuse until the VM has left.
pub(super) fn refuse_clone_of_joined(
    vm_id: &str,
    env: &dyn Fn(&str) -> Option<String>,
) -> Option<String> {
    joined_here(env, vm_id).then(|| {
        format!(
            "cmux: {vm_id} is on your tailnet; a copy would carry its node key and come up as the same node. Run `cmux vm tailnet leave {vm_id}` first, copy it, then join each again."
        )
    })
}

pub(super) fn leave_before_delete(vm_id: &str, env: &dyn Fn(&str) -> Option<String>) {
    let Some(name) = read_record(env).get(vm_id).cloned() else {
        return;
    };
    match release_before_delete(vm_id, env, &name) {
        Ok(Some(_)) => {
            eprintln!(
                "cmux: your vault keeps {vm_id}'s tailnet node {name}; `cmux vm tailnet adopt VM` brings it back"
            );
            let mut record = read_record(env);
            record.remove(vm_id);
            write_record(env, &record);
            return;
        }
        Ok(None) => {}
        Err(error) => eprintln!("cmux: {error}; signing {vm_id} out of your tailnet instead"),
    }
    match with_guest(vm_id, env, leave) {
        Ok(()) => {
            eprintln!("cmux: {vm_id} left your tailnet");
            if let Some(note) = forget_signed_out(env, vm_id, &name) {
                eprintln!("cmux: {note}");
            }
        }
        Err(error) => {
            eprintln!("cmux: {vm_id} could not leave your tailnet ({error}); deleting it anyway");
            // The VM goes either way, so it holds the node no more.
            let signed_in = vault::signed_in(env).ok().flatten();
            if let Some(Err(why)) = signed_in.map(|vault| vault::let_go(&vault, vm_id)) {
                eprintln!("cmux: your vault still names {vm_id} the node's holder ({why})");
            }
        }
    }
    let mut record = read_record(env);
    record.remove(vm_id);
    write_record(env, &record);
}

/// `vm resume|start` succeeded: a VM paused while it ran the node comes back from its memory
/// snapshot with `tailscaled` still up. When the vault's lease moved to another VM meanwhile, stop
/// the node here so two VMs never run one node. Best effort: any failure is a warning and the
/// resume's own result stands.
pub(super) fn stand_down_if_moved(vm_id: &str, env: &dyn Fn(&str) -> Option<String>) {
    let Some(name) = read_record(env).get(vm_id).cloned() else {
        return;
    };
    let signed = vault::signed_in(env);
    let signed = signed.as_ref().map(|signed| signed.as_ref().map(|v| v as &dyn vault::NodeVault));
    let (note, stood_down) =
        settle_resumed(signed, vm_id, &name, |vm| with_guest(vm, env, vault::stand_down));
    if let Some(note) = note {
        eprintln!("cmux: {note}");
    }
    if stood_down {
        let mut record = read_record(env);
        record.remove(vm_id);
        write_record(env, &record);
    }
}

/// The note to print and whether `vm_id` stopped running the node `name`.
fn settle_resumed(
    vault: Result<Option<&dyn vault::NodeVault>, &String>,
    vm_id: &str,
    name: &str,
    stand_down: impl FnOnce(&str) -> Result<(), String>,
) -> (Option<String>, bool) {
    let checked = match vault {
        Ok(Some(vault)) => vault::moved_away(vault, vm_id, name),
        Ok(None) => return (None, false),
        Err(why) => Err(why.clone()),
    };
    match checked {
        Ok(None) => (None, false),
        Ok(Some(holder)) => match stand_down(vm_id) {
            Ok(()) => (
                Some(format!(
                    "{holder} holds your tailnet node now (your vault's lease); {vm_id} resumed still running it, so its node was stopped"
                )),
                true,
            ),
            Err(why) => (
                Some(format!(
                    "{holder} holds your tailnet node now, but {vm_id} resumed still running it and did not stop ({why}); run `cmux vm tailnet leave {vm_id}` only if {holder} is gone"
                )),
                false,
            ),
        },
        Err(why) => (
            Some(format!(
                "could not check your vault's tailnet lease after resuming {vm_id} ({why})"
            )),
            false,
        ),
    }
}

// MARK: The vault keeps the node (RFD 0169)

/// `connect`'s words: `join`'s, for the one stable node. Tailscale SSH is on, the node is never
/// ephemeral (it outlives every VM that holds it), and it is named `--hostname` or `YOU-cmux`.
pub(super) fn parse_connect(
    words: &[String],
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<JoinArgs, String> {
    let mut args =
        parse_join(words).map_err(|why| why.replace("tailnet join", "tailnet connect"))?;
    if args.request.ephemeral {
        return Err(
            "connect makes the node that outlives your VMs, so it is never --ephemeral; use `cmux vm tailnet join --ephemeral` for a throwaway node"
                .to_owned(),
        );
    }
    args.request.ssh = true;
    if args.request.hostname.is_none() {
        args.request.hostname = Some(stable_name(env));
    }
    Ok(args)
}

/// `YOU-cmux`, YOU this machine's user as a DNS label; `cmux` when there is none.
pub(super) fn stable_name(env: &dyn Fn(&str) -> Option<String>) -> String {
    let user = env("USER").or_else(|| env("USERNAME")).unwrap_or_default();
    let mut label = String::new();
    for c in user.trim().to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            label.push(c);
        } else if !label.is_empty() && !label.ends_with('-') {
            label.push('-');
        }
    }
    let label = label.trim_end_matches('-');
    // A DNS label is at most 63 bytes; `-cmux` takes 5.
    let label = &label[..label.len().min(58)];
    if label.is_empty() {
        "cmux".to_owned()
    } else {
        format!("{}-cmux", label.trim_end_matches('-'))
    }
}

/// May `connect` make a node? Not while the vault keeps one: that node moves with `adopt`, and a
/// second would be a second device with the same purpose.
pub(super) fn may_connect(vault: &dyn vault::NodeVault, vm_id: &str) -> Result<(), String> {
    match vault.get()? {
        Some(kept) => Err(format!(
            "your vault already keeps your node {}; `cmux vm tailnet adopt {vm_id}` brings it up on {vm_id} with no key (`leave` the VM that holds it first to start over)",
            kept.name
        )),
        None => Ok(()),
    }
}

const NOT_SIGNED_IN: &str =
    "your vault needs you signed in to cmux (CMUX_CLOUD_ACCESS_TOKEN); nothing changed";

/// `adopt`'s words: `VM [--take-over] [--timeout SECONDS]`.
pub(super) fn parse_adopt(words: &[String]) -> Result<(String, bool, Duration), String> {
    let mut ids = Vec::new();
    let mut take_over = false;
    let mut timeout = Duration::from_secs(180);
    let mut it = words.iter();
    while let Some(word) = it.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        match flag {
            "--timeout" => {
                let value =
                    inline.or_else(|| it.next().cloned()).ok_or("--timeout needs seconds")?;
                let secs: u64 =
                    value.parse().map_err(|_| format!("--timeout {value} is not seconds"))?;
                timeout = Duration::from_secs(secs.max(1));
            }
            "--take-over" if inline.is_none() => take_over = true,
            other if other.starts_with('-') => {
                return Err(format!("unknown option {other} (cmux vm tailnet --help)"));
            }
            id => ids.push(id.to_owned()),
        }
    }
    match ids.as_slice() {
        [vm] => Ok((vm.clone(), take_over, timeout)),
        _ => Err("cmux vm tailnet adopt needs one VM id".to_owned()),
    }
}

/// The vault's node may be up on one VM at a time: refuse when a VM joined here holds it.
fn refuse_second_holder(
    record: &BTreeMap<String, String>,
    vault: &dyn vault::NodeVault,
    vm_id: &str,
) -> Option<String> {
    let kept = match vault.get() {
        Ok(Some(kept)) => kept.name,
        _ => return None,
    };
    record.iter().find(|(_, name)| vault::label(name) == vault::label(&kept)).map(|(holder, _)| {
        if holder == vm_id {
            format!("{vm_id} already holds your vault's node {kept}")
        } else {
            format!(
                "{holder} holds your vault's node {kept}; run `cmux vm tailnet move {holder} {vm_id}` instead, so it is never up twice"
            )
        }
    })
}

/// `join` and `connect` once their words are read: join the VM, record its node, and have the
/// vault keep it. `connect` passes its `vault`, and a node that vault does not keep fails it;
/// `join` keeps it best effort (when signed in), with a note when it did not.
fn join_verb(
    args: JoinArgs,
    vault: Option<&dyn vault::NodeVault>,
    json_output: bool,
    env: &dyn Fn(&str) -> Option<String>,
    fail: &dyn Fn(&str, i32) -> i32,
) -> i32 {
    let vm_id = args.vm_id.clone();
    let timeout = args.timeout;
    let checked = match checked(args, read_key, mint_key) {
        Ok(checked) => checked,
        Err(message) => return fail(&message, 2),
    };
    let result = with_guest(&vm_id, env, |guest| join(guest, &checked, timeout));
    match result {
        Ok(node) => {
            let mut record = read_record(env);
            record.insert(
                vm_id.clone(),
                node.get("dnsName").and_then(Value::as_str).unwrap_or_default().to_owned(),
            );
            write_record(env, &record);
            let kept = match vault {
                Some(vault) => keep_in(vault, &vm_id, None, env, &record[&vm_id]),
                None => auto_keep(&vm_id, None, env, &record[&vm_id]),
            };
            if vault.is_some()
                && let Err(why) = &kept
            {
                return fail(
                    &format!(
                        "{vm_id} joined your tailnet as {}, but your vault did not keep it ({why}); run `cmux vm tailnet keep {vm_id}`",
                        record[&vm_id]
                    ),
                    1,
                );
            }
            let node = with_kept(node, kept);
            if json_output {
                println!("{}", json!({"ok": true, "vm": vm_id, "node": node}));
            } else {
                println!(
                    "Joined {vm_id} to your tailnet as {}.",
                    node.get("dnsName").and_then(Value::as_str).unwrap_or("?")
                );
                if let Some(ips) = node.get("ips").and_then(Value::as_array) {
                    let ips: Vec<&str> = ips.iter().filter_map(Value::as_str).collect();
                    println!("Addresses: {}", ips.join(", "));
                }
                for note in node
                    .get("notes")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                {
                    println!("Note: {note}");
                }
            }
            0
        }
        Err(message) => fail(&message, 1),
    }
}

/// After a join or move: the vault keeps the node, when signed in and it keeps no other node. The
/// note says what happened when it did not.
fn auto_keep(
    vm_id: &str,
    from: Option<&str>,
    env: &dyn Fn(&str) -> Option<String>,
    name: &str,
) -> Result<bool, String> {
    let Some(vault) = vault::signed_in(env)? else { return Ok(false) };
    keep_in(&vault, vm_id, from, env, name)
}

/// The vault keeps the node VM holds as `name`, and VM holds its lease (taken over from `from`).
fn keep_in(
    vault: &dyn vault::NodeVault,
    vm_id: &str,
    from: Option<&str>,
    env: &dyn Fn(&str) -> Option<String>,
    name: &str,
) -> Result<bool, String> {
    keep_unless_other(vault, name, |kept_in| {
        let revision = with_guest(vm_id, env, |guest| vault::keep(guest, kept_in, name))?;
        // The VM the node is on now holds the vault's lease; a move takes it over from FROM.
        vault::hold(kept_in, vm_id, from, false)?;
        Ok(revision)
    })
}

fn keep_unless_other(
    vault: &dyn vault::NodeVault,
    name: &str,
    keep: impl FnOnce(&dyn vault::NodeVault) -> Result<u64, String>,
) -> Result<bool, String> {
    if let Some(other) = vault::holds_other(vault, name)? {
        return Err(format!(
            "your vault keeps {other}, so it was left as is; `cmux vm tailnet keep VM` keeps this node instead"
        ));
    }
    keep(vault).map(|_| true)
}

/// The node's facts with whether the vault kept it, and why not as a note.
fn with_kept(mut node: Value, kept: Result<bool, String>) -> Value {
    let Some(facts) = node.as_object_mut() else { return node };
    facts.insert("keptInVault".to_owned(), json!(matches!(kept, Ok(true))));
    if let Err(why) = kept {
        let note = json!(format!("not kept in your vault: {why}"));
        match facts.get_mut("notes").and_then(Value::as_array_mut) {
            Some(notes) => notes.push(note),
            None => {
                facts.insert("notes".to_owned(), json!([note]));
            }
        }
    }
    node
}

/// `leave` signed the node out, so a kept copy of it opens nothing: drop it from the vault.
fn forget_signed_out(
    env: &dyn Fn(&str) -> Option<String>,
    vm_id: &str,
    name: &str,
) -> Option<String> {
    let vault = vault::signed_in(env).ok()??;
    drop_if_kept(&vault, vm_id, name)
}

fn drop_if_kept(vault: &dyn vault::NodeVault, vm_id: &str, name: &str) -> Option<String> {
    if let Err(why) = vault::let_go(vault, vm_id) {
        return Some(format!("your vault still names {vm_id} the node's holder ({why})"));
    }
    match vault.get() {
        Ok(Some(kept)) if vault::label(&kept.name) == vault::label(name) => vault
            .delete()
            .err()
            .map(|why| format!("your vault still keeps the signed-out node ({why})")),
        _ => None,
    }
}

/// `vm rm`: hand the node to the vault when signed in and the vault keeps no other node. `Ok(None)`
/// when it was not asked to (the caller signs the VM out as before).
fn release_before_delete(
    vm_id: &str,
    env: &dyn Fn(&str) -> Option<String>,
    name: &str,
) -> Result<Option<u64>, String> {
    let Some(vault) = vault::signed_in(env)? else { return Ok(None) };
    if vault::holds_other(&vault, name)?.is_some() {
        return Ok(None);
    }
    with_guest(vm_id, env, |guest| vault::release_to_vault(guest, &vault, vm_id, name))
        .map(Some)
        .map_err(|why| format!("your vault did not take {vm_id}'s tailnet node ({why})"))
}

fn with_guest<T>(
    vm_id: &str,
    env: &dyn Fn(&str) -> Option<String>,
    body: impl FnOnce(&mut dyn Guest) -> Result<T, String>,
) -> Result<T, String> {
    let runtime =
        super::vm::client_runtime().map_err(|e| format!("cannot start the VM client: {e}"))?;
    let mut stderr = std::io::stderr();
    let guest = cmux_vm::guest::Guest::connect(None, None, None, env, &mut stderr)
        .map_err(|e| e.message)?;
    let mut api =
        super::vm_bootstrap::ApiGuest { runtime: &runtime, guest, vm_id: vm_id.to_owned() };
    body(&mut api)
}
