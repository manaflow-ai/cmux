//! The cmux-tui CLIs Move to Cloud, Bring Back Local and a chat start run: the arguments of each
//! verb, and what its one JSON answer line means. Each CLI prints `{"ok":true,...}` with exit 0,
//! or `{"ok":false,"error":...,"error_code":...}` with exit 1; bad usage exits 64. The app runs
//! the process (its stdin carries any credential, never argv) and hands the output here.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// The error code of an answer that isn't a JSON line (a crash, a kill).
pub const BAD_ANSWER: &str = "bad_answer";

/// Longer than `link machine update`'s own wait for the machine (25 minutes) plus a first download.
pub const MACHINE_UPDATE_TIMEOUT_SECONDS: u64 = 45 * 60;

/// How long one run may take unless its verb says otherwise; past it the run is killed.
pub const DEFAULT_TIMEOUT_SECONDS: u64 = 30 * 60;

/// A chat start's ledger verbs (`link start-chat pin|create-begin|create-sent|create-refused|
/// target-pane|import`): a read and write of this Mac's ledger file under its lock, which each
/// holder keeps only for an in-memory change (cmux-tui `start_chat_cli/ledger.rs` `update`), no
/// network. A minute is far past any of them; without it a stuck one held a Cloud start for the
/// 30 minutes of [`DEFAULT_TIMEOUT_SECONDS`], with the composer's start card silent all along.
pub const START_CHAT_LEDGER_TIMEOUT_SECONDS: u64 = 60;

/// One CLI's answer line.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Answer {
    pub ok: bool,
    pub error_code: Option<String>,
    pub error: Option<String>,
    /// `link agent move`: the chat's session on the machine.
    #[serde(rename = "sessionID")]
    pub session_id: Option<String>,
    /// `link agent move`: the move's id.
    #[serde(rename = "transferID")]
    pub transfer_id: Option<String>,
    /// `link sync pull`'s `sync_conflict`: the paths changed on both sides.
    pub conflicts: Vec<String>,
    /// `link agent move`'s `machine_outdated`: the daemon it is about, `source` or `target`.
    pub side: Option<String>,
    /// `link machine update`: whether the machine's cmux-tui changed.
    pub updated: bool,
    /// `link machine update`: the build the machine runs after it; with
    /// `machine_update_unsupported`, the build it was judged on (it still runs it).
    pub build: Option<String>,
    /// `link machine update --if-older`: the machine runs a build not older than this app's.
    pub not_older: bool,
    pub seed_state: Option<String>,
    pub seed_phase: Option<String>,
    pub seed_started_at: Option<f64>,
    pub seed_finished_at: Option<f64>,
    /// `link start-chat plan`'s refusal of the platform's Cloud table (cmux-platform#1192): the
    /// same send may pass later (a busy machine, a rate limit, an outage), so the card offers
    /// Retry; false for a cap or any line that does not say.
    pub retryable: bool,
    /// With `retryable`, a rate limit's window in seconds: a Retry before it meets the limit again.
    pub retry_after_s: Option<u64>,
}

impl Answer {
    /// A refusal with `code` and `error`.
    pub fn failed(code: &str, error: impl Into<String>) -> Self {
        Self {
            ok: false,
            error_code: Some(code.to_owned()),
            error: Some(error.into()),
            ..Self::default()
        }
    }

    /// `link machine update`: whether the machine's daemon may have restarted in the run that gave
    /// this answer: an update, a rollback, or an end the CLI lost track of. Not for a machine that
    /// needed nothing, nor for an answer given before anything reached it (another update runs, no
    /// daemon answer, no build to install, too old to update in place, a daemon on someone's own
    /// build from another path).
    pub fn may_have_restarted_daemon(&self) -> bool {
        if self.ok {
            return self.updated;
        }
        !matches!(
            self.error_code.as_deref(),
            Some(
                "machine_update_busy"
                    | "machine_unreachable"
                    | "machine_update_unavailable"
                    | "machine_update_download_failed"
                    | "machine_update_unsupported"
                    | "machine_update_foreign_daemon"
            )
        )
    }
}

