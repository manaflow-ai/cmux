mod startup_benchmark_support;

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use startup_benchmark_support::{
    Args, ComparisonReport, Evidence, Fixture, HostMetadata, LifecycleRecorder, Pair, PhaseMetric,
    ProfileReport, RunPhases, SampleKind, SampleSet, Scenario, ScenarioReport, SignedSummary,
    Target, TargetKind, TargetMetadata, now_unix_ms, run_sample,
};

fn main() {
    if let Err(error) = run() {
        eprintln!("cmux-tui startup benchmark: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args = Args::parse()?;
    fs::create_dir_all(&args.output_dir)
        .with_context(|| format!("create {}", args.output_dir.display()))?;
    let baseline = Target::new(
        TargetKind::Baseline,
        args.baseline_binary.clone(),
        args.baseline_source.clone(),
        args.baseline_sha.clone(),
        args.baseline_launcher.clone(),
    )?;
    let candidate = Target::new(
        TargetKind::Candidate,
        args.candidate_binary.clone(),
        args.candidate_source.clone(),
        args.candidate_sha.clone(),
        args.candidate_launcher.clone(),
    )?;

    if let Some(scenario) = args.profile_only {
        let target = match args.profile_target.context("profile target missing")? {
            TargetKind::Baseline => baseline,
            TargetKind::Candidate => candidate,
        };
        return run_profile(&args, target, scenario);
    }
    run_comparison(args, baseline, candidate)
}

fn run_profile(args: &Args, target: Target, scenario: Scenario) -> Result<()> {
    let metadata = TargetMetadata::collect(&target)?;
    let mut lifecycle =
        LifecycleRecorder::new(args.fixture_parent.clone(), args.output_dir.clone())?;
    let prepare_started = std::time::Instant::now();
    let mut fixture = Fixture::new(target.clone(), scenario, true, lifecycle.fixture_parent())
        .with_context(|| format!("prepare {} {scenario:?} profile", target.kind.as_str()))?;
    let prepare = PhaseMetric::completed(prepare_started.elapsed())?;
    let mut evidence = fixture.setup_evidence();
    let mut result = run_sample(&mut fixture)
        .with_context(|| format!("run {} {scenario:?} profile", target.kind.as_str()))?;
    evidence.add(&result.evidence);
    evidence.samples_completed += 1;
    let cleanup_started = std::time::Instant::now();
    evidence.add(&fixture.cleanup()?);
    let fixture_cleanup = PhaseMetric::completed(cleanup_started.elapsed())?;
    let root_deferral = fixture.defer_root(&mut lifecycle)?;
    result.phases.prepare = prepare;
    result.phases.fixture_cleanup = fixture_cleanup;
    result.phases.root_deferral = root_deferral;
    let report = ProfileReport {
        schema_version: 2,
        generated_at_unix_ms: now_unix_ms(),
        platform_label: args.platform_label.clone(),
        target: target.kind,
        scenario,
        duration_ns: result.duration_ns,
        evidence,
        host: HostMetadata::collect(),
        binary: metadata,
    };
    let name = format!("startup-profile-{}-{}.json", target.kind.as_str(), scenario.as_str());
    let report_path = args.output_dir.join(name);
    write_json(&report_path, &report)?;
    lifecycle.record_profile(target.kind, scenario, &result.phases)?;
    lifecycle.persist_final(
        &[report_path],
        &format!("startup-lifecycle-{}-{}.json", target.kind.as_str(), scenario.as_str()),
    )
}

fn run_comparison(args: Args, baseline: Target, candidate: Target) -> Result<()> {
    let baseline_metadata = TargetMetadata::collect(&baseline)?;
    let candidate_metadata = TargetMetadata::collect(&candidate)?;
    let mut lifecycle =
        LifecycleRecorder::new(args.fixture_parent.clone(), args.output_dir.clone())?;
    let suite_deadline = Instant::now()
        .checked_add(Duration::from_secs(u64::try_from(args.suite_deadline_seconds)?))
        .context("benchmark suite deadline overflow")?;
    let mut scenarios = Vec::new();
    for scenario in Scenario::ALL {
        scenarios.push(
            compare_scenario(
                &args,
                baseline.clone(),
                candidate.clone(),
                scenario,
                suite_deadline,
                &mut lifecycle,
            )
            .with_context(|| format!("compare {} startup", scenario.as_str()))?,
        );
    }
    let report = ComparisonReport {
        schema_version: 2,
        generated_at_unix_ms: now_unix_ms(),
        platform_label: args.platform_label,
        warmups: args.warmups,
        paired_samples: args.samples,
        order: "alternating baseline-first and candidate-first pairs",
        host: HostMetadata::collect(),
        baseline: baseline_metadata,
        candidate: candidate_metadata,
        scenarios,
    };
    let json_path = args.output_dir.join("startup-benchmark.json");
    let markdown_path = args.output_dir.join("startup-benchmark.md");
    write_json(&json_path, &report)?;
    write_bytes(&markdown_path, render_markdown(&report).as_bytes())?;
    lifecycle.persist_final(&[json_path, markdown_path], "startup-lifecycle.json")
}

fn compare_scenario(
    args: &Args,
    baseline: Target,
    candidate: Target,
    scenario: Scenario,
    suite_deadline: Instant,
    lifecycle: &mut LifecycleRecorder,
) -> Result<ScenarioReport> {
    let mut baseline = ScenarioTarget::new(baseline, scenario, lifecycle)?;
    let mut candidate = ScenarioTarget::new(candidate, scenario, lifecycle)?;

    for index in 0..args.warmups {
        ensure_suite_deadline(suite_deadline, scenario, SampleKind::Warmup, index)?;
        let first = if index % 2 == 0 { TargetKind::Baseline } else { TargetKind::Candidate };
        run_pair(first, SampleKind::Warmup, index, &mut baseline, &mut candidate, lifecycle)
            .with_context(|| format!("warmup pair {index}"))?;
        ensure_suite_deadline(suite_deadline, scenario, SampleKind::Warmup, index)?;
        baseline.evidence.warmups_completed += 1;
        candidate.evidence.warmups_completed += 1;
    }

    let mut baseline_values = Vec::with_capacity(args.samples);
    let mut candidate_values = Vec::with_capacity(args.samples);
    let mut pairs = Vec::with_capacity(args.samples);
    for index in 0..args.samples {
        ensure_suite_deadline(suite_deadline, scenario, SampleKind::Measured, index)?;
        let first = if index % 2 == 0 { TargetKind::Baseline } else { TargetKind::Candidate };
        let (baseline_result, candidate_result) =
            run_pair(first, SampleKind::Measured, index, &mut baseline, &mut candidate, lifecycle)
                .with_context(|| format!("measured pair {index}"))?;
        ensure_suite_deadline(suite_deadline, scenario, SampleKind::Measured, index)?;
        baseline.evidence.samples_completed += 1;
        candidate.evidence.samples_completed += 1;
        let baseline_ns = baseline_result.duration_ns;
        let candidate_ns = candidate_result.duration_ns;
        let delta = i64::try_from(i128::from(candidate_ns) - i128::from(baseline_ns))
            .context("paired delta does not fit i64")?;
        baseline_values.push(baseline_ns);
        candidate_values.push(candidate_ns);
        pairs.push(Pair {
            index,
            first,
            baseline_ns,
            candidate_ns,
            candidate_minus_baseline_ns: delta,
        });
    }
    baseline.finish(lifecycle)?;
    candidate.finish(lifecycle)?;
    let baseline_evidence = baseline.evidence;
    let candidate_evidence = candidate.evidence;
    validate_evidence(scenario, args, &baseline_evidence)?;
    validate_evidence(scenario, args, &candidate_evidence)?;
    let deltas = pairs.iter().map(|pair| pair.candidate_minus_baseline_ns).collect::<Vec<_>>();
    Ok(ScenarioReport {
        scenario,
        event: scenario.event(),
        baseline: SampleSet::new(baseline_values, baseline_evidence)?,
        candidate: SampleSet::new(candidate_values, candidate_evidence)?,
        pairs,
        paired_delta_summary_ns: SignedSummary::new(&deltas)?,
    })
}

fn ensure_suite_deadline(
    deadline: Instant,
    scenario: Scenario,
    kind: SampleKind,
    index: usize,
) -> Result<()> {
    if Instant::now() >= deadline {
        bail!(
            "benchmark suite deadline expired at the boundary of {} {} pair {index}",
            scenario.as_str(),
            kind.as_str(),
        );
    }
    Ok(())
}

struct ScenarioTarget {
    target: Target,
    scenario: Scenario,
    fixture: Option<Fixture>,
    evidence: Evidence,
}

impl ScenarioTarget {
    fn new(target: Target, scenario: Scenario, lifecycle: &mut LifecycleRecorder) -> Result<Self> {
        let prepare_started = std::time::Instant::now();
        let fixture =
            matches!(scenario, Scenario::Warm | Scenario::Restored | Scenario::Incompatible)
                .then(|| Fixture::new(target.clone(), scenario, false, lifecycle.fixture_parent()))
                .transpose()?;
        if fixture.is_some() {
            lifecycle.record_fixture(
                target.kind,
                scenario,
                "prepare",
                RunPhases {
                    prepare: PhaseMetric::completed(prepare_started.elapsed())?,
                    ..RunPhases::default()
                },
            );
        }
        let evidence = fixture.as_ref().map(Fixture::setup_evidence).unwrap_or_default();
        Ok(Self { target, scenario, fixture, evidence })
    }

    fn run(
        &mut self,
        recorder: &mut LifecycleRecorder,
    ) -> Result<startup_benchmark_support::RunResult> {
        if let Some(fixture) = self.fixture.as_mut() {
            let result = run_sample(fixture)?;
            self.evidence.add(&result.evidence);
            return Ok(result);
        }

        let prepare_started = std::time::Instant::now();
        let mut fixture =
            Fixture::new(self.target.clone(), self.scenario, false, recorder.fixture_parent())?;
        let prepare = PhaseMetric::completed(prepare_started.elapsed())?;
        self.evidence.add(&fixture.setup_evidence());
        let result = run_sample(&mut fixture);
        let cleanup_started = std::time::Instant::now();
        let cleanup = fixture.cleanup();
        let cleanup_duration = cleanup_started.elapsed();
        let root_deferral = if cleanup.is_ok() { Some(fixture.defer_root(recorder)) } else { None };
        let root_deferral = root_deferral.transpose()?;
        let result = match (result, cleanup) {
            (Ok(mut result), Ok(cleanup)) => {
                self.evidence.add(&cleanup);
                result.phases.prepare = prepare;
                result.phases.fixture_cleanup = PhaseMetric::completed(cleanup_duration)?;
                result.phases.root_deferral = root_deferral
                    .context("root deferral was not attempted after successful cleanup")?;
                result
            }
            (Err(error), Ok(_)) => return Err(error),
            (Ok(_), Err(error)) => return Err(error),
            (Err(error), Err(cleanup)) => {
                return Err(error.context(format!("fixture cleanup also failed: {cleanup:#}")));
            }
        };
        self.evidence.add(&result.evidence);
        Ok(result)
    }

    fn finish(&mut self, recorder: &mut LifecycleRecorder) -> Result<()> {
        if let Some(fixture) = self.fixture.as_mut() {
            let cleanup_started = std::time::Instant::now();
            self.evidence.add(&fixture.cleanup()?);
            let fixture_cleanup = PhaseMetric::completed(cleanup_started.elapsed())?;
            let root_deferral = fixture.defer_root(recorder)?;
            recorder.record_fixture(
                self.target.kind,
                self.scenario,
                "cleanup-and-defer",
                RunPhases { fixture_cleanup, root_deferral, ..RunPhases::default() },
            );
        }
        Ok(())
    }
}

fn run_pair(
    first: TargetKind,
    kind: SampleKind,
    index: usize,
    baseline: &mut ScenarioTarget,
    candidate: &mut ScenarioTarget,
    recorder: &mut LifecycleRecorder,
) -> Result<(startup_benchmark_support::RunResult, startup_benchmark_support::RunResult)> {
    let (baseline_result, candidate_result) = match first {
        TargetKind::Baseline => {
            let baseline = baseline.run(recorder).context("run baseline")?;
            let candidate = candidate.run(recorder).context("run candidate")?;
            (baseline, candidate)
        }
        TargetKind::Candidate => {
            let candidate = candidate.run(recorder).context("run candidate")?;
            let baseline = baseline.run(recorder).context("run baseline")?;
            (baseline, candidate)
        }
    };
    recorder.record_pair(
        baseline.scenario,
        kind,
        index,
        first,
        &baseline_result.phases,
        &candidate_result.phases,
    )?;
    Ok((baseline_result, candidate_result))
}

fn validate_evidence(scenario: Scenario, args: &Args, evidence: &Evidence) -> Result<()> {
    if evidence.warmups_completed != args.warmups {
        bail!(
            "{} completed {} warmups, expected {}",
            scenario.as_str(),
            evidence.warmups_completed,
            args.warmups
        );
    }
    if evidence.samples_completed != args.samples {
        bail!(
            "{} completed {} samples, expected {}",
            scenario.as_str(),
            evidence.samples_completed,
            args.samples
        );
    }
    let total = args.warmups + args.samples;
    match scenario {
        Scenario::Cold | Scenario::Warm if evidence.frame_completions < total => {
            bail!("{} observed too few complete frames", scenario.as_str())
        }
        Scenario::Cold | Scenario::Warm if evidence.terminal_probe_responses < total * 4 => {
            bail!("{} answered too few terminal probes", scenario.as_str())
        }
        Scenario::Cold | Scenario::Warm
            if evidence.frame_cursor_shows + evidence.frame_cursor_hides != total =>
        {
            bail!("{} observed an invalid frame-end cursor count", scenario.as_str())
        }
        Scenario::Headless if evidence.readiness_lines < total => {
            bail!("headless observed too few readiness lines")
        }
        Scenario::Restored if evidence.restored_topologies < total => {
            bail!("restored observed too few topology responses")
        }
        Scenario::Incompatible if evidence.schema_rejections < total => {
            bail!("incompatible observed too few schema rejections")
        }
        _ => {}
    }
    Ok(())
}

fn write_json(path: &Path, value: &impl serde::Serialize) -> Result<()> {
    let mut json = serde_json::to_vec_pretty(value)?;
    json.push(b'\n');
    write_bytes(path, &json)
}

fn write_bytes(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .with_context(|| format!("create {}", path.display()))?;
    file.write_all(bytes).with_context(|| format!("write {}", path.display()))?;
    file.sync_all().with_context(|| format!("flush {}", path.display()))
}

fn render_markdown(report: &ComparisonReport) -> String {
    let mut output = format!(
        "# cmux-tui startup benchmark\n\nPlatform: {}  \nBaseline: {}  \nCandidate: {}  \nWarmups: {}  \nPaired samples: {}\n\n| Scenario | Baseline p50 | Candidate p50 | Paired mean delta | Baseline p95 | Candidate p95 |\n| --- | ---: | ---: | ---: | ---: | ---: |\n",
        report.platform_label,
        report.baseline.observed_sha,
        report.candidate.observed_sha,
        report.warmups,
        report.paired_samples,
    );
    for scenario in &report.scenarios {
        output.push_str(&format!(
            "| {} | {:.3} ms | {:.3} ms | {:+.3} ms | {:.3} ms | {:.3} ms |\n",
            scenario.scenario.as_str(),
            ns_ms(scenario.baseline.summary_ns.p50),
            ns_ms(scenario.candidate.summary_ns.p50),
            scenario.paired_delta_summary_ns.mean / 1_000_000.0,
            ns_ms(scenario.baseline.summary_ns.p95),
            ns_ms(scenario.candidate.summary_ns.p95),
        ));
    }
    output.push_str(
        "\nThe paired delta is candidate minus baseline. Negative values are faster. Hosted timing is evidence, not a gating threshold.\n",
    );
    output
}

fn ns_ms(value: u64) -> f64 {
    value as f64 / 1_000_000.0
}
