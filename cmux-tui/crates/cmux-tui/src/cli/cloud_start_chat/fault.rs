//! `cmux cloud start-chat … --carrier-fault kill-route=ROUTE,after-events=N`: the probe account's
//! carrier fault drill (crate::carrier::fault). Not in the usage text: it is for cmux's probe
//! accounts only, and every other caller is refused before anything starts.
//!
//! The order, each step before any machine or chat is made:
//! 1. `CMUX_CARRIER_PROBE_FAULTS=1`, else `carrier_fault.not_probe`.
//! 2. A prompt and `--wait` (the drill kills the carrier mid-turn), else `usage.invalid`.
//! 3. The app's signed-in account (`cloud diagnostics`' `email`) is a probe account, else
//!    `carrier_fault.not_probe` (the same refusal, so it tells a person nothing more).
//! 4. The fault leaves the turn another carrier to go on over, else
//!    `carrier_fault.no_other_route`. A device whose only route is the relay (ssh unavailable
//!    in `carrier capabilities`: no tunnel hub, or no carrier key) always ends here for
//!    `kill-route=relay`.
//!
//! 5. The drill's event source (`internal/fault_routes.rs`): the chat starts as `cloud start-chat` starts one,
//!    without its prompt (a start's own failure is the answer, unchanged, so a probe retries a cold start as
//!    it does any); the app hands its credential (`auth.token`, else `carrier_fault.no_credential`); one Cloud
//!    carrier dial to the machine opens the chat tab's event stream on the relay, and the prompt is sent once
//!    it is attached. The drill kills the relay inside that dial after N events, the session resumes over ssh
//!    and the stream attaches again there after the last seq it had.
//!
//! A refusal at step 4 or later carries the drill record in `error.details`: `capabilities`
//! (`routes`, `faults`), `fault`, `kill`, `events` and `resumes`, the fields the probe's judge reads
//! (cmuxterm-hq `cloud_carrier_failover_probe.py`). Exit 2 for every refusal. A drill that reached
//! the turn's last event answers the same record under `drill` (exit 0): the judge, not this
//! command, says whether it lost, repeated or resumed from the wrong seq.
//!
//! No answer after step 4 hides where the drill stopped: a failure of the start, the credential or the dial (a
//! `--timeout` that ran out included) carries the partial record as `details.drill` beside the start's own
//! `stages_ms`: the empty record, `steps` (`start`, `credential`, `dial`, each `{step, ms, ok}`), `stopped_in`,
//! `elapsed_ms` and `timeout_ms`; the turn's record adds `turn_ms`, `timeout_ms` and, when it did not finish,
//! `stopped_in` (`relay connect`, `relay events`, `ssh resume`, `ssh events`; [`turn_step`]).

use serde_json::{Value, json};

use std::time::{Duration, Instant};

use super::internal::{self, fault_routes};
use super::{
    GlobalArgs, Outcome, Parsed, Request, Runner, SelfRunner, TAKES_VALUE, UsageError, failed,
    lift_output_of, parse, report, run, send_to, step_result, words,
};
use crate::carrier::drill::{Drill, EventRoutes, run_drill};
use crate::carrier::fault::{
    Carrier, FaultPlan, FaultSpec, capabilities, parse_spec, probe_gate, probe_run, routes,
    this_device,
};

/// The flag.
pub(super) const FLAG: &str = "--carrier-fault";
/// The prompt `--prompt -` stands for until the drill reads stdin.
const STDIN_PROMPT: &str = "(the prompt on stdin, read when the drill runs)";
const NOT_PROBE: &str = "--carrier-fault is for cmux's probe accounts only";
/// `auth.token`'s own limit (auth_token.rs).
const TOKEN_TIMEOUT: Duration = Duration::from_secs(30);

