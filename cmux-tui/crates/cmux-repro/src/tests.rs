use super::*;
use crate::create::{Options, create, replay_local};
use std::path::Path;
use std::process::Command as Proc;

const UNITTEST_FAIL: &str = "\
..F
======================================================================
FAIL: test_jobs (__main__.Jobs.test_jobs)
----------------------------------------------------------------------
Traceback (most recent call last):
  File \"/home/someone/repo/tests/test_x.py\", line 40, in test_jobs
    self.assertEqual(set(), unclassified)
AssertionError: Items in the first set but not the second:
'nightly-next-pkg'
----------------------------------------------------------------------
Ran 3 tests in 0.004s

FAILED (failures=1)
";

fn capsule_with(signature: Vec<String>, exit: Option<i32>) -> Capsule {
    Capsule {
        schema: SCHEMA,
        id: String::new(),
        created_at: "2026-11-25T00:00:00Z".into(),
        title: "t".into(),
        made_by: "test".into(),
        repo: Repo { url: "https://github.com/o/r.git".into(), base_sha: "abc".into() },
        diff: String::new(),
        diff_files: vec![],
        command: Command {
            shell: "false".into(),
            cwd: String::new(),
            timeout_s: 30,
            env: Default::default(),
        },
        setup: String::new(),
        prerequisites: vec![],
        expected: Expected { exit_code: exit, signature },
        observed: Observed {
            exit_code: 1,
            duration_ms: 1,
            output_tail: String::new(),
            os: "linux".into(),
            arch: "x86_64".into(),
        },
        fingerprint: Fingerprint::default(),
        removed: vec![],
    }
}

#[test]
fn signature_takes_the_failure_lines_not_the_timing() {
    let sig = derive_signature(UNITTEST_FAIL, Some("/home/someone/repo"));
    assert!(
        sig.iter().any(|l| l == "AssertionError: Items in the first set but not the second:"),
        "{sig:?}"
    );
    assert!(sig.iter().any(|l| l == "FAILED (failures=1)"), "{sig:?}");
    assert!(sig.iter().all(|l| !l.contains("0.004s")), "{sig:?}");
}

#[test]
fn normalize_drops_machine_specific_text() {
    let text =
        "\u{1b}[31merror\u{1b}[0m at /w/x/src/a.rs took 12.5ms ptr 0xdeadbeef ThreadId(7)\r\n";
    assert_eq!(
        normalize(text, Some("/w/x")),
        "error at <ROOT>/src/a.rs took <T> ptr <HEX> ThreadId(<N>)\n"
    );
}

#[test]
fn judge_reads_red_green_and_the_rest() {
    let c = capsule_with(vec!["AssertionError: boom".into()], Some(1));
    let red = "CAPSULE-ROOT: /tmp/x\nAssertionError:   boom\nCAPSULE-EXIT: 1\n";
    assert_eq!(judge(&c, red).1, Verdict::Reproduced);
    assert_eq!(judge(&c, "ok\nCAPSULE-EXIT: 0\n").1, Verdict::Passed);
    assert!(matches!(
        judge(&c, "other\nCAPSULE-EXIT: 2\n").1,
        Verdict::FailedDifferently { exit_code: 2, .. }
    ));
    // Exit 0 while the failure text still prints is not green.
    assert!(matches!(
        judge(&c, "AssertionError: boom\nCAPSULE-EXIT: 0\n").1,
        Verdict::FailedDifferently { .. }
    ));
    assert_eq!(
        judge(&c, "CAPSULE-PREREQ-MISSING: python3\nCAPSULE-EXIT: 97\n").1,
        Verdict::MissingPrerequisite { missing: vec!["python3".into()] }
    );
    assert_eq!(judge(&c, "killed\n").1, Verdict::NoAnswer);
    let (_, _, drift) = judge(&c, "CAPSULE-FINGERPRINT-DIFFERS: Cargo.lock\nCAPSULE-EXIT: 0\n");
    assert_eq!(drift, vec!["Cargo.lock".to_owned()]);
}

