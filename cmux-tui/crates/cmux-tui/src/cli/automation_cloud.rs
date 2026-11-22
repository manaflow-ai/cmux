//! `cmux automation … --target cloud`: Cloud Chief jobs on cmux Cloud
//! (docs/automations-platonic-ideal.md, Cloud slice).
//!
//! The CLI holds no account token. Each verb is one `cloud.automation` call
//! to the cmux app, which forwards the op to the API Worker as the signed-in
//! user (`cmux cloud automation-relay`, rules in `cmux_cloud_wire::automation`). A Cloud automation's body
//! is `{type: "chief", chief, conversation, prompt}`: each run puts the prompt
//! in the person's default Cloud Chief's main conversation and starts a turn
//! there, with every computer of the person asleep too. The free plan has one
//! Cloud job; the next create answers `automation.plan.required` with a
//! checkout link, which the CLI prints.

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode};

/// The app bounds its Cloud call at 20 s; the CLI waits a little longer.
const CLOUD_TIMEOUT: Duration = Duration::from_secs(35);

/// A schedule as Cloud triggers (`cron` with an IANA zone, `webhook`, or
/// `manual` only). Every Cloud automation also gets a `manual` trigger, so
/// `run` works on it.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum CloudSchedule {
    Cron { expr: String, tz: String },
    Webhook,
    Manual,
}

impl CloudSchedule {
    pub(super) fn triggers(&self) -> Value {
        match self {
            CloudSchedule::Cron { expr, tz } => {
                json!([{"type": "cron", "expr": expr, "tz": tz}, {"type": "manual"}])
            }
            CloudSchedule::Webhook => json!([{"type": "webhook"}, {"type": "manual"}]),
            CloudSchedule::Manual => json!([{"type": "manual"}]),
        }
    }
}

/// The IANA zone of this machine (`/etc/localtime` points into a zoneinfo
/// folder), else `UTC`.
pub(super) fn local_zone_name() -> String {
    if let Ok(tz) = std::env::var("TZ")
        && tz.contains('/')
        && !tz.starts_with('/')
    {
        return tz;
    }
    std::fs::read_link("/etc/localtime")
        .ok()
        .and_then(|target| zone_from_path(&target.to_string_lossy()))
        .unwrap_or_else(|| "UTC".into())
}

/// `…/zoneinfo/America/Los_Angeles` → `America/Los_Angeles`.
pub(super) fn zone_from_path(path: &str) -> Option<String> {
    let (_, zone) = path.split_once("zoneinfo/")?;
    (!zone.is_empty()).then(|| zone.to_string())
}

/// The default Cloud Chief and its main conversation from a `chief.list`
/// value: the active default one, else the oldest active one.
pub(super) fn default_chief(list: &Value) -> Option<(String, String)> {
    let chiefs = list.get("chiefs")?.as_array()?;
    let active = |c: &&Value| c.get("archived_at").is_none_or(Value::is_null);
    let pick = chiefs
        .iter()
        .filter(active)
        .find(|c| c.get("is_default").and_then(Value::as_bool) == Some(true))
        .or_else(|| chiefs.iter().find(active))?;
    Some((
        pick.get("id")?.as_str()?.to_string(),
        pick.get("main_conversation")?.as_str()?.to_string(),
    ))
}

/// The `automation.create` params of a Cloud job.
pub(super) fn create_params(
    name: &str,
    prompt: &str,
    schedule: &CloudSchedule,
    chief: &(String, String),
    paused: bool,
) -> Value {
    json!({
        "name": name,
        "description": format!("Cloud job made with cmux automation: {}", prompt.chars().take(200).collect::<String>()),
        "enabled": !paused,
        "triggers": schedule.triggers(),
        "body": {"type": "chief", "chief": chief.0, "conversation": chief.1, "prompt": prompt},
    })
}

