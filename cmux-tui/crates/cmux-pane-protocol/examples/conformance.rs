//! The Rust runner of the oracle's pane-protocol suite
//! (`tests/oracle/corpus/pane-protocol/`, written by
//! `scripts/cmux-next/oracle/gen_pane_protocol.py`). The TS runner
//! (`webviews/scripts/pane-protocol-conformance.ts`) and the Swift runner
//! (`PaneProtocolConformanceTests`) read the same files, as the Mojo
//! validation vectors are read by every binding
//! (chromium/src `mojo/public/interfaces/bindings/tests/data/validation/`).
//!
//! ```text
//! cargo run -p cmux-pane-protocol --example conformance -- [--corpus DIR] [--json FILE]
//! ```
//!
//! A case that does not conform fails the run unless `_expectations.json`
//! lists it as a known Rust divergence; a listed case that conforms is an
//! unexpected pass, reported without failing (Blink's TestExpectations
//! rule). `--json` writes one record per case: `{case, implementation,
//! result, detail}`.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use anyhow::{Context, bail};
use bytes::Bytes;
use cmux_pane_protocol::envelope::Envelope;
use cmux_pane_protocol::frame::{self, DataFrame, Message};
use cmux_pane_protocol::stream::{RecvWindow, SendCredit};
use cmux_pane_protocol::token::{Claims, SigningKey, Verifier};
use serde_json::{Value, json};

const IMPLEMENTATION: &str = "rust";
const CATEGORIES: [&str; 4] = ["envelopes", "frames", "tokens", "credit"];
const CREDIT_EXCEEDED: &str = "cmux.protocol.credit_exceeded";

/// Whether one case conforms: `Err` carries what differed.
type Check = Result<(), String>;

#[derive(Default)]
struct Tally {
    passed: usize,
    expected: usize,
    unexpected_passes: Vec<String>,
    failures: Vec<String>,
    skipped: usize,
    records: Vec<Value>,
}

impl Tally {
    fn record(&mut self, id: &str, result: &str, detail: &str) {
        self.records.push(json!({ "case": id, "implementation": IMPLEMENTATION, "result": result, "detail": detail }));
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(error) => {
            eprintln!("pane-protocol conformance (rust): {error:#}");
            ExitCode::from(2)
        }
    }
}

fn run() -> anyhow::Result<bool> {
    let mut corpus =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tests/oracle/corpus/pane-protocol");
    let mut json_out: Option<PathBuf> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--corpus" => corpus = args.next().context("--corpus needs a directory")?.into(),
            "--json" => json_out = Some(args.next().context("--json needs a file")?.into()),
            other => bail!("unknown argument {other:?} (use --corpus DIR, --json FILE)"),
        }
    }
    let expectations = read(&corpus, "_expectations.json")?;
    let mine = &expectations["implementations"][IMPLEMENTATION];
    let runtime = tokio::runtime::Builder::new_current_thread().build()?;
    let mut tally = Tally::default();
    for category in CATEGORIES {
        let plan =
            mine["categories"][category].as_str().unwrap_or("missing from _expectations.json");
        if plan != "run" {
            println!("{category}: not run: {plan}");
            continue;
        }
        let file = read(&corpus, &format!("_{category}.json"))?;
        let cases =
            file["cases"].as_array().with_context(|| format!("_{category}.json has no cases"))?;
        for case in cases {
            let id = case["id"].as_str().context("a case without an id")?;
            if let Some(reason) = mine["skip"][id].as_str() {
                tally.skipped += 1;
                tally.record(id, "Skip", reason);
                continue;
            }
            let check = match category {
                "envelopes" => envelope(case),
                "frames" => frame_case(case),
                "tokens" => token(&file["key"], case),
                _ => runtime.block_on(credit(case)),
            };
            judge(&mut tally, id, mine["divergences"].get(id), check);
        }
    }
    for line in &tally.unexpected_passes {
        println!("UNEXPECTED PASS {line}");
    }
    for line in &tally.failures {
        println!("FAIL {line}");
    }
    println!(
        "pane-protocol conformance (rust): {} passed, {} known divergences, {} skipped, {} unexpected passes, {} failures",
        tally.passed,
        tally.expected,
        tally.skipped,
        tally.unexpected_passes.len(),
        tally.failures.len()
    );
    if let Some(path) = json_out {
        let lines: Vec<String> = tally.records.iter().map(Value::to_string).collect();
        std::fs::write(&path, lines.join("\n") + "\n")
            .with_context(|| format!("write {}", path.display()))?;
    }
    Ok(tally.failures.is_empty())
}

