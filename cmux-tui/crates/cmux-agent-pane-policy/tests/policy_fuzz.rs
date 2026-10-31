//! Fuzz-catalog row l (security): the agent pane page -> acpmux trust
//! boundary. A page frame reaches acpmux only when the policy allows it: a
//! method off the lists, a near miss of an allowed name, an extra top-level
//! key, `mcpServers` anywhere, an unknown param or a command-bearing param
//! is refused with a typed refusal code, and the check never panics.
//!
//! Seeded and deterministic: `CMUX_FUZZ_SEED=<seed>` replays a run (the seed
//! is printed), `CMUX_FUZZ_CASES=<n>` sets the cases per property.

use cmux_agent_pane_policy::check::{Checked, FrameState, PaneScope, check_frame, encode};
use cmux_agent_pane_policy::frame::{FRAME_KEYS, carries_servers};
use cmux_agent_pane_policy::gesture::PermissionOptions;
use cmux_agent_pane_policy::{Refusal, policy};
use serde_json::{Map, Value, json};
use std::time::{SystemTime, UNIX_EPOCH};
use unicode_normalization::UnicodeNormalization;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: usize) -> usize {
        if n == 0 { 0 } else { (self.next() % n as u64) as usize }
    }
    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }
}

fn seed(test: &str) -> u64 {
    let seed =
        std::env::var("CMUX_FUZZ_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or_else(|| {
            SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(1)
        });
    eprintln!("fuzz-seed {test} {seed} (replay: CMUX_FUZZ_SEED={seed})");
    seed
}

fn cases() -> usize {
    std::env::var("CMUX_FUZZ_CASES")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|n| *n > 0)
        .unwrap_or(4000)
}

struct Scope;

impl PaneScope for Scope {
    fn contains(&self, session: &str) -> bool {
        session == "s1"
    }
    fn holds_source(&self, params: &Map<String, Value>) -> bool {
        params.get("sessionId").and_then(Value::as_str) == Some("s1")
    }
}

fn check(text: &str, is_first: bool) -> Checked {
    let options = PermissionOptions::new();
    let state = FrameState {
        is_first,
        local_app_token: Some("tok"),
        mode_fields: None,
        scope: &Scope,
        options: &options,
    };
    check_frame(text, &state)
}

/// A name the policy holds, as its `contains` decides (exact or canonically
/// equivalent: NFC).
fn allowed(name: &str, request: bool) -> bool {
    let p = policy();
    let set = if request { &p.requests } else { &p.notifications };
    let nfc: String = name.nfc().collect();
    set.iter().any(|s| s.nfc().eq(nfc.chars()))
}

/// A near miss of an allowed method name.
fn near_miss(rng: &mut Rng) -> String {
    let p = policy();
    let names: Vec<&String> = p.requests.iter().chain(p.notifications.iter()).collect();
    let base = rng.pick(&names).to_string();
    let mut chars: Vec<char> = base.chars().collect();
    match rng.below(10) {
        0 => base.to_uppercase(),
        1 => format!(" {base}"),
        2 => format!("{base}/"),
        3 => format!("{base}\u{0}"),
        4 => format!("{base}\u{200b}"),
        5 => {
            // A homoglyph (Cyrillic а, о, е) for a Latin letter.
            if let Some(at) = chars.iter().position(|c| matches!(c, 'a' | 'o' | 'e')) {
                chars[at] = match chars[at] {
                    'a' => 'а',
                    'o' => 'о',
                    _ => 'е',
                };
            }
            chars.into_iter().collect()
        }
        6 => base.replace('/', "\\/").replace('\\', "/./"),
        7 => format!("../{base}"),
        8 => {
            // A fullwidth letter (NFKC folds it, NFC does not).
            if let Some(c) = chars.iter_mut().find(|c| c.is_ascii_lowercase()) {
                *c = char::from_u32(*c as u32 - 'a' as u32 + 0xFF41).unwrap();
            }
            chars.into_iter().collect()
        }
        _ => {
            let at = rng.below(chars.len().max(1));
            if !chars.is_empty() {
                chars.remove(at);
            }
            chars.into_iter().collect()
        }
    }
}