#[test]
fn receipt_verifies_only_red_then_green() {
    let c = capsule_with(vec![], None);
    let run = |phase: &str, verdict| Run {
        phase: phase.into(),
        place: "p".into(),
        candidate_sha256: String::new(),
        exit_code: Some(0),
        duration_ms: 1,
        verdict,
        drift: vec![],
        output_tail: String::new(),
    };
    assert!(
        Receipt::new(
            &c,
            vec![run("original", Verdict::Reproduced), run("candidate", Verdict::Passed)]
        )
        .repair_verified
    );
    assert!(
        !Receipt::new(
            &c,
            vec![run("original", Verdict::Passed), run("candidate", Verdict::Passed)]
        )
        .repair_verified
    );
    assert!(!Receipt::new(&c, vec![run("original", Verdict::Reproduced)]).repair_verified);
}

#[test]
fn scrub_removes_the_canary_everywhere_and_leaks_finds_what_is_left() {
    let canary = "cmux-canary-7f3a9c2e51".to_owned();
    let mut c = capsule_with(vec![format!("token {canary} rejected")], None);
    c.title = format!("fails with {canary}");
    c.diff = format!("+KEY={canary}\n");
    c.command.shell = format!("curl -H 'auth: {canary}' x");
    c.command.env.insert("X".into(), canary.clone());
    c.observed.output_tail = format!("{canary}\n");
    c.repo.url = format!("https://bot:{canary}@github.com/o/r.git");
    assert_eq!(c.leaks(std::slice::from_ref(&canary)), vec![0]);
    c.scrub(std::slice::from_ref(&canary), &|t| t.to_owned());
    assert!(c.leaks(std::slice::from_ref(&canary)).is_empty(), "{}", c.to_json());
    assert_eq!(c.repo.url, "https://github.com/o/r.git");
    // The masker runs too.
    c.title = "ghp_abcdefghijklmnopqrstuvwxyz0123456789".into();
    c.scrub(&[], &|t| t.replace("ghp_abcdefghijklmnopqrstuvwxyz0123456789", REDACTED));
    assert_eq!(c.title, REDACTED);
}

#[test]
fn leaks_sees_json_escaped_secrets() {
    let secret = "pa\"ss\\word99".to_owned();
    let mut c = capsule_with(vec![], None);
    c.title = secret.clone();
    assert_eq!(c.leaks(std::slice::from_ref(&secret)), vec![0]);
}

#[test]
fn secret_values_take_secret_shaped_names_and_denied_ones() {
    let env = vec![
        ("GITHUB_TOKEN".to_owned(), "ghs_longvalue1".to_owned()),
        ("HOME".to_owned(), "/home/me".to_owned()),
        ("MY_THING".to_owned(), "plainvalue".to_owned()),
        ("SHORT_SECRET".to_owned(), "abc".to_owned()),
    ];
    assert_eq!(
        secret_values(env, &["MY_THING".to_owned()]),
        vec!["ghs_longvalue1".to_owned(), "plainvalue".to_owned()]
    );
}

#[test]
fn drop_entry_takes_out_one_file_and_reseals() {
    let mut c = capsule_with(vec![], None);
    c.diff = "diff --git a/a.txt b/a.txt\n+a\ndiff --git a/b.txt b/b.txt\n+b\n".into();
    c.diff_files = patch_files(&c.diff);
    c.seal();
    let before = c.id.clone();
    assert!(c.drop_entry("diff:a.txt"));
    assert_eq!(c.diff, "diff --git a/b.txt b/b.txt\n+b\n");
    assert_eq!(c.diff_files, vec!["b.txt".to_owned()]);
    assert_eq!(c.removed, vec!["diff:a.txt".to_owned()]);
    assert_ne!(c.id, before);
    assert!(!c.drop_entry("diff:nope.txt"));
    assert!(!c.drop_entry("bogus"));
}

#[test]
fn urls_lose_credentials() {
    assert_eq!(strip_url_credentials("git@github.com:o/r.git"), "https://github.com/o/r.git");
    assert_eq!(
        strip_url_credentials("https://x-access-token:abc@github.com/o/r"),
        "https://github.com/o/r"
    );
}

#[test]
fn quote_survives_single_quotes() {
    let out = Proc::new("bash")
        .arg("-c")
        .arg(format!("printf %s {}", script::quote("it's $HOME `x`")))
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&out.stdout), "it's $HOME `x`");
}

