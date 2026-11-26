//! A new machine that never comes up is given up within a bound and replaced by a fresh one, once.
//!
//! Production, 2026-11-17 22:11Z and 2026-11-18 00:21Z (cmuxterm-hq `cloud-chat-replies-production`, runs
//! 44172747597 and 44202141526): `cloud start-session` on a machine this run made waited the app's whole 180 s
//! connect (`connect.link 180005 ms`, then `refused: {"kind":"not_up","state":"parked_timeout"}`), because the
//! machine's session host never registered on the relay. Both machines booted cmux-platform's fallback image pin
//! (`cloud-native-bd31f93-rd022`, bake 2026-11-07), whose cmux-tui exits when its relay ticket command fails
//! (`transport provider failed: relay credential source command was unsuccessful`, then `arm-backoff ms=30000`),
//! and stays down until its updater replaces cmux-tui (22:17:38Z, five minutes after the create). The first run's
//! retry on the same machine linked after 133.6 s and then lost the agent's identify to that update's restart. A
//! fresh machine boots the image the platform follows and links in seconds.
//!
//! So a `start-session` on a machine this run makes for itself (no `--name`, `--target` or `--environment`: the
//! caller asked for a new machine, never for this one) is bounded by [`START_BOUND`]; past it, or on the app's own
//! "didn't connect" or timed-out "agent didn't" answer ([`STUCK_WORDS`]), the run deletes that machine and starts
//! again on a fresh one, at most [`FRESH_RETRIES`] times. A machine it gives up on is always deleted (nobody else
//! could have used it), so nothing is left counting against the team's machines. A delete that cannot happen yet
//! (its create still on its way, the machine pausing) is tried again for up to [`RELEASE_WAIT`]; one it still could
//! not delete stops the retries and names the command that does. A `--from-folder` start is not bounded (its copy
//! runs inside the step), but its app's own stuck answer is retried the same way.
//!
//! A machine still booting is not stuck. Production, 2026-11-26 (cmuxterm-hq `app-chat-production`, run
//! 45723457278): every `cloud.machine_stuck` (6 of 6) was a cold create (no spare: the create took 18 to 28 s, and
//! the platform named no spare claim), and every start that passed (5) claimed a spare (create 3.2 to 5.8 s). A
//! cold machine takes about 90 to 120 s to create and boot: its guest daemon spawned only at the 90 s mark
//! (`cmux-host: spawn-daemon`), its create was still on its way at the bound or the machine was "not running"
//! there, and the run deleted it and cold-created another that needed the same 90 to 120 s, so the retry could not
//! succeed. So at [`START_BOUND`] the run reads the machine ([`Boot`]): one whose create is still on its way, or
//! listed as provisioning or starting, is waited on while it boots, read again every [`BOOT_EVERY`]; once it
//! runs it gets [`UP_BOUND`] to connect and start its agent; all of it within [`COLD_BOUND`] of the start. A machine
//! already running at the bound (the 11-17 bad image pin: running, its session host never on the relay) is given up
//! there, as before.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::internal::bounded::PAST_DEADLINE;
use super::{Deadline, Outcome, Ran, Request, Runner, at, failed, run_once, step_result, words};

/// The longest a `cloud start-session` on a machine this run made may take before the machine is given up, when the
/// machine is running by then (a claimed spare); one still booting then is waited on ([`Boot`], [`COLD_BOUND`]).
/// Production's healthy starts (24 passing `cloud-chat-replies-production` rows, 2026-11-16 to 11-18): the link
/// (`connect.link`) took 1.5 to 31.6 s, median 6.6 s, and the whole step (machine, connect, approvals, anchor, tab,
/// agent start) at most about 60 s (2026-11-17 21:12Z: 10.0 + 33.6 + 8.4 + 3.8 + 4.2 s). The stuck ones waited 180 s
/// and more. 90 s is half again the slowest healthy start, and half the app's own connect wait.
pub(super) const START_BOUND: Duration = Duration::from_secs(90);

/// How many fresh machines a run starts after the first one it gave up on.
// short-gate: fresh machines started after one stuck past START_BOUND (a hang breaker), not retries of a slow start.
pub(super) const FRESH_RETRIES: usize = 1;

