//! `cmux repro`: repro capsules (cmuxterm-hq#23808, crate `cmux-repro`). Off unless `CMUX_REPRO=1`.
//!
//! `create` runs a failing command in the current checkout and writes an inspectable JSON capsule:
//! repository and base commit, the local diff, the command, the failure's signature, the lockfile
//! and tool fingerprint, the output's tail. Every field is masked with acpmux's secret scanner
//! and every secret-shaped environment value (plus `--deny-env NAME`) is replaced; then the
//! written bytes are checked for those values and the capsule is refused if one is still there.
//! Nothing is uploaded. `show` prints it, `drop` takes an entry out before sharing, and `run`
//! replays it in a fresh checkout (`--local`) or on a fresh cmux Cloud machine that is deleted after
//! (`--cloud BACKEND`), red on the original and green with `--candidate PATCH`, and writes the
//! receipt.

use std::collections::BTreeMap;
use std::path::PathBuf;

use cmux_repro::{Capsule, Prerequisite, Receipt, create};

use super::GlobalArgs;

const FLAG: &str = "CMUX_REPRO";

const USAGE: &str = "\
usage: cmux repro create [--title T] [--base REV] [--expect LINE]... [--expect-exit N]
                         [--setup CMD] [--require NAME=CHECK]... [--env NAME]...
                         [--deny-env NAME]... [--timeout S] [--out FILE] -- COMMAND...
       cmux repro show FILE
       cmux repro drop FILE ENTRY...      (diff, diff:PATH, output, env:NAME, fingerprint, setup)
       cmux repro run FILE [--candidate PATCH] [--local | --cloud BACKEND [--team T]]
                         [--receipt FILE] [--out DIR]

A capsule is one failing command written down so a fresh machine can run it again and prove a fix:
`run` replays it red, then green with the candidate patch applied. Off unless CMUX_REPRO=1.
";

/// `Some(exit code)` when `args` is `repro …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let [repro, rest @ ..] = words.as_slice() else { return None };
    if repro != "repro" {
        return None;
    }
    if std::env::var(FLAG).ok().as_deref() != Some("1") {
        eprintln!("cmux repro is off: set {FLAG}=1 to use it (cmuxterm-hq#23808)");
        return Some(2);
    }
    if rest.is_empty() || rest.iter().any(|w| w == "-h" || w == "--help" || w == "help") {
        print!("{USAGE}");
        return Some(if rest.is_empty() { 2 } else { 0 });
    }
    let result = match rest[0].as_str() {
        "create" => create_verb(&rest[1..]),
        "show" => show_verb(&rest[1..]),
        "drop" => drop_verb(&rest[1..]),
        "run" => return Some(run_verb(&global, &rest[1..])),
        other => Err(format!("unknown verb {other}\n{USAGE}")),
    };
    Some(match result {
        Ok(code) => code,
        Err(message) => {
            eprintln!("cmux repro: {message}");
            2
        }
    })
}

fn masker(text: &str) -> String {
    acpmux::secret_scan::mask(text)
}

fn read_capsule(path: &str) -> Result<Capsule, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    Capsule::from_json(&text)
}

/// Writes the capsule after scrubbing it and checking the canary; refuses a leaking capsule.
fn write_capsule(path: &str, capsule: &mut Capsule, secrets: &[String]) -> Result<(), String> {
    capsule.scrub(secrets, &masker);
    capsule.seal();
    let leaks = capsule.leaks(secrets);
    if !leaks.is_empty() {
        return Err(format!(
            "refused: {} secret value(s) would still be in the capsule after redaction; nothing written",
            leaks.len()
        ));
    }
    std::fs::write(path, capsule.to_json()).map_err(|e| format!("{path}: {e}"))
}

