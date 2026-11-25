//! `cmux repro run CAPSULE --cloud BACKEND`: a repro capsule (cmuxterm-hq#23808, crate
//! `cmux-repro`) replayed on a fresh Cloud machine. The journey creates the machine and runs its
//! first exec as always; then, instead of a chat, it writes the capsule's runner script and patches
//! over the Cloud file API, runs the original (red) and, with `--candidate`, the candidate fix
//! (green), each in its own fresh checkout, and records one step per replay. The machine is deleted
//! after, so the replay never shares a machine with anything else.
//!
//! Each replay runs in the background on the machine (`nohup`), polled by short execs, so a replay
//! longer than the provider's five-minute inline exec limit still finishes.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_repro::{Capsule, Receipt, Run, Verdict, script};

use super::{Exec, Journey, tail};

/// Room past the command's own timeout for the fetch, the patches and the setup.
const FETCH_AND_SETUP: Duration = Duration::from_secs(900);
const POLL: Duration = Duration::from_secs(3);
/// The output read back from the machine: its last 64 KiB.
const READ_BACK_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct CapsuleJob {
    pub capsule: Capsule,
    /// The candidate fix's patch: when given, the green replay runs after the red one.
    pub candidate: Option<String>,
    /// Where the receipt (both runs and the verdict) is written.
    pub receipt: Option<PathBuf>,
}

/// The replays, each a journey step: `capsule red (original)` passes when it reproduced, `capsule
/// green (candidate)` when it passed.
pub(super) async fn capsule_steps(
    j: &mut Journey,
    exec: &mut Exec<'_>,
    job: &CapsuleJob,
    machine_id: &str,
) -> Result<(), ()> {
    let capsule = &job.capsule;
    let dir = format!("/home/cmux/.cmux/capsule-{}", capsule.id);

    // upload capsule
    let t0 = Instant::now();
    // 0644: `/fs/write` writes as the file service's user, not the exec user, so a 0600 or 0700 file is
    // unreadable to the replay ("bash: red.sh: Permission denied" on staging). The scripts run as
    // `bash FILE`, so read is enough, and a capsule holds nothing secret (`create` scrubs it).
    const MODE: u32 = 0o644;
    let mut files: Vec<(String, Vec<u8>)> = vec![
        (script::DIFF_FILE.to_owned(), capsule.diff.clone().into_bytes()),
        ("red.sh".to_owned(), script::runner(capsule, false).into_bytes()),
    ];
    if let Some(candidate) = &job.candidate {
        files.push((script::CANDIDATE_FILE.to_owned(), candidate.clone().into_bytes()));
        files.push(("green.sh".to_owned(), script::runner(capsule, true).into_bytes()));
    }
    if let Err(error) = exec.run(&format!("mkdir -p {}", script::quote(&dir)), 30_000).await {
        j.fail("upload capsule", t0, &error);
        return Err(());
    }
    let mut bytes = 0;
    for (name, data) in &files {
        bytes += data.len();
        if let Err(error) = exec.write(&format!("{dir}/{name}"), data, MODE).await {
            j.fail("upload capsule", t0, &error);
            return Err(());
        }
    }
    j.pass(
        "upload capsule",
        t0,
        &format!(
            "capsule {} ({} files, {bytes} bytes; base {} of {})",
            capsule.id,
            files.len(),
            &capsule.repo.base_sha[..12.min(capsule.repo.base_sha.len())],
            capsule.repo.url
        ),
    );

    let place = format!("cmux Cloud machine {machine_id}");
    let mut runs = Vec::new();
    let red = replay(j, exec, capsule, &dir, "red", &place, None).await;
    let red_ok = red.as_ref().is_some_and(|r| r.verdict == Verdict::Reproduced);
    runs.extend(red);
    if let Some(candidate) = &job.candidate {
        // The green run proves the fix only against a reproduced red.
        if red_ok {
            runs.extend(replay(j, exec, capsule, &dir, "green", &place, Some(candidate)).await);
        } else {
            j.record(
                "capsule green (candidate)",
                super::Status::Skip,
                Instant::now(),
                "the original did not reproduce, so a pass would prove nothing",
            );
        }
    }
    let receipt = Receipt::new(capsule, runs);
    let text = serde_json::to_string_pretty(&receipt).unwrap_or_default() + "\n";
    for path in job.receipt.iter().chain(j.out.as_ref().map(|d| d.join("receipt.json")).as_ref()) {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(path, &text);
    }
    if receipt.repair_verified || (job.candidate.is_none() && red_ok) { Ok(()) } else { Err(()) }
}