/// The code of a start whose new machine never came up ([`stuck`]); after the retries, the run's answer.
pub(super) const STUCK_CODE: &str = "cloud.machine_stuck";

/// The app's words for a start whose machine never came up (CloudStartSessionStrings `notConnected`) or whose
/// agent never answered in time (`agentFailed` with a timed-out reason, e.g. `timed out: identify`). The app sends
/// no code of its own for either (`unavailable`), so its English words are what tells them apart.
const STUCK_WORDS: &[&str] =
    &["didn't connect, so no agent started there", "started but its agent didn't (timed out"];

/// The longest a start on a new machine that was still booting at [`START_BOUND`] may take in all, from the start.
/// 2026-11-26: a cold create plus its boot took about 90 to 120 s (the guest daemon spawned at the 90 s mark); the
/// slowest of those, 120 s, and then [`UP_BOUND`] to connect and start the agent. It ends well before the app's own
/// connect wait (180 s after the create) answers.
pub(super) const COLD_BOUND: Duration = Duration::from_secs(180);

/// How long a machine seen booting at a read, then running at the next one, has to connect and start its agent: the
/// slowest healthy start's whole step (about 60 s, 2026-11-17 21:12Z), whose machine was up from its claim.
pub(super) const UP_BOUND: Duration = Duration::from_secs(60);

/// How often a booting machine is read again ([`Boot`]).
pub(super) const BOOT_EVERY: Duration = Duration::from_secs(10);

/// The longest one read of the machine list may take while a start waits on a booting machine.
const BOOT_READ: Duration = Duration::from_secs(10);

/// The bound of the `start-session` on a machine this run makes ([`START_BOUND`], within the run's deadline), and
/// whether it is moved when it comes ([`Boot::later`]): a machine still booting then is waited on, never given up.
pub(super) struct Boot {
    name: String,
    /// When the start began.
    began: Instant,
    /// Where the start stops now: [`START_BOUND`] from its start, or a later instant [`Boot::later`] named.
    pub(super) until: Instant,
    /// The furthest the start may go: [`COLD_BOUND`] from its start, or the run's deadline when sooner.
    cap: Instant,
    /// The last read found the machine booting.
    booting: bool,
    /// Any read found it booting (the answer's `booted`).
    waited: bool,
}

/// What a read of the machine list says of the machine a start makes.
#[derive(Debug, PartialEq, Eq)]
enum Seen {
    /// Its create is still on its way, or it is listed as provisioning or starting: it is coming up.
    Booting,
    /// Listed as running.
    Running,
    /// Anything else (paused, failed, not listed, the list not read): nothing to wait on.
    Other,
}

impl Boot {
    pub(super) fn new(runner: &mut dyn Runner, name: &str, deadline: Deadline) -> Self {
        let began = runner.now();
        let until = began + deadline.bound(runner, START_BOUND);
        let cap = began + deadline.bound(runner, COLD_BOUND);
        Self { name: name.to_owned(), began, until, cap, booting: false, waited: false }
    }

    /// The start's new end, asked when its `until` came with it still running: [`BOOT_EVERY`] on while the machine
    /// boots, [`UP_BOUND`] on once it runs after booting, never past `cap`. `None` gives the machine up: running
    /// already at the bound (a hang, not a boot), running for its whole [`UP_BOUND`], or `cap` reached.
    pub(super) fn later(&mut self, runner: &mut dyn Runner) -> Option<Instant> {
        if runner.now() >= self.cap {
            return None;
        }
        let seen = self.read(runner);
        let now = runner.now();
        let next = match seen {
            Seen::Booting => {
                self.booting = true;
                self.waited = true;
                now + BOOT_EVERY
            }
            Seen::Running if self.booting => {
                self.booting = false;
                now + UP_BOUND
            }
            Seen::Running | Seen::Other => return None,
        };
        let next = next.min(self.cap);
        (next > now).then(|| {
            self.until = next;
            next
        })
    }