/// One run's output, as the app read it.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct Output {
    pub stdout: String,
    pub stderr: String,
    pub status: i32,
}

fn string(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn boolean(object: &Map<String, Value>, key: &str) -> Option<bool> {
    object.get(key).and_then(Value::as_bool)
}

/// The run's last non-blank stdout line as a JSON object with an `ok` flag, else none.
pub fn answer_object(stdout: &str) -> Option<Map<String, Value>> {
    let line = stdout.split('\n').rev().find(|line| !line.trim().is_empty())?;
    let Value::Object(object) = serde_json::from_str::<Value>(line).ok()? else { return None };
    object.get("ok")?.as_bool()?;
    Some(object)
}

/// A run's answer, and its JSON line (none when it printed none). A run with no JSON line is
/// [`BAD_ANSWER`], saying what its stderr said, else its exit status.
pub fn parse(output: &Output) -> (Answer, Option<Map<String, Value>>) {
    let Some(object) = answer_object(&output.stdout) else {
        let detail = output.stderr.trim();
        let error =
            if detail.is_empty() { format!("exit {}", output.status) } else { detail.to_owned() };
        return (Answer::failed(BAD_ANSWER, error), None);
    };
    let answer = Answer {
        ok: boolean(&object, "ok").unwrap_or(false),
        error_code: string(&object, "error_code"),
        error: string(&object, "error"),
        session_id: string(&object, "session_id"),
        transfer_id: string(&object, "transfer_id"),
        conflicts: match object.get("conflicts") {
            // All strings or none, as the app's cast read them.
            Some(Value::Array(items)) if items.iter().all(Value::is_string) => {
                items.iter().filter_map(Value::as_str).map(str::to_owned).collect()
            }
            _ => Vec::new(),
        },
        side: string(&object, "side"),
        updated: boolean(&object, "updated").unwrap_or(false),
        build: string(&object, "build"),
        not_older: boolean(&object, "not_older").unwrap_or(false),
        seed_state: string(&object, "seed_state"),
        seed_phase: string(&object, "seed_phase"),
        seed_started_at: object.get("seed_started_at").and_then(Value::as_f64),
        seed_finished_at: object.get("seed_finished_at").and_then(Value::as_f64),
        retryable: boolean(&object, "retryable").unwrap_or(false),
        retry_after_s: object.get("retry_after_s").and_then(Value::as_u64),
    };
    (answer, Some(object))
}

/// A `link machine update` success is exit 0 with `updated`, and with the `build` it reached
/// when it updated. Any other `ok` line is no answer: an update that ran but said nothing of
/// its outcome must not read as a machine that needed nothing.
pub fn machine_update_answer(
    answer: Answer,
    object: Option<&Map<String, Value>>,
    status: i32,
) -> Answer {
    if !answer.ok {
        return answer;
    }
    let outcome = object.filter(|_| status == 0).and_then(|object| {
        let updated = boolean(object, "updated")?;
        let build =
            object.get("build").and_then(Value::as_str).is_some_and(|build| !build.is_empty());
        (!updated || build).then_some(())
    });
    match outcome {
        Some(()) => answer,
        None => Answer::failed(
            BAD_ANSWER,
            format!("link machine update answered ok without its outcome (exit {status})"),
        ),
    }
}

/// Setup progress returned with a Cloud start plan and forwarded to the startup card.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Setup {
    pub state: Option<String>,
    pub status: Option<String>,
    pub started_at: Option<f64>,
    pub finished_at: Option<f64>,
    pub error: Option<String>,
    pub has_script: Option<bool>,
}

impl Setup {
    /// The setup an object names, with either key spelling; none when it names nothing.
    pub fn read(object: &Map<String, Value>) -> Option<Self> {
        let number = |snake: &str, camel: &str| {
            object
                .get(snake)
                .and_then(Value::as_f64)
                .or_else(|| object.get(camel).and_then(Value::as_f64))
        };
        let setup = Self {
            state: string(object, "state"),
            status: string(object, "status"),
            started_at: number("started_at", "startedAt"),
            finished_at: number("finished_at", "finishedAt"),
            error: string(object, "error"),
            has_script: boolean(object, "has_script").or_else(|| boolean(object, "hasScript")),
        };
        (setup != Self::default()).then_some(setup)
    }
}