fn judge(tally: &mut Tally, id: &str, divergence: Option<&Value>, check: Check) {
    match (check, divergence) {
        (Ok(()), None) => {
            tally.passed += 1;
            tally.record(id, "Pass", "");
        }
        (Ok(()), Some(listed)) => {
            let bug = listed["bug"].as_str().unwrap_or("?");
            tally.unexpected_passes.push(format!("{id}: conforms; remove its divergence ({bug})"));
            tally.record(id, "Pass", "listed as a divergence");
        }
        (Err(detail), Some(_)) => {
            tally.expected += 1;
            tally.record(id, "Failure", &detail);
        }
        (Err(detail), None) => {
            tally.failures.push(format!("{id}: {detail}"));
            tally.record(id, "Failure", &detail);
        }
    }
}

fn read(dir: &Path, name: &str) -> anyhow::Result<Value> {
    let path = dir.join(name);
    let text =
        std::fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    serde_json::from_str(&text).with_context(|| format!("parse {}", path.display()))
}

fn text<'a>(case: &'a Value, key: &str) -> Result<&'a str, String> {
    case[key].as_str().ok_or_else(|| format!("the case has no string {key}"))
}

fn number(case: &Value, key: &str) -> Result<u64, String> {
    case[key].as_u64().ok_or_else(|| format!("the case has no number {key}"))
}

fn unhex(hex: &str) -> Result<Vec<u8>, String> {
    if !hex.len().is_multiple_of(2) {
        return Err(format!("odd hex length in {hex:?}"));
    }
    (0..hex.len())
        .step_by(2)
        .map(|at| {
            hex.get(at..at + 2)
                .and_then(|pair| u8::from_str_radix(pair, 16).ok())
                .ok_or_else(|| format!("bad hex {hex:?}"))
        })
        .collect()
}

fn valid(case: &Value) -> Result<bool, String> {
    match case["verdict"].as_str() {
        Some("valid") => Ok(true),
        Some("invalid") => Ok(false),
        other => Err(format!("verdict {other:?} is not valid or invalid")),
    }
}

fn envelope(case: &Value) -> Check {
    let decoded = Envelope::decode(text(case, "text")?);
    if !valid(case)? {
        return match decoded {
            Ok(envelope) => Err(format!("accepted as {}", envelope.encode())),
            Err(_) => Ok(()),
        };
    }
    let envelope = decoded.map_err(|error| format!("refused: {error}"))?;
    let encoded = envelope.encode();
    if let Some(expected) = case["encoded"].as_str()
        && encoded != expected
    {
        return Err(format!("encoded {encoded} != {expected}"));
    }
    match Envelope::decode(&encoded) {
        Ok(again) if again == envelope => Ok(()),
        _ => Err(format!("{encoded} does not decode to the same envelope")),
    }
}

fn data_frame(value: &Value) -> Result<DataFrame, String> {
    let stream =
        u32::try_from(number(value, "stream")?).map_err(|_| "stream above u32".to_owned())?;
    let credit =
        u32::try_from(number(value, "credit")?).map_err(|_| "credit above u32".to_owned())?;
    Ok(DataFrame { stream, credit, payload: Bytes::from(unhex(text(value, "payload_hex")?)?) })
}