    /// The machine named `name` in the app's list, read within [`BOOT_READ`].
    fn read(&self, runner: &mut dyn Runner) -> Seen {
        let until = (runner.now() + BOOT_READ).min(self.cap);
        let Ok(listed) =
            step_result(&runner.cmux_by(&words(&["cloud", "list-machines", "--json"]), until))
        else {
            return Seen::Other;
        };
        if at(&listed, "loaded").as_bool() == Some(false) {
            return Seen::Other;
        }
        let rows = |key: &str| at(&listed, key).as_array().cloned().unwrap_or_default();
        let named = |row: &Value, key: &str| at(row, key).as_str() == Some(self.name.as_str());
        if let Some(row) = rows("machines").iter().find(|row| named(row, "title")) {
            return match at(row, "status").as_str() {
                Some("running") => Seen::Running,
                // The app lists a create's machine as provisioning until its daemon connects or the list
                // says otherwise (CloudMachineSession `effectiveStatus`); starting is a machine on its way up.
                Some("provisioning" | "starting" | "unknown") => Seen::Booting,
                _ => Seen::Other,
            };
        }
        let creating =
            rows("creating").iter().any(|row| named(row, "name") && at(row, "failed").is_null());
        if creating { Seen::Booting } else { Seen::Other }
    }

    /// How long the start was given before it stopped.
    fn bound(&self) -> Duration {
        self.until.saturating_duration_since(self.began)
    }
}

/// `ran`, the `start-session` on the fresh machine `name`, as a stuck machine: stopped at `boot`'s bound (its own,
/// not the run's deadline nor the runner's), or the app's own stuck answer. `None` for anything else.
pub(super) fn stuck(
    runner: &mut dyn Runner,
    ran: &Ran,
    boot: Option<&Boot>,
    name: &str,
    deadline: Deadline,
) -> Option<Outcome> {
    if ran.code == 0 {
        return None;
    }
    if ran.code == PAST_DEADLINE
        && let Some(boot) = boot
        && !deadline.passed(runner)
        && runner.until().is_none_or(|until| until > boot.until)
    {
        let bound = boot.bound();
        return Some(failed(
            STUCK_CODE,
            format!(
                "Machine `{name}` didn't connect or start its agent within {} s",
                bound.as_secs()
            ),
            json!({"machine_name": name, "bound_ms": bound.as_millis(), "booted": boot.waited,
                   "why": "bound"}),
            1,
        ));
    }
    let error = step_result(ran).err()?;
    let message = at(&error, "message").as_str().unwrap_or_default().to_owned();
    if !STUCK_WORDS.iter().any(|words| message.contains(words)) {
        return None;
    }
    // The app's own next steps (`machine-status`, `start-session --target` on that machine) are for a machine this
    // run then deletes: only its reason is kept.
    let reason = message.split(". Check it").next().unwrap_or_default();
    let reason = reason.split(". Run `").next().unwrap_or_default().trim_end_matches('.');
    Some(failed(STUCK_CODE, reason, json!({"machine_name": name, "why": "app", "app": error}), 1))
}

/// What became of a machine given up on.
struct Released {
    /// Its id, when the app listed it.
    machine_id: Option<String>,
    /// It is gone: deleted now, or never listed and no create of it on its way.
    gone: bool,
    /// Why it is not gone.
    error: Option<Value>,
    /// What the machine said about itself before its delete ([`look`]), when it was looked at.
    guest: Option<Value>,
}

impl Released {
    fn json(&self, name: &str, why: &Value) -> Value {
        let mut row = json!({"machine_name": name, "machine_id": self.machine_id, "why": why,
                             "deleted": self.gone, "error": self.error});
        if let (Some(guest), Some(fields)) = (&self.guest, row.as_object_mut()) {
            fields.insert("guest".to_owned(), guest.clone());
        }
        row
    }
}

/// How long the look at a stuck machine ([`LOOK`]) may take before its delete.
pub(super) const LOOK_BOUND: Duration = Duration::from_secs(25);
/// The most of the look's output kept in the answer.
const LOOK_KEEP: usize = 4000;