/// A shell command that runs on one of the team's Cloud machines on each run
/// (`--command … --target cloud`), with the machine asleep or not: the
/// Cloud's own scheduler fires it, so this Mac can sleep. One provider exec
/// answers within about 300 s, so the run is a `steps` body of machine steps:
/// step 0 starts the command detached on the machine (in `folder`, or in a
/// checkout of `repo` moved to the newest head of its branch first), and each
/// later step waits up to [`WAIT_SECONDS`] for it to end. The first wait that
/// sees it end answers with its exit code (a failure carries the log's last
/// lines, so the run's reason names them); the last one ends a command still
/// running at `timeout_seconds` as a timeout. The command's whole output stays
/// on the machine (`~/.cmux/automations/runs/RUN/log`, `logs RUN --target
/// cloud`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct CloudCommand {
    pub command: String,
    pub folder: Option<String>,
    /// `OWNER/NAME` and the branch whose newest head each run checks out.
    pub repo: Option<(String, String)>,
    /// The Cloud machine (`vm_…`).
    pub machine: String,
    pub timeout_seconds: u64,
}

/// How long one wait step waits. Its step limit is this plus [`STEP_SLACK`],
/// [`STEP_LIMIT`], within the provider's 300 s exec. (On 2026-11-21 an exec
/// held open was cut at about 125 s by the provider's edge, a 524; cmux-vm now
/// sends a longer one as a background request, workers/cmux-vm
/// src/upstream/live-background.ts, and a 200 s step passed on production.)
pub(super) const WAIT_SECONDS: u64 = 280;
const STEP_SLACK: u64 = 10;
/// The limit of every step, the start step's too: within the provider's 300 s.
const STEP_LIMIT: u64 = WAIT_SECONDS + STEP_SLACK;
/// A body holds at most 50 steps: one start and 49 waits.
pub(super) const MAX_CLOUD_COMMAND_SECONDS: u64 = 49 * WAIT_SECONDS;
/// Where a run keeps its files on the machine (under the machine user's home).
const RUNS: &str = "$HOME/.cmux/automations/runs";

/// `~/x` and `~` as `"$HOME"/x`, anything else quoted as it is.
fn folder_words(folder: &str) -> String {
    match folder.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => {
            format!("\"$HOME\"{}", super::cloud_start_chat::shell_quote(rest))
        }
        _ => super::cloud_start_chat::shell_quote(folder),
    }
}

/// A checkout folder name for `repo` (`owner-name`).
fn checkout_name(repo: &str) -> String {
    repo.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).collect()
}