async fn replay(
    j: &mut Journey,
    exec: &mut Exec<'_>,
    capsule: &Capsule,
    dir: &str,
    phase: &str,
    place: &str,
    candidate: Option<&String>,
) -> Option<Run> {
    let step = if phase == "red" { "capsule red (original)" } else { "capsule green (candidate)" };
    let t0 = Instant::now();
    let q = |name: &str| script::quote(&format!("{dir}/{name}"));
    let start = format!(
        "rm -f {done} {out}; nohup bash -c {inner} </dev/null >/dev/null 2>&1 & echo started",
        done = q(&format!("{phase}.done")),
        out = q(&format!("{phase}.out")),
        inner = script::quote(&format!(
            "bash {} > {} 2>&1; echo $? > {}",
            q(&format!("{phase}.sh")),
            q(&format!("{phase}.out")),
            q(&format!("{phase}.done"))
        )),
    );
    match exec.run(&start, 30_000).await {
        Ok(answer) if answer.exit_code == 0 => {}
        Ok(answer) => {
            j.fail(
                step,
                t0,
                &format!("start: exit {} {}", answer.exit_code, tail(&answer.stderr, 300)),
            );
            return None;
        }
        Err(error) => {
            j.fail(step, t0, &format!("start: {error}"));
            return None;
        }
    }
    let budget = Duration::from_secs(capsule.command.timeout_s) + FETCH_AND_SETUP;
    let check = format!("cat {} 2>/dev/null", q(&format!("{phase}.done")));
    loop {
        tokio::time::sleep(POLL).await;
        // A failed poll (a dropped connection) is retried until the budget ends.
        if let Ok(answer) = exec.run(&check, 30_000).await
            && !answer.stdout.trim().is_empty()
        {
            break;
        }
        if t0.elapsed() > budget {
            j.fail(step, t0, &format!("no exit within {} s", budget.as_secs()));
            return None;
        }
    }
    let read = format!("tail -c {READ_BACK_BYTES} {}", q(&format!("{phase}.out")));
    let output = match exec.run(&read, 60_000).await {
        Ok(answer) => answer.stdout,
        Err(error) => {
            j.fail(step, t0, &format!("read output: {error}"));
            return None;
        }
    };
    let (exit_code, verdict, drift) = cmux_repro::judge(capsule, &output);
    let duration_ms = u64::try_from(t0.elapsed().as_millis()).unwrap_or(u64::MAX);
    let wanted = if phase == "red" { Verdict::Reproduced } else { Verdict::Passed };
    let mut detail =
        format!("{} exit {}", verdict.word(), exit_code.map_or("?".into(), |c| c.to_string()));
    match &verdict {
        Verdict::FailedDifferently { missing, .. } if !missing.is_empty() => {
            detail.push_str(&format!("; signature lines absent: {}", missing.join(" | ")));
        }
        Verdict::MissingPrerequisite { missing } => {
            detail.push_str(&format!("; absent: {}", missing.join(", ")));
        }
        _ => {}
    }
    if !drift.is_empty() {
        detail.push_str(&format!("; fingerprint differs: {}", drift.join(", ")));
    }
    if verdict == wanted {
        j.pass(step, t0, &detail);
    } else {
        j.fail(step, t0, &format!("{detail} :: {}", tail(&output, 400)));
    }
    Some(Run {
        phase: if phase == "red" { "original" } else { "candidate" }.to_owned(),
        place: place.to_owned(),
        candidate_sha256: candidate
            .map(|p| cmux_repro::sha256_hex(p.as_bytes()))
            .unwrap_or_default(),
        exit_code,
        duration_ms,
        verdict,
        drift,
        output_tail: cmux_repro::tail_bytes(&output, cmux_repro::OUTPUT_TAIL_BYTES),
    })
}