#[test]
fn schema_from_the_future_is_refused() {
    let mut c = capsule_with(vec![], None);
    c.schema = SCHEMA + 1;
    assert!(Capsule::from_json(&c.to_json()).unwrap_err().contains("newer"));
}

fn sh(dir: &Path, cmd: &str) {
    let ok = Proc::new("bash").arg("-c").arg(cmd).current_dir(dir).status().unwrap().success();
    assert!(ok, "{cmd}");
}

/// End to end on a local "remote": capture a failure that lives in an uncommitted edit, replay it
/// red in a fresh checkout, replay it green with the fix, and keep a planted canary out of all of it.
#[test]
fn create_then_replay_red_then_green() {
    let top = std::env::temp_dir().join(format!("cmux-repro-test-{}", std::process::id()));
    let origin = top.join("origin");
    let work = top.join("work");
    std::fs::create_dir_all(&origin).unwrap();
    sh(
        &origin,
        "git init -q -b main && git config user.email t@t && git config user.name t \
        && printf 'def add(a, b):\\n    return a + b\\n' > calc.py \
        && printf 'import calc\\nassert calc.add(2, 2) == 4, \"add is broken\"\\nprint(\"ok\")\\n' > check.py \
        && git add . && git commit -qm base && git config uploadpack.allowAnySHA1InWant true",
    );
    sh(&top, &format!("git clone -q {} work", origin.display()));
    // The bug: an uncommitted edit.
    sh(
        &work,
        "printf 'def add(a, b):\\n    return a - b\\n' > calc.py && echo note > untracked.txt",
    );
    let canary = "cmux-canary-91b2c3d4e5".to_owned();
    let mut env = BTreeMap::new();
    env.insert("REPRO_SECRET".to_owned(), canary.clone());
    let created = create(&Options {
        dir: work,
        shell: "echo \"secret is $REPRO_SECRET\"; python3 check.py".into(),
        title: "add is broken".into(),
        base: None,
        expect: vec![],
        expect_exit: None,
        setup: String::new(),
        prerequisites: vec![Prerequisite {
            name: "python3".into(),
            check: "command -v python3".into(),
        }],
        env,
        timeout_s: 60,
        created_at: "2026-11-25T00:00:00Z".into(),
        made_by: "test".into(),
    })
    .unwrap();
    let mut capsule = created.capsule;
    assert!(capsule.observed.output_tail.contains(&canary), "the raw run saw the canary");
    capsule.scrub(std::slice::from_ref(&canary), &|t| t.to_owned());
    capsule.seal();
    assert!(capsule.leaks(std::slice::from_ref(&canary)).is_empty());
    assert!(capsule.diff_files.contains(&"calc.py".to_owned()));
    assert!(capsule.diff_files.contains(&"untracked.txt".to_owned()));
    assert!(
        capsule.expected.signature.iter().any(|l| l.contains("add is broken")),
        "{:?}",
        capsule.expected.signature
    );

    let red = replay_local(&capsule, None, "test").unwrap();
    assert_eq!(red.verdict, Verdict::Reproduced, "{}", red.output_tail);
    let fix = "diff --git a/calc.py b/calc.py\n--- a/calc.py\n+++ b/calc.py\n@@ -1,2 +1,2 @@\n def add(a, b):\n-    return a - b\n+    return a + b\n";
    let green = replay_local(&capsule, Some(fix), "test").unwrap();
    assert_eq!(green.verdict, Verdict::Passed, "{}", green.output_tail);
    let receipt = Receipt::new(&capsule, vec![red, green]);
    assert!(receipt.repair_verified);
    let receipt_json = serde_json::to_string(&receipt).unwrap();
    assert!(!receipt_json.contains(&canary), "the replay never had the secret");

    // A prerequisite the machine lacks is named, not a red.
    capsule.prerequisites.push(Prerequisite {
        name: "no-such-tool".into(),
        check: "command -v no-such-tool-xyz".into(),
    });
    let absent = replay_local(&capsule, None, "test").unwrap();
    assert_eq!(
        absent.verdict,
        Verdict::MissingPrerequisite { missing: vec!["no-such-tool".into()] }
    );
    let _ = std::fs::remove_dir_all(&top);
}

#[test]
fn rfc3339_formats_utc() {
    assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
    assert_eq!(rfc3339(1_795_581_000), "2026-11-25T04:30:00Z");
}