/// Step 0's script: start the command once per run (`CMUX_RUN` names it), detached.
/// A repo's checkout (the first clone of a large repo takes minutes; manaflow-ai/cmux's is 1.1 GB)
/// runs in the detached part too, before the command, so step 0 returns at once and the wait steps
/// cover the clone (in step 0 it outlived the provider's exec and the run failed "the machine did
/// not answer", leaving a half-made checkout and its `index.lock`, which the next run clears).
/// It leads a session of its own (`setsid`, or perl's where there is none, as on macOS), so the
/// step's process group can end without it and the last wait can end its whole group. The step
/// returns only after the command detached (its `detached` mark, at most 10 s), so a step runner
/// that ends the step's group on exit never ends the command. No `nohup`: macOS's fails with "can't
/// detach from console" under launchd (a fleet or Cloud daemon), so the command ignores HUP itself.
pub(super) fn start_script(c: &CloudCommand) -> String {
    let q = super::cloud_start_chat::shell_quote;
    // `prep.sh WORKDIR RUNDIR`: what readies the folder, run detached before the command.
    let (place, prep) = match (&c.repo, &c.folder) {
        (Some((repo, branch)), _) => (
            format!("w=\"$HOME/.cmux/automations/checkouts/\"{}; ", q(&checkout_name(repo))),
            format!(
                "set -e; w=\"$1\"; rm -f \"$w/.git/index.lock\"; \
                 if [ -d \"$w/.git\" ]; then git -C \"$w\" fetch --quiet origin {branch} && git -C \"$w\" checkout --quiet --force --detach FETCH_HEAD; \
                 else rm -rf \"$w\" && mkdir -p \"$(dirname \"$w\")\" && git clone --quiet --filter=blob:none --branch {branch} {url} \"$w\"; fi; \
                 git -C \"$w\" log -1 --format='%H %s' > \"$2/commit\"",
                branch = q(branch),
                url = q(&format!("https://github.com/{repo}.git")),
            ),
        ),
        (None, Some(folder)) => (format!("w={}; ", folder_words(folder)), ":".into()),
        (None, None) => ("w=\"$HOME\"; ".into(), ":".into()),
    };
    format!(
        "set -e; d=\"{RUNS}/$CMUX_RUN\"; if [ -e \"$d/started\" ]; then echo started; exit 0; fi; mkdir -p \"$d\"; \
         {place}printf '%s\\n' {prep} > \"$d/prep.sh\"; printf '%s\\n' {command} > \"$d/cmd.sh\"; s=; if command -v setsid >/dev/null 2>&1; then s=setsid; \
         elif command -v perl >/dev/null 2>&1; then s='perl -MPOSIX -e POSIX::setsid();exec(@ARGV)'; fi; \
         $s sh -c 'trap \"\" HUP; : > \"$1/detached\"; {{ bash \"$1/prep.sh\" \"$2\" \"$1\" && cd \"$2\" && bash \"$1/cmd.sh\"; }} > \"$1/log\" 2>&1; echo $? > \"$1/exit.tmp\"; mv \"$1/exit.tmp\" \"$1/exit\"' _ \"$d\" \"$w\" </dev/null >/dev/null 2>\"$d/launch.log\" & \
         echo $! > \"$d/pid\"; i=0; while [ ! -e \"$d/detached\" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; \
         : > \"$d/started\"; echo started in \"$w\"",
        prep = q(&prep),
        command = q(&c.command),
    )
}

/// A wait step's script: wait up to `wait` seconds for the command to end;
/// `last`: end a command still running as a timeout (exit 124).
pub(super) fn wait_script(wait: u64, last: bool) -> String {
    let still = if last {
        "p=$(cat \"$d/pid\" 2>/dev/null); [ -n \"$p\" ] && { kill -TERM -- -\"$p\" 2>/dev/null || kill -TERM \"$p\" 2>/dev/null; sleep 5; \
         kill -KILL -- -\"$p\" 2>/dev/null || kill -KILL \"$p\" 2>/dev/null; }; tail -n 20 \"$d/log\" >&2; echo timed out >&2; exit 124"
    } else {
        "echo running; exit 0"
    };
    format!(
        "d=\"{RUNS}/$CMUX_RUN\"; e=$(( $(date +%s) + {wait} )); \
         while [ ! -e \"$d/exit\" ] && [ \"$(date +%s)\" -lt \"$e\" ]; do sleep 2; done; \
         if [ -e \"$d/exit\" ]; then c=$(cat \"$d/exit\"); if [ \"$c\" = 0 ]; then tail -c 4000 \"$d/log\"; exit 0; fi; \
         tail -n 20 \"$d/log\" >&2; exit \"$c\"; fi; {still}"
    )
}

/// The `steps` body of `c`: one start step, then enough waits to cover its timeout.
pub(super) fn command_body(c: &CloudCommand) -> Value {
    let waits = c.timeout_seconds.clamp(1, MAX_CLOUD_COMMAND_SECONDS).div_ceil(WAIT_SECONDS);
    let mut steps = vec![json!({
        "type": "machine", "machine": c.machine, "command": start_script(c), "timeout_seconds": STEP_LIMIT,
    })];
    let mut left = c.timeout_seconds.clamp(1, MAX_CLOUD_COMMAND_SECONDS);
    for i in 0..waits {
        let wait = left.min(WAIT_SECONDS);
        left -= wait;
        steps.push(json!({
            "type": "machine", "machine": c.machine, "command": wait_script(wait, i + 1 == waits),
            "timeout_seconds": wait + STEP_SLACK,
        }));
    }
    json!({"type": "steps", "steps": steps})
}