/// `cloud start-chat …` with `--carrier-fault` (`rest`: the words after the verb), run as the
/// drill; `None` without the flag, for the usual start. Read before the start's own parse, which
/// never sees the flag.
pub(super) fn run_if_requested(global: &GlobalArgs, rest: &[String]) -> Option<i32> {
    let mut global = global.clone();
    let takes: Vec<&str> = TAKES_VALUE.iter().copied().chain([FLAG]).collect();
    let lifted = lift_output_of(rest, &mut global.output, &takes);
    let usage = |error: UsageError, output| {
        let text = format!("cmux: {}\n{}", error.0, crate::cli::cloud_help::START_CHAT_USAGE);
        crate::cli::app::failure("usage.invalid", &text, output, 2)
    };
    let (words, spec) = match take(&lifted) {
        Ok((_, None)) => return None,
        Ok((words, Some(spec))) => (words, spec),
        Err(error) => return Some(usage(error, global.output)),
    };
    // `--prompt -` is not read here: reading stdin first would block a refused run with stdin
    // open. The drill reads it once the gates passed (`drill_source`).
    let stdin = std::cell::Cell::new(false);
    let parsed = parse(&words, || {
        stdin.set(true);
        Ok(STDIN_PROMPT.to_owned())
    });
    let stdin = stdin.get();
    let request = match parsed {
        Ok(Parsed::Run(request)) => *request,
        Ok(Parsed::Help) => {
            print!("{}", crate::cli::cloud_help::START_CHAT_USAGE);
            return Some(0);
        }
        Err(error) => {
            let refused = super::folder_refused(&error, global.output);
            return Some(refused.unwrap_or_else(|| usage(error, global.output)));
        }
    };
    let mut runner = SelfRunner::new(&global);
    let env = std::env::var(crate::carrier::fault::PROBE_ENV).ok();
    // The source's steps run on a runner bound to the drill's deadline: a step still running at it is killed, and
    // a remote script gets what is left of it as its own limit (internal/bounded.rs).
    let sourced = std::cell::Cell::new(false);
    let source = |_: &mut dyn Runner, plan: &FaultPlan, caps: &Value, until| {
        sourced.set(true);
        let mut bounded = SelfRunner::new(&global).until(until);
        drill_source(&mut bounded, &global, &request, stdin, (plan, caps, until))
    };
    let outcome = start(&mut runner, &request, spec, env.as_deref(), || this_device(None), source);
    // The drill ends here: a step a thread still runs (a send it gave up on) goes now, before the process exits.
    if sourced.get() {
        internal::bounded::kill_steps();
    }
    Some(report(&outcome, global.output))
}

/// The drill's event source for `request` (`stdin`: its prompt is `--prompt -`), all of it inside the drill's one
/// deadline `until` (from `--timeout`, on `runner`'s clock): the chat started without its prompt, the app's
/// credential, and the routes over one Cloud dial that send the prompt once attached. A start that failed, or
/// answered past `until`, answers as it would without the drill; nothing is sent after `until`.
pub(super) fn drill_source(
    runner: &mut dyn Runner,
    global: &GlobalArgs,
    request: &Request,
    stdin: bool,
    (plan, caps, until): (&FaultPlan, &Value, Instant),
) -> Result<Box<dyn EventRoutes>, Outcome> {
    let refuse = |code: &str, message: String| {
        failed(code, message, Drill::new(plan.spec, caps.clone()).json(), 2)
    };
    let out_of_time = || {
        refuse("carrier_fault.timeout", "--timeout ran out before the drill's turn started".into())
    };
    let prompt = if stdin {
        // Bounded too: a stdin that never ends stops the drill at its deadline, not later.
        internal::bounded::read_by(std::io::stdin(), until)
            .map_err(|error| refuse("usage.invalid", format!("--prompt -: {error}")))?
    } else {
        request.prompt.clone().unwrap_or_default()
    };
    // The start's own steps are bounded by the drill's deadline, prompt or not (`Request::until`).
    let mut trail = Trail::new(runner.now());
    // Every answer from here on names the step it stopped in and what each step took (`details.drill`).
    let stopped =
        |trail: &Trail, outcome: Outcome| trail.stopped(outcome, plan.spec, caps, request.timeout);
    let bounded = Request { prompt: None, wait: false, until: Some(until), ..request.clone() };
    let started = match run(runner, &bounded) {
        Outcome::Done(answer) => answer,
        refused => {
            trail.ended(STEP_START, runner.now(), false);
            return Err(stopped(&trail, refused));
        }
    };
    trail.ended(STEP_START, runner.now(), true);
    let left = |runner: &mut dyn Runner| until.saturating_duration_since(runner.now());
    if left(runner).is_zero() {
        trail.stop_at(STEP_CREDENTIAL);
        return Err(stopped(&trail, out_of_time()));
    }
    let asked = left(runner).min(TOKEN_TIMEOUT);
    let token = credential(runner.app("auth.token", json!({}), asked));
    trail.ended(STEP_CREDENTIAL, runner.now(), token.is_ok());
    let token = token.map_err(|why| stopped(&trail, refuse("carrier_fault.no_credential", why)))?;
    let left = left(runner);
    if left.is_zero() {
        trail.stop_at(STEP_DIAL);
        return Err(stopped(&trail, out_of_time()));
    }
    let text = |key: &str| started.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
    let send = prompt_send(
        SelfRunner::new(global),
        request,
        prompt,
        (text("machine_id"), text("session_id")),
        until,
    );
    let dial_deadline = tokio::time::Instant::now() + left;
    let routes = fault_routes::cloud_routes(&started, &token, dial_deadline, send);
    trail.ended(STEP_DIAL, runner.now(), routes.is_ok());
    match routes {
        Ok(routes) => Ok(Box::new(routes)),
        Err(why) => Err(stopped(&trail, refuse("carrier_fault.no_event_source", why))),
    }
}

