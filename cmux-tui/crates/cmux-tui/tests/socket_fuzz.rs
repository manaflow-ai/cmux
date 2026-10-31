//! Fuzz-catalog row b: every `cmux.protocol/2` operation, every legacy
//! `{"cmd"}` command, the envelope, and every catalogued CLI command line,
//! against an isolated headless daemon, with valid, boundary and malformed
//! arguments.
//!
//! The oracle (socket_fuzz_support/harness.rs): a typed answer or a typed
//! error before a deadline; never a hang, a closed connection, a dead daemon,
//! an accepted request that breaks the catalog, or a refused request that
//! changed the topology.
//!
//! Fleet only (cargo never runs on a developer Mac):
//!   cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref SHA \
//!     --arg test --arg socket_fuzz
//! Replay: CMUX_FUZZ_SEED=<seed>. More: CMUX_FUZZ_CASES=<n>, CMUX_FUZZ_BUDGET_SECS=<s>.
#![cfg(unix)]

mod socket_fuzz_support;

use std::time::Duration;

use serde_json::{Map, Value, json};
use socket_fuzz_support::catalog::{LegacyCommand, Operation, legacy_commands};
use socket_fuzz_support::cli_cases::{cli_cases, localize, run_cli};
use socket_fuzz_support::daemon::{Conn, Outcome};
use socket_fuzz_support::generate::{Context, Gen, safe_value, valid_params};
use socket_fuzz_support::harness::{Expect, Run};
use socket_fuzz_support::oracle::{DEADLINE, v2_request};
use socket_fuzz_support::{Budget, Rng, cases, seed};

/// Valid calls that end the session on purpose: only their malformed cases
/// are sent (and those must not end it).
const ENDS_SESSION: &[&str] = &["session.shutdown", "shutdown-daemon"];

fn key_for(op: &Operation, rng: &mut Rng) -> Option<String> {
    op.is_mutation().then(|| format!("fuzz-{:016x}", rng.next_u64()))
}

/// One sure violation of `op`'s descriptor, applied to `params` / `key`.
/// Returns its label and whether the catalog says it must be refused.
fn malform(
    generator: &Gen<'_>,
    op: &Operation,
    params: &mut Map<String, Value>,
    key: &mut Option<String>,
    rng: &mut Rng,
) -> (String, bool) {
    let unknown = |params: &mut Map<String, Value>| {
        params.insert("__fuzz_unknown".into(), json!("x"));
        ("unknown-field".to_string(), !op.extra)
    };
    match rng.below(6) {
        0 if !op.fields.is_empty() => {
            let (name, (_, ty)) = op.fields.iter().nth(rng.below(op.fields.len())).unwrap();
            let (value, label) = generator.invalid(ty, rng);
            if label.is_empty() {
                return unknown(params);
            }
            params.insert(name.clone(), value);
            (format!("{name}:{label}"), true)
        }
        1 => match op.fields.iter().find(|(_, (required, _))| *required) {
            Some((name, _)) => {
                params.remove(name);
                (format!("{name}:missing-required"), true)
            }
            None => unknown(params),
        },
        2 => match op.selectors.iter().filter(|(_, r)| **r).map(|(k, _)| k.clone()).last() {
            Some(name) => {
                let long = "x".repeat(300);
                let bad =
                    rng.pick(&["", "ws_nothex", "name:", "current_", long.as_str()]).to_string();
                params.insert(name.clone(), json!(bad));
                (format!("selector {name}:bad"), true)
            }
            None => unknown(params),
        },
        3 if op.is_mutation() => {
            *key = None;
            ("mutation-without-idempotency-key".into(), true)
        }
        4 if op.is_mutation() => {
            let long = "k".repeat(129);
            *key = Some(rng.pick(&["", "   ", "a\u{7}b", long.as_str()]).to_string());
            ("bad-idempotency-key".into(), true)
        }
        4 if op.class == "read" => {
            *key = Some("fuzz-key".into());
            ("read-with-idempotency-key".into(), true)
        }
        _ => unknown(params),
    }
}