/// What a stuck machine is asked before its delete, over the Cloud exec route (the provider's exec, which needs no
/// relay link): its resolver, whether each https host its cmux config names resolves and answers, its session host
/// and server units, and their last log lines. Production, 2026-11-23 (cmuxterm-hq `cloud-chat-replies-production`,
/// runs 45262141250 and 45272430608, cmux-platform#1719): every fresh machine a gateway-mode start made parked its
/// dials for 88 s and was refused `disconnected`: its daemon never joined the relay, and the delete took with it
/// whatever said why. The first line is the look's marker.
pub(super) const LOOK: &str = r#"# cmux stuck-machine look
exec 2>&1
printf 'resolv: %s
' "$(grep -E '^(nameserver|search|options)' /etc/resolv.conf 2>/dev/null | tr '
' ' ')"
for h in $(sudo -n grep -rhoE 'https://[A-Za-z0-9.-]+' /etc/cmux 2>/dev/null | cut -d/ -f3 | sort -u | head -4); do
  a=$(timeout 2 getent hosts "$h" | head -1 | cut -d' ' -f1)
  c=$(curl -sS -m 3 -o /dev/null -w '%{http_code}' "https://$h/" 2>&1 | tail -1 | cut -c1-80)
  printf 'host %s dns=%s http=%s
' "$h" "${a:-fail}" "$c"
done
for u in cmux-host cmux-server; do printf '%s: %s
' "$u" "$(systemctl is-active "$u" 2>&1)"; done
sudo -n journalctl -u cmux-host -u cmux-server -n 15 --no-pager -o short-iso 2>&1 | cut -c1-240"#;

/// The machine `id` asked [`LOOK`] within [`LOOK_BOUND`] (and the run's deadline): its exit code and output, or
/// the route's error. Never fails the run: what it finds is evidence only.
fn look(runner: &mut dyn Runner, id: &str, deadline: Deadline) -> Value {
    let left = deadline.bound(runner, LOOK_BOUND);
    let now = runner.now();
    let until = now.checked_add(left).unwrap_or(now);
    let Some(script) = super::internal::bounded::remote_script(LOOK, left) else {
        return json!({"error": "no time left to look"});
    };
    let target = format!("machine:{id}");
    let args = words(&["cloud", "exec", "--target", &target, "--command", &script, "--json"]);
    match step_result(&runner.cmux_by(&args, until)) {
        Ok(result) => {
            let stdout = at(&result, "stdout").as_str().unwrap_or_default();
            let kept: String = stdout.chars().take(LOOK_KEEP).collect();
            json!({"exit_code": at(&result, "exit_code"), "stdout": kept})
        }
        Err(error) => json!({"error": error}),
    }
}

/// The look's lines that name a host or a unit, on one line: what the run says before the delete.
fn look_said(guest: &Value) -> Option<String> {
    let stdout = at(guest, "stdout").as_str()?;
    let lines: Vec<&str> = stdout
        .lines()
        .filter(|line| line.starts_with("host ") || line.starts_with("cmux-"))
        .collect();
    (!lines.is_empty()).then(|| lines.join("; "))
}

/// How long a delete that cannot happen yet is tried again: a create of the machine still on its way, or a machine
/// that is pausing ("This machine is pausing. Try again once it is paused."). Production, 2026-11-22 (cmuxterm-hq
/// `app-chat-production`, jobs 137042288152, 137057804629 and 137099694829): the Cloud service held a create at
/// `approval.pending` past [`START_BOUND`] twice, and paused a 45-minute-old spare just after its claim once; each
/// time the one delete found nothing to delete yet, so the run ended "could not be deleted" with no fresh machine.
pub(super) const RELEASE_WAIT: Duration = Duration::from_secs(30);
/// How often within [`RELEASE_WAIT`] the delete is tried again.
const RELEASE_EVERY: Duration = Duration::from_secs(3);

/// Deletes the machine named `name` this run made ([`release_once`]); a delete that cannot happen yet (its create
/// still on its way, the machine pausing) is tried again every [`RELEASE_EVERY`] for up to [`RELEASE_WAIT`], within
/// the run's deadline.
///
/// With `looked` (a stuck machine), the machine is first asked [`LOOK`], once, so what it says outlives it.
fn release(runner: &mut dyn Runner, name: &str, deadline: Deadline, looked: bool) -> Released {
    let until = runner.now() + deadline.bound(runner, RELEASE_WAIT);
    let mut guest = (!looked).then_some(Value::Null);
    loop {
        let mut released = release_once(runner, name, &mut guest, deadline);
        if released.gone || !not_yet(&released) || runner.now() + RELEASE_EVERY > until {
            released.guest = guest.filter(|guest| !guest.is_null());
            return released;
        }
        runner.pause(RELEASE_EVERY);
    }
}