/// The environment and setup state carried by a `link start-chat plan` answer.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartInfo {
    pub environment_id: Option<String>,
    pub setup: Option<Setup>,
}

impl StartInfo {
    pub fn read(object: &Map<String, Value>) -> Self {
        let ensured = object.get("ensured").and_then(Value::as_object);
        let environment = ensured
            .and_then(|ensured| ensured.get("environment"))
            .and_then(Value::as_object)
            .or_else(|| object.get("environment").and_then(Value::as_object));
        let setup = ensured
            .and_then(|ensured| ensured.get("setup"))
            .and_then(Value::as_object)
            .or_else(|| object.get("setup").and_then(Value::as_object));
        let environment_id = ensured
            .and_then(|ensured| string(ensured, "environment_id"))
            .or_else(|| string(object, "environment_id"))
            .or_else(|| environment.and_then(|environment| string(environment, "id")));
        Self { environment_id, setup: setup.and_then(Setup::read) }
    }
}

/// `cmux link start-chat plan`'s answer: the machine a `cloud.startChat` send takes (none: make
/// one named `new_name`), pinned to the send, and the send's keys.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartChatPlan {
    pub machine: Option<String>,
    pub new_name: Option<String>,
    pub create_key: String,
    pub tab_key: String,
    pub target_pane: Option<String>,
    pub create_team: Option<String>,
    pub create_sent: bool,
    pub environment_id: Option<String>,
    pub setup: Option<Setup>,
}

/// The plan an answer names. An ok answer without its keys is no answer: a create or open
/// without them is not idempotent.
pub fn start_chat_plan(
    answer: Answer,
    object: Option<&Map<String, Value>>,
) -> (Answer, StartChatPlan) {
    let empty = Map::new();
    let object = object.unwrap_or(&empty);
    let info = StartInfo::read(object);
    let plan = StartChatPlan {
        machine: string(object, "machine"),
        new_name: string(object, "new_name"),
        create_key: string(object, "create_key").unwrap_or_default(),
        tab_key: string(object, "tab_key").unwrap_or_default(),
        target_pane: string(object, "target_pane"),
        create_team: string(object, "create_team"),
        create_sent: boolean(object, "create_sent").unwrap_or(false),
        environment_id: info.environment_id,
        setup: info.setup,
    };
    if answer.ok && (plan.create_key.is_empty() || plan.tab_key.is_empty()) {
        return (
            Answer::failed(BAD_ANSWER, "link start-chat plan answered ok without its keys"),
            plan,
        );
    }
    (answer, plan)
}

/// `cmux link start-chat copy`'s answer: the chat's folder on the machine, whether it copied now,
/// and whether this Mac's acpmux trusts the chat's folder here.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartChatCopy {
    pub chat: String,
    pub folder: String,
    pub copied: bool,
    pub source_trusted: bool,
}

/// The copy an answer names. An ok answer whose folder is not absolute, or whose chat is not in
/// it, is no answer.
pub fn start_chat_copy(
    answer: Answer,
    object: Option<&Map<String, Value>>,
) -> (Answer, StartChatCopy) {
    let empty = Map::new();
    let object = object.unwrap_or(&empty);
    let chat = string(object, "chat").unwrap_or_default();
    let folder = string(object, "folder").unwrap_or_default();
    let inside =
        folder.starts_with('/') && (chat == folder || chat.starts_with(&format!("{folder}/")));
    if answer.ok && !inside {
        let copy = StartChatCopy { chat, folder, copied: false, source_trusted: false };
        return (
            Answer::failed(BAD_ANSWER, "link start-chat copy answered ok without its folder"),
            copy,
        );
    }
    let copy = StartChatCopy {
        copied: boolean(object, "copied").unwrap_or(false),
        source_trusted: boolean(object, "source_trusted") == Some(true),
        chat,
        folder,
    };
    (answer, copy)
}