fn fuzz_operation(run: &mut Run, op: &Operation, rng: &mut Rng, per_kind: usize) {
    let ctx = run.context();
    let catalog = run.catalog.clone();
    let generator = Gen { catalog: &catalog, ctx: &ctx };
    // A socket-less operation must be refused on the socket whatever it carries.
    let local = if op.class == "local" { Expect::Refusal } else { Expect::Typed };
    for n in 0..per_kind {
        if !ENDS_SESSION.contains(&op.name.as_str()) {
            let params = valid_params(&generator, op, rng);
            let request =
                v2_request(&format!("v{n}"), &op.name, Value::Object(params), key_for(op, rng));
            run.v2_case(&op.name, &format!("valid#{n}"), request, local);
            let mut params = valid_params(&generator, op, rng);
            if let Some((name, (_, ty))) = op.fields.iter().nth(rng.below(op.fields.len().max(1))) {
                if safe_value(name, &ctx, &mut rng.clone()).is_none() {
                    params.insert(name.clone(), generator.boundary(ty, rng));
                }
            }
            let request =
                v2_request(&format!("b{n}"), &op.name, Value::Object(params), key_for(op, rng));
            run.v2_case(&op.name, &format!("boundary#{n}"), request, local);
        }
        for m in 0..2 {
            let mut params = valid_params(&generator, op, rng);
            let mut key = key_for(op, rng);
            let (label, sure) = malform(&generator, op, &mut params, &mut key, rng);
            let request = v2_request(&format!("m{n}-{m}"), &op.name, Value::Object(params), key);
            let expect =
                if sure || local == Expect::Refusal { Expect::Refusal } else { Expect::Typed };
            run.v2_case(&op.name, &format!("malformed#{n}-{m} {label}"), request, expect);
        }
    }
}

#[test]
fn fuzz_bl_every_v2_operation_answers_typed_with_valid_boundary_and_malformed_params() {
    let seed = seed("every_v2_operation");
    let root = Rng::new(seed);
    let budget = Budget::start();
    let mut run = Run::new("v2", "b-v2", seed);
    let mut operations: Vec<Operation> =
        run.catalog.operations.iter().chain(run.catalog.local_operations.iter()).cloned().collect();
    // A different order each seed, so a budget stop does not always skip the same tail.
    let mut order = root.fork("order");
    for i in (1..operations.len()).rev() {
        operations.swap(i, order.below(i + 1));
    }
    for op in &operations {
        if budget.spent() {
            run.report.budget_stop = true;
            break;
        }
        run.report.targets.insert(op.name.clone());
        fuzz_operation(&mut run, op, &mut root.fork(&op.name), cases(1));
    }
    run.report.finish();
}

fn envelope(extra: Value) -> Vec<u8> {
    let mut base = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "e",
                          "operation": "session.ping", "params": {"machine": "current", "session": "current"}});
    for (key, value) in extra.as_object().unwrap() {
        if value.is_null() {
            base.as_object_mut().unwrap().remove(key);
        } else {
            base[key] = value.clone();
        }
    }
    format!("{base}\n").into_bytes()
}