/// The app's `auth.token` answer as the drill's credential, or why there is none.
fn credential(answer: Option<Result<Value, Value>>) -> Result<Value, String> {
    match answer {
        Some(Ok(token)) => Ok(token),
        Some(Err(error)) => Err(format!("the app gave no cmux credential: {error}")),
        None => Err("no app answered auth.token".into()),
    }
}

/// The drill's steps before its turn, as the partial record names them.
const STEP_START: &str = "start";
const STEP_CREDENTIAL: &str = "credential";
const STEP_DIAL: &str = "dial";

/// Where a drill got to before its turn: each step it ended (`{step, ms, ok}`, in order) and the one it stopped in.
/// A drill that stops there, a timeout most of all, answers this beside the start's own `stages_ms` as
/// `details.drill`, so its record says where it stopped and how long each step took, never only "--timeout ran out".
pub(super) struct Trail {
    began: Instant,
    last: Instant,
    steps: Vec<Value>,
    stopped_in: Option<&'static str>,
}

impl Trail {
    fn new(began: Instant) -> Self {
        Self { began, last: began, steps: Vec::new(), stopped_in: None }
    }

    /// `step` ended at `now`; one that failed is the step the drill stopped in.
    fn ended(&mut self, step: &'static str, now: Instant, ok: bool) {
        let ms = now.saturating_duration_since(self.last).as_millis();
        self.steps.push(json!({"step": step, "ms": ms, "ok": ok}));
        self.last = now;
        if !ok {
            self.stopped_in = Some(step);
        }
    }

    /// The drill stopped before `step` started (no time was left for it).
    fn stop_at(&mut self, step: &'static str) {
        self.stopped_in = Some(step);
    }

    /// `outcome` (a failure) with this trail as `details.drill`: the empty drill record (`events` and `resumes`
    /// none, the judge's shape), the steps, the step it stopped in, the time since the source began and the
    /// `--timeout` it had. An outcome without a `details` object gets one.
    fn stopped(
        &self,
        outcome: Outcome,
        spec: FaultSpec,
        caps: &Value,
        timeout: Duration,
    ) -> Outcome {
        let Outcome::Failed { mut error, exit } = outcome else { return outcome };
        let mut record = Drill::new(spec, caps.clone()).json();
        if let Some(object) = record.as_object_mut() {
            object.insert("steps".into(), json!(self.steps));
            object.insert("stopped_in".into(), json!(self.stopped_in.unwrap_or(STEP_START)));
            object.insert(
                "elapsed_ms".into(),
                json!(self.last.duration_since(self.began).as_millis()),
            );
            object.insert("timeout_ms".into(), json!(timeout.as_millis()));
        }
        if let Some(error) = error.as_object_mut() {
            let details = error.entry("details").or_insert_with(|| json!({}));
            if !details.is_object() {
                *details = json!({"was": details.clone()});
            }
            if let Some(details) = details.as_object_mut() {
                details.insert("drill".into(), record);
            }
        }
        Outcome::Failed { error, exit }
    }
}