fn frame_case(case: &Value) -> Check {
    let bytes = unhex(text(case, "hex")?)?;
    let valid = valid(case)?;
    match text(case, "layer")? {
        "data_frame" => {
            let bytes = Bytes::from(bytes);
            match (DataFrame::decode(&bytes), valid) {
                (None, false) => Ok(()),
                (Some(frame), false) => {
                    Err(format!("accepted as stream {} credit {}", frame.stream, frame.credit))
                }
                (None, true) => Err("refused".into()),
                (Some(frame), true) => {
                    let expected = data_frame(&case["frame"])?;
                    if frame != expected {
                        return Err(format!("decoded {frame:?} != {expected:?}"));
                    }
                    if frame.encode() != bytes {
                        return Err("re-encoding differs".into());
                    }
                    Ok(())
                }
            }
        }
        "unix" if case["header_only"].as_bool() == Some(true) => {
            let header: [u8; 4] = bytes
                .get(..4)
                .and_then(|head| head.try_into().ok())
                .ok_or("a header is 4 bytes")?;
            match (frame::parse_header(header).is_ok(), valid) {
                (true, false) => Err("header accepted".into()),
                (false, true) => Err("header refused".into()),
                _ => Ok(()),
            }
        }
        "unix" => match (frame::decode(&bytes), valid) {
            (Err(_), false) => Ok(()),
            (Ok(_), false) => Err("accepted".into()),
            (Err(error), true) => Err(format!("refused: {error}")),
            (Ok(None), true) => Err("decoder wants more bytes".into()),
            (Ok(Some((message, used))), true) => {
                let spec = &case["message"];
                let expected = match text(spec, "kind")? {
                    "text" => Message::Text(text(spec, "text")?.to_owned()),
                    _ => Message::Binary(data_frame(&spec["frame"])?.encode()),
                };
                if used != bytes.len() {
                    return Err(format!("used {used} of {} bytes", bytes.len()));
                }
                if message != expected {
                    return Err(format!("decoded {message:?} != {expected:?}"));
                }
                match frame::encode(&expected) {
                    Ok(encoded) if encoded == bytes => Ok(()),
                    _ => Err("re-encoding differs".into()),
                }
            }
        },
        other => Err(format!("unknown frame layer {other:?}")),
    }
}

fn key_bytes(key: &Value, field: &str) -> Result<[u8; 32], String> {
    unhex(text(key, field)?)?.try_into().map_err(|_| format!("{field} is not 32 bytes"))
}

fn token(key: &Value, case: &Value) -> Check {
    let public_key = key_bytes(key, "public_key_hex")?;
    let signing =
        SigningKey::from_seed(&key_bytes(key, "seed_hex")?).map_err(|error| error.to_string())?;
    if signing.public_key() != public_key {
        return Err("seed_hex does not give public_key_hex".into());
    }
    let claims: Claims =
        serde_json::from_value(key["claims"].clone()).map_err(|error| error.to_string())?;
    // Ed25519 is deterministic, so the key's token is reproducible.
    if signing.sign(&claims) != text(key, "token")? {
        return Err("the key's claims do not sign to its token".into());
    }
    let expected = text(case, "verdict")?;
    let got = match text(case, "kind")? {
        "verify" => Verifier::new(public_key, text(case, "aud")?)
            .verify(text(case, "token")?, number(case, "now")?, case["origin"].as_str())
            .map_or_else(|error| error.as_str(), |_| "ok"),
        "allows" => {
            if claims.allows(text(case, "op")?, text(case, "scope")?) {
                "allowed"
            } else {
                "denied"
            }
        }
        other => return Err(format!("unknown token check {other:?}")),
    };
    if got == expected { Ok(()) } else { Err(format!("{got} != {expected}")) }
}

fn size(step: &Value, key: &str) -> Result<usize, String> {
    usize::try_from(number(step, key)?).map_err(|_| format!("{key} above usize"))
}

fn grant_of(step: &Value, key: &str) -> Result<u32, String> {
    u32::try_from(number(step, key)?).map_err(|_| format!("{key} above u32"))
}

async fn credit(case: &Value) -> Check {
    let steps = case["steps"].as_array().ok_or("the sequence has no steps")?;
    match text(case, "role")? {
        "sender" => {
            let credit = SendCredit::new();
            let (mut queued, mut sent) = (0usize, 0usize);
            for (index, step) in steps.iter().enumerate() {
                if step.get("write").is_some() {
                    queued = queued.saturating_add(size(step, "write")?);
                } else if step.get("credit").is_some() {
                    credit.grant(grant_of(step, "credit")?).await;
                } else {
                    // A data frame's credit field grants the same window as a `credit` envelope.
                    credit.grant(grant_of(step, "frame_credit")?).await;
                }
                let taken = credit.try_take(queued).await;
                queued -= taken;
                sent += taken;
                let expected = size(step, "sent")?;
                if sent != expected {
                    return Err(format!("step {index}: sent {sent} != {expected}"));
                }
            }
            Ok(())
        }
        "receiver" => {
            let mut window = RecvWindow::new(grant_of(case, "window")?);
            window.initial_grant();
            for (index, step) in steps.iter().enumerate() {
                let got = match window.received(size(step, "receive")?) {
                    Ok(()) => "ok",
                    Err(_) => CREDIT_EXCEEDED,
                };
                let expected = text(step, "verdict")?;
                if got != expected {
                    return Err(format!("step {index}: {got} != {expected}"));
                }
            }
            Ok(())
        }
        other => Err(format!("unknown credit role {other:?}")),
    }
}