fn envelope_lines(rng: &mut Rng) -> Vec<(String, Vec<u8>)> {
    let deep_params = format!(
        "{{\"protocol\":\"cmux.protocol/2\",\"type\":\"request\",\"id\":\"deep\",\"operation\":\"session.ping\",\"params\":{}1{}}}\n",
        "{\"a\":".repeat(5000),
        "}".repeat(5000)
    );
    let mut lines: Vec<(String, Vec<u8>)> = vec![
        ("not-json".into(), b"hello\n".to_vec()),
        ("truncated".into(), b"{\"protocol\":\"cmux.protocol/2\",\"type\":\"req\n".to_vec()),
        ("array".into(), b"[1,2,3]\n".to_vec()),
        ("number".into(), b"42\n".to_vec()),
        ("null".into(), b"null\n".to_vec()),
        ("empty-object".into(), b"{}\n".to_vec()),
        ("invalid-utf8".into(), b"{\"id\":\"\xff\xfe\"}\n".to_vec()),
        ("nul-byte".into(), b"{\"id\":\"a\x00b\",\"cmd\":\"ping\"}\n".to_vec()),
        (
            "deep-nesting".into(),
            format!("{}{}\n", "[".repeat(100_000), "]".repeat(100_000)).into_bytes(),
        ),
        ("deep-params".into(), deep_params.into_bytes()),
    ];
    for (label, extra) in [
        ("wrong-protocol", json!({"protocol": "cmux.protocol/3"})),
        ("wrong-type", json!({"type": "response"})),
        ("numeric-id", json!({"id": 7})),
        ("empty-id", json!({"id": ""})),
        ("long-id", json!({"id": "i".repeat(129)})),
        ("no-params", json!({"params": null})),
        ("params-array", json!({"params": [1]})),
        ("params-string", json!({"params": "x"})),
        ("unknown-operation", json!({"operation": "no.such.operation"})),
        ("operation-number", json!({"operation": 5})),
        ("unknown-envelope-member", json!({"fuzz": true})),
        ("read-with-key", json!({"idempotency_key": "k"})),
        ("origin-garbage", json!({"origin": "x"})),
        ("origin-object-garbage", json!({"origin": {"kind": "no-such-origin", "x": 1}})),
        ("credential-garbage", json!({"credential": {"token": "x".repeat(4096)}})),
        (
            "machine-selector-bad",
            json!({"params": {"machine": "machine_zz", "session": "current"}}),
        ),
        ("session-selector-bad", json!({"params": {"machine": "current", "session": 1}})),
    ] {
        lines.push((label.into(), envelope(extra)));
    }
    let tokens = [
        "{",
        "}",
        "[",
        "]",
        ",",
        ":",
        "\"protocol\"",
        "\"cmux.protocol/2\"",
        "\"cmd\"",
        "\"id\"",
        "1",
        "null",
        "\"x\"",
        "true",
    ];
    for n in 0..cases(20) {
        let mut bytes: Vec<u8> = (0..rng.below(512))
            .map(|_| (rng.next_u64() & 0xff) as u8)
            .filter(|b| *b != b'\n')
            .collect();
        bytes.push(b'\n');
        lines.push((format!("random-bytes#{n}"), bytes));
        let soup: String = (0..1 + rng.below(40)).map(|_| *rng.pick(&tokens)).collect();
        lines.push((format!("token-soup#{n}"), format!("{soup}\n").into_bytes()));
    }
    lines
}

/// One raw line on its own connection: a typed refusal, then a working
/// `session.ping` on a new connection.
fn envelope_case(run: &mut Run, label: &str, line: &[u8]) {
    run.report.cases += 1;
    run.report.targets.insert(format!("envelope:{}", label.split('#').next().unwrap()));
    let shown: String = String::from_utf8_lossy(line).chars().take(300).collect();
    let blank = String::from_utf8_lossy(line).trim().is_empty();
    let outcome = match Conn::open(&run.daemon.socket) {
        Ok(mut conn) => {
            let _ = conn.send_raw(line);
            conn.reply_to(&Value::Null, DEADLINE)
        }
        Err(_) => Outcome::Closed,
    };
    match &outcome {
        Outcome::Reply(reply) if reply["ok"] == false => run.report.replies_error += 1,
        // Random bytes may form a valid legacy command by chance.
        Outcome::Reply(reply) if reply["ok"] == true && label.starts_with("random") => {
            run.report.replies_ok += 1
        }
        Outcome::Reply(reply) => run.finding(
            "accepts-invalid",
            "envelope",
            label,
            &shown,
            format!("malformed line answered: {reply}"),
        ),
        // A blank line gets no answer by design.
        Outcome::Timeout if blank => {}
        other => {
            let class = if matches!(other, Outcome::Timeout) { "hang" } else { "untyped" };
            run.finding(class, "envelope", label, &shown, format!("{other:?}"));
        }
    }
    run.check_alive("envelope", label, &shown);
    let ping = v2_request(
        "alive",
        "session.ping",
        json!({"machine": "current", "session": "current"}),
        None,
    );
    let alive = Conn::open(&run.daemon.socket)
        .map(|mut conn| matches!(conn.call(&ping, &json!("alive"), DEADLINE), Outcome::Reply(ref r) if r["ok"] == true))
        .unwrap_or(false);
    if !alive {
        run.finding(
            "hang",
            "envelope",
            label,
            &shown,
            "session.ping failed after this line".into(),
        );
        run.check_alive("envelope", label, &shown);
    }
}

