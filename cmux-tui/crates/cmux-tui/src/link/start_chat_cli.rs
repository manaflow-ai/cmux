//! `cmux link start-chat plan|pin|copy`: the bookkeeping of a new chat's
//! first send that runs in Cloud (`cloud.startChat`, the App's
//! `CloudStartChat`), moved out of Swift so it builds and tests on Linux
//! (Leo, 2026-10-30: "AS MUCH RUST AS POSSIBLE INSTEAD OF SWIFT"). The App
//! lists its Cloud machines, makes the one a plan asks for, opens the chat
//! and closes its own tab; what decides is here:
//!
//! - `plan --request JSON`: the machine the send takes ([`pick::destination`]):
//!   (a new one for a send from a folder with a GitHub repository, on the
//!   personal account, with the cmux credential on stdin
//!   (`credential_on_stdin`): the platform's workspace machine, as `ensure`
//!   makes it, pinned like any other and answered with `ensured`; the App
//!   makes it only when the platform made none)
//!   the one its first try took while that machine exists; for a send from a
//!   Mac workspace, the machine that workspace already has; else a new one
//!   named for chats; and the send's keys ([`Keys`]). For now each workspace
//!   gets a small machine of its own and no machine serves two workspaces
//!   (leo-workspace `design/cloud.md`, "One workspace per small machine,
//!   snapshots, and a Cloud button"). A machine that exists is pinned to the
//!   send before anything runs there, so a retry of the send names it.
//! - `pin --key K --account A --machine ID [--workspace W]`: pins the send
//!   to the machine the App just made for it, and makes it the workspace's
//!   when the workspace has none yet and no other workspace has it.
//! - `copy --key K --account A --machine ID --socket PATH --local ROOT
//!   [--subpath SUB] --work-root R...`: puts ROOT in a folder of the send's
//!   own on the machine (`cmux link seed push`: seeded from its GitHub
//!   remote, else copied), trying each work root in turn, unless this send's
//!   copy already finished there: a second push would overwrite what the chat
//!   changed since. Answers the chat's folder there, and how it got there:
//!   `mode` (`seed` or `copy`), `fallback_code`, `fallback_why` and
//!   `install_url` when a seed copied instead, and `skipped_files`. The push's
//!   progress lines go to stderr; `--acpmux-home H` adds `source_trusted` ([`trust`]).
//! - `ensure --workspace W --key K --repo OWNER/NAME [--ref REF] [--environment env_...]
//!   [--platform URL]`, the cmux credential on stdin: the workspace's own
//!   machine from the cmux platform (`POST /v1/workspaces/{W}/machine`), made
//!   under the plan's `create_key` so a retry gets the same one. With the
//!   folder's repository (the plan's `repo`) it boots from the repository's
//!   set-up snapshot once that is ready (zero-setup hot start), keyed by the
//!   chosen cloud environment (`cloud.startChat`'s `environment`; absent: the
//!   personal Default).
//! - `import --entries JSON`: takes in the sends the App kept in its user
//!   defaults before this did ([`Ledger::import`]), once, on upgrade.
//!
//! Every send is kept under the account it began in (`account`: the user and
//! the team, as the App spells them): a team switch keeps the person signed
//! in, and a send of the previous team must never take, or copy to, this
//! team's machine. The pins live in this Mac's state folder ([`ledger`]). Output: one JSON
//! line on stdout, `{"ok":true,...}` with exit 0, or
//! `{"ok":false,"error":...,"error_code":...}` with exit 1; bad usage exits 64.

mod ledger;
mod pick;
#[cfg(test)]
mod tests;
mod trust;

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use ledger::{Ledger, Send};
use pick::{Candidate, Destination};

const USAGE: &str = "usage: cmux link start-chat plan --request JSON\n       \
cmux link start-chat pin --key KEY --account ACCOUNT --machine ID [--workspace ID]\n       \
cmux link start-chat ensure --workspace ID --key KEY --repo OWNER/NAME [--ref REF] [--environment env_ID] [--platform URL] (the cmux credential on stdin)\n       \
cmux link start-chat import --entries JSON\n       \
cmux link start-chat copy --key KEY --account ACCOUNT --machine ID --socket PATH --local FOLDER [--subpath PATH] --work-root PATH... [--acpmux-home PATH]";

/// The error code a work root the machine's user cannot write answers with:
/// the next root is tried.
const PERMISSION_DENIED: &str = "fs.permission_denied";

