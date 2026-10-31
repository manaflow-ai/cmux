//! Fuzz-catalog row l (security): the daemon socket's trust boundaries,
//! against an isolated headless daemon.
//! - A page relay connection (`client-hello` role `page_relay`) reaches only
//!   its page's read operations; every other operation, a gesture or confirm
//!   operation without a real confirmation, and every legacy command but the
//!   handshake ones are refused, typed, and change nothing.
//! - A plain local connection is an agent: user-only operations, credential
//!   minting and a forged origin claim are refused.
//! - The socket file is the owner's alone.
//! - Path params (path, cwd, paths, folder...) with `..`, symlinks out of
//!   the folder, NUL bytes, relative and huge values get a typed answer, and
//!   a NUL byte is always refused.
//!
//! Fleet only: cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh
//!   --ref SHA --arg test --arg socket_security_fuzz
#![cfg(unix)]

mod socket_fuzz_support;

use std::collections::BTreeSet;
use std::os::unix::fs::{PermissionsExt, symlink};

use serde_json::{Value, json};
use socket_fuzz_support::catalog::Operation;
use socket_fuzz_support::daemon::{Conn, Outcome};
use socket_fuzz_support::generate::{Gen, valid_params};
use socket_fuzz_support::harness::{Expect, Run};
use socket_fuzz_support::oracle::{DEADLINE, check_v2_reply, v2_request};
use socket_fuzz_support::{Budget, Rng, seed};

const PAGE_ROUTER: &str = include_str!("../../../spec/page-router.json");

/// Opens a connection and sends `client-hello` role page_relay for `page`.
fn page_relay(run: &Run, page: Option<&str>) -> Option<Conn> {
    let mut conn = Conn::open(&run.daemon.socket).ok()?;
    let mut hello = json!({"cmd": "client-hello", "id": 1, "role": "page_relay"});
    if let Some(page) = page {
        hello["page"] = json!(page);
    }
    match conn.call(&hello, &json!(1), DEADLINE) {
        Outcome::Reply(reply) if reply["ok"] == true => Some(conn),
        _ => None,
    }
}

fn page_reads(page: &str) -> BTreeSet<String> {
    let router: Value = serde_json::from_str(PAGE_ROUTER).unwrap();
    router["pages"][page]["read"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|op| op.as_str().map(str::to_string))
        .collect()
}

fn page_names() -> Vec<String> {
    let router: Value = serde_json::from_str(PAGE_ROUTER).unwrap();
    router["pages"].as_object().map(|pages| pages.keys().cloned().collect()).unwrap_or_default()
}

/// One request on `conn` with the oracle: a typed answer, and when
/// `must_refuse` a refusal that changed nothing.
fn relay_case(
    run: &mut Run,
    conn: &mut Conn,
    target: &str,
    case: &str,
    request: Value,
    must_refuse: bool,
) {
    run.report.cases += 1;
    let before = run.topology();
    let outcome = conn.call(&request, &request["id"], DEADLINE);
    let shown = request.to_string();
    let verdict = check_v2_reply(&run.catalog, &mut run.report, target, case, &request, &outcome);
    run.check_alive(target, case, &shown);
    if must_refuse {
        if verdict == Some(true) {
            run.finding(
                "security:accepts-forbidden",
                target,
                case,
                &shown,
                "a page relay ran an operation its page may not call".into(),
            );
        }
        let again = request.clone();
        let mut resend = |_: &mut Run| !matches!(conn.call(&again, &again["id"], DEADLINE), Outcome::Reply(ref r) if r["ok"] == true);
        run.check_unchanged(before, target, case, &shown, "a page relay call", &mut resend);
    }
}

