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
//! 5. The build has an event source for the turn over its carriers, else
//!    `carrier_fault.no_event_source` (every build until plan slice S1 gives the drill one).
//!
//! A refusal at step 4 or later carries the drill record in `error.details`: `capabilities`
//! (`routes`, `faults`), `fault`, `kill`, `events` and `resumes`, the fields the probe's judge reads
//! (cmuxterm-hq `cloud_carrier_failover_probe.py`). Exit 2 for every refusal. A drill that reached
//! the turn's last event answers the same record under `drill` (exit 0): the judge, not this
//! command, says whether it lost, repeated or resumed from the wrong seq.

use serde_json::{Value, json};

use super::{
    GlobalArgs, Outcome, Parsed, Request, Runner, SelfRunner, TAKES_VALUE, UsageError, failed,
    forwarded_globals, lift_output_of, parse, report, step_result, words,
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
    // `--prompt -` is never read here: every run of this build is refused before its turn, and
    // reading stdin first would block a refused run with stdin open. The drill reads it once it
    // has a turn to send it to (plan slice S1), after the gates.
    let parsed = parse(&words, || Ok(STDIN_PROMPT.to_owned()));
    let request = match parsed {
        Ok(Parsed::Run(request)) => request,
        Ok(Parsed::Help) => {
            print!("{}", crate::cli::cloud_help::START_CHAT_USAGE);
            return Some(0);
        }
        Err(error) => {
            let refused = super::folder_refused(&error, global.output);
            return Some(refused.unwrap_or_else(|| usage(error, global.output)));
        }
    };
    let mut runner = SelfRunner { globals: forwarded_globals(&global), global: global.clone() };
    let env = std::env::var(crate::carrier::fault::PROBE_ENV).ok();
    let outcome =
        start(&mut runner, &request, spec, env.as_deref(), || this_device(None), |_| None);
    Some(report(&outcome, global.output))
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
/// carriers (`None`: this build has none), both asked only once the gates passed.
pub(super) fn start(
    runner: &mut dyn Runner,
    request: &Request,
    spec: FaultSpec,
    env: Option<&str>,
    carriers: impl FnOnce() -> [Carrier; 2],
    source: impl FnOnce(&FaultPlan) -> Option<Box<dyn EventRoutes>>,
) -> Outcome {
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
    // No build follows a turn's events over its carriers before slice S1 (the drill's event
    // source on the Cloud dial): say so rather than run half a drill.
    let Some(mut events) = source(&plan) else {
        return failed(
            "carrier_fault.no_event_source",
            "this build cannot follow a turn's events over its carriers yet",
            Drill::new(plan.spec, caps).json(),
            2,
        );
    };
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
        return failed(
            "carrier_fault.runtime",
            "the drill's runtime did not start",
            Drill::new(plan.spec, caps).json(),
            2,
        );
    };
    let drilled = runtime.block_on(async {
        let deadline = tokio::time::Instant::now() + request.timeout;
        run_drill(&plan, events.as_mut(), caps, deadline).await
    });
    match drilled {
        Ok(record) => Outcome::Done(json!({"drill": record})),
        Err(error) => failed(error.code, error.message, error.record, 2),
    }
}

#[cfg(test)]
#[path = "fault_tests.rs"]
mod tests;