pub(super) fn run(args: &[String]) -> i32 {
    if matches!(args.first().map(String::as_str), Some("-h" | "--help" | "help")) {
        println!("{USAGE}");
        return 0;
    }
    let Some((action, flags)) = args.split_first() else {
        eprintln!("{USAGE}");
        return 64;
    };
    let Some(flags) = Flags::parse(flags) else {
        eprintln!("{USAGE}");
        return 64;
    };
    let Some(ledger) = ledger::path() else {
        println!(
            "{}",
            refused("ledger_failed", "this Mac has no state folder to keep the send's machine in")
        );
        return 1;
    };
    let answer = match action.as_str() {
        "plan" => flags.one("--request").map(|request| {
            plan_with(&ledger, request, &mut std::io::stdin().lock(), &|ensure, credential| {
                ensure.post(credential)
            })
        }),
        "pin" => match (flags.key(), flags.account(), flags.one("--machine"), flags.workspace()) {
            (Some(key), Some(account), Some(machine), Some(workspace)) => {
                Some(pin(&ledger, &key, account, machine, workspace))
            }
            _ => None,
        },
        "copy" => StartCopy::of(&flags).map(|copy| copy.run(&ledger, &push)),
        "import" => flags.one("--entries").map(|entries| import(&ledger, entries)),
        "ensure" => Ensure::of(&flags).map(|ensure| ensure.run(&mut std::io::stdin().lock())),
        _ => None,
    };
    let Some(answer) = answer else {
        eprintln!("{USAGE}");
        return 64;
    };
    println!("{answer}");
    if answer["ok"] == json!(true) { 0 } else { 1 }
}

/// The keys of the send `key` (lowercased: a retry may spell it in another case).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Keys {
    /// The idempotency key of the Cloud machine the send creates: a retry
    /// whose create reached the server but lost its answer gets that machine
    /// back, never a second paid VM.
    pub(super) create: String,
    /// The creation key of the machine's chat tab: a retry gets the tab its
    /// first try made, never a second chat with the prompt again.
    pub(super) tab: String,
    /// The folder under the machine's work root the send's copies go in: its
    /// own, so a second chat from the same folder never writes over the first
    /// one's changes on a reused machine. Each copy goes to a new folder in it
    /// ([`StartCopy::run`]).
    pub(super) place: String,
}

impl Keys {
    pub(super) fn of(key: &str) -> Self {
        let key = key.to_lowercase();
        Self {
            create: format!("cloud-start-chat-{key}"),
            tab: format!("cloud-start-chat-{key}"),
            place: format!("chats/{key}"),
        }
    }

    fn json(&self) -> Value {
        json!({"create_key": self.create, "tab_key": self.tab, "remote_place": self.place})
    }
}

/// A send's key: the page's UUID, as `AgentPaneCloudStart` checked it.
pub(super) fn valid_key(key: &str) -> bool {
    key.len() == 36
        && key.char_indices().all(|(index, char)| match index {
            8 | 13 | 18 | 23 => char == '-',
            _ => char.is_ascii_hexdigit(),
        })
}

fn refused(code: &str, error: impl std::fmt::Display) -> Value {
    json!({"ok": false, "error": error.to_string(), "error_code": code})
}

#[allow(clippy::arithmetic_side_effects, reason = "epoch milliseconds conversion")]
fn now_millis() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs_f64() * 1_000.0)
        .unwrap_or_default()
}

/// Copy timing belongs to the clone row, never machine creation or harness startup.
fn copy_progress(
    mut answer: Value,
    state: &str,
    phase: &str,
    started_at: f64,
    finished_at: f64,
) -> Value {
    if let Some(object) = answer.as_object_mut() {
        object.insert("seed_state".into(), json!(state));
        object.insert("seed_phase".into(), json!(phase));
        object.insert("seed_started_at".into(), json!(started_at));
        object.insert("seed_finished_at".into(), json!(finished_at));
    }
    answer
}

/// The account a send began in, as the App spells it: printable, at most 512 bytes.
pub(super) fn valid_account(account: &str) -> bool {
    account.len() <= 512 && !account.chars().any(char::is_control)
}

/// A Mac workspace's id, as the App spells it: 1 to 128 printable characters.
pub(super) fn valid_workspace(workspace: &str) -> bool {
    (1..=128).contains(&workspace.chars().count()) && !workspace.chars().any(char::is_control)
}

/// What `plan` reads: the send, the account it began in, the Mac workspace it
/// came from, who is signed in, and the Cloud machines the App's list for
/// that account named.
#[derive(serde::Deserialize)]
struct PlanRequest {
    key: String,
    account: String,
    /// The Mac workspace of the tab that sent; None for a send from no workspace.
    #[serde(default)]
    workspace: Option<String>,
    #[serde(default)]
    user: Option<String>,
    /// Whether the App has loaded its machine list: before it has, a machine
    /// a pin names is kept (it may be one made for this send, not listed yet).
    #[serde(default)]
    loaded: bool,
    /// The machines the account's list named: the only ones a send may take.
    #[serde(default)]
    machines: Vec<Candidate>,
    /// Machines in the App's store that its list did not name yet (made
    /// since): a send pinned to one keeps it, but none is picked.
    #[serde(default)]
    stored: Vec<String>,
    /// The chat's folder on this Mac: its GitHub `origin` is the plan's `repo`.
    #[serde(default)]
    local: Option<String>,
    /// The cloud environment the send chose (`cloud.startChat`'s `environment`), echoed for `ensure`.
    #[serde(default)]
    environment: Option<String>,
    /// The cmux credential is the first line of stdin: a new machine for a send from a repository's folder, on the
    /// personal account, is the platform's workspace machine.
    #[serde(default)]
    credential_on_stdin: bool,
}

