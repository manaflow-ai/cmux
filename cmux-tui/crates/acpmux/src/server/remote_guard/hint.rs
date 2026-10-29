//! A peer's refusal of a `session/new` this daemon forwarded (`acpmux new --host HOST`) says
//! what works instead: `data.try` is a command to copy, and the message ends with it (Leo,
//! 2026-10-24: "we improve the instructions and the error messages and the hints"). The
//! peer's rules (`remote_guard.rs`) stay as they are; only the way out is named:
//!
//! - from a peer that serves this daemon as a remote Web client (`data.servedAs`), or a
//!   policy that skips asking: the same start on HOST itself, where its own unix socket
//!   accepts it (`ssh -- DEST '...'` for an `ssh://` peer; else the command with
//!   `data.runOn: HOST`), with its folder made first;
//! - from a peer that serves it as a peer, a folder outside its roots: the same start in the
//!   folder the peer checked (`data.tryCwd`), else with no folder (a scratch folder there).
//!
//! A mode is never taken at a remote start, nor by HOST's own CLI (not the person), so no
//! suggestion keeps one: the session starts in the harness's asking mode. The peer judges a
//! new session's folder before its policy and mode, so one refusal covers every field. A peer
//! on an older build names no `reason` (its message is read instead) and judged the mode
//! before the folder: its way out is HOST's own CLI in the shell's own folder.

use crate::rpc::RpcError;
use serde_json::{Value, json};

/// Why a remote `session/new` was refused, in `data.reason`: the daemon that forwarded it
/// turns each into a command that works (below).
pub(crate) const POLICY_REFUSED: &str = "remote.policy_refused";
pub(crate) const MODE_REFUSED: &str = "remote.mode_refused";
pub(crate) const CWD_MISSING: &str = "remote.cwd_missing";
pub(crate) const CWD_OUTSIDE_ROOTS: &str = "remote.cwd_outside_roots";

/// `remote_guard::check_inner`. A refused remote `session/new` (`remote.*`) says how this
/// daemon served the caller (`data.servedAs`: `peer` or `remote`), for the forwarding
/// daemon's hint.
pub(in crate::server) async fn check(
    hub: &std::sync::Arc<crate::hub::Hub>,
    origin: crate::server::Origin,
    auth: crate::server::ConnAuth,
    device: Option<&str>,
    m: &str,
    params: &mut Value,
) -> Result<(), RpcError> {
    let peer = super::control_of(origin, auth, params) == crate::hub::Control::Peer;
    let mut result = super::check_inner(hub, origin, auth, device, m, params).await;
    if m == crate::rpc::method::SESSION_NEW
        && origin.web_class()
        && let Err(e) = &mut result
        && let Some(Value::Object(data)) = &mut e.data
        && data.get("reason").and_then(Value::as_str).is_some_and(|r| r.starts_with("remote."))
    {
        data.insert("servedAs".into(), Value::from(if peer { "peer" } else { "remote" }));
    }
    result
}

/// `peer`'s answer to the `session/new` `p` this daemon forwarded for `params`, a refusal
/// explained.
pub(in crate::server) async fn new_on(
    peer: &crate::peer::Peer,
    params: &Value,
    p: Value,
) -> Result<Value, RpcError> {
    let method = crate::rpc::method::SESSION_NEW;
    let web = via_web(&p);
    peer.request(method, p).await.map_err(|e| {
        let (build, served_peer) =
            (peer.remote_build(), peer.served_as().as_deref() == Some("peer"));
        update_first(&e, &peer.name, build.as_deref(), served_peer && !web, params)
            .unwrap_or_else(|| explain(peer, params, e))
    })
}

/// Whether this daemon forwarded `p` for a Web client (`mark_forwarded`'s `via: web`): the
/// peer runs such a start under Web rules on any build, so no update gives it a scratch folder.
fn via_web(p: &Value) -> bool {
    p.pointer("/_meta/acpmux/via").and_then(Value::as_str) == Some("web")
}