#[test]
fn fuzz_bl_malformed_lines_and_envelopes_get_a_typed_error_and_never_stop_the_daemon() {
    let seed = seed("malformed_lines");
    let mut rng = Rng::new(seed);
    let mut run = Run::new("env", "b-envelope", seed);
    for (label, line) in envelope_lines(&mut rng) {
        envelope_case(&mut run, &label, &line);
    }
    // Over the limits: a 5 MiB v2 message (limit 4 MiB), a 17 MiB line (limit 16 MiB).
    for (label, size) in [("v2-over-4MiB", 5usize << 20), ("line-over-16MiB", 17usize << 20)] {
        run.report.cases += 1;
        run.report.targets.insert(format!("envelope:{label}"));
        let pad = "a".repeat(size);
        let params = json!({"machine": "current", "session": "current", "pad": pad});
        let request = v2_request("big", "session.ping", params, None);
        let outcome = run.daemon.connect().call(&request, &json!("big"), Duration::from_secs(20));
        match outcome {
            // Closing the connection of an over-limit line is a refusal too.
            Outcome::Reply(ref reply) if reply["ok"] == false => run.report.replies_error += 1,
            Outcome::Closed => run.report.replies_error += 1,
            other => run.finding(
                "untyped",
                "envelope",
                label,
                &format!("{size} byte line"),
                format!("{other:?}"),
            ),
        }
        run.check_alive("envelope", label, "");
    }
    // Half a line, then the client goes away.
    let mut conn = run.daemon.connect();
    let _ = conn.send_raw(b"{\"protocol\":\"cmux.protocol/2\"");
    drop(conn);
    envelope_case(&mut run, "after-half-line", b"{}\n");
    run.report.finish();
}

fn legacy_value(spec: &Value, ctx: &Context, field: &str, rng: &mut Rng) -> Value {
    if field.contains("timeout") {
        return json!(rng.below(800));
    }
    if let Some(value) = safe_value(field, ctx, rng) {
        return value;
    }
    match field {
        "shell_args" => return json!([]),
        "terminal_id" | "expected_terminal_id" => {
            if let Some(id) = ctx.ids.get("terminal").and_then(|ids| ids.first()) {
                return json!(id);
            }
        }
        _ if field.ends_with("url") => return json!("https://example.invalid/"),
        _ => {}
    }
    match spec["ty"].as_str().unwrap_or_default() {
        "string" => json!(*rng.pick(&["fuzz", "", "a b", "🦀"])),
        "uint64" | "uint32" | "uint16" => json!(rng.below(4)),
        "int64" => json!(rng.below(4) as i64 - 1),
        "float32" | "float64" => json!(0.5),
        "boolean" => json!(rng.chance(50)),
        "array" => json!([]),
        "enum" => spec["values"].as_array().and_then(|v| v.first().cloned()).unwrap_or(json!("x")),
        "map" | "object" | "json" => json!({}),
        _ => Value::Null,
    }
}

fn legacy_invalid(spec: &Value, rng: &mut Rng) -> Value {
    match spec["ty"].as_str().unwrap_or_default() {
        "string" | "enum" => rng.pick(&[json!(5), json!([1]), json!({"a": 1})]).clone(),
        "uint64" | "uint32" | "uint16" | "int64" => {
            rng.pick(&[json!(-1), json!("7"), json!(1.5), json!(1e300)]).clone()
        }
        "boolean" => json!("yes"),
        "array" => json!("not an array"),
        _ => json!(12345),
    }
}