/// The folder copy a move makes once the chat is frozen (`--sync`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FrozenSync {
    /// Pull from the machine (Bring Back Local) rather than seed it (Move to Cloud).
    pub pull: bool,
    pub socket: String,
    pub local: String,
    pub remote: String,
    /// Machine to machine (Move to another Cloud machine): the source machine's link socket.
    /// `local` is then the folder on that machine, and the copy is `cmux link sync relay`.
    #[serde(default)]
    pub from_socket: Option<String>,
    /// With `from_socket`: the folder on this Mac a Move to Cloud seeded the source from. Its
    /// seed record follows the chat to the new machine, so Bring Back Local still merges there.
    #[serde(default)]
    pub seed_local: Option<String>,
}

/// One CLI call: its verb and the facts its arguments carry.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "verb", rename_all = "kebab-case", rename_all_fields = "camelCase")]
pub enum Call {
    /// `link seed push`: seeds `local` at `remote` from its GitHub remote plus one bundle, else copies it.
    SeedPush {
        socket: String,
        local: String,
        remote: String,
    },
    /// `link seed pull --or-copy` (Bring Back Local).
    BringBackPull {
        socket: String,
        local: String,
        remote: String,
    },
    /// `link agent move`: a running turn stops for the move (`--interrupt`) and goes on where the chat lands.
    AgentMove {
        from: String,
        surface: u64,
        to: String,
        cwd: String,
        #[serde(default)]
        sync: Option<FrozenSync>,
        /// A second copy once the chat is frozen, after `sync` (Move to Another Machine: `sync` pulls
        /// from the machine the chat leaves, this seeds the one it goes to).
        #[serde(default)]
        then_sync: Option<FrozenSync>,
        #[serde(default)]
        ask_first: bool,
        #[serde(default)]
        vm_kind: Option<String>,
        #[serde(default)]
        to_pid: Option<i32>,
    },
    /// `link machine update`: `--to-bundled`, and with `--if-older` only onto an older build.
    MachineUpdate {
        socket: String,
        #[serde(default)]
        to_bundled: bool,
        #[serde(default)]
        if_older: bool,
    },
    /// `link machine pin`: the Linux build this client pins.
    MachinePin,
    /// `link start-chat reserve|release --request JSON`.
    StartChatReservation {
        release: bool,
        request: String,
    },
    /// `link start-chat warm-spare --request JSON`: the person's paused spare, warmed on intent.
    StartChatWarmSpare {
        request: String,
    },
    /// `link start-chat plan --request JSON`.
    StartChatPlan {
        request: String,
    },
    /// `link start-chat pin`: the send runs on `machine`, one the app just made for it.
    StartChatPin {
        key: String,
        account: String,
        machine: String,
        #[serde(default)]
        workspace: Option<String>,
    },
    StartChatCreateBegin {
        key: String,
        account: String,
        name: String,
        create_key: String,
    },
    StartChatCreateSent {
        key: String,
        account: String,
        team: String,
        create_key: String,
    },
    StartChatCreateRefused {
        key: String,
        account: String,
        create_key: String,
    },
    StartChatTargetPane {
        key: String,
        account: String,
        machine: String,
        pane: String,
    },
    /// `link start-chat import`: the sends the app kept itself before.
    StartChatImport {
        entries: String,
    },
    /// `link start-chat copy`: with `store` (the access token on stdin) through the content-addressed store.
    StartChatCopy {
        key: String,
        account: String,
        machine: String,
        socket: String,
        local: String,
        subpath: String,
        #[serde(default)]
        work_roots: Vec<String>,
        #[serde(default)]
        acpmux_home: Option<String>,
        #[serde(default)]
        store: bool,
    },
    /// `link start-chat trust`: this Mac's acpmux trust level for the folder a start would copy, read
    /// before any machine is taken (the copy is trusted there only when this Mac trusts it).
    StartChatTrust {
        folder: String,
        acpmux_home: String,
    },
}

/// How the app runs one call: its arguments and how long it may take.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Invocation {
    pub args: Vec<String>,
    /// A fixed limit; none takes the runner's own.
    pub timeout_seconds: Option<u64>,
    /// The least the runner's limit may be.
    pub min_timeout_seconds: Option<u64>,
}

fn words(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|part| (*part).to_owned()).collect()
}