/// The step of the turn the drill stopped in, from its record: the first carrier's connect, its events before the
/// kill, the next carrier's resume, or that carrier's events (`relay connect`, `relay events`, `ssh resume`,
/// `ssh events`). The record names each carrier as it went.
pub(super) fn turn_step(record: &Value, plan: &FaultPlan) -> String {
    let name = |index: usize| plan.candidates.get(index).map_or("carrier", |route| route.name());
    let resumes = record.get("resumes").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    let failed = |row: &Value| row.get("outcome").and_then(Value::as_str) == Some("error");
    let killed = record.get("kill").is_some_and(|kill| !kill.is_null());
    match (resumes, killed) {
        ([], _) => format!("{} connect", name(0)),
        ([first], _) if failed(first) => format!("{} connect", name(0)),
        ([_], false) => format!("{} events", name(0)),
        ([_], true) => format!("{} resume", name(1)),
        ([_, second, ..], _) if failed(second) => format!("{} resume", name(1)),
        _ => format!("{} events", name(1)),
    }
}

/// The turn's record (a finished drill's answer, or a failed one's `details`) with the turn's step beside the
/// source's: `turn_ms`, `timeout_ms` and, when it did not finish, `stopped_in` ([`turn_step`]).
fn with_turn(
    record: &mut Value,
    plan: &FaultPlan,
    took: Duration,
    finished: bool,
    timeout: Duration,
) {
    let step = turn_step(record, plan);
    let Some(object) = record.as_object_mut() else { return };
    object.insert("turn_ms".into(), json!(took.as_millis()));
    object.insert("timeout_ms".into(), json!(timeout.as_millis()));
    if !finished {
        object.insert("stopped_in".into(), json!(step));
    }
}

/// The turn's prompt to `session` on `machine` (`cmux chat send`'s run, on `runner`), bounded by `until`: past it
/// nothing is sent, every step of the send is bounded by it (`Request::until`), a step still running at it is
/// killed and each remote script gets what is left of it as its own limit ([`SelfRunner::until`]).
pub(super) fn prompt_send(
    runner: SelfRunner,
    request: &Request,
    prompt: String,
    (machine, session): (String, String),
    until: Instant,
) -> fault_routes::SendPrompt {
    let request =
        Request { prompt: Some(prompt), wait: false, until: Some(until), ..request.clone() };
    let mut runner = runner.until(until);
    Box::new(move || {
        if Instant::now() >= until {
            return Err("--timeout ran out before the prompt was sent".into());
        }
        match send_to(&mut runner, &request, &machine, &session) {
            Outcome::Done(_) => Ok(()),
            Outcome::Failed { error, .. } => Err(error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("the send failed")
                .to_owned()),
        }
    })
}

/// `words` without `--carrier-fault SPEC` (or `--carrier-fault=SPEC`), and the spec. The flag is
/// read only before `--`, and never as another flag's value.
pub(super) fn take(words: &[String]) -> Result<(Vec<String>, Option<FaultSpec>), UsageError> {
    let mut kept = Vec::with_capacity(words.len());
    let mut spec = None;
    let mut rest = words.iter();
    while let Some(word) = rest.next() {
        let text = if word == FLAG {
            Some(
                rest.next()
                    .ok_or_else(|| UsageError::new(format!("{FLAG} needs a value")))?
                    .clone(),
            )
        } else {
            word.strip_prefix(FLAG).and_then(|tail| tail.strip_prefix('=')).map(str::to_owned)
        };
        let Some(text) = text else {
            kept.push(word.clone());
            if word == "--" {
                kept.extend(rest.cloned());
                break;
            }
            if TAKES_VALUE.contains(&word.as_str())
                && let Some(value) = rest.next()
            {
                kept.push(value.clone());
            }
            continue;
        };
        if spec.replace(parse_spec(&text).map_err(UsageError::new)?).is_some() {
            return Err(UsageError::new(format!("{FLAG} is given twice")));
        }
    }
    Ok((kept, spec))
}