/// One legacy request: valid, or with one field of the wrong type.
fn legacy_request(
    command: &LegacyCommand,
    ctx: &Context,
    id: u64,
    malformed: bool,
    rng: &mut Rng,
) -> (Value, String) {
    let mut request = json!({"cmd": command.name, "id": id});
    for (field, spec) in &command.fields {
        if spec["required"] == true || field.contains("timeout") || rng.chance(30) {
            request[field] = legacy_value(spec, ctx, field, rng);
        }
    }
    if !malformed {
        return (request, "valid".into());
    }
    let typed: Vec<_> = command
        .fields
        .iter()
        .filter(|(_, s)| !matches!(s["ty"].as_str(), Some("json") | Some("map") | None))
        .collect();
    if typed.is_empty() {
        request["__fuzz_unknown"] = json!(1);
        return (request, "unknown-field".into());
    }
    let (field, spec) = typed[rng.below(typed.len())];
    request[field] = legacy_invalid(spec, rng);
    (request, format!("{field}:invalid"))
}

fn legacy_case(
    run: &mut Run,
    command: &LegacyCommand,
    request: Value,
    case: &str,
    malformed: bool,
) {
    run.report.cases += 1;
    let before = run.topology();
    let id = request["id"].clone();
    let outcome = match Conn::open(&run.daemon.socket) {
        Ok(mut conn) => conn.call(&request, &id, DEADLINE),
        Err(_) => Outcome::Closed,
    };
    let shown: String = request.to_string().chars().take(600).collect();
    let target = format!("cmd:{}", command.name);
    let refused = match &outcome {
        Outcome::Reply(reply) if reply["ok"] == true => {
            run.report.replies_ok += 1;
            false
        }
        Outcome::Reply(reply) if reply["ok"] == false => {
            run.report.replies_error += 1;
            if reply["error"].as_str().is_none_or(str::is_empty) {
                run.finding(
                    "untyped",
                    &target,
                    case,
                    &shown,
                    format!("refusal without an error text: {reply}"),
                );
            }
            true
        }
        Outcome::Reply(reply) => {
            run.finding("untyped", &target, case, &shown, format!("no ok: {reply}"));
            true
        }
        other => {
            let class = if matches!(other, Outcome::Timeout) { "hang" } else { "closed" };
            run.finding(class, &target, case, &shown, format!("{other:?}"));
            true
        }
    };
    run.check_alive(&target, case, &shown);
    if malformed && !refused {
        run.finding(
            "accepts-invalid",
            &target,
            case,
            &shown,
            "a field of the wrong type was accepted".into(),
        );
    }
    if refused {
        run.check_unchanged_line(before, &target, case, &request, "refused");
    }
}

/// The private `{"cmd": ...}` commands (spec/api-compat.surface.json).
#[test]
fn fuzz_bl_every_legacy_command_answers_typed_with_valid_and_malformed_fields() {
    let seed = seed("every_legacy_command");
    let root = Rng::new(seed);
    let budget = Budget::start();
    let mut run = Run::new("leg", "b-legacy", seed);
    let mut id = 1u64;
    for command in legacy_commands() {
        if budget.spent() {
            run.report.budget_stop = true;
            break;
        }
        run.report.targets.insert(format!("cmd:{}", command.name));
        let mut rng = root.fork(&command.name);
        let ctx = run.context();
        for n in 0..cases(1) * 2 {
            let malformed = n % 2 == 1;
            if !malformed && ENDS_SESSION.contains(&command.name.as_str()) {
                continue;
            }
            id += 1;
            let (request, label) = legacy_request(&command, &ctx, id, malformed, &mut rng);
            legacy_case(&mut run, &command, request, &format!("{label}#{n}"), malformed);
        }
    }
    run.report.finish();
}