/// How `plan` asks the cmux platform for a workspace's machine: `ensure` with a credential.
pub(super) type EnsureCall<'a> =
    &'a dyn Fn(&Ensure, &str) -> Result<Value, crate::cli::PlatformCallError>;

/// `plan`: where the send goes, pinned when it is a machine that exists (no platform: [`plan_with`] makes the CLI's).
#[cfg(test)]
pub(super) fn plan(ledger: &Path, request: &str) -> Value {
    plan_with(ledger, request, &mut std::io::empty(), &|_, _| {
        Err(crate::cli::PlatformCallError::Unreachable("no platform here".into()))
    })
}

/// [`plan`], making a new machine through `ensure` when the send's folder has a GitHub repository and the account is
/// the personal one ([`ensures`]).
pub(super) fn plan_with(
    ledger: &Path,
    request: &str,
    stdin: &mut dyn std::io::BufRead,
    ensure: EnsureCall<'_>,
) -> Value {
    let request: PlanRequest = match serde_json::from_str(request) {
        Ok(request) => request,
        Err(error) => return refused("bad_request", error),
    };
    if !valid_key(&request.key) {
        return refused("bad_request", "the send's key is not a UUID");
    }
    if !valid_account(&request.account) {
        return refused("bad_request", "the account is too long or has control characters");
    }
    let workspace = request.workspace.as_deref();
    if workspace.is_some_and(|workspace| !valid_workspace(workspace)) {
        return refused(
            "bad_request",
            "the workspace id is empty, too long or has control characters",
        );
    }
    if request.environment.as_deref().is_some_and(|id| !valid_environment(id)) {
        return refused("bad_request", "the environment is not a cloud environment id (env_...)");
    }
    let keys = Keys::of(&request.key);
    let send = Send::new(&request.key, &request.account);
    let planned = Ledger::update(ledger, |pins| {
        let destination = pick::destination(
            &send,
            &request.account,
            workspace,
            pins,
            &request.machines,
            &request.stored,
            request.user.as_deref(),
            request.loaded,
        );
        if let Destination::Machine(id) = &destination {
            pins.record(id, &send);
            // A retry of an older send keeps its machine, never the workspace's newer one,
            // and a machine another workspace has never becomes this one's too.
            if let Some(workspace) = workspace {
                pick::claim(pins, workspace, &request.account, id);
            }
        }
        destination
    });
    let repo = request.local.as_deref().and_then(folder_repo);
    let mut line = keys.json();
    let fields = match planned {
        Ok(Destination::Machine(id)) => json!({"ok": true, "machine": id}),
        Ok(Destination::New) if ensures(&request, repo.as_deref()) => {
            let mut credential = String::new();
            let _ = stdin.read_line(&mut credential);
            let ask = Ensure {
                // A send from no Mac workspace is a workspace of its own.
                workspace: workspace.map_or_else(|| keys.create.clone(), str::to_string),
                create_key: keys.create,
                repo: repo.clone().unwrap_or_default(),
                git_ref: None,
                environment: request.environment.clone(),
                platform: None,
            };
            let answer = if credential.trim().is_empty() {
                Err(crate::cli::PlatformCallError::Status { status: 401, code: "" })
            } else {
                ensure(&ask, credential.trim())
            };
            match answer {
                Ok(body) => {
                    let line = ensure_answer(Ok(body));
                    let Some(id) = line.get("machine").and_then(Value::as_str) else { return line };
                    // Pinned before the App opens anything there, as a machine the App made.
                    if let Err(error) = Ledger::update(ledger, |pins| {
                        pins.record(id, &send);
                        if let Some(workspace) = workspace {
                            pick::claim(pins, workspace, &request.account, id);
                        }
                    }) {
                        return refused("ledger_failed", format!("{error:#}"));
                    }
                    json!({"ok": true, "machine": id, "ensured": {
                        "created": line.get("created"), "snapshot": line.get("snapshot"),
                        "environment": line.get("environment"),
                    }})
                }
                // The platform made no machine: the App makes it, as before.
                Err(error) if made_no_machine(&error) => json!({
                    "ok": true,
                    "machine": null,
                    "new_name": pick::new_machine_name(request.machines.iter().map(|machine| machine.title.as_str())),
                }),
                // It may have made one: a retry with the same key reaches it, never a second paid machine.
                Err(error) => return ensure_answer(Err(error)),
            }
        }
        Ok(Destination::New) => json!({
            "ok": true,
            "machine": null,
            "new_name": pick::new_machine_name(request.machines.iter().map(|machine| machine.title.as_str())),
        }),
        Err(error) => return refused("ledger_failed", format!("{error:#}")),
    };
    if let (Value::Object(line), Value::Object(fields)) = (&mut line, fields) {
        line.extend(fields);
        line.insert("repo".into(), json!(repo));
        line.insert("environment".into(), json!(request.environment));
    }
    line
}