fn create_verb(words: &[String]) -> Result<i32, String> {
    let split = words.iter().position(|w| w == "--");
    let (flags, command) = match split {
        Some(at) => (&words[..at], &words[at + 1..]),
        None => return Err(format!("create needs -- COMMAND\n{USAGE}")),
    };
    if command.is_empty() {
        return Err("create needs a command after --".into());
    }
    let shell = if command.len() == 1 { command[0].clone() } else { shell_join(command) };
    let mut title = String::new();
    let mut base = None;
    let mut expect = Vec::new();
    let mut expect_exit = None;
    let mut setup = String::new();
    let mut prerequisites = Vec::new();
    let mut env_names = Vec::new();
    let mut deny = Vec::new();
    let mut timeout_s = 600;
    let mut out = String::from("capsule.json");
    let mut it = flags.iter();
    while let Some(flag) = it.next() {
        let mut value = || it.next().cloned().ok_or_else(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--title" => title = value()?,
            "--base" => base = Some(value()?),
            "--expect" => expect.push(value()?),
            "--expect-exit" => {
                expect_exit = Some(value()?.parse().map_err(|_| "--expect-exit takes a number")?)
            }
            "--setup" => setup = value()?,
            "--require" => {
                let spec = value()?;
                let (name, check) = spec.split_once('=').ok_or(
                    "--require takes NAME=CHECK (a shell check that exits 0 when NAME is there)",
                )?;
                prerequisites.push(Prerequisite { name: name.into(), check: check.into() });
            }
            "--env" => env_names.push(value()?),
            "--deny-env" => deny.push(value()?),
            "--timeout" => timeout_s = value()?.parse().map_err(|_| "--timeout takes seconds")?,
            "--out" => out = value()?,
            other => return Err(format!("unknown flag {other}")),
        }
    }
    let mut env = BTreeMap::new();
    for name in &env_names {
        if let Ok(value) = std::env::var(name) {
            env.insert(name.clone(), value);
        }
    }
    let secrets = cmux_repro::secret_values(std::env::vars(), &deny);
    if title.is_empty() {
        title = shell.chars().take(80).collect();
    }
    let created = create::create(&create::Options {
        dir: std::env::current_dir().map_err(|e| e.to_string())?,
        shell,
        title,
        base,
        expect,
        expect_exit,
        setup,
        prerequisites,
        env,
        timeout_s,
        created_at: cmux_repro::now_rfc3339(),
        made_by: concat!("cmux-tui ", env!("CARGO_PKG_VERSION")).to_owned(),
    })?;
    let mut capsule = created.capsule;
    write_capsule(&out, &mut capsule, &secrets)?;
    println!(
        "wrote {out}: capsule {} — exit {} in {} ms, base {}, {} diff file(s), signature:",
        capsule.id,
        capsule.observed.exit_code,
        capsule.observed.duration_ms,
        &capsule.repo.base_sha[..12.min(capsule.repo.base_sha.len())],
        capsule.diff_files.len()
    );
    for line in &capsule.expected.signature {
        println!("  {line}");
    }
    println!(
        "inspect it with `cmux repro show {out}`; take entries out with `cmux repro drop {out} ENTRY`"
    );
    Ok(0)
}

fn show_verb(words: &[String]) -> Result<i32, String> {
    let [path] = words else { return Err("show takes one FILE".into()) };
    let c = read_capsule(path)?;
    use std::fmt::Write as _;
    let mut o = String::new();
    let _ = writeln!(o, "capsule {} ({}), made {} by {}", c.id, c.title, c.created_at, c.made_by);
    let _ = writeln!(o, "repo      {} @ {}", c.repo.url, c.repo.base_sha);
    let _ = writeln!(
        o,
        "command   {} (in ./{}, timeout {} s)",
        c.command.shell, c.command.cwd, c.command.timeout_s
    );
    if !c.setup.is_empty() {
        let _ = writeln!(o, "setup     {}", c.setup);
    }
    for p in &c.prerequisites {
        let _ = writeln!(o, "requires  {} ({})", p.name, p.check);
    }
    for name in c.command.env.keys() {
        let _ = writeln!(o, "env       {name}");
    }
    let _ = writeln!(
        o,
        "diff      {} file(s), {} bytes: {}",
        c.diff_files.len(),
        c.diff.len(),
        c.diff_files.join(", ")
    );
    let _ = writeln!(
        o,
        "expected  exit {}",
        c.expected.exit_code.map_or("non-zero".into(), |e| e.to_string())
    );
    for line in &c.expected.signature {
        let _ = writeln!(o, "          {line}");
    }
    let _ = writeln!(
        o,
        "observed  exit {} in {} ms on {}/{}",
        c.observed.exit_code, c.observed.duration_ms, c.observed.os, c.observed.arch
    );
    for (f, sha) in &c.fingerprint.files {
        let _ = writeln!(o, "lockfile  {f} {}", &sha[..12.min(sha.len())]);
    }
    for (t, v) in &c.fingerprint.tools {
        let _ = writeln!(o, "tool      {t}: {v}");
    }
    if !c.removed.is_empty() {
        let _ = writeln!(o, "removed   {}", c.removed.join(", "));
    }
    let _ = writeln!(o, "--- output tail ---\n{}", c.observed.output_tail);
    // A reader that stops early (`| head`) is not an error.
    let _ = std::io::Write::write_all(&mut std::io::stdout(), o.as_bytes());
    Ok(0)
}