fn random_name(rng: &mut Rng) -> String {
    let parts = [
        "session",
        "_acpmux",
        "acp",
        "fs",
        "terminal",
        "process",
        "kill",
        "exec",
        "spawn",
        "run",
        "write_text_file",
        "read_text_file",
        "shell",
        "/",
        "_",
        ".",
        "new",
        "create",
    ];
    (0..1 + rng.below(4)).map(|_| *rng.pick(&parts)).collect()
}

fn refusal(checked: &Checked) -> Option<Refusal> {
    match checked {
        Checked::Refuse { refused, .. } => Some(refused.refusal),
        Checked::Frame { .. } => None,
    }
}

#[test]
fn fuzz_bl_a_method_off_the_lists_is_refused_with_a_typed_code() {
    let mut rng = Rng(seed("method_off_the_lists"));
    let mut failures = Vec::new();
    for n in 0..cases() {
        let name = if n % 2 == 0 { near_miss(&mut rng) } else { random_name(&mut rng) };
        let request = n % 3 != 0;
        let mut frame = json!({"jsonrpc": "2.0", "method": name, "params": {}});
        if request {
            frame["id"] = json!(n);
        }
        let checked = check(&frame.to_string(), false);
        let refused = refusal(&checked);
        if allowed(&name, request) {
            continue;
        }
        if !matches!(
            refused,
            Some(Refusal::MethodRefused | Refusal::InvalidFrame | Refusal::IntentInvalid)
        ) {
            failures.push(format!("{name:?} (request {request}): {checked:?}"));
        }
    }
    assert!(
        failures.is_empty(),
        "{} frames off the lists not refused, e.g. {:?}",
        failures.len(),
        &failures[..failures.len().min(5)]
    );
}

const COMMAND_KEYS: &[&str] = &[
    "command",
    "initial_command",
    "argv",
    "args",
    "env",
    "shell",
    "executable",
    "mcpServers",
    "tmux_start_command",
    "pane_start_command",
];

/// An allowed request with one unknown or command-bearing key, at the top of
/// params, in `_meta`, or in `_meta.acpmux`.
#[test]
fn fuzz_bl_an_allowed_method_with_an_unknown_or_command_param_is_refused() {
    let mut rng = Rng(seed("unknown_or_command_param"));
    let p = policy();
    let methods: Vec<&String> =
        p.requests.iter().filter(|m| p.known_params.contains_key(*m)).collect();
    let mut failures = Vec::new();
    for n in 0..cases() {
        let method = rng.pick(&methods).to_string();
        let known = &p.known_params[&method];
        let key = if rng.below(2) == 0 {
            rng.pick(COMMAND_KEYS).to_string()
        } else {
            format!("fuzz_{}", rng.next() % 1000)
        };
        let value = rng
            .pick(&[
                json!("/bin/sh -c id"),
                json!(["/bin/sh", "-c", "id"]),
                json!({"PATH": "/tmp"}),
                json!([{"name": "x", "command": "/bin/sh"}]),
            ])
            .clone();
        let mut params = json!({});
        if known.params.contains("sessionId") {
            params["sessionId"] = json!("s1");
        }
        let place = rng.below(3);
        match place {
            0 => params[&key] = value,
            1 => params["_meta"] = json!({ key.clone(): value }),
            _ => params["_meta"] = json!({"acpmux": { key.clone(): value }}),
        }
        let in_list = match place {
            0 => known.params.contains(&key),
            1 => false,
            _ => known.acpmux.contains(&key),
        };
        if in_list && key != p.servers_key {
            continue;
        }
        let frame = json!({"jsonrpc": "2.0", "id": n, "method": method, "params": params});
        let checked = check(&frame.to_string(), false);
        if refusal(&checked).is_none() {
            failures.push(format!("{method} {key} at place {place}: {checked:?}"));
        }
    }
    assert!(
        failures.is_empty(),
        "{} frames with an unknown or command param were let through, e.g. {:?}",
        failures.len(),
        &failures[..failures.len().min(5)]
    );
}