/// Whether a new machine for the send is the platform's workspace machine: the send's folder has a GitHub repository
/// (`repo`), the account is the personal one (the App spells it `user/` with no team: workspace machines are made in
/// the personal team) and the App handed over the credential.
fn ensures(request: &PlanRequest, repo: Option<&str>) -> bool {
    let personal = request
        .account
        .split_once('/')
        .is_some_and(|(user, team)| !user.is_empty() && team.is_empty());
    repo.is_some() && personal && request.credential_on_stdin
}

/// Whether a failed ensure made no machine, so the App may make one: the platform has no workspace machines here (a
/// 404 that is not a refused environment), refused the sign-in, has none configured, or admitted none.
pub(super) fn made_no_machine(error: &crate::cli::PlatformCallError) -> bool {
    use crate::cli::PlatformCallError as E;
    match error {
        E::Status { code: "cloud_environment.not_found", .. } => false,
        E::Status { status: 401 | 403 | 404, .. } => true,
        E::Status {
            code: "workspace_machine.unconfigured" | "workspace_machine.not_admitted",
            ..
        } => true,
        _ => false,
    }
}

/// A cloud environment's id, as the cmux platform makes them: `env_` and 24 hex digits.
pub(super) fn valid_environment(id: &str) -> bool {
    id.len() == 28
        && id.starts_with("env_")
        && id
            .get(4..)
            .is_some_and(|hex| hex.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f')))
}

/// A repository as the cmux platform names one: `owner/name`, GitHub's characters, at most 140 bytes.
pub(super) fn valid_repo(repo: &str) -> bool {
    let part = |part: &str| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    };
    repo.len() <= 140
        && matches!(repo.split_once('/'), Some((owner, name)) if part(owner) && part(name))
}

/// The GitHub repository of the folder `local` (absolute): its repository's `origin` remote, when that is
/// GitHub's. Read from the repository's config file, never by running git: no hooks, no inherited `GIT_*`
/// variables, no Command Line Tools prompt, nothing that can wait on a credential.
fn folder_repo(local: &str) -> Option<String> {
    let local = Path::new(local);
    if !local.is_absolute() {
        return None;
    }
    let config = std::fs::read_to_string(git_common_dir(local)?.join("config")).ok()?;
    github_repo(&origin_url(&config)?)
}

/// The git directory that holds the config of the repository `folder` is in: the nearest `.git` at or above
/// it, followed through a worktree's `gitdir:` file and its `commondir`.
fn git_common_dir(folder: &Path) -> Option<PathBuf> {
    let dot_git =
        folder.ancestors().map(|dir| dir.join(".git")).find(|dot_git| dot_git.exists())?;
    if dot_git.is_dir() {
        return Some(dot_git);
    }
    let link = std::fs::read_to_string(&dot_git).ok()?;
    let gitdir = link.lines().find_map(|line| line.strip_prefix("gitdir:"))?.trim();
    let gitdir = dot_git.parent()?.join(gitdir);
    match std::fs::read_to_string(gitdir.join("commondir")) {
        Ok(common) => Some(gitdir.join(common.trim())),
        Err(_) => Some(gitdir),
    }
}

/// The `url` of `[remote "origin"]` in a git config file's text (the last one wins, as in git).
pub(super) fn origin_url(config: &str) -> Option<String> {
    let mut in_origin = false;
    let mut url = None;
    for line in config.lines().map(str::trim) {
        if let Some(section) = line.strip_prefix('[') {
            let section = section.split(']').next().unwrap_or("");
            let (name, sub) = section.split_once(char::is_whitespace).unwrap_or((section, ""));
            in_origin = name.eq_ignore_ascii_case("remote") && sub.trim() == "\"origin\"";
        } else if in_origin
            && let Some((key, value)) = line.split_once('=')
            && key.trim().eq_ignore_ascii_case("url")
        {
            url = Some(value.trim().trim_matches('"').to_string());
        }
    }
    url
}

