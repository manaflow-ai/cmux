//! `cmux vm tailnet join|leave VM`: add a Cloud VM to the user's own tailnet, and take it off
//! again (`cmux vm rm` does that first for a VM this machine joined). The plan, its checks and the
//! scripts are crate cmux-tailnet-join; this runs them over the VM API's file write and exec
//! (vm_bootstrap.rs's [`Guest`]). The key comes from a file or stdin, never an argument, and goes
//! to the VM only as a 0600 file the join deletes.

#[cfg(test)]
#[path = "vm_tailnet/tests.rs"]
mod tests;

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_tailnet_join::{
    Checked, Credential, JoinRequest, KEY_FILE, Outcome, Progress, SCRIPT_FILE, Secret, ServePort,
};
use serde_json::{Value, json};

use super::vm_bootstrap::Guest;

pub(super) const HELP: &str = "\
cmux vm tailnet join VM (--key-file FILE | --key-stdin) [options]
cmux vm tailnet leave VM

Adds a Cloud VM to your own tailnet (Tailscale or Headscale), or takes it off.
Nothing changes your routes, exit nodes or ACLs. `cmux vm rm` leaves first for a VM joined here.

  --key-file FILE      your auth key (tskey-auth-…, or a Headscale key) or OAuth client secret
  --key-stdin          read it from stdin instead
  --oauth              the key is an OAuth client secret (tskey-client-…); needs --tag
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
    Ok(JoinArgs { vm_id, key, oauth, request, timeout })
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

/// Reads the key and checks the request; the key is trimmed of its trailing newline.
pub(super) fn checked(
    args: JoinArgs,
    read_key: impl FnOnce(&KeySource) -> Result<String, String>,
) -> Result<Checked, String> {
    let text = read_key(&args.key)?;
    let secret = Secret::new(text.trim());
    let mut request = args.request;
    request.credential = if args.oauth {
        Credential::OauthClient { secret }
    } else {
        Credential::AuthKey { key: secret }
    };
    request.check().map_err(|e| e.0)
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
    let read = cmux_tailnet_join::read_command();
    let mut failures = 0;
    loop {
        if Instant::now() >= deadline {
            return Err(format!(
                "the join did not end in {} s (on the VM: systemctl status {})",
                timeout.as_secs(),
                cmux_tailnet_join::UNIT
            ));
        }
        guest.pause(Duration::from_secs(2));
        let answer = match guest.exec(&read) {
            Ok(answer) => answer,
            Err(error) => {
                failures += 1;
                if failures >= 3 {
                    return Err(format!("reading the join: {error}"));
                }
                continue;
            }
        };
        failures = 0;
        match cmux_tailnet_join::read_answer(&answer.stdout) {
            Progress::Running => continue,
            Progress::Ended(Outcome::Joined(node)) => {
                return Ok(json!({
                    "dnsName": node.dns_name,
                    "ips": node.ips,
                    "tags": node.tags,
                    "online": node.online,
                    "elapsedMs": u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
                    "notes": checked.notes(),
                }));
            }
            Progress::Ended(Outcome::OtherTailnet { control_url }) => {
                return Err(format!(
                    "the VM is already on another tailnet ({control_url}); nothing changed. Run again with --switch to add yours as a second profile."
                ));
            }
            Progress::Ended(Outcome::Failed(why)) => return Err(why),
        }
    }
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
        "join" => {
            let args = match parse_join(tail) {
                Ok(args) => args,
                Err(message) => return fail(&message, 2),
            };
            let vm_id = args.vm_id.clone();
            let timeout = args.timeout;
            let checked = match checked(args, read_key) {
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
        "leave" => {
            let Some(vm_id) = tail.first().filter(|w| !w.starts_with('-')) else {
                return fail("cmux vm tailnet leave needs a VM id", 2);
            };
            match with_guest(vm_id, env, leave) {
                Ok(()) => {
                    let mut record = read_record(env);
                    record.remove(vm_id);
                    write_record(env, &record);
                    if json_output {
                        println!("{}", json!({"ok": true, "vm": vm_id}));
                    } else {
                        println!("{vm_id} left your tailnet.");
                    }
                    0
                }
                Err(message) => fail(&message, 1),
            }
        }
        other => fail(&format!("unknown tailnet verb \"{other}\"; verbs: join, leave"), 2),
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
    if !joined_here(env, vm_id) {
        return;
    }
    match with_guest(vm_id, env, leave) {
        Ok(()) => eprintln!("cmux: {vm_id} left your tailnet"),
        Err(error) => {
            eprintln!("cmux: {vm_id} could not leave your tailnet ({error}); deleting it anyway");
        }
    }
    let mut record = read_record(env);
    record.remove(vm_id);
    write_record(env, &record);
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