/// The delete failed only for now: the machine's create is still on its way, or it is pausing.
fn not_yet(released: &Released) -> bool {
    let message = released.error.as_ref().map(|e| at(e, "message").as_str().unwrap_or_default());
    message.is_some_and(|m| m.contains("still on its way") || m.contains("is pausing"))
}

/// One delete of the machine named `name` this run made: its id from the app's list, then `cloud kill-machine`.
/// `guest` empty: the machine is asked [`LOOK`] first, and the answer kept there.
fn release_once(
    runner: &mut dyn Runner,
    name: &str,
    guest: &mut Option<Value>,
    deadline: Deadline,
) -> Released {
    let listed = match step_result(&runner.cmux(&words(&["cloud", "list-machines", "--json"]))) {
        Ok(listed) => listed,
        Err(error) => {
            return Released { machine_id: None, gone: false, error: Some(error), guest: None };
        }
    };
    let rows = |key: &str| at(&listed, key).as_array().cloned().unwrap_or_default();
    if at(&listed, "loaded").as_bool() == Some(false)
        || listed.pointer("/account/signed_in").and_then(Value::as_bool) == Some(false)
    {
        return Released {
            machine_id: None,
            gone: false,
            error: Some(json!({"message": "the machine list is not available"})),
            guest: None,
        };
    }
    let named = |row: &Value, key: &str| at(row, key).as_str() == Some(name);
    let Some(id) = rows("machines")
        .iter()
        .find(|row| named(row, "title"))
        .and_then(|row| at(row, "machine_id").as_str().map(str::to_owned))
    else {
        // A create of it still on its way has no id to delete yet: it is not gone.
        let creating = rows("creating").iter().any(|row| named(row, "name"));
        let error = creating.then(|| json!({"message": "its create is still on its way"}));
        return Released { machine_id: None, gone: !creating, error, guest: None };
    };
    if guest.is_none() {
        let found = look(runner, &id, deadline);
        if let Some(said) = look_said(&found) {
            runner.say(&format!("Machine `{name}` before its delete: {said}"));
        }
        *guest = Some(found);
    }
    release_id(runner, &id)
}

fn release_id(runner: &mut dyn Runner, id: &str) -> Released {
    let target = format!("machine:{id}");
    let kill = ["cloud", "kill-machine", "--target", target.as_str(), "--confirm", "--json"];
    match step_result(&runner.cmux(&words(&kill))) {
        Ok(_) => Released { machine_id: Some(id.to_owned()), gone: true, error: None, guest: None },
        Err(error) => Released {
            machine_id: Some(id.to_owned()),
            gone: false,
            error: Some(error),
            guest: None,
        },
    }
}

/// A definitive refusal before an agent exists rolls back only this run's newly created machine.
/// A timeout or lost reply is ambiguous, so it keeps the existing retry/reconciliation path.
/// The app wraps daemon refusal codes in its message; retain that original refusal as evidence.
pub(super) fn release_refused(
    runner: &mut dyn Runner,
    fresh_name: Option<&str>,
    made: Option<&str>,
    mut outcome: Outcome,
    deadline: Deadline,
) -> Outcome {
    let Outcome::Failed { error, .. } = &mut outcome else { return outcome };
    if fresh_name.is_none() && made.is_none() {
        return outcome;
    }
    let code = at(error, "code").as_str().unwrap_or_default();
    let message = at(error, "message").as_str().unwrap_or_default();
    let refused = [
        "agent_session.bad_request",
        "agent_session.not_trusted",
        "agent_session.not_asking",
        "agent_session.untrusted_folder",
        "agent_session.harness_missing",
        "agent_session.team_vm_blocked",
        "agent_session.start_unsupported",
    ];
    if !refused.iter().any(|reason| code == *reason || message.contains(reason)) {
        return outcome;
    }
    let released = match (made, fresh_name) {
        (Some(id), _) => release_id(runner, id),
        (None, Some(name)) => release(runner, name, deadline, false),
        (None, None) => return outcome,
    };
    let next = if released.gone {
        "The new machine was deleted because its agent could not start.".to_owned()
    } else {
        released.machine_id.as_ref().map_or_else(
            || "The new machine could not be deleted; find it with `cmux cloud list-machines`, then run `cmux cloud kill-machine --target machine:ID --confirm`.".to_owned(),
            |id| format!("The new machine could not be deleted; run `cmux cloud kill-machine --target machine:{id} --confirm`."),
        )
    };
    // The app's retry command targets the machine we just deleted. Keep it in details.app,
    // while the top-level error names the actual terminal outcome.
    let reason = message.split(". Run `").next().unwrap_or(message);
    error["message"] = json!(format!("{reason}. {next}"));
    if let Some(details) = error.get_mut("details").and_then(Value::as_object_mut) {
        details.insert(
            "cleanup".to_owned(),
            released.json(fresh_name.unwrap_or_default(), &json!("agent_refused")),
        );
    }
    outcome
}