/// `owner/name` of a GitHub remote URL (https, ssh or scp-like, any case, with or without a user), None for
/// any other host.
pub(super) fn github_repo(url: &str) -> Option<String> {
    let rest = ["https://", "http://", "ssh://", "git+ssh://"].iter().find_map(|scheme| {
        url.split_at_checked(scheme.len())
            .filter(|(head, _)| head.eq_ignore_ascii_case(scheme))
            .map(|(_, rest)| rest)
    });
    let path = match rest {
        Some(rest) => {
            let (host, path) = rest.split_once('/')?;
            let host = host.rsplit('@').next()?;
            host.eq_ignore_ascii_case("github.com").then_some(path)?
        }
        None => {
            // scp-like: [user@]github.com:owner/name
            let (host, path) = url.split_once(':')?;
            let host = host.rsplit('@').next()?;
            host.eq_ignore_ascii_case("github.com").then_some(path)?
        }
    };
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    valid_repo(path).then(|| path.to_string())
}

/// `ensure`: the Mac workspace's own machine from the cmux platform.
pub(super) struct Ensure {
    workspace: String,
    create_key: String,
    repo: String,
    git_ref: Option<String>,
    environment: Option<String>,
    platform: Option<String>,
}

impl Ensure {
    fn of(flags: &Flags) -> Option<Self> {
        let optional = |name: &str| match flags.all(name).as_slice() {
            [] => Some(None),
            [value] => Some(Some(value.to_string())),
            _ => None,
        };
        let environment = optional("--environment")?;
        let git_ref = optional("--ref")?;
        if environment.as_deref().is_some_and(|id| !valid_environment(id))
            || git_ref
                .as_deref()
                .is_some_and(|r| r.is_empty() || r.len() > 200 || r.chars().any(char::is_control))
        {
            return None;
        }
        Some(Self {
            workspace: flags.workspace()??.to_string(),
            create_key: Keys::of(&flags.key()?).create,
            repo: flags.one("--repo").filter(|repo| valid_repo(repo))?.to_string(),
            git_ref,
            environment,
            platform: optional("--platform")?,
        })
    }

    /// The request body: the plan's `create_key` as the client key, so a retry gets the same machine.
    pub(super) fn body(&self) -> Value {
        let mut body = json!({"clientKey": self.create_key, "repo": self.repo});
        if let Some(git_ref) = &self.git_ref {
            body.set("ref", json!(git_ref));
        }
        if let Some(environment) = &self.environment {
            body.set("environment", json!(environment));
        }
        body
    }

    fn run(&self, stdin: &mut dyn std::io::BufRead) -> Value {
        let mut credential = String::new();
        if stdin.read_line(&mut credential).is_err() || credential.trim().is_empty() {
            return refused("unauthorized", "no cmux credential on stdin");
        }
        ensure_answer(self.post(credential.trim()))
    }

    /// `POST /v1/workspaces/{W}/machine` as `credential`. A platform this cannot reach (a bad `--platform`) is
    /// unreachable.
    fn post(&self, credential: &str) -> Result<Value, crate::cli::PlatformCallError> {
        let unreachable = crate::cli::PlatformCallError::Unreachable;
        let env = |name: &str| std::env::var(name).ok();
        let origin =
            crate::cli::platform_origin(self.platform.as_deref(), &env).map_err(unreachable)?;
        // A new machine's placement may take a while; the platform answers once it is admitted.
        let platform = crate::cli::Platform::new(
            origin,
            credential.to_string(),
            std::time::Duration::from_secs(120),
        )
        .map_err(|failure| unreachable(failure.message))?;
        let path = format!("/v1/workspaces/{}/machine", percent_segment(&self.workspace));
        platform.post(&path, self.body())
    }
}