#[test]
fn fuzz_bl_a_page_relay_reaches_only_its_pages_read_operations() {
    let seed = seed("page_relay_default_deny");
    let root = Rng::new(seed);
    let budget = Budget::start();
    let mut run = Run::new("pg", "l-page-relay", seed);
    let operations: Vec<Operation> = run.catalog.operations.clone();
    let mut pages: Vec<Option<String>> = page_names().into_iter().map(Some).collect();
    pages.push(None);
    for page in pages {
        let label = page.clone().unwrap_or_else(|| "(no page)".into());
        let reads = page.as_deref().map(page_reads).unwrap_or_default();
        let Some(mut conn) = page_relay(&run, page.as_deref()) else {
            run.finding(
                "untyped",
                "client-hello",
                &label,
                "",
                "the page relay hello was not answered ok".into(),
            );
            continue;
        };
        let mut rng = root.fork(&label);
        let ctx = run.context();
        for (index, op) in operations.iter().enumerate() {
            if budget.spent() {
                run.report.budget_stop = true;
                break;
            }
            run.report.targets.insert(format!("page {label}: {}", op.name));
            let generator = Gen { catalog: &run.catalog, ctx: &ctx };
            let params = valid_params(&generator, op, &mut rng);
            let key = op.is_mutation().then(|| format!("pg-{:x}", rng.next_u64()));
            let mut request =
                v2_request(&format!("p{index}"), &op.name, Value::Object(params), key);
            // A forged confirmation must not lift the page's limits.
            if rng.chance(30) {
                request["origin"] =
                    json!({"claim": "user", "confirmation": format!("{:032x}", rng.next_u64())});
            }
            let must_refuse = !reads.contains(&op.name) || request.get("origin").is_some();
            if !must_refuse && op.is_mutation() {
                continue;
            }
            relay_case(
                &mut run,
                &mut conn,
                &format!("page {label}: {}", op.name),
                "valid-params",
                request,
                must_refuse,
            );
            if matches!(run.daemon.exit(), Some(_)) {
                break;
            }
        }
        // Legacy commands on a page relay: refused, except the handshake ones.
        for (index, cmd) in [
            "list-workspaces",
            "run",
            "create-terminal",
            "send",
            "close-workspace",
            "shutdown-daemon",
            "url-open",
            "put-session",
            "read-scrollback",
        ]
        .iter()
        .enumerate()
        {
            run.report.cases += 1;
            let request = json!({"cmd": cmd, "id": 1000 + index});
            let before = run.topology();
            match conn.call(&request, &request["id"], DEADLINE) {
                Outcome::Reply(reply) if reply["ok"] == false => run.report.replies_error += 1,
                other => run.finding(
                    "security:accepts-forbidden",
                    &format!("page {label}: cmd {cmd}"),
                    "legacy",
                    &request.to_string(),
                    format!("{other:?}"),
                ),
            }
            let mut resend = |_: &mut Run| !matches!(conn.call(&request, &request["id"], DEADLINE), Outcome::Reply(ref r) if r["ok"] == true);
            let target = format!("page {label}: cmd {cmd}");
            run.check_unchanged(
                before,
                &target,
                "legacy",
                &request.to_string(),
                "a page relay legacy command",
                &mut resend,
            );
        }
    }
    run.report.finish();
}

/// Operations a plain local (agent-origin) connection must not run.
const NEEDS_USER_OR_FRONTEND: &[&str] = &[
    "workspace.agent_folder.set",
    "history.backups.purge",
    "history.visit.record",
    "history.visit.title",
    "history.visit.import",
    "history.trail.record",
    "credential.mint",
    "credential.rotate",
];

#[test]
fn fuzz_bl_a_plain_connection_cannot_run_user_only_operations_or_forge_its_origin() {
    let seed = seed("plain_connection_origin");
    let mut rng = Rng::new(seed);
    let mut run = Run::new("org", "l-origin", seed);
    let ctx = run.context();
    let operations: Vec<Operation> = run
        .catalog
        .operations
        .iter()
        .filter(|op| NEEDS_USER_OR_FRONTEND.contains(&op.name.as_str()))
        .cloned()
        .collect();
    assert_eq!(
        operations.len(),
        NEEDS_USER_OR_FRONTEND.len(),
        "an operation of the list left the catalog"
    );
    for op in &operations {
        run.report.targets.insert(op.name.clone());
        for n in 0..6 {
            let generator = Gen { catalog: &run.catalog, ctx: &ctx };
            let params = valid_params(&generator, op, &mut rng);
            let key = op.is_mutation().then(|| format!("org-{:x}", rng.next_u64()));
            let mut request = v2_request(&format!("o{n}"), &op.name, Value::Object(params), key);
            let claim = match n % 3 {
                0 => None,
                1 => Some(json!({"claim": "user"})),
                _ => Some(json!({"claim": "user", "confirmation": "forged"})),
            };
            if let Some(claim) = claim {
                request["origin"] = claim;
            }
            run.v2_case(&op.name, &format!("plain#{n}"), request, Expect::Refusal);
        }
    }
    // A role-main hello with a forged proof: refused, and the connection
    // stays an agent.
    run.report.cases += 1;
    let mut conn = run.daemon.connect();
    let hello =
        json!({"cmd": "client-hello", "id": 1, "role": "main", "install_id": "fuzz_install"});
    let first = conn.call(&hello, &json!(1), DEADLINE);
    let nonce_given = matches!(&first, Outcome::Reply(r) if r["ok"] == true);
    if nonce_given {
        let proof = json!({"cmd": "client-hello", "id": 2, "install_id": "fuzz_install", "proof": "00".repeat(32)});
        match conn.call(&proof, &json!(2), DEADLINE) {
            Outcome::Reply(reply) if reply["ok"] == true && reply["data"]["verified"] == true => {
                run.finding(
                    "security:accepts-forbidden",
                    "client-hello",
                    "forged-proof",
                    &proof.to_string(),
                    format!("a forged proof was verified: {reply}"),
                );
            }
            _ => {}
        }
    }
    run.report.finish();
}