/// `link agent move`'s flags after `--cwd`: one `--sync` group per copy, run in order.
pub fn agent_move_flags(
    syncs: &[&FrozenSync],
    ask_first: bool,
    vm_kind: Option<&str>,
    to_pid: Option<i32>,
) -> Vec<String> {
    let mut flags = words(&["--interrupt"]);
    for sync in syncs {
        if let Some(from) = &sync.from_socket {
            flags.extend(words(&["--sync", "relay", "--sync-from-socket", from]));
        }
        let kind = if sync.pull { "pull" } else { "seed" };
        let kind = if sync.from_socket.is_some() { None } else { Some(kind) };
        flags.extend(kind.map(|kind| words(&["--sync", kind])).unwrap_or_default());
        flags.extend(words(&[
            "--sync-socket",
            &sync.socket,
            "--sync-local",
            &sync.local,
            "--sync-remote",
            &sync.remote,
        ]));
        if let (Some(_), Some(seed_local)) = (&sync.from_socket, &sync.seed_local) {
            flags.extend(words(&["--sync-seed-local", seed_local]));
        }
    }
    if ask_first {
        flags.push("--ask-first".to_owned());
    }
    if let Some(vm_kind) = vm_kind {
        flags.extend(words(&["--vm-kind", vm_kind]));
    }
    if let Some(pid) = to_pid {
        flags.extend(["--to-pid".to_owned(), pid.to_string()]);
    }
    flags
}