/// One URL path segment: unreserved bytes kept, every other byte percent-encoded.
pub(super) fn percent_segment(segment: &str) -> String {
    segment
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

/// `ensure`'s line from the platform's answer: the machine's id and what it booted from.
pub(super) fn ensure_answer(answer: Result<Value, crate::cli::PlatformCallError>) -> Value {
    use crate::cli::PlatformCallError as E;
    match answer {
        Ok(body) => match body.pointer("/machine/id").and_then(Value::as_str) {
            Some(id) => json!({
                "ok": true,
                "machine": id,
                "team": body.get("team"),
                "created": body.get("created").and_then(Value::as_bool).unwrap_or(false),
                "snapshot": body.get("snapshot"),
                "environment": body.get("environment"),
            }),
            None => refused("bad_answer", "the cmux platform answered without the machine"),
        },
        Err(E::Status { status: 404, code: "" | "not_found" }) => {
            refused("unavailable", "this cmux platform has no workspace machines (it answered 404)")
        }
        Err(E::Status { status, code }) => refused(
            if code.is_empty() { "refused" } else { code },
            format!(
                "the cmux platform refused the workspace's machine: {}",
                format!("{status} {code}").trim_end()
            ),
        ),
        Err(E::Unreachable(reason)) => {
            refused("unreachable", format!("the cmux platform did not answer: {reason}"))
        }
        Err(E::Unreadable(status)) => refused(
            "bad_answer",
            format!("the cmux platform answered {status} with no readable body"),
        ),
    }
}

/// `pin`: the send `key` of `account` runs on `machine` (one the App just made
/// for it), which is the Mac workspace `workspace`'s own from now on when the
/// workspace has none yet and no other workspace has it ([`pick::claim`]).
pub(super) fn pin(
    ledger: &Path,
    key: &str,
    account: &str,
    machine: &str,
    workspace: Option<&str>,
) -> Value {
    match Ledger::update(ledger, |pins| {
        pins.record(machine, &Send::new(key, account));
        if let Some(workspace) = workspace {
            pick::claim(pins, workspace, account, machine);
        }
    }) {
        Ok(()) => json!({"ok": true}),
        Err(error) => refused("ledger_failed", format!("{error:#}")),
    }
}

/// `import`: the sends the App kept before cmux-tui did, a JSON list of its
/// entries ([`ledger::AppEntry`]).
pub(super) fn import(ledger: &Path, entries: &str) -> Value {
    let entries: Vec<ledger::AppEntry> = match serde_json::from_str(entries) {
        Ok(entries) => entries,
        Err(error) => return refused("bad_request", error),
    };
    match Ledger::update(ledger, |pins| pins.import(&entries)) {
        Ok(count) => json!({"ok": true, "imported": count}),
        Err(error) => refused("ledger_failed", format!("{error:#}")),
    }
}

/// One push of a folder to a machine: `(socket, local, remote)` to what the
/// answer adds about it ([`pushed_fields`]), or the push's error code and
/// message.
pub(super) type Push<'a> = dyn Fn(&Path, &Path, &str) -> Result<Value, (String, String)> + 'a;

/// `cmux link seed push` (design/cloud.md, "Getting the project onto the
/// machine"): a git folder with a GitHub remote is seeded from it, anything
/// else copied (`cmux link sync push`), which refuses a machine without
/// `fs-v1` (`machine_outdated`) itself.
fn push(socket: &Path, local: &Path, remote: &str) -> Result<Value, (String, String)> {
    super::seed_cli::push(socket, local, remote)
        .map(|pushed| pushed_fields(&pushed.json()))
        .map_err(|error| super::seed_cli::failure(&error))
}

/// What the copy's answer carries of the push's own line: how it went
/// (`mode`: seed or copy), why a seed copied instead (`fallback_code`,
/// `fallback_why`, and `install_url` when the machine needs the GitHub App),
/// and the files it left on this Mac, by name.
fn pushed_fields(line: &Value) -> Value {
    let mut fields = serde_json::Map::new();
    for key in ["mode", "fallback_code", "fallback_why", "install_url", "skipped_files"] {
        if let Some(value) = line.get(key).filter(|value| !value.is_null()) {
            fields.insert(key.to_string(), value.clone());
        }
    }
    Value::Object(fields)
}

/// Folders a chat's copy refuses as too broad: the disk's root and the
/// system's own top folders (each itself; a project below one is fine).
/// The home folder itself is refused too ([`too_broad`]).
const TOO_BROAD: &[&str] = &[
    "/",
    "/System",
    "/Library",
    "/Applications",
    "/Users",
    "/usr",
    "/bin",
    "/sbin",
    "/private",
    "/etc",
    "/var",
    "/tmp",
    "/opt",
    "/Volumes",
    "/home",
    "/root",
];

/// Whether `local` is a folder too broad to copy: the root, a system top
/// folder, or the home folder `home` itself, as spelled or as it resolves
/// (`/etc` is `/private/etc` on a Mac).
pub(super) fn too_broad(local: &str, home: Option<&Path>) -> bool {
    let spelled = PathBuf::from(if local.len() > 1 { local.trim_end_matches('/') } else { local });
    let resolved = std::fs::canonicalize(&spelled).ok();
    let home_resolved = home.and_then(|home| std::fs::canonicalize(home).ok());
    [Some(spelled), resolved].into_iter().flatten().any(|path| {
        TOO_BROAD.iter().any(|broad| path == Path::new(broad))
            || home.is_some_and(|home| path == home)
            || home_resolved.as_deref().is_some_and(|home| path == home)
    })
}

/// `copy`'s arguments.
#[derive(Clone, Debug)]
pub(super) struct StartCopy {
    pub(super) key: String,
    pub(super) account: String,
    pub(super) machine: String,
    pub(super) socket: PathBuf,
    /// The folder that is copied (a Git working copy's top, else the chat's
    /// folder), absolute, as the App spells it (its name on the machine is
    /// hashed from this spelling, as Move to Cloud's is).
    pub(super) local: String,
    /// The chat's folder inside `local`; empty for `local` itself.
    pub(super) subpath: String,
    /// The machine's folders for copies, in the order they are tried.
    pub(super) work_roots: Vec<String>,
    /// This Mac's acpmux home (`--acpmux-home`) for `source_trusted`; none: never trusted.
    pub(super) acpmux_home: Option<PathBuf>,
}

impl StartCopy {
    fn of(flags: &Flags) -> Option<Self> {
        let local = flags.one("--local")?;
        let subpath = flags.one("--subpath").unwrap_or("").trim_matches('/').to_string();
        let work_roots: Vec<String> =
            flags.all("--work-root").into_iter().map(str::to_string).collect();
        if !local.starts_with('/')
            || local == "/"
            || subpath.split('/').any(|part| part == "..")
            || work_roots.is_empty()
            || work_roots.iter().any(|root| !root.starts_with('/'))
        {
            return None;
        }
        Some(Self {
            key: flags.key()?,
            account: flags.account()?.to_string(),
            machine: flags.one("--machine")?.to_string(),
            socket: PathBuf::from(flags.one("--socket")?),
            local: local.to_string(),
            subpath,
            work_roots,
            acpmux_home: trust::acpmux_home(flags),
        })
    }

    /// A new folder for one copy of the send, under its [`Keys::place`].
    pub(super) fn fresh_place(&self) -> String {
        // The first 8 hex digits of a random id (all ASCII, so 8 chars are 8 bytes).
        let id: String = uuid::Uuid::new_v4().simple().to_string().chars().take(8).collect();
        format!("{}/{}", Keys::of(&self.key).place, id)
    }

    /// The copied folder and the chat's folder in it, in `place` under `work_root`.
    pub(super) fn remote(&self, work_root: &str, place: &str) -> (String, String) {
        let folder = join(&join(work_root, place), &remote_name(&self.local));
        let chat =
            if self.subpath.is_empty() { folder.clone() } else { join(&folder, &self.subpath) };
        (folder, chat)
    }

    /// The copy, or the chat's folder of the one that already finished.
    ///
    /// A retry resumes: the copy that did not finish (cut off, its answer
    /// lost, or its process gone) left its folder in the ledger, and the
    /// retry pushes into it again, so what already landed is not sent again
    /// (`cmux link sync push` saves its record as it goes). The folder is
    /// held by a lease for as long as its push runs ([`Lease`], a lock the
    /// system lets go when the process ends, also when it is killed): a
    /// second copy of the same send at once finds it held and takes a new
    /// folder, so two copies never write over each other. No chat opens in
    /// a folder before its copy finished, so a resumed one is never written
    /// over a chat's changes. An abandoned folder (its send never retried
    /// on that machine) stays on the machine; nothing cleans it up.
    pub(super) fn run(&self, ledger: &Path, push: &Push<'_>) -> Value {
        let started_at = now_millis();
        let mut answer = self.run_copy(ledger, push);
        if answer["ok"] == json!(true) {
            answer["source_trusted"] = json!(self.source_trusted());
        }
        let (state, phase) = if answer.get("ok").and_then(Value::as_bool) == Some(true) {
            (
                "done",
                if answer.get("copied").and_then(Value::as_bool) == Some(false) {
                    "cached"
                } else {
                    "complete"
                },
            )
        } else {
            (
                "failed",
                if answer.get("error_code").and_then(Value::as_str) == Some("ledger_failed") {
                    "ledger"
                } else {
                    "copy"
                },
            )
        };
        copy_progress(answer, state, phase, started_at, now_millis())
    }

    fn run_copy(&self, ledger: &Path, push: &Push<'_>) -> Value {
        if too_broad(&self.local, std::env::var_os("HOME").map(PathBuf::from).as_deref()) {
            return refused(
                "folder_too_broad",
                format!(
                    "{} is too broad to copy to a Cloud machine; pick a project folder",
                    self.local
                ),
            );
        }
        let send = Send::new(&self.key, &self.account);
        let in_flight = match Ledger::update(ledger, |pins| {
            pins.copied_chat(&send, &self.machine)
                .map_or_else(|| Err(pins.copy_place(&send, &self.machine)), Ok)
        }) {
            Ok(Ok(chat)) => return json!({"ok": true, "chat": chat, "copied": false}),
            Ok(Err(place)) => place,
            Err(error) => return refused("ledger_failed", format!("{error:#}")),
        };
        // The unfinished copy's folder when no live copy holds it, else a new one.
        let resumed = in_flight
            .and_then(|place| Some((Lease::take(ledger, &send, &self.machine, &place)?, place)));
        let (lease, place) = match resumed {
            Some(held) => held,
            None => {
                let place = self.fresh_place();
                match Lease::take(ledger, &send, &self.machine, &place) {
                    Some(lease) => (lease, place),
                    None => return refused("ledger_failed", "cannot hold the copy's folder"),
                }
            }
        };
        // Checked again under the lease: a copy that finished between the
        // first read and the lease (and let it go) is the send's copy now,
        // and its folder may hold a chat; it is never pushed over.
        match Ledger::update(ledger, |pins| {
            let finished = pins.copied_chat(&send, &self.machine);
            if finished.is_none() {
                pins.start_copy(&send, &self.machine, &place);
            }
            finished
        }) {
            Ok(Some(chat)) => return json!({"ok": true, "chat": chat, "copied": false}),
            Ok(None) => {}
            Err(error) => return refused("ledger_failed", format!("{error:#}")),
        }
        let mut last = ("sync_failed".to_string(), "no work root to copy to".to_string());
        for root in &self.work_roots {
            let (folder, chat) = self.remote(root, &place);
            match push(&self.socket, Path::new(&self.local), &folder) {
                Ok(fields) => {
                    let recorded = Ledger::update(ledger, |pins| {
                        pins.record_copy(&chat, &send, &self.machine, &place);
                    });
                    lease.release();
                    return match recorded {
                        Ok(()) => {
                            let mut answer =
                                json!({"ok": true, "chat": chat, "folder": folder, "copied": true});
                            if let (Some(answer), Value::Object(fields)) =
                                (answer.as_object_mut(), fields)
                            {
                                answer.extend(fields);
                            }
                            answer
                        }
                        Err(error) => refused("ledger_failed", format!("{error:#}")),
                    };
                }
                Err(failure) => {
                    let next = failure.0 == PERMISSION_DENIED;
                    last = failure;
                    // Not this machine's home (an image without the work user): the next root.
                    if !next {
                        break;
                    }
                }
            }
        }
        refused(&last.0, last.1)
    }
}

/// A copy's hold on its folder while its push runs: an exclusive lock on a
/// file of its own beside the ledger (`copies/<hash>.lock`), which the
/// system lets go when the process ends.
pub(super) struct Lease {
    file: std::fs::File,
    path: PathBuf,
}

impl Lease {
    /// Holds `place` of `send` on `machine`; None when a live copy holds it
    /// (or its lock cannot be made).
    pub(super) fn take(ledger: &Path, send: &Send, machine: &str, place: &str) -> Option<Self> {
        use sha2::Digest as _;
        use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
        let dir = ledger.parent()?.join("copies");
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir).ok()?;
        let mut hasher = sha2::Sha256::new();
        for part in [send.key(), send.account(), machine, place] {
            hasher.update(part.as_bytes());
            hasher.update([0]);
        }
        let name: String =
            hasher.finalize().iter().take(16).map(|byte| format!("{byte:02x}")).collect();
        let path = dir.join(format!("{name}.lock"));
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
            .ok()?;
        file.try_lock().ok()?;
        Some(Self { file, path })
    }

    /// The copy finished: its lock file goes.
    fn release(self) {
        let _ = std::fs::remove_file(&self.path);
        drop(self.file);
    }
}

