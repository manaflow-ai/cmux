//! Fuzz-catalog row l (security): the remote entry's gates
//! (skills/cmux-socket-policy/references/remote-relay-authorization.md).
//! A relay client is a compromised client: a gate denies by default, and a
//! frame with a command-bearing param (`initial_command`, `command`,
//! `tmux_start_command`, `pane_start_command`) is denied on every method,
//! at any depth.
//!
//! Checked for both gates the daemon has: `FsGate` (the gate the link entry
//! installs, cmux-tui src/link/mod.rs `link_entry_gate`) and
//! `ConversationGate`. Seeded: `CMUX_FUZZ_SEED=<seed>` replays.
#![cfg(unix)]

use std::time::{SystemTime, UNIX_EPOCH};

use cmux_tui_core::server::{ConversationGate, DenyAllGate, FsGate, RemoteGate, RemotePeer};
use serde_json::{Value, json};

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
        .unwrap_or(5000)
}

fn peer() -> RemotePeer {
    RemotePeer { install: "inst_1".into(), user: "42".into(), team: "team_a".into() }
}

const COMMAND_PARAMS: &[&str] =
    &["initial_command", "command", "tmux_start_command", "pane_start_command"];
const FS_COMMANDS: &[&str] =
    &["fs.stat", "fs.list", "fs.read", "fs.write", "fs.mkdir", "fs.rename", "fs.delete"];
const CONVERSATION_COMMANDS: &[&str] = &[
    "identify",
    "set-client-info",
    "subscribe",
    "conversation-list",
    "conversation-snapshot",
    "conversation-history",
    "conversation-op",
    "conversation-typing",
];
/// Commands a relay must never reach: they spawn, type, close or read local state.
const DANGEROUS: &[&str] = &[
    "run",
    "create-terminal",
    "new-tab",
    "new-pane",
    "split",
    "send",
    "send-key",
    "close-workspace",
    "shutdown-daemon",
    "url-open",
    "paste-image",
    "put-session",
    "attach-surface",
    "read-scrollback",
    "terminal-resume-command",
    "list-workspaces",
    "workspace.create",
    "terminal.input.write",
];

/// A frame for `cmd` with one command-bearing param, at the top level or
/// nested (in `op`, in `params`, in a list).
fn with_command_param(cmd: &str, rng: &mut Rng) -> (Value, String) {
    let param = *rng.pick(COMMAND_PARAMS);
    let payload = json!(*rng.pick(&["/bin/sh -c id", "open -a Calculator", "rm -rf ~"]));
    let mut frame = json!({"id": 1, "cmd": cmd, "path": "/home/cmux/notes.txt"});
    let place = match rng.below(4) {
        0 => {
            frame[param] = payload;
            "top"
        }
        1 => {
            frame["op"] = json!({"kind": "message.send", param: payload});
            "op"
        }
        2 => {
            frame["params"] = json!({ param: payload });
            "params"
        }
        _ => {
            frame["paths"] = json!([{ param: payload }]);
            "list"
        }
    };
    (frame, format!("{cmd} {param} at {place}"))
}

#[test]
fn fuzz_bl_every_gate_denies_command_bearing_params_on_every_method() {
    let mut rng = Rng(seed("gate_command_params"));
    let gates: [(&str, Box<dyn RemoteGate>); 3] = [
        ("FsGate", Box::new(FsGate)),
        ("ConversationGate", Box::new(ConversationGate)),
        ("DenyAllGate", Box::new(DenyAllGate)),
    ];
    let commands: Vec<&str> =
        FS_COMMANDS.iter().chain(CONVERSATION_COMMANDS).chain(DANGEROUS).copied().collect();
    let mut admitted = std::collections::BTreeMap::<String, Vec<String>>::new();
    for _ in 0..cases() {
        let cmd = *rng.pick(&commands);
        let (frame, label) = with_command_param(cmd, &mut rng);
        for (name, gate) in &gates {
            if gate.admit(&peer(), &frame.to_string()) {
                admitted.entry(name.to_string()).or_default().push(label.clone());
            }
        }
    }
    let report: Vec<String> = admitted
        .iter()
        .map(|(gate, labels)| {
            let mut unique: Vec<&String> = labels.iter().collect();
            unique.sort();
            unique.dedup();
            format!(
                "{gate}: {} frames admitted, e.g. {:?}",
                labels.len(),
                &unique[..unique.len().min(4)]
            )
        })
        .collect();
    assert!(
        report.is_empty(),
        "a remote gate admitted a frame with a command-bearing param:\n{}",
        report.join("\n")
    );
}

#[test]
fn fuzz_bl_every_gate_denies_commands_off_its_allowlist_and_near_misses() {
    let mut rng = Rng(seed("gate_default_deny"));
    let mut failures = Vec::new();
    for n in 0..cases() {
        let base = *rng.pick(&[FS_COMMANDS, CONVERSATION_COMMANDS].concat());
        let cmd = match n % 8 {
            0 => base.to_uppercase(),
            1 => format!(" {base}"),
            2 => format!("{base}\u{0}"),
            3 => format!("{base}\u{200b}"),
            4 => base.replace('.', "\u{2024}"),
            5 => rng.pick(DANGEROUS).to_string(),
            6 => format!("{base}/"),
            _ => base.chars().rev().collect(),
        };
        let frames = [
            json!({"id": n, "cmd": cmd, "path": "/home/cmux/x"}),
            json!({"protocol": "cmux.protocol/2", "type": "request", "id": "x", "operation": base, "cmd": base, "params": {}}),
        ];
        for frame in frames {
            let text = frame.to_string();
            if FsGate.admit(&peer(), &text) {
                failures.push(format!("FsGate admitted {text}"));
            }
            if ConversationGate.admit(&peer(), &text) {
                failures.push(format!("ConversationGate admitted {text}"));
            }
        }
    }
    // Raw noise: never admitted, never a panic.
    for _ in 0..cases() {
        let bytes: Vec<u8> = (0..rng.below(200)).map(|_| (rng.next() & 0xff) as u8).collect();
        let text = String::from_utf8_lossy(&bytes);
        assert!(
            !FsGate.admit(&peer(), &text) && !ConversationGate.admit(&peer(), &text),
            "noise admitted: {text:?}"
        );
    }
    assert!(
        failures.is_empty(),
        "{} near misses admitted, e.g. {:?}",
        failures.len(),
        &failures[..failures.len().min(5)]
    );
}