/// The invocation of `call`.
pub fn invocation(call: &Call) -> Invocation {
    let plain =
        |args: Vec<String>| Invocation { args, timeout_seconds: None, min_timeout_seconds: None };
    let ledger = |args: Vec<String>| Invocation {
        args,
        timeout_seconds: Some(START_CHAT_LEDGER_TIMEOUT_SECONDS),
        min_timeout_seconds: None,
    };
    match call {
        Call::SeedPush { socket, local, remote } => {
            plain(words(&["link", "seed", "push", "--socket", socket, local, remote]))
        }
        Call::BringBackPull { socket, local, remote } => {
            plain(words(&["link", "seed", "pull", "--socket", socket, local, remote, "--or-copy"]))
        }
        Call::AgentMove { from, surface, to, cwd, sync, then_sync, ask_first, vm_kind, to_pid } => {
            let surface = surface.to_string();
            let mut args = words(&[
                "link",
                "agent",
                "move",
                "--from-socket",
                from,
                "--surface",
                &surface,
                "--to-socket",
                to,
                "--cwd",
                cwd,
            ]);
            let syncs: Vec<&FrozenSync> = sync.iter().chain(then_sync).collect();
            args.extend(agent_move_flags(&syncs, *ask_first, vm_kind.as_deref(), *to_pid));
            plain(args)
        }
        Call::MachineUpdate { socket, to_bundled, if_older } => {
            let mut args = words(&["link", "machine", "update", "--socket", socket]);
            if *to_bundled {
                args.push("--to-bundled".to_owned());
                if *if_older {
                    args.push("--if-older".to_owned());
                }
            }
            Invocation {
                args,
                timeout_seconds: None,
                min_timeout_seconds: Some(MACHINE_UPDATE_TIMEOUT_SECONDS),
            }
        }
        Call::MachinePin => Invocation {
            args: words(&["link", "machine", "pin"]),
            timeout_seconds: Some(150),
            min_timeout_seconds: None,
        },
        Call::StartChatReservation { release, request } => Invocation {
            args: words(&[
                "link",
                "start-chat",
                if *release { "release" } else { "reserve" },
                "--request",
                request,
            ]),
            timeout_seconds: Some(if *release { 15 } else { 125 }),
            min_timeout_seconds: None,
        },
        Call::StartChatWarmSpare { request } => Invocation {
            args: words(&["link", "start-chat", "warm-spare", "--request", request]),
            // The platform's resume of a paused spare waits for running (CloudCarrier WAIT_MS).
            timeout_seconds: Some(95),
            min_timeout_seconds: None,
        },
        Call::StartChatPlan { request } => {
            plain(words(&["link", "start-chat", "plan", "--request", request]))
        }
        Call::StartChatPin { key, account, machine, workspace } => {
            let mut args = words(&[
                "link",
                "start-chat",
                "pin",
                "--key",
                key,
                "--account",
                account,
                "--machine",
                machine,
            ]);
            if let Some(workspace) = workspace {
                args.extend(words(&["--workspace", workspace]));
            }
            ledger(args)
        }
        Call::StartChatCreateBegin { key, account, name, create_key } => ledger(words(&[
            "link",
            "start-chat",
            "create-begin",
            "--key",
            key,
            "--account",
            account,
            "--name",
            name,
            "--create-key",
            create_key,
        ])),
        Call::StartChatCreateSent { key, account, team, create_key } => ledger(words(&[
            "link",
            "start-chat",
            "create-sent",
            "--key",
            key,
            "--account",
            account,
            "--team",
            team,
            "--create-key",
            create_key,
        ])),
        Call::StartChatCreateRefused { key, account, create_key } => ledger(words(&[
            "link",
            "start-chat",
            "create-refused",
            "--key",
            key,
            "--account",
            account,
            "--create-key",
            create_key,
        ])),
        Call::StartChatTargetPane { key, account, machine, pane } => ledger(words(&[
            "link",
            "start-chat",
            "target-pane",
            "--key",
            key,
            "--account",
            account,
            "--machine",
            machine,
            "--pane",
            pane,
        ])),
        Call::StartChatImport { entries } => {
            ledger(words(&["link", "start-chat", "import", "--entries", entries]))
        }
        Call::StartChatCopy {
            key,
            account,
            machine,
            socket,
            local,
            subpath,
            work_roots,
            acpmux_home,
            store,
        } => {
            let mut args = words(&[
                "link",
                "start-chat",
                "copy",
                "--key",
                key,
                "--account",
                account,
                "--machine",
                machine,
                "--socket",
                socket,
                "--local",
                local,
                "--subpath",
                subpath,
            ]);
            for root in work_roots {
                args.extend(words(&["--work-root", root]));
            }
            if let Some(home) = acpmux_home {
                args.extend(words(&["--acpmux-home", home]));
            }
            // With the cmux access token (on stdin), the copy goes through the content-addressed
            // store (cmux-tui `link/sync_cli/store.rs`); the link copy stays its fallback.
            if *store {
                args.extend(words(&["--store", "default"]));
            }
            plain(args)
        }
        // A local file read: a short fixed bound, so a stuck run never holds the start.
        Call::StartChatTrust { folder, acpmux_home } => Invocation {
            args: words(&[
                "link",
                "start-chat",
                "trust",
                "--folder",
                folder,
                "--acpmux-home",
                acpmux_home,
            ]),
            timeout_seconds: Some(START_CHAT_TRUST_TIMEOUT_SECONDS),
            min_timeout_seconds: None,
        },
    }
}

/// How long `link start-chat trust` may take: it reads this Mac's trust files only.
pub const START_CHAT_TRUST_TIMEOUT_SECONDS: u64 = 15;

/// `link start-chat trust`'s answer: the level this Mac's acpmux answers for the folder
/// (`trusted`, `untrusted` or `unknown`); none when the answer failed or names no level.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct StartChatTrust {
    pub level: Option<String>,
}

/// The level an answer names, only from an ok answer.
pub fn start_chat_trust(answer: &Answer, object: Option<&Map<String, Value>>) -> StartChatTrust {
    let level = object
        .filter(|_| answer.ok)
        .and_then(|object| string(object, "level"))
        .filter(|level| matches!(level.as_str(), "trusted" | "untrusted" | "unknown"));
    StartChatTrust { level }
}

/// How an answer is read, by the verb that gave it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Reading {
    Plain,
    MachineUpdate,
    StartChatPlan,
    StartChatCopy,
    StartChatTrust,
    /// The answer object itself, else a bad answer's.
    Reservation,
}