/// `e`, with `data.host`, `data.try` (and `data.runOn` when it runs on HOST) and the command
/// at the end of its message, when it is one of the refusals above; any other error unchanged.
fn explain(peer: &crate::peer::Peer, params: &Value, e: RpcError) -> RpcError {
    let Some(reason) = reason_of(&e) else { return e };
    let data = e.data.as_ref();
    // `peer` or `remote`; an older peer does not say.
    let served = data.and_then(|d| d.get("servedAs")).and_then(Value::as_str);
    // A folder inside its roots the peer checked for this start (`peer_folder::outside_told`).
    let try_cwd = data.and_then(|d| d.get("tryCwd")).and_then(Value::as_str);
    let ssh = crate::peer::ssh_target(&peer.url).ok().map(|t| t.destination);
    let mut run_on = None;
    // `missing` (mkdir -p makes it) or `unusable`; an older peer does not say.
    let cause = data.and_then(|d| d.get("cause")).and_then(Value::as_str);
    let found = Found { served, try_cwd, cause };
    let (command, why) = match suggest(&Start::of(params), &reason, found) {
        Hint::Here(start) => {
            (command(params, &start, Some(&peer.name), false).render(None), String::new())
        }
        Hint::OnHost(start) => {
            let then = start
                .name
                .as_ref()
                .map(|n| format!(", then reach it from here as {}/{n}", peer.name))
                .unwrap_or_default();
            let served = if served == Some("remote") {
                format!(" ({} serves this daemon as a remote client, not as a peer)", peer.name)
            } else {
                String::new()
            };
            if ssh.is_none() {
                run_on = Some(peer.name.clone());
            }
            (
                command(params, &start, None, true).render(ssh.as_deref()),
                format!("{served}: run it on {} itself{then}", peer.name),
            )
        }
    };
    let message = format!("{}{why}; instead: {command}", e.message);
    let mut data = match e.data {
        Some(Value::Object(o)) => Value::Object(o),
        _ => json!({}),
    };
    data["reason"] = json!(reason);
    data["host"] = json!(peer.name);
    data["try"] = json!(command);
    if let Some(host) = run_on {
        data["runOn"] = json!(host);
    }
    RpcError::new(e.code, message).with_data(data)
}

/// A start with no folder that `peer_name` refused as outside its roots, from a peer of
/// another build that serves this daemon as a peer (`served_peer`: its handshake, for a start
/// this daemon did not forward for a Web client) but names no
/// `servedAs` in the refusal: one older than the peer scratch folder (#24442), which treats
/// an absent folder as the home folder. Its way out is updating it once no session there is
/// mid-turn (`--if-idle`), then the same command;
/// the peer's own folder rule is unchanged. None for any other refusal.
fn update_first(
    e: &RpcError,
    peer_name: &str,
    build: Option<&str>,
    served_peer: bool,
    params: &Value,
) -> Option<RpcError> {
    let named_folder = params.get("cwd").is_some_and(|c| !c.is_null());
    let served = e.data.as_ref().and_then(|d| d.get("servedAs")).is_some();
    if !served_peer || named_folder || served || build == Some(crate::hub::BUILD) {
        return None;
    }
    if reason_of(e).as_deref() != Some(CWD_OUTSIDE_ROOTS) {
        return None;
    }
    // `--if-idle`: the update never restarts the peer under a session mid-turn there.
    let update = format!("acpmux host update {peer_name} --if-idle");
    let then = command(params, &Start::of(params), Some(peer_name), false).render(None);
    let message = format!(
        "{}: {peer_name} runs acpmux build {} (this daemon: {}), from before a start with no folder runs in a scratch folder there; run `{update}`, then `{then}`",
        e.message,
        build.unwrap_or("unknown"),
        crate::hub::BUILD
    );
    Some(RpcError::new(e.code, message).with_data(json!({
        "reason": "peer_version_skew",
        "refused": CWD_OUTSIDE_ROOTS,
        "host": peer_name,
        "try": update,
        "then": then,
    })))
}