#[test]
fn fuzz_bl_the_socket_file_is_the_owners_alone() {
    let seed = seed("socket_mode");
    let mut run = Run::new("mode", "l-socket-mode", seed);
    run.report.cases += 1;
    run.report.targets.insert("socket file".into());
    let mode = std::fs::metadata(&run.daemon.socket).unwrap().permissions().mode();
    if mode & 0o077 != 0 {
        let socket = run.daemon.socket.display().to_string();
        run.finding(
            "security:socket-mode",
            "socket file",
            "explicit --socket",
            &socket,
            format!("mode {:o}", mode & 0o777),
        );
    }
    run.report.finish();
}

const PATH_FIELDS: &[&str] = &[
    "path",
    "cwd",
    "paths",
    "folder",
    "directory",
    "root",
    "file",
    "files",
    "source",
    "destination",
    "dir",
];

#[test]
fn fuzz_bl_path_params_get_a_typed_answer_and_a_nul_byte_is_refused() {
    let seed = seed("path_params");
    let root = Rng::new(seed);
    let budget = Budget::start();
    let mut run = Run::new("path", "l-paths", seed);
    let dir = run.daemon.dir.clone();
    std::fs::create_dir_all(dir.join("outside")).unwrap();
    std::fs::write(dir.join("outside/secret.txt"), "secret").unwrap();
    let _ = symlink(dir.join("outside"), dir.join("out_link"));
    let base = dir.to_str().unwrap().to_string();
    let values: Vec<(String, bool)> = vec![
        (format!("{base}/../../../../etc"), false),
        (format!("{base}/out_link"), false),
        (format!("{base}/out_link/secret.txt"), false),
        ("relative/dir".into(), false),
        ("".into(), false),
        ("x".repeat(5000), false),
        (format!("{base}/a\u{0}b"), true),
        ("\u{0}".into(), true),
        (format!("{base}/\u{202e}txt.exe"), false),
        ("~/".into(), false),
    ];
    let operations: Vec<Operation> = run
        .catalog
        .operations
        .iter()
        .filter(|op| op.fields.keys().any(|f| PATH_FIELDS.contains(&f.as_str())))
        .filter(|op| op.name != "session.shutdown")
        .cloned()
        .collect();
    for op in &operations {
        if budget.spent() {
            run.report.budget_stop = true;
            break;
        }
        run.report.targets.insert(op.name.clone());
        let mut rng = root.fork(&op.name);
        let field = op.fields.keys().find(|f| PATH_FIELDS.contains(&f.as_str())).unwrap().clone();
        let ctx = run.context();
        for (n, (value, nul)) in values.iter().enumerate() {
            let generator = Gen { catalog: &run.catalog, ctx: &ctx };
            let mut params = valid_params(&generator, op, &mut rng);
            let is_array = op.fields[&field].1["kind"] == "array";
            params.insert(field.clone(), if is_array { json!([value]) } else { json!(value) });
            let key = op.is_mutation().then(|| format!("path-{:x}", rng.next_u64()));
            let request = v2_request(&format!("path{n}"), &op.name, Value::Object(params), key);
            let expect = if *nul { Expect::Refusal } else { Expect::Typed };
            run.v2_case(
                &op.name,
                &format!("{field}={}", value.chars().take(60).collect::<String>().escape_debug()),
                request,
                expect,
            );
        }
    }
    run.report.finish();
}