/// The `automation.create` params of a Cloud command automation: one live run
/// at a time (a run that fires while one runs is skipped).
pub(super) fn command_create_params(
    name: &str,
    c: &CloudCommand,
    schedule: &CloudSchedule,
    catch_up: Option<&str>,
    paused: bool,
) -> Value {
    let mut params = json!({
        "name": name,
        "description": format!("Cloud command made with cmux automation: {}", c.command.chars().take(200).collect::<String>()),
        "enabled": !paused,
        "triggers": schedule.triggers(),
        "body": command_body(c),
        "concurrency": {"max": 1, "on_limit": "skip"},
    });
    if let Some(policy) = catch_up {
        params["catch_up"] = json!(policy);
    }
    params
}

/// The machine of a Cloud command automation's body (its first machine step).
pub(super) fn command_machine(body: &Value) -> Option<&str> {
    body.get("steps")?.as_array()?.iter().find_map(|s| s.get("machine")?.as_str())
}

/// The script `logs RUN --target cloud` runs on the machine: the run's log,
/// wherever the machine user's home is.
pub(super) fn log_script(run: &str) -> String {
    let run = super::cloud_start_chat::shell_quote(run);
    format!(
        "for f in \"$HOME/.cmux/automations/runs/\"{run}/log /home/*/.cmux/automations/runs/{run}/log /root/.cmux/automations/runs/{run}/log; do \
         if [ -r \"$f\" ]; then tail -c 262144 \"$f\"; exit 0; fi; done; echo \"no log for this run on the machine\" >&2; exit 3"
    )
}

/// A fresh idempotency key for one mutation of this command (the global
/// `--idempotency-key` wins, so a retried command applies once).
pub(super) fn key(global: &GlobalArgs, verb: &str) -> String {
    if let Some(k) = &global.idempotency_key {
        return k.clone();
    }
    let mut bytes = [0u8; 12];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        use std::io::Read as _;
        let _ = f.read_exact(&mut bytes);
    }
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("cli-automation-{verb}-{hex}")
}

/// What one `cloud.automation` call answered.
pub(super) enum Answer {
    /// The op's value.
    Value(Value),
    /// The owner (or the app) refused: the error object, details included.
    Refused(Value),
}

/// One `cloud.automation` call to the cmux app.
pub(super) fn call(
    global: &GlobalArgs,
    op: &str,
    params: Value,
    key: Option<String>,
) -> Result<Answer, Value> {
    let mut stream = super::app::connect_command(global)?;
    let mut request = Map::new();
    request.insert("op".into(), json!(op));
    request.insert("params".into(), params);
    if let Some(k) = key {
        request.insert("idempotency_key".into(), json!(k));
    }
    match super::app::request(
        &mut stream,
        "cloud.automation",
        Value::Object(request),
        CLOUD_TIMEOUT,
    ) {
        Ok(Ok(reply)) => Ok(match reply.get("ok").and_then(Value::as_bool) {
            Some(true) => Answer::Value(reply.get("value").cloned().unwrap_or(Value::Null)),
            _ => Answer::Refused(
                reply.get("error").cloned().unwrap_or_else(|| json!({"code": "owner.bad_reply"})),
            ),
        }),
        Ok(Err(error)) => Err(error),
        Err(message) => Err(json!({"code": "app.transport", "message": message})),
    }
}

/// The exit code of a refusal: 4 for a plan refusal (a person can act on
/// it), 3 signed out, 5 an app without the method, 1 else.
pub(super) fn refusal_exit(error: &Value) -> i32 {
    match error.get("code").and_then(Value::as_str).unwrap_or("error") {
        "automation.plan.required" => 4,
        "automation.signed_out" | "not_signed_in" => 3,
        "method_not_found" => 5,
        _ => 1,
    }
}