/// `inner` as run on the peer's machine: through ssh to `dest` (an `ssh://` peer's checked
/// destination, after `--` so it is never read as an option), else as it is, for that machine.
fn on_host(dest: Option<&str>, inner: &str) -> String {
    match dest {
        Some(dest) => format!("ssh -- {} {}", quote(dest), quote(inner)),
        None => inner.to_owned(),
    }
}

/// The refusal's reason, from its data or, from a peer on an older build, its message.
fn reason_of(e: &RpcError) -> Option<String> {
    let named = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
    if let Some(r) = named
        && r.starts_with("remote.")
    {
        return Some(r.to_owned());
    }
    let m = e.message.as_str();
    if m.starts_with("a permission policy other than ask or deny-all is accepted only") {
        Some(POLICY_REFUSED.to_owned())
    } else if m.starts_with("a mode at session start is accepted only") {
        Some(MODE_REFUSED.to_owned())
    } else if m.starts_with("cwd is refused: from a WebSocket connection it must be") {
        Some(CWD_MISSING.to_owned())
    } else if m.starts_with("cwd is refused: a remote WebSocket connection may use only") {
        Some(CWD_OUTSIDE_ROOTS.to_owned())
    } else {
        None
    }
}

/// A command and optional prompt-file input, rendered together only at the outer shell.
struct Retry {
    command: String,
    input: Option<String>,
}

impl Retry {
    fn render(&self, ssh: Option<&str>) -> String {
        let command = on_host(ssh, &self.command);
        match &self.input {
            // Keep file text outside ssh's command argument: accepted files can be 1 MiB,
            // larger than exec's per-argument limit. The shell's printf streams it over stdin.
            Some(text) => format!("printf %s {} | ({command})", quote(text)),
            None => command,
        }
    }
}

/// Build a refusal's runnable command from the original CLI argv when available. The CLI
/// adds this metadata before forwarding a request, so prompts and launcher flags survive intact.
fn command(params: &Value, start: &Start, host: Option<&str>, on_host: bool) -> Retry {
    let Some(mut words) = params
        .pointer("/_meta/acpmux/argv")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>())
    else {
        return Retry {
            command: if on_host { start.on_host_command() } else { start.command(host) },
            input: None,
        };
    };
    if on_host {
        change_option(&mut words, "--host", None);
    } else if let Some(host) = host {
        // Pin an automatic placement to the peer that actually refused this start.
        change_option(&mut words, "--host", Some(host));
    }
    change_option(&mut words, "--mode", None);
    // `suggest` already selected the usable folder (or the scratch-folder fallback).
    change_option(&mut words, "--cwd", start.cwd.as_deref());
    let prompt_file = params.pointer("/_meta/acpmux/promptFileText").and_then(Value::as_str);
    let input = prompt_file
        .filter(|_| change_option(&mut words, "--prompt-file", Some("/dev/stdin")))
        .map(str::to_owned);
    let rendered = words.iter().map(|w| quote(w)).collect::<Vec<_>>();
    let inner = format!("acpmux {}", rendered.join(" "));
    let command = if on_host && let Some(cwd) = start.cwd.as_deref() {
        format!("mkdir -p {} && {inner}", quote(cwd))
    } else {
        inner
    };
    Retry { command, input }
}

/// Change only actual options, never another option's value or prompt words after `--`.
/// Read value-taking flags from clap's grammar so future launcher options are preserved too.
fn change_option(words: &mut Vec<String>, option: &str, value: Option<&str>) -> bool {
    use clap::Args;
    // Only creation flags take values here (the global flags are switches). Building the
    // whole CLI grammar inside the request handler exhausts a debug worker's 2 MiB stack.
    let new = crate::cli::command::NewArgs::augment_args(clap::Command::new("new"));
    let args: Vec<_> = new.get_arguments().collect();
    let mut i = 0;
    while i < words.len() {
        let word = &words[i];
        if word == "--" {
            break;
        }
        if let Some(long) = word.strip_prefix("--") {
            let (name, inline) = long.split_once('=').map_or((long, false), |(k, _)| (k, true));
            let takes =
                args.iter().any(|a| a.get_long() == Some(name) && a.get_action().takes_values());
            let end = (i + if takes && !inline { 2 } else { 1 }).min(words.len());
            if name == option.trim_start_matches('-') {
                let replacement = value.map(|v| format!("{option}={v}"));
                words.splice(i..end, replacement);
                return true;
            }
            i = end;
        } else if let Some(shorts) = word.strip_prefix('-').filter(|s| !s.is_empty()) {
            let mut separate_value = false;
            for (offset, short) in shorts.char_indices() {
                if args
                    .iter()
                    .any(|a| a.get_short() == Some(short) && a.get_action().takes_values())
                {
                    separate_value = offset + short.len_utf8() == shorts.len();
                    break;
                }
            }
            i += if separate_value { 2 } else { 1 };
        } else {
            i += 1;
        }
    }
    false
}

