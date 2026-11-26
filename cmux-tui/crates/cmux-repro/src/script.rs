//! The replay: one bash script that a fresh machine runs with nothing but git and the capsule's
//! prerequisites. It makes a new checkout of the base commit, applies the capsule's diff (and the
//! candidate fix, for the green run), checks the prerequisites and the fingerprint, runs the setup
//! and then the command under its timeout, and prints marker lines [`crate::judge`] reads.
//!
//! The patches are not in the script: they sit next to it as `diff.patch` and `candidate.patch`, so
//! the script stays readable and nothing the capsule captured is ever interpreted as shell. Every
//! value from the capsule goes into the script single-quoted ([`quote`]).

use crate::{Capsule, DRIFT_MARKER, EXIT_MARKER, PREREQ_EXIT, PREREQ_MARKER, ROOT_MARKER};
use std::fmt::Write as _;

/// The patch files the script reads from its own directory.
pub const DIFF_FILE: &str = "diff.patch";
pub const CANDIDATE_FILE: &str = "candidate.patch";

/// A shell word that is exactly `value`.
pub fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r#"'\''"#))
}

/// The runner script. `with_candidate` makes it apply `candidate.patch` after the capsule's diff.
pub fn runner(capsule: &Capsule, with_candidate: bool) -> String {
    let mut s = String::new();
    let missing = |what: &str| -> String {
        format!(
            "{{ echo {}; echo {}; exit {PREREQ_EXIT}; }}",
            quote(&format!("{PREREQ_MARKER}{what}")),
            quote(&format!("{EXIT_MARKER}{PREREQ_EXIT}"))
        )
    };
    let _ = writeln!(s, "#!/usr/bin/env bash");
    let _ =
        writeln!(s, "# cmux repro capsule {} ({})", capsule.id, capsule.title.replace('\n', " "));
    let _ = writeln!(s, "set -u");
    let _ = writeln!(s, "here=\"$(cd \"$(dirname \"$0\")\" && pwd)\"");
    let _ = writeln!(s, "export GIT_TERMINAL_PROMPT=0");
    let _ = writeln!(s, "command -v git >/dev/null 2>&1 || {}", missing("git"));
    let _ = writeln!(s, "absent=0");
    for p in &capsule.prerequisites {
        let _ = writeln!(
            s,
            "bash -c {} >/dev/null 2>&1 || {{ echo {}; absent=1; }}",
            quote(&p.check),
            quote(&format!("{PREREQ_MARKER}{}", p.name))
        );
    }
    let _ = writeln!(
        s,
        "[ \"$absent\" = 0 ] || {{ echo {}; exit {PREREQ_EXIT}; }}",
        quote(&format!("{EXIT_MARKER}{PREREQ_EXIT}"))
    );
    let _ = writeln!(s, "work=\"$(mktemp -d \"${{TMPDIR:-/tmp}}/capsule-work.XXXXXX\")/repo\"");
    let _ = writeln!(
        s,
        "mkdir -p \"$work\" && cd \"$work\" || {}",
        missing("a writable temp directory")
    );
    let _ = writeln!(s, "echo \"{ROOT_MARKER}$work\"");
    let _ = writeln!(s, "git init -q . && git remote add origin {}", quote(&capsule.repo.url));
    let _ = writeln!(
        s,
        "git fetch -q --depth 1 origin {} || {}",
        quote(&capsule.repo.base_sha),
        missing(&format!("base commit {} from {}", capsule.repo.base_sha, capsule.repo.url))
    );
    let _ = writeln!(
        s,
        "git -c advice.detachedHead=false checkout -q FETCH_HEAD || {}",
        missing("checkout of the base commit")
    );
    let _ = writeln!(
        s,
        "if [ -s \"$here/{DIFF_FILE}\" ]; then git apply --whitespace=nowarn \"$here/{DIFF_FILE}\" || {}; fi",
        missing("the capsule's diff applies to the base commit")
    );
    if with_candidate {
        let _ = writeln!(
            s,
            "git apply --whitespace=nowarn \"$here/{CANDIDATE_FILE}\" || {}",
            missing("the candidate patch applies on top of the capsule's diff")
        );
    }
    for (path, sha) in &capsule.fingerprint.files {
        let _ = writeln!(
            s,
            "[ \"$(sha256sum {p} 2>/dev/null | cut -d' ' -f1)\" = {sha} ] || echo {msg}",
            p = quote(path),
            sha = quote(sha),
            msg = quote(&format!("{DRIFT_MARKER}{path}"))
        );
    }
    for (tool, version) in &capsule.fingerprint.tools {
        let _ = writeln!(
            s,
            "v=\"$({t} --version 2>&1 | head -n1)\"; [ \"$v\" = {v} ] || echo \"{DRIFT_MARKER}{tool}: \"{v}\" here: $v\"",
            t = quote(tool),
            v = quote(version)
        );
    }
    let cwd =
        if capsule.command.cwd.is_empty() { ".".to_owned() } else { capsule.command.cwd.clone() };
    let _ = writeln!(s, "cd {} || {}", quote(&cwd), missing(&format!("directory {cwd}")));
    for (name, value) in &capsule.command.env {
        if is_env_name(name) {
            let _ = writeln!(s, "export {name}={}", quote(value));
        }
    }
    if !capsule.setup.is_empty() {
        let _ =
            writeln!(s, "bash -c {} 2>&1 || {}", quote(&capsule.setup), missing("setup succeeds"));
    }
    let _ = writeln!(
        s,
        "timeout --kill-after=10 {} bash -c {} 2>&1",
        capsule.command.timeout_s.max(1),
        quote(&capsule.command.shell)
    );
    let _ = writeln!(s, "code=$?");
    let _ = writeln!(s, "echo \"{EXIT_MARKER}$code\"");
    let _ = writeln!(s, "exit \"$code\"");
    s
}

fn is_env_name(name: &str) -> bool {
    !name.is_empty()
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        && !name.starts_with(|c: char| c.is_ascii_digit())
}
