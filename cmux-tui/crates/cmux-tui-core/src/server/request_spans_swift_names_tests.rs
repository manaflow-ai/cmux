//! The app's copy of the method ids (p09-observability task 025): the Swift
//! tables `scripts/cmux-next/gen-daemon-command-names.py` writes must give
//! every name the id this daemon's `daemon.request` slice carries, so both
//! sides of a request name the same method in a trace. A table change that
//! skips the generator fails here, in the daemon's own `cargo test`.

use std::io::Write;
use std::path::{Path, PathBuf};

use super::super::command_names::COMMANDS;
use super::{Fnv1a, RequestMethod};
use crate::resource::ResourceOperation;

/// The app's generated Swift file `name`, or `None` in a cmux-tui tree
/// without the app beside it (a published tree).
fn generated(name: &str) -> Option<(PathBuf, String)> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let dir = root.join("Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Connection");
    if !dir.is_dir() {
        eprintln!("SWIFT NAMES: no Packages/macOS/CmuxNext in this tree; skipped");
        return None;
    }
    let path = dir.join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("SWIFT NAMES: {}: {error}", path.display()));
    Some((path, text))
}

fn fnv1a(text: &str) -> u64 {
    let mut hash = Fnv1a(Fnv1a::OFFSET);
    hash.write_all(text.as_bytes()).expect("hashing cannot fail");
    hash.0
}

/// Every `case 0xHASH: return (ID, "SPELLING")` row of a generated table.
fn rows(text: &str) -> Vec<(u64, u16, String)> {
    text.lines()
        .filter_map(|line| line.trim().strip_prefix("case 0x"))
        .map(|row| {
            let (hash, rest) = row.split_once(": return (").expect("a table row");
            let (id, spelling) = rest.split_once(", \"").expect("a table row");
            let spelling = spelling.strip_suffix("\")").expect("a table row");
            let hash = u64::from_str_radix(hash, 16).expect("a hex hash");
            (hash, id.parse().expect("a decimal id"), spelling.to_owned())
        })
        .collect()
}

/// The generated rows are `want`, compared by id (`ResourceOperation::ALL`
/// lists the operations in wire-name order, not by id).
fn expect_rows(path: &Path, text: &str, mut want: Vec<(u16, &str)>) {
    let mut got = rows(text);
    got.sort_by(|a, b| (a.1, &a.2).cmp(&(b.1, &b.2)));
    want.sort_unstable();
    let stale = "run scripts/cmux-next/gen-daemon-command-names.py";
    assert_eq!(got.len(), want.len(), "{}: row count differs; {stale}", path.display());
    for ((hash, id, spelling), (want_id, want_spelling)) in got.iter().zip(want) {
        assert_eq!(
            (*id, spelling.as_str()),
            (want_id, want_spelling),
            "{}: row differs; {stale}",
            path.display()
        );
        assert_eq!(*hash, fnv1a(spelling), "{}: {spelling} has another hash", path.display());
    }
}

#[test]
fn request_spans_generated_swift_command_ids_match_the_daemon() {
    let Some((path, text)) = generated("DaemonCommandName+Commands.swift") else { return };
    let want = COMMANDS
        .iter()
        .enumerate()
        .flat_map(|(row, command)| {
            let id = u16::try_from(row).expect("fewer than 2^16 commands");
            std::iter::once(command.wire)
                .chain(command.aliases.iter().copied())
                .map(move |name| (id, name))
        })
        .collect();
    expect_rows(&path, &text, want);
}

#[test]
fn request_spans_generated_swift_resource_ids_match_the_daemon() {
    let Some((path, text)) = generated("DaemonCommandName+Resources.swift") else { return };
    let want = ResourceOperation::ALL
        .iter()
        .map(|&operation| (RequestMethod::of_resource(operation).id, operation.wire_name()))
        .collect();
    expect_rows(&path, &text, want);
}

/// The Swift `routedID`: its prefix arms in order, then its fallback.
fn swift_routed(text: &str) -> (Vec<(Vec<String>, u16)>, u16) {
    let body = text.split_once("static func routedID").expect("a routedID function").1;
    let mut arms = Vec::new();
    for line in body.lines().map(str::trim) {
        if let Some(arm) = line.strip_prefix("if ") {
            let (test, id) = arm.split_once(" { return 0x").expect("a prefix arm");
            let prefixes = test
                .split(" || ")
                .map(|part| {
                    let quoted = part.strip_prefix("bytes.starts(with: \"").expect("a prefix test");
                    quoted.strip_suffix("\".utf8)").expect("a prefix test").to_owned()
                })
                .collect();
            let id = u16::from_str_radix(id.strip_suffix(" }").expect("an arm id"), 16)
                .expect("a hex id");
            arms.push((prefixes, id));
        } else if let Some(id) = line.strip_prefix("return 0x") {
            return (arms, u16::from_str_radix(id, 16).expect("a hex id"));
        }
    }
    panic!("routedID has no fallback");
}

#[test]
fn request_spans_generated_swift_routed_ids_match_the_daemon() {
    let Some((path, text)) = generated("DaemonCommandName+Commands.swift") else { return };
    let (arms, fallback) = swift_routed(&text);
    let id_of = |name: &str| {
        arms.iter()
            .find(|(prefixes, _)| prefixes.iter().any(|prefix| name.starts_with(prefix.as_str())))
            .map_or(fallback, |(_, id)| *id)
    };
    let mut probes = vec!["", "agent", "browser", "access", "other-thing", "agent-session-events"];
    let prefixes: Vec<String> = arms.iter().flat_map(|(prefixes, _)| prefixes.clone()).collect();
    let extended: Vec<String> = prefixes.iter().map(|prefix| format!("{prefix}x")).collect();
    probes.extend(prefixes.iter().map(String::as_str));
    probes.extend(extended.iter().map(String::as_str));
    for name in probes {
        assert_eq!(
            id_of(name),
            RequestMethod::routed(Some(name)).id,
            "{}: `{name}` routes elsewhere; run scripts/cmux-next/gen-daemon-command-names.py",
            path.display()
        );
    }
    assert_eq!(fallback, RequestMethod::routed(None).id);
}