/// What the caller asked to start, as `acpmux new` flags.
#[derive(Clone, Debug, Default, PartialEq)]
struct Start {
    preset: Option<String>,
    model: Option<String>,
    effort: Option<String>,
    name: Option<String>,
    cwd: Option<String>,
    policy: Option<String>,
    mode: Option<String>,
}

impl Start {
    fn of(params: &Value) -> Start {
        let meta = params.pointer("/_meta/acpmux");
        let pick = |key: &str| {
            meta.and_then(|m| m.get(key))
                .or_else(|| params.get(key))
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
                .map(str::to_owned)
        };
        let model = match (pick("harness"), pick("model")) {
            (Some(h), Some(m)) => Some(format!("{h}/{m}")),
            (h, m) => h.or(m),
        };
        let mode = crate::web_modes::MODE_FIELDS.iter().find_map(|f| pick(f));
        Start {
            preset: pick("preset"),
            model,
            effort: pick("effort"),
            name: pick("name"),
            cwd: params.get("cwd").and_then(Value::as_str).map(str::to_owned),
            policy: pick("policy"),
            mode,
        }
    }

    /// `acpmux new [--host HOST] ... -d`, each value quoted for a POSIX shell.
    fn command(&self, host: Option<&str>) -> String {
        let mut words = vec!["acpmux".to_owned(), "new".to_owned()];
        let flags = [
            ("--host", host.map(str::to_owned)),
            ("--preset", self.preset.clone()),
            ("-m", self.model.clone()),
            ("-e", self.effort.clone()),
            ("-n", self.name.clone()),
            ("--cwd", self.cwd.clone()),
            ("--policy", self.policy.clone()),
            ("--mode", self.mode.clone()),
        ];
        for (flag, value) in flags {
            if let Some(value) = value {
                words.push(flag.to_owned());
                words.push(quote(&value));
            }
        }
        words.push("-d".to_owned());
        words.join(" ")
    }

    /// `command` for HOST's own shell, its folder made first.
    fn on_host_command(&self) -> String {
        let new = self.command(None);
        match &self.cwd {
            Some(cwd) => format!("mkdir -p {} && {new}", quote(cwd)),
            None => new,
        }
    }
}

#[derive(Debug, PartialEq)]
enum Hint {
    /// `acpmux new --host HOST ...` from here.
    Here(Start),
    /// The start on HOST itself.
    OnHost(Start),
}

/// What the refusal says besides its reason.
#[derive(Clone, Copy, Default)]
struct Found<'a> {
    served: Option<&'a str>,
    try_cwd: Option<&'a str>,
    cause: Option<&'a str>,
}

/// The start that works after `reason`. A peer that serves this daemon as a remote Web
/// client takes only its own roots (which it does not name) and asking policies, so the
/// way out there is HOST's own CLI, in the folder asked for unless the peer did not say
/// `mkdir -p` makes it (then in the shell's own). From a peer that serves it as a peer, a
/// folder outside its roots becomes the one it checked, else none (a scratch folder). A mode
/// is dropped either way.
fn suggest(start: &Start, reason: &str, found: Found) -> Hint {
    let Found { served, try_cwd, cause } = found;
    let mut next = Start { mode: None, ..start.clone() };
    match (served, reason) {
        (None, _) => {
            next.cwd = None;
            Hint::OnHost(next)
        }
        (Some("peer"), CWD_OUTSIDE_ROOTS | CWD_MISSING | MODE_REFUSED) => {
            if reason != MODE_REFUSED {
                next.cwd = try_cwd.filter(|_| reason == CWD_OUTSIDE_ROOTS).map(str::to_owned);
            }
            Hint::Here(next)
        }
        _ => {
            if reason == CWD_MISSING && cause != Some("missing") {
                next.cwd = None;
            }
            Hint::OnHost(next)
        }
    }
}