/// `base` and `name` joined by one slash.
fn join(base: &str, name: &str) -> String {
    if base.ends_with('/') { format!("{base}{name}") } else { format!("{base}/{name}") }
}

/// A copied folder's name on a machine: its own name and a short hash
/// (32-bit FNV-1a, low 24 bits) of where it is on this Mac, so two folders
/// with one name never share a copy. The same name Move to Cloud gives
/// (`CloudMoveFolder.remoteName`).
pub(super) fn remote_name(root: &str) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in root.bytes() {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    let name = root.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    let name = if name.is_empty() { "folder" } else { name };
    format!("{name}-{:06x}", hash & 0x00ff_ffff)
}

/// `--flag value` pairs; a flag may repeat (`--work-root`).
struct Flags(Vec<(String, String)>);

impl Flags {
    fn parse(args: &[String]) -> Option<Self> {
        let mut pairs = Vec::new();
        let mut args = args.iter();
        while let Some(flag) = args.next() {
            if !flag.starts_with("--") {
                return None;
            }
            pairs.push((flag.clone(), args.next()?.clone()));
        }
        Some(Self(pairs))
    }

    fn all(&self, name: &str) -> Vec<&str> {
        self.0.iter().filter(|(flag, _)| flag == name).map(|(_, value)| value.as_str()).collect()
    }

    fn one(&self, name: &str) -> Option<&str> {
        match self.all(name).as_slice() {
            [value] => Some(*value),
            _ => None,
        }
    }

    fn key(&self) -> Option<String> {
        self.one("--key").filter(|key| valid_key(key)).map(str::to_string)
    }

    fn account(&self) -> Option<&str> {
        self.one("--account").filter(|account| valid_account(account))
    }

    /// `--workspace`: Some(None) when it is not given, None when it is not a valid id.
    fn workspace(&self) -> Option<Option<&str>> {
        match self.all("--workspace").as_slice() {
            [] => Some(None),
            [workspace] if valid_workspace(workspace) => Some(Some(*workspace)),
            _ => None,
        }
    }
}