fn drop_verb(words: &[String]) -> Result<i32, String> {
    let [path, entries @ ..] = words else { return Err("drop takes FILE ENTRY...".into()) };
    if entries.is_empty() {
        return Err(
            "drop takes FILE ENTRY... (diff, diff:PATH, output, env:NAME, fingerprint, setup)"
                .into(),
        );
    }
    let mut capsule = read_capsule(path)?;
    for entry in entries {
        if !capsule.drop_entry(entry) {
            return Err(format!("{path} has no entry {entry}; nothing written"));
        }
    }
    let secrets = cmux_repro::secret_values(std::env::vars(), &[]);
    write_capsule(path, &mut capsule, &secrets)?;
    println!("{path}: removed {}; capsule is now {}", entries.join(", "), capsule.id);
    Ok(0)
}

fn run_verb(global: &GlobalArgs, words: &[String]) -> i32 {
    match run_verb_inner(global, words) {
        Ok(code) => code,
        Err(message) => {
            eprintln!("cmux repro: {message}");
            2
        }
    }
}

fn run_verb_inner(global: &GlobalArgs, words: &[String]) -> Result<i32, String> {
    let Some((path, flags)) = words.split_first() else { return Err("run takes FILE".into()) };
    let capsule = read_capsule(path)?;
    let mut candidate = None;
    let mut cloud = None;
    let mut team = None;
    let mut receipt = None;
    let mut out = None;
    let mut it = flags.iter();
    while let Some(flag) = it.next() {
        let mut value = || it.next().cloned().ok_or_else(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--candidate" => {
                let p = value()?;
                candidate = Some(std::fs::read_to_string(&p).map_err(|e| format!("{p}: {e}"))?);
            }
            "--local" => cloud = None,
            "--cloud" => cloud = Some(value()?),
            "--team" => team = Some(value()?),
            "--receipt" => receipt = Some(PathBuf::from(value()?)),
            "--out" => out = Some(PathBuf::from(value()?)),
            other => return Err(format!("unknown flag {other}")),
        }
    }
    let Some(backend) = cloud else {
        let mut runs = vec![create::replay_local(&capsule, None, "local fresh checkout")?];
        println!("original:  {}", runs[0].verdict.word());
        if let Some(patch) = &candidate {
            let green = create::replay_local(&capsule, Some(patch), "local fresh checkout")?;
            println!("candidate: {}", green.verdict.word());
            runs.push(green);
        }
        let receipt_value = Receipt::new(&capsule, runs);
        let text = serde_json::to_string_pretty(&receipt_value).unwrap_or_default() + "\n";
        if let Some(path) = &receipt {
            std::fs::write(path, &text).map_err(|e| format!("{}: {e}", path.display()))?;
        } else {
            print!("{text}");
        }
        let ok = if candidate.is_some() {
            receipt_value.repair_verified
        } else {
            receipt_value.runs[0].verdict == cmux_repro::Verdict::Reproduced
        };
        return Ok(i32::from(!ok));
    };
    let mut words = vec!["--backend".to_owned(), backend];
    if let Some(team) = team {
        words.extend(["--team".to_owned(), team]);
    }
    if let Some(out) = &out {
        words.extend(["--out".to_owned(), out.display().to_string()]);
    }
    let mut args = super::cloud_journey::parse(&words)?;
    args.capsule = Some(super::cloud_journey::capsule::CapsuleJob { capsule, candidate, receipt });
    Ok(super::cloud_journey::run(global, &args))
}

/// Words as one shell line, each quoted when it needs it.
fn shell_join(words: &[String]) -> String {
    words
        .iter()
        .map(|w| {
            if !w.is_empty()
                && w.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:@%+,".contains(c))
            {
                w.clone()
            } else {
                cmux_repro::script::quote(w)
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}