/// `text` as one POSIX shell word: unchanged when it holds only characters no shell reads
/// specially, else in single quotes.
fn quote(text: &str) -> String {
    let plain = !text.is_empty()
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-./=:@%+,".contains(&b));
    if plain { text.to_owned() } else { format!("'{}'", text.replace('\'', r"'\''")) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn start() -> Start {
        Start::of(&json!({
            "cwd": "/home/cmux/hb-acpmux/x",
            "_meta": {"acpmux": {"harness": "codex", "model": "gpt-6", "name": "lane", "policy": "approve-all", "mode": "auto"}}
        }))
    }

    #[test]
    fn a_start_is_spelled_as_the_flags_that_make_it() {
        assert_eq!(
            start().command(Some("gcp-1")),
            "acpmux new --host gcp-1 -m codex/gpt-6 -n lane --cwd /home/cmux/hb-acpmux/x --policy approve-all --mode auto -d"
        );
        let odd = Start { cwd: Some("/tmp/a b/it's".into()), ..Start::default() };
        assert_eq!(odd.command(None), r"acpmux new --cwd '/tmp/a b/it'\''s' -d");
    }

    fn peer(try_cwd: Option<&str>) -> Found<'_> {
        Found { served: Some("peer"), try_cwd, cause: None }
    }

    #[test]
    fn each_refusal_suggests_a_start_the_peer_takes() {
        let s = start();
        // From a peer that serves us as a peer: the folder it checked, or none; never a mode.
        let Hint::Here(next) = suggest(&s, CWD_OUTSIDE_ROOTS, peer(Some("/home/cmux/Projects/x")))
        else {
            panic!()
        };
        assert_eq!(next.cwd.as_deref(), Some("/home/cmux/Projects/x"));
        assert_eq!(next.mode, None);
        let Hint::Here(next) = suggest(&s, CWD_OUTSIDE_ROOTS, peer(None)) else { panic!() };
        assert_eq!(next.cwd, None);
        let Hint::Here(next) = suggest(&s, MODE_REFUSED, peer(None)) else { panic!() };
        assert_eq!((next.mode, next.policy.as_deref()), (None, Some("approve-all")));
        // A policy it refused, or anything from a peer that serves us as Web: on the host,
        // its folder made first, with no mode.
        assert!(matches!(suggest(&s, POLICY_REFUSED, peer(None)), Hint::OnHost(_)));
        let web = |cause| Found { served: Some("remote"), cause, ..Found::default() };
        let Hint::OnHost(next) = suggest(&s, CWD_MISSING, web(Some("missing"))) else { panic!() };
        assert_eq!(
            next.on_host_command(),
            "mkdir -p /home/cmux/hb-acpmux/x && acpmux new -m codex/gpt-6 -n lane --cwd /home/cmux/hb-acpmux/x --policy approve-all -d"
        );
        // A path no `mkdir -p` makes (a file, a link) is left out.
        for cause in [Some("unusable"), None] {
            let Hint::OnHost(next) = suggest(&s, CWD_MISSING, web(cause)) else { panic!() };
            assert_eq!(next.cwd, None, "{cause:?}");
        }
        // An older peer checked the mode before the folder: on the host, in the shell's folder.
        for reason in [MODE_REFUSED, POLICY_REFUSED, CWD_OUTSIDE_ROOTS] {
            let Hint::OnHost(next) = suggest(&s, reason, Found::default()) else { panic!() };
            assert_eq!((next.cwd, next.mode), (None, None), "{reason}");
        }
    }

    #[test]
    fn a_start_on_the_host_goes_through_ssh_only_for_an_ssh_peer() {
        let inner = "mkdir -p /x && acpmux new -d";
        assert_eq!(
            on_host(Some("leo@huge-blue"), inner),
            "ssh -- leo@huge-blue 'mkdir -p /x && acpmux new -d'"
        );
        assert_eq!(on_host(None, inner), inner);
    }

    #[test]
    fn original_argv_keeps_prompts_launcher_flags_and_quotes_shell_input() {
        let params = json!({
            "_meta": {"acpmux": {
                "argv": ["new", "--host", "b", "-m", "codex", "--prompt-file", "brief.md",
                         "--tag", "a=$()", "a prompt with 'quotes' and\nnewlines"],
                "promptFileText": "line 1; $(touch nope)\nline 'two'"
            }},
            "cwd": "/remote/project"
        });
        let start = Start { cwd: Some("/remote/project".into()), ..Start::default() };
        let got = command(&params, &start, Some("b"), false).render(None);
        assert_eq!(
            got,
            r#"printf %s 'line 1; $(touch nope)
line '\''two'\''' | (acpmux new --host=b -m codex --prompt-file=/dev/stdin --tag 'a=$()' 'a prompt with '\''quotes'\'' and
newlines')"#
        );
    }

    #[test]
    fn option_rewrites_do_not_touch_values_or_prompt_words() {
        let mut words: Vec<String> = [
            "new",
            "--name",
            "--host=x",
            "-m--cwd",
            "--host",
            "auto",
            "--mode=yolo",
            "--cwd=/bad",
            "--",
            "--host",
            "prompt",
            "--mode=yolo",
            "--cwd=/bad",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
        assert!(change_option(&mut words, "--host", Some("b")));
        assert!(change_option(&mut words, "--mode", None));
        assert!(change_option(&mut words, "--cwd", None));
        assert_eq!(
            words,
            [
                "new",
                "--name",
                "--host=x",
                "-m--cwd",
                "--host=b",
                "--",
                "--host",
                "prompt",
                "--mode=yolo",
                "--cwd=/bad"
            ]
        );
    }

    #[test]
    #[cfg(unix)]
    fn pasted_ssh_command_preserves_every_argument_and_prompt_file_byte() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("acpmux-hint-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir(&dir).unwrap();
        for (name, script) in [
            ("ssh", "#!/bin/sh\n[ \"$1\" = -- ] || exit 9\nshift 2\nexec /bin/sh -c \"$1\"\n"),
            ("acpmux", "#!/bin/sh\nprintf '%s\\0' \"$@\"\ncat\n"),
        ] {
            let path = dir.join(name);
            std::fs::write(&path, script).unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let prompt = "'quoted' \"double\" $HOME $(exit 99) `exit 98`\nsecond line";
        let file = format!(
            "{}file's text $HOME $(exit 97)\ntrailing newline\n",
            "a".repeat((1 << 20) - 100)
        );
        let file = file.as_str();
        let argv = json!([
            "--json",
            "new",
            "--host=b",
            "-n",
            "demo",
            "-m",
            "codex",
            "-e",
            "xhigh",
            "--policy",
            "approve-all",
            "--prompt-file=brief with spaces.md",
            "--tag",
            "a=b",
            "--worktree",
            "repo@main",
            "--report-to",
            "boss",
            "-d",
            "--",
            prompt,
            "--host",
            "--mode"
        ]);
        let params = json!({"_meta":{"acpmux":{"argv":argv,"promptFileText":file}}});
        let start = Start {
            cwd: Some(dir.join("project").to_string_lossy().into_owned()),
            ..Start::default()
        };
        let inner = command(&params, &start, None, true);
        for ssh in [Some("example-host"), None] {
            let tried = inner.render(ssh);
            let path = format!("{}:{}", dir.display(), std::env::var("PATH").unwrap());
            use std::io::Write;
            use std::process::Stdio;
            let mut shell = std::process::Command::new("sh")
                .env("PATH", path)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            shell.stdin.take().unwrap().write_all(format!("{tried}\n").as_bytes()).unwrap();
            let output = shell.wait_with_output().unwrap();
            assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
            let output = String::from_utf8(output.stdout).unwrap();
            let actual: Vec<_> = output.split('\0').collect();
            assert_eq!(
                actual,
                [
                    "--json",
                    "new",
                    "-n",
                    "demo",
                    "-m",
                    "codex",
                    "-e",
                    "xhigh",
                    "--policy",
                    "approve-all",
                    "--prompt-file=/dev/stdin",
                    "--tag",
                    "a=b",
                    "--worktree",
                    "repo@main",
                    "--report-to",
                    "boss",
                    "-d",
                    "--",
                    prompt,
                    "--host",
                    "--mode",
                    file
                ]
            );
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_older_peers_refusal_is_known_by_its_message() {
        let e = |m: &str| RpcError::invalid_params(m);
        assert_eq!(
            reason_of(&e(
                "a mode at session start is accepted only from the local app or the unix socket, never from a remote WebSocket connection"
            )),
            Some(MODE_REFUSED.to_owned())
        );
        assert_eq!(
            reason_of(&e(
                "cwd is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder"
            )),
            Some(CWD_OUTSIDE_ROOTS.to_owned())
        );
        assert_eq!(reason_of(&e("no peer \"x\"")), None);
        let other = e("x").with_data(json!({"reason": "trust.remote"}));
        assert_eq!(reason_of(&other), None);
    }

    /// `acpmux new --host H -m claude hi` with no --cwd, refused by a peer from before the
    /// peer scratch folder: the way out is `acpmux host update H --if-idle`, then the same command.
    #[test]
    fn an_older_peer_refusing_a_start_with_no_folder_names_the_update() {
        let refused = || {
            RpcError::invalid_params(
                "cwd is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder",
            )
        };
        let argv = json!(["new", "--host", "gcp-codex-lane-1", "-m", "claude", "hi"]);
        let params = json!({"_meta": {"acpmux": {"harness": "claude", "argv": argv}}});
        let old = Some("972843ddd 2026-10-22");
        let e = update_first(&refused(), "gcp-codex-lane-1", old, true, &params)
            .expect("an update hint");
        let data = e.data.clone().unwrap();
        assert_eq!(data["reason"], "peer_version_skew");
        assert_eq!(data["refused"], CWD_OUTSIDE_ROOTS);
        assert_eq!(data["try"], "acpmux host update gcp-codex-lane-1 --if-idle");
        assert_eq!(data["then"], "acpmux new --host=gcp-codex-lane-1 -m claude hi");
        assert!(e.message.contains("972843ddd"), "{}", e.message);
        let update = "`acpmux host update gcp-codex-lane-1 --if-idle`";
        assert!(e.message.contains(update), "{}", e.message);
        // A folder named, a peer that says how it served us, or one of this build: as before.
        let named = json!({"cwd": "/tmp/x", "_meta": {"acpmux": {"argv": argv}}});
        assert!(update_first(&refused(), "gcp-codex-lane-1", old, true, &named).is_none());
        let told = refused().with_data(json!({"reason": CWD_OUTSIDE_ROOTS, "servedAs": "remote"}));
        assert!(update_first(&told, "gcp-codex-lane-1", old, true, &params).is_none());
        let same = Some(crate::hub::BUILD);
        assert!(update_first(&refused(), "gcp-codex-lane-1", same, true, &params).is_none());
        // A peer that serves this daemon as Web refuses no folder on any build: no update hint.
        assert!(update_first(&refused(), "gcp-codex-lane-1", old, false, &params).is_none());
    }

    /// A start this daemon forwards for a Web client keeps Web rules on the peer after any
    /// update, so `new_on` passes it as not served as a peer: no update hint for it.
    #[test]
    fn a_start_forwarded_for_web_gets_no_update_hint() {
        let web = json!({"_meta": {"acpmux": {"harness": "claude", "via": "web"}}});
        assert!(via_web(&web));
        for p in [json!({"_meta": {"acpmux": {"via": "app"}}}), json!({"_meta": {"acpmux": {}}})] {
            assert!(!via_web(&p), "{p}");
        }
    }
}