/// Whatever the page writes, the check never panics; a frame it lets
/// through names an allowed method and has only the four frame keys and no
/// `mcpServers` at any depth after encoding.
#[test]
fn fuzz_bl_random_frames_never_panic_and_only_allowed_frames_pass() {
    let mut rng = Rng(seed("random_frames"));
    let p = policy();
    let names: Vec<&String> = p.requests.iter().collect();
    let tokens = [
        "{",
        "}",
        "[",
        "]",
        ",",
        ":",
        "\"jsonrpc\"",
        "\"2.0\"",
        "\"method\"",
        "\"id\"",
        "\"params\"",
        "1",
        "null",
        "\"mcpServers\"",
        "\"session/new\"",
        "\"_meta\"",
        "\"acpmux\"",
        "\"cwd\"",
        "\"/\"",
    ];
    let mut failures = Vec::new();
    for n in 0..cases() {
        let text = match n % 3 {
            0 => (0..rng.below(60)).map(|_| *rng.pick(&tokens)).collect::<String>(),
            1 => {
                let mut frame = json!({"jsonrpc": "2.0", "id": n, "method": rng.pick(&names).as_str(), "params": {"sessionId": "s1"}});
                if rng.below(3) == 0 {
                    frame[*rng.pick(&["result", "error", "fuzz", "Method", "jsonrpc "])] = json!(1);
                }
                frame.to_string()
            }
            _ => String::from_utf8_lossy(
                &(0..rng.below(300)).map(|_| (rng.next() & 0xff) as u8).collect::<Vec<_>>(),
            )
            .into_owned(),
        };
        let is_first = rng.below(8) == 0;
        let checked = check(&text, is_first);
        let Checked::Frame { frame, .. } = &checked else { continue };
        let method = frame.get("method").and_then(Value::as_str).unwrap_or_default();
        let request = frame.contains_key("id");
        let ok_method = if is_first { method == p.initialize } else { allowed(method, request) };
        let extra_key = frame.keys().find(|k| !FRAME_KEYS.contains(&k.as_str()));
        let encoded = encode(frame, Some(7)).unwrap_or_default();
        let servers = serde_json::from_str::<Value>(&encoded).is_ok_and(|v| carries_servers(&v));
        if !ok_method || extra_key.is_some() || servers {
            failures.push(format!("let through: {}", text.chars().take(200).collect::<String>()));
        }
    }
    assert!(
        failures.is_empty(),
        "{} frames let through that break the policy: {:?}",
        failures.len(),
        &failures[..failures.len().min(5)]
    );
}

/// The first frame of a connection is `initialize` with an id, or refused.
#[test]
fn fuzz_bl_a_first_frame_that_is_not_initialize_is_refused() {
    let mut rng = Rng(seed("first_frame"));
    let p = policy();
    let names: Vec<&String> = p.requests.iter().chain(p.notifications.iter()).collect();
    for n in 0..cases() / 4 {
        let method = if n % 2 == 0 { rng.pick(&names).to_string() } else { near_miss(&mut rng) };
        if method == p.initialize {
            continue;
        }
        let frame = json!({"jsonrpc": "2.0", "id": n, "method": method, "params": {}});
        let refused = refusal(&check(&frame.to_string(), true));
        assert!(
            matches!(
                refused,
                Some(
                    Refusal::FirstFrameNotInitialize
                        | Refusal::InvalidFrame
                        | Refusal::MethodRefused
                )
            ),
            "first frame {method:?} not refused: {refused:?}"
        );
    }
    let no_id = json!({"jsonrpc": "2.0", "method": p.initialize, "params": {}});
    assert!(
        refusal(&check(&no_id.to_string(), true)).is_some(),
        "an initialize with no id passed as a first frame"
    );
}