/// The signed-in account's email, as the app's Cloud diagnostics name it (`details`, a JSON text).
fn account_email(runner: &mut dyn Runner) -> Option<String> {
    let result = step_result(&runner.cmux(&words(&["cloud", "diagnostics", "--json"]))).ok()?;
    let details = match result.get("details")? {
        Value::String(text) => serde_json::from_str::<Value>(text).ok()?,
        other => other.clone(),
    };
    if details.get("signed_in") == Some(&Value::Bool(false)) {
        return None;
    }
    details.get("email").and_then(Value::as_str).map(str::to_owned)
}

/// The drill for `request` with `spec`; `env` is `CMUX_CARRIER_PROBE_FAULTS`' value,
/// `carriers` this device's ([`this_device`]), and `source` the turn's events over the plan's
/// carriers (given the plan, the capabilities and the drill's deadline; `Err`: the answer), both
/// asked only once the gates passed. One deadline, `--timeout` from this call on `runner`'s clock,
/// bounds the source (the start, the credential, the dial, the send) and the drill.
pub(super) fn start(
    runner: &mut dyn Runner,
    request: &Request,
    spec: FaultSpec,
    env: Option<&str>,
    carriers: impl FnOnce() -> [Carrier; 2],
    source: impl FnOnce(
        &mut dyn Runner,
        &FaultPlan,
        &Value,
        Instant,
    ) -> Result<Box<dyn EventRoutes>, Outcome>,
) -> Outcome {
    let began = runner.now();
    let until = began.checked_add(request.timeout).unwrap_or(began);
    let not_probe = || failed("carrier_fault.not_probe", NOT_PROBE, json!({}), 2);
    if !probe_run(env) {
        return not_probe();
    }
    if request.prompt.is_none() || !request.wait {
        return failed(
            "usage.invalid",
            format!("{FLAG} needs a prompt and --wait: it kills the carrier mid-turn"),
            json!({"fault": spec.json()}),
            2,
        );
    }
    let email = account_email(runner);
    if probe_gate(env, email.as_deref()).is_err() {
        return not_probe();
    }
    let carriers = carriers();
    let caps = capabilities(&carriers);
    let plan = match FaultPlan::new(spec, routes(&carriers), &caps) {
        Ok(plan) => plan,
        Err(refused) => return failed(refused.code, refused.message, refused.record, 2),
    };
    let mut events = match source(runner, &plan, &caps, until) {
        Ok(events) => events,
        Err(outcome) => return outcome,
    };
    // The same deadline on the drill's clock: what is left of it now.
    let deadline = tokio::time::Instant::now() + until.saturating_duration_since(runner.now());
    // The dial's own runtime, as `cmux carrier dial` runs it.
    let Ok(runtime) = tokio::runtime::Builder::new_multi_thread().enable_all().build() else {
        return failed(
            "carrier_fault.runtime",
            "the drill's runtime did not start",
            Drill::new(plan.spec, caps).json(),
            2,
        );
    };
    let turn_began = runner.now();
    let drilled = runtime.block_on(run_drill(&plan, events.as_mut(), caps, deadline));
    let took = runner.now().saturating_duration_since(turn_began);
    // The session's streams end with the routes, inside the runtime.
    runtime.block_on(async move { drop(events) });
    match drilled {
        Ok(mut record) => {
            with_turn(&mut record, &plan, took, true, request.timeout);
            Outcome::Done(json!({"drill": record}))
        }
        Err(mut error) => {
            with_turn(&mut error.record, &plan, took, false, request.timeout);
            failed(error.code, error.message, error.record, 2)
        }
    }
}

#[cfg(test)]
#[path = "fault_tests.rs"]
mod tests;