/// A run's output read as `reading` says: the answer, and the plan, the copy or the object.
pub fn read(reading: Reading, output: &Output) -> Value {
    let (answer, object) = parse(output);
    let mut reply = Map::new();
    match reading {
        Reading::Plain => {
            reply.insert("answer".into(), to_value(&answer));
        }
        Reading::MachineUpdate => {
            reply.insert(
                "answer".into(),
                to_value(&machine_update_answer(answer, object.as_ref(), output.status)),
            );
        }
        Reading::StartChatPlan => {
            let (answer, plan) = start_chat_plan(answer, object.as_ref());
            reply.insert("answer".into(), to_value(&answer));
            reply.insert("plan".into(), to_value(&plan));
        }
        Reading::StartChatCopy => {
            let (answer, copy) = start_chat_copy(answer, object.as_ref());
            reply.insert("answer".into(), to_value(&answer));
            reply.insert("copy".into(), to_value(&copy));
        }
        Reading::StartChatTrust => {
            let trust = start_chat_trust(&answer, object.as_ref());
            reply.insert("answer".into(), to_value(&answer));
            reply.insert("trust".into(), to_value(&trust));
        }
        Reading::Reservation => {
            reply.insert("answer".into(), to_value(&answer));
            let object = object.unwrap_or_else(|| {
                let mut bad = Map::new();
                bad.insert("ok".into(), Value::Bool(false));
                bad.insert("error_code".into(), Value::String(BAD_ANSWER.into()));
                bad
            });
            reply.insert("object".into(), Value::Object(object));
        }
    }
    Value::Object(reply)
}

fn to_value<T: Serialize>(value: &T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

/// The legacy exec update's run (the app runs the fleet's guest upgrade through the Cloud API's
/// exec for a machine too old to update in place).
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ExecRun {
    pub exit_code: i64,
    pub stdout: String,
    pub stderr: String,
}

impl ExecRun {
    /// The last line of stdout: the guest script's result line.
    pub fn last_line(&self) -> &str {
        self.stdout.split(['\n', '\r']).rev().find(|line| !line.is_empty()).unwrap_or("")
    }

    /// What a failure says: the result line, else the end of stderr (its last 400 characters).
    pub fn failure_detail(&self) -> String {
        let line = self.last_line();
        if !line.is_empty() {
            return line.to_owned();
        }
        let count = self.stderr.chars().count();
        self.stderr.chars().skip(count.saturating_sub(400)).collect()
    }

    /// The guest script's result line as a `link machine update` answer for the pinned build
    /// `commit`. No line yet, `running`, or an exec the provider ended (exit 124: the run may still
    /// go on) is `machine_update_unresolved`: the next wait asks again.
    pub fn legacy_update_answer(&self, commit: &str) -> Answer {
        let line = self.last_line();
        let failed = |code: &str| Answer::failed(code, self.failure_detail());
        match line.split(' ').find(|word| !word.is_empty()).unwrap_or("") {
            // UNVERIFIED: the new daemon serves and kept every host; only the terminal count was unreadable.
            // `OK already-current`: the daemon already ran the pinned build; nothing restarted.
            "OK" | "UNVERIFIED" => Answer {
                ok: true,
                updated: !line.starts_with("OK already-current"),
                build: Some(commit.to_owned()),
                ..Answer::default()
            },
            "ROLLBACK" => failed("machine_update_rolled_back"),
            "FAIL" => failed("machine_update_failed"),
            "NOROOT" => failed("machine_update_unsupported"),
            // A daemon the fleet upgrade does not replace (no trusted carrier): not this way.
            "SKIP" if line.starts_with("SKIP unsupported-cloud-auth") => {
                failed("machine_update_unsupported")
            }
            // Between restarts of a crash-looping daemon: ask again later.
            "SKIP" if line.starts_with("SKIP no-daemon") => failed("machine_unreachable"),
            // Another run holds the lock, too little disk, any other skip: nothing changed; ask
            // again later, never a failure kept for the build.
            "SKIP" => failed("machine_update_busy"),
            _ if line.is_empty()
                || line == "running"
                || line.starts_with("PENDING")
                || self.exit_code == 124 =>
            {
                failed("machine_update_unresolved")
            }
            _ => failed("machine_update_failed"),
        }
    }
}

#[cfg(test)]
mod tests;