/// `outcome` (the run's first start, begun at `began`), or, when its new machine was stuck ([`stuck`]), the start
/// again on a fresh machine after that one is deleted, up to [`FRESH_RETRIES`] times within the run's one deadline.
/// Every machine given up on is listed under `fresh_retry` (the answer's, or the error's `details`).
pub(super) fn replace_stuck(
    runner: &mut dyn Runner,
    request: &Request,
    began: Instant,
    mut outcome: Outcome,
) -> Outcome {
    // Every retry keeps the run's own deadline: `--timeout` counts from the command's start.
    let again =
        Request { until: request.until.or(Deadline::of(request, began).0), ..request.clone() };
    let deadline = Deadline::of(&again, began);
    let mut replaced = Vec::new();
    let mut tries = 0;
    while let Outcome::Failed { error, .. } = &outcome {
        if at(error, "code").as_str() != Some(STUCK_CODE) {
            break;
        }
        let details = at(error, "details");
        let Some(name) = at(details, "machine_name").as_str().map(str::to_owned) else { break };
        let why = at(details, "why").clone();
        let released = release(runner, &name, deadline, true);
        replaced.push(released.json(&name, &why));
        if !released.gone {
            // The very command `release` ran, so the person's retry of it is the same step.
            let delete = released.machine_id.as_ref().map_or_else(
                || {
                    "find it with `cmux cloud list-machines`, then delete it with `cmux cloud \
                     kill-machine --target machine:ID --confirm`"
                        .to_owned()
                },
                |id| {
                    format!(
                        "delete it with `cmux cloud kill-machine --target machine:{id} --confirm`"
                    )
                },
            );
            if let Outcome::Failed { error, .. } = &mut outcome
                && let Some(message) = error.get("message").and_then(Value::as_str)
            {
                let message = format!("{message}. It could not be deleted; {delete}");
                error["message"] = json!(message);
            }
            break;
        }
        if tries == FRESH_RETRIES || deadline.passed(runner) {
            break;
        }
        tries += 1;
        runner.say(&format!(
            "Machine `{name}` didn't come up, so it was deleted; starting the chat on a fresh machine \
             ({tries} of {FRESH_RETRIES})"
        ));
        outcome = run_once(runner, &again);
    }
    if replaced.is_empty() {
        return outcome;
    }
    let replaced = json!(replaced);
    match &mut outcome {
        Outcome::Done(answer) => {
            answer["fresh_retry"] = replaced;
        }
        Outcome::Failed { error, .. } => {
            if at(error, "code").as_str() == Some(STUCK_CODE)
                && let Some(message) = error.get("message").and_then(Value::as_str)
                && !message.contains("could not be deleted")
            {
                let message = format!(
                    "{message}. cmux deleted it and every machine it tried for this chat ({}); run the same \
                     command again to start on a new one",
                    replaced.as_array().map_or(0, Vec::len)
                );
                error["message"] = json!(message);
            }
            if let Some(details) = error.get_mut("details").and_then(Value::as_object_mut) {
                details.insert("fresh_retry".to_owned(), replaced);
            }
        }
    }
    outcome
}