fn mutate_argv(args: &mut Vec<String>, rng: &mut Rng) -> String {
    let at = 1 + rng.below(args.len().saturating_sub(1).max(1));
    match rng.below(6) {
        0 if args.len() > 1 => format!("drop:{}", args.remove(rng.below(args.len()))),
        1 => {
            args.push("--fuzz-unknown-flag".into());
            "unknown-flag".into()
        }
        2 if args.len() > 1 => {
            args[at] = String::new();
            format!("empty-arg@{at}")
        }
        3 if args.len() > 1 => {
            args[at] = "x".repeat(100_000);
            format!("huge-arg@{at}")
        }
        4 if args.len() > 1 => {
            let odd = [
                "-1",
                "18446744073709551616",
                "NaN",
                "--",
                "name:",
                "\u{202e}rtl",
                "🦀",
                "../../etc",
            ];
            args[at] = rng.pick(&odd).to_string();
            format!("odd-arg@{at}={}", args[at])
        }
        _ => {
            let flag = args
                .iter()
                .find(|a| a.starts_with("--") && a.len() > 2)
                .cloned()
                .unwrap_or("--json".into());
            args.push(flag.clone());
            args.push("again".into());
            format!("repeat:{flag}")
        }
    }
}

fn cli_case(run: &mut Run, target: &str, args: &[String], case: &str) {
    run.report.cases += 1;
    let before = run.topology();
    let deadline = Duration::from_secs(15);
    let outcome = run_cli(&run.daemon, args, deadline);
    let shown: String = args.join(" ").chars().take(600).collect();
    let stderr: String = outcome.stderr.chars().take(800).collect();
    let killed = outcome.code.is_none() && !outcome.timed_out;
    if outcome.timed_out {
        run.finding("hang", target, case, &shown, format!("no exit in {deadline:?}"));
    } else if stderr.contains("panicked at") || outcome.code == Some(101) || killed {
        run.finding(
            "crash",
            target,
            case,
            &shown,
            format!("cli exit {:?}: {stderr}", outcome.code),
        );
    } else if outcome.code != Some(0) && stderr.trim().is_empty() {
        run.finding(
            "untyped",
            target,
            case,
            &shown,
            format!("exit {:?} with no error text", outcome.code),
        );
    }
    if outcome.code == Some(0) {
        run.report.replies_ok += 1;
    } else {
        run.report.replies_error += 1;
    }
    run.check_alive(target, case, &shown);
    if outcome.code != Some(0) {
        let why =
            format!("exit {:?} ({})", outcome.code, stderr.chars().take(160).collect::<String>());
        let argv = args.to_vec();
        let mut resend = |run: &mut Run| run_cli(&run.daemon, &argv, deadline).code != Some(0);
        run.check_unchanged(before, target, case, &shown, &why, &mut resend);
    }
}

/// Every catalogued command line, then mutations of it: a dropped word, an
/// unknown flag, an empty, huge or odd value, a repeated flag.
#[test]
fn fuzz_bl_every_cli_command_line_ends_typed_with_valid_and_mutated_arguments() {
    let seed = seed("every_cli_command");
    let root = Rng::new(seed);
    let budget = Budget::start();
    let mut run = Run::new("cli", "b-cli", seed);
    let lines = cli_cases();
    assert!(lines.len() > 100, "the CLI catalogue reader found only {} cases", lines.len());
    for (index, (argv, operation)) in lines.iter().enumerate() {
        if budget.spent() {
            run.report.budget_stop = true;
            break;
        }
        let words: Vec<&str> = argv.iter().take(3).map(String::as_str).collect();
        let target = format!("cli:{} ({operation})", words.join(" "));
        run.report.targets.insert(target.clone());
        let mut rng = root.fork(&index.to_string());
        let base = localize(argv, &run.context());
        let ends_session = ENDS_SESSION.contains(&operation.as_str());
        if !ends_session {
            cli_case(&mut run, &target, &base, "valid");
        }
        for n in 0..cases(1) {
            let mut args = base.clone();
            let label = mutate_argv(&mut args, &mut rng);
            if ends_session && !label.starts_with("drop") && !label.starts_with("unknown") {
                continue;
            }
            cli_case(&mut run, &target, &args, &format!("{label}#{n}"));
        }
    }
    run.report.finish();
}