/// Prints a refusal: the checkout link of a plan refusal on its own line.
/// Exit as [`refusal_exit`].
pub(super) fn print_refusal(error: &Value, output: OutputMode) -> i32 {
    let code = error.get("code").and_then(Value::as_str).unwrap_or("error");
    let exit = refusal_exit(error);
    if output == OutputMode::Json {
        println!("{}", json!({"ok": false, "error": error}));
        return exit;
    }
    let message = error.get("message").and_then(Value::as_str).unwrap_or("");
    eprintln!("cmux: {code}: {message}");
    if let Some(link) = error.get("details").and_then(|d| d.get("checkout")).and_then(Value::as_str)
    {
        eprintln!("{link}");
    }
    exit
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zone_names_come_from_the_zoneinfo_link() {
        assert_eq!(
            zone_from_path("/var/db/timezone/zoneinfo/America/Los_Angeles").as_deref(),
            Some("America/Los_Angeles")
        );
        assert_eq!(zone_from_path("/usr/share/zoneinfo/UTC").as_deref(), Some("UTC"));
        assert_eq!(zone_from_path("/etc/elsewhere"), None);
    }

    #[test]
    fn the_default_active_chief_is_picked() {
        let list = json!({"chiefs": [
            {"id": "agent_OLD", "is_default": true, "archived_at": 5, "main_conversation": "c_old"},
            {"id": "agent_A", "is_default": false, "archived_at": null, "main_conversation": "c_a"},
            {"id": "agent_B", "is_default": true, "archived_at": null, "main_conversation": "c_b"},
        ], "tombstones": []});
        assert_eq!(default_chief(&list), Some(("agent_B".into(), "c_b".into())));
        let no_default =
            json!({"chiefs": [{"id": "agent_A", "is_default": false, "main_conversation": "c_a"}]});
        assert_eq!(default_chief(&no_default), Some(("agent_A".into(), "c_a".into())));
        assert_eq!(default_chief(&json!({"chiefs": []})), None);
    }

    fn scout(timeout: u64) -> CloudCommand {
        CloudCommand {
            command: "bash scripts/models/run-scout.sh".into(),
            folder: None,
            repo: Some(("manaflow-ai/cmux".into(), "feat-cmux-next".into())),
            machine: "vm_abcdefghij0123456789".into(),
            timeout_seconds: timeout,
        }
    }

    #[test]
    fn every_step_ends_before_the_provider_cuts_an_exec_even_at_the_longest_timeout() {
        for timeout in [
            1,
            WAIT_SECONDS,
            WAIT_SECONDS + 1,
            1_200,
            MAX_CLOUD_COMMAND_SECONDS,
            MAX_CLOUD_COMMAND_SECONDS + 999,
        ] {
            let body = command_body(&scout(timeout));
            let steps = body["steps"].as_array().unwrap();
            assert!(
                steps.len() <= 50,
                "a body holds at most 50 steps ({timeout} s: {})",
                steps.len()
            );
            // STEP_LIMIT itself stays within the provider's 300 s exec; checked at compile time.
            const { assert!(STEP_LIMIT <= 300) };
            for (i, s) in steps.iter().enumerate() {
                let limit = s["timeout_seconds"].as_u64().unwrap();
                assert!(
                    limit <= STEP_LIMIT,
                    "{timeout} s: step {i} may run {limit} s, past the provider's 300 s exec"
                );
            }
            let waited: u64 = steps[1..]
                .iter()
                .map(|s| s["timeout_seconds"].as_u64().unwrap() - STEP_SLACK)
                .sum();
            assert_eq!(
                waited,
                timeout.clamp(1, MAX_CLOUD_COMMAND_SECONDS),
                "the waits cover the timeout exactly"
            );
        }
        for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
            let usage = crate::localization::catalog_for_locale(locale).automation.usage;
            let max = format!("{}m", MAX_CLOUD_COMMAND_SECONDS / 60);
            assert!(
                usage.contains(&max),
                "{locale}: the help names the real --timeout maximum, {max}"
            );
        }
    }

    #[test]
    fn a_cloud_command_is_one_start_step_then_waits_that_cover_its_timeout() {
        let p = command_create_params(
            "models-scout",
            &scout(1_200),
            &CloudSchedule::Cron { expr: "0 */6 * * *".into(), tz: "UTC".into() },
            Some("latest"),
            false,
        );
        let steps = p["body"]["steps"].as_array().unwrap();
        assert_eq!(p["body"]["type"], "steps");
        assert_eq!(steps.len(), 1 + 5, "20 min = 5 waits of at most 280 s");
        for s in steps {
            assert_eq!(s["type"], "machine");
            assert_eq!(s["machine"], "vm_abcdefghij0123456789");
            assert!(
                s["timeout_seconds"].as_u64().unwrap() <= 300,
                "one provider exec answers within 300 s"
            );
            assert!(
                s["command"].as_str().unwrap().len() <= 4000,
                "a step command is at most 4000 characters"
            );
        }
        assert!(
            steps[0]["command"]
                .as_str()
                .unwrap()
                .contains("git -C \"$w\" fetch --quiet origin feat-cmux-next"),
            "each run moves to the branch's newest head"
        );
        assert_eq!(p["concurrency"], json!({"max": 1, "on_limit": "skip"}));
        assert_eq!(p["catch_up"], "latest");
        assert_eq!(p["triggers"][1], json!({"type": "manual"}));
        assert_eq!(command_machine(&p["body"]), Some("vm_abcdefghij0123456789"));
        let long = command_body(&scout(10 * 86_400));
        assert_eq!(long["steps"].as_array().unwrap().len(), 50, "a body holds at most 50 steps");
    }

    /// Runs one step script as the Workflow does (`bash -lc`, `CMUX_RUN` set) with HOME at `home`.
    fn step(script: &str, home: &std::path::Path, run: &str) -> (i32, String, String) {
        let out = cmux_process::Command::new("bash")
            .args(["-c", script])
            .env("HOME", home)
            .env("CMUX_RUN", run)
            .stdin(cmux_process::Stdio::null())
            .output()
            .unwrap();
        (
            out.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&out.stdout).into(),
            String::from_utf8_lossy(&out.stderr).into(),
        )
    }

    #[test]
    fn the_step_scripts_start_once_wait_and_answer_the_commands_exit() {
        let home = std::env::temp_dir().join(format!("cmux-cloud-command-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join("work")).unwrap();
        let mut c = scout(60);
        c.repo = None;
        c.folder = Some("~/work".into());

        // A command that succeeds: the start answers at once, a wait sees it end.
        c.command = "pwd; echo hello".into();
        let (code, out, _) = step(&start_script(&c), &home, "run_ok");
        assert_eq!(code, 0, "{out}");
        let (again, out2, _) = step(&start_script(&c), &home, "run_ok");
        assert_eq!((again, out2.trim()), (0, "started"), "a replayed start never starts it twice");
        let (code, out, err) = step(&wait_script(20, true), &home, "run_ok");
        let launch = std::fs::read_to_string(home.join(".cmux/automations/runs/run_ok/launch.log"))
            .unwrap_or_default();
        assert_eq!(code, 0, "wait: {err}; launch: {launch}");
        assert!(out.contains("hello") && out.contains("/work"), "{out}");
        let log = std::fs::read_to_string(home.join(".cmux/automations/runs/run_ok/log")).unwrap();
        assert!(log.contains("hello"));

        // A command that fails: the wait answers its exit code with the log's last lines on stderr.
        c.command = "echo building; echo 'error: 2 tests failed' >&2; exit 3".into();
        step(&start_script(&c), &home, "run_fail");
        let (code, _, err) = step(&wait_script(20, true), &home, "run_fail");
        assert_eq!(code, 3);
        assert!(err.contains("error: 2 tests failed"), "{err}");

        // A command still running: a middle wait says so, the last one ends it as a timeout.
        c.command = "sleep 30; echo never".into();
        step(&start_script(&c), &home, "run_slow");
        let (code, out, _) = step(&wait_script(1, false), &home, "run_slow");
        assert_eq!((code, out.trim()), (0, "running"));
        let (code, _, err) = step(&wait_script(1, true), &home, "run_slow");
        assert_eq!(code, 124, "{err}");
        assert!(err.contains("timed out"));
        let (code, out, _) = step(&log_script("run_fail"), &home, "x");
        assert_eq!(code, 0);
        assert!(out.contains("building"));
        let (code, _, _) = step(&log_script("run_none"), &home, "x");
        assert_eq!(code, 3);
        let _ = std::fs::remove_dir_all(&home);
    }

    /// [`step`] with `PATH` led by `bin`.
    fn step_with_path(
        script: &str,
        home: &std::path::Path,
        run: &str,
        bin: &std::path::Path,
    ) -> (i32, String, String) {
        let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
        let out = cmux_process::Command::new("bash")
            .args(["-c", script])
            .env("HOME", home)
            .env("CMUX_RUN", run)
            .env("PATH", path)
            .stdin(cmux_process::Stdio::null())
            .output()
            .unwrap();
        (
            out.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&out.stdout).into(),
            String::from_utf8_lossy(&out.stderr).into(),
        )
    }

    /// models-scout on a fresh machine (2026-11-20): step 0 cloned manaflow-ai/cmux (1.1 GB) in the
    /// foreground, the provider's exec gave up first ("the machine did not answer") and left a
    /// half-made checkout with its `index.lock`. The checkout now runs detached, before the command.
    #[cfg(unix)]
    #[test]
    fn a_slow_first_clone_runs_detached_so_the_start_step_answers_at_once() {
        let home = std::env::temp_dir().join(format!("cmux-cloud-clone-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let bin = home.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        // A git whose clone takes 3 s and makes the checkout; every other verb succeeds.
        let git = bin.join("git");
        std::fs::write(&git, "#!/bin/sh\nif [ \"$1\" = clone ]; then sleep 3; for a; do w=\"$a\"; done; mkdir -p \"$w/.git\"; fi\nexit 0\n").unwrap();
        std::fs::set_permissions(&git, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        let mut c = scout(60);
        c.command = "pwd; echo hello".into();

        let started = std::time::Instant::now();
        let (code, out, err) = step_with_path(&start_script(&c), &home, "run_clone", &bin);
        assert_eq!(code, 0, "{out} {err}");
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "step 0 waited for the clone: {:?}",
            started.elapsed()
        );
        let (code, out, err) = step_with_path(&wait_script(20, true), &home, "run_clone", &bin);
        assert_eq!(code, 0, "{err}");
        assert!(out.contains("hello") && out.contains("checkouts/manaflow-ai-cmux"), "{out}");

        // A half-made checkout (a clone the provider ended) is fetched again, its lock cleared.
        std::fs::write(
            home.join(".cmux/automations/checkouts/manaflow-ai-cmux/.git/index.lock"),
            "",
        )
        .unwrap();
        step_with_path(&start_script(&c), &home, "run_again", &bin);
        let (code, out, err) = step_with_path(&wait_script(20, true), &home, "run_again", &bin);
        assert_eq!(code, 0, "{err}");
        assert!(out.contains("hello"), "{out}");
        assert!(
            !home.join(".cmux/automations/checkouts/manaflow-ai-cmux/.git/index.lock").exists()
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn create_params_make_a_chief_job_with_a_manual_trigger() {
        let p = create_params(
            "Morning brief",
            "Summarize PRs",
            &CloudSchedule::Cron { expr: "0 9 * * 1-5".into(), tz: "America/Los_Angeles".into() },
            &("agent_B".into(), "c_b".into()),
            false,
        );
        assert_eq!(
            p["body"],
            json!({"type": "chief", "chief": "agent_B", "conversation": "c_b", "prompt": "Summarize PRs"})
        );
        assert_eq!(
            p["triggers"],
            json!([{"type": "cron", "expr": "0 9 * * 1-5", "tz": "America/Los_Angeles"}, {"type": "manual"}])
        );
        assert_eq!(p["enabled"], json!(true));
        assert_eq!(CloudSchedule::Manual.triggers(), json!([{"type": "manual"}]));
    }
}
