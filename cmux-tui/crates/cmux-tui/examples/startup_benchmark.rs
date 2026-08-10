mod startup_benchmark_support;

use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use startup_benchmark_support::{
    Args, ComparisonReport, Evidence, Fixture, HostMetadata, Pair, ProfileReport, SampleSet,
    Scenario, ScenarioReport, SignedSummary, Target, TargetKind, TargetMetadata, now_unix_ms,
    run_sample,
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
        return run_profile(&args.output_dir, &args.platform_label, target, scenario);
    }
    run_comparison(args, baseline, candidate)
}

fn run_profile(
    output_dir: &Path,
    platform_label: &str,
    target: Target,
    scenario: Scenario,
) -> Result<()> {
    let metadata = TargetMetadata::collect(&target)?;
    let mut fixture = Fixture::new(target.clone(), scenario, true)
        .with_context(|| format!("prepare {} {scenario:?} profile", target.kind.as_str()))?;
    let mut evidence = fixture.setup_evidence();
    let result = run_sample(&mut fixture)
        .with_context(|| format!("run {} {scenario:?} profile", target.kind.as_str()))?;
    evidence.add(&result.evidence);
    evidence.samples_completed += 1;
    evidence.add(&fixture.cleanup()?);
    let report = ProfileReport {
        schema_version: 1,
        generated_at_unix_ms: now_unix_ms(),
        platform_label: platform_label.to_string(),
        target: target.kind,
        scenario,
        duration_ns: result.duration_ns,
        evidence,
        host: HostMetadata::collect(),
        binary: metadata,
    };
    let name = format!("startup-profile-{}-{}.json", target.kind.as_str(), scenario.as_str());
    write_json(&output_dir.join(name), &report)
}

fn run_comparison(args: Args, baseline: Target, candidate: Target) -> Result<()> {
    let baseline_metadata = TargetMetadata::collect(&baseline)?;
    let candidate_metadata = TargetMetadata::collect(&candidate)?;
    let mut scenarios = Vec::new();
    for scenario in Scenario::ALL {
        scenarios.push(
            compare_scenario(&args, baseline.clone(), candidate.clone(), scenario)
                .with_context(|| format!("compare {} startup", scenario.as_str()))?,
        );
    }
    let report = ComparisonReport {
        schema_version: 1,
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
    write_json(&args.output_dir.join("startup-benchmark.json"), &report)?;
    fs::write(args.output_dir.join("startup-benchmark.md"), render_markdown(&report))?;
    Ok(())
}

fn compare_scenario(
    args: &Args,
    baseline: Target,
    candidate: Target,
    scenario: Scenario,
) -> Result<ScenarioReport> {
    let mut baseline = ScenarioTarget::new(baseline, scenario)?;
    let mut candidate = ScenarioTarget::new(candidate, scenario)?;

    for index in 0..args.warmups {
        let first = if index % 2 == 0 { TargetKind::Baseline } else { TargetKind::Candidate };
        run_pair(first, &mut baseline, &mut candidate)
            .with_context(|| format!("warmup pair {index}"))?;
        baseline.evidence.warmups_completed += 1;
        candidate.evidence.warmups_completed += 1;
    }

    let mut baseline_values = Vec::with_capacity(args.samples);
    let mut candidate_values = Vec::with_capacity(args.samples);
    let mut pairs = Vec::with_capacity(args.samples);
    for index in 0..args.samples {
        let first = if index % 2 == 0 { TargetKind::Baseline } else { TargetKind::Candidate };
        let (baseline_result, candidate_result) = run_pair(first, &mut baseline, &mut candidate)
            .with_context(|| format!("measured pair {index}"))?;
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
    baseline.finish()?;
    candidate.finish()?;
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

struct ScenarioTarget {
    target: Target,
    scenario: Scenario,
    fixture: Option<Fixture>,
    evidence: Evidence,
}

impl ScenarioTarget {
    fn new(target: Target, scenario: Scenario) -> Result<Self> {
        let fixture =
            matches!(scenario, Scenario::Warm | Scenario::Restored | Scenario::Incompatible)
                .then(|| Fixture::new(target.clone(), scenario, false))
                .transpose()?;
        let evidence = fixture.as_ref().map(Fixture::setup_evidence).unwrap_or_default();
        Ok(Self { target, scenario, fixture, evidence })
    }

    fn run(&mut self) -> Result<startup_benchmark_support::RunResult> {
        if let Some(fixture) = self.fixture.as_mut() {
            let result = run_sample(fixture)?;
            self.evidence.add(&result.evidence);
            return Ok(result);
        }

        let mut fixture = Fixture::new(self.target.clone(), self.scenario, false)?;
        self.evidence.add(&fixture.setup_evidence());
        let result = run_sample(&mut fixture);
        let cleanup = fixture.cleanup();
        let result = match (result, cleanup) {
            (Ok(result), Ok(cleanup)) => {
                self.evidence.add(&cleanup);
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

    fn finish(&mut self) -> Result<()> {
        if let Some(fixture) = self.fixture.as_mut() {
            self.evidence.add(&fixture.cleanup()?);
        }
        Ok(())
    }
}

fn run_pair(
    first: TargetKind,
    baseline: &mut ScenarioTarget,
    candidate: &mut ScenarioTarget,
) -> Result<(startup_benchmark_support::RunResult, startup_benchmark_support::RunResult)> {
    match first {
        TargetKind::Baseline => {
            let baseline = baseline.run().context("run baseline")?;
            let candidate = candidate.run().context("run candidate")?;
            Ok((baseline, candidate))
        }
        TargetKind::Candidate => {
            let candidate = candidate.run().context("run candidate")?;
            let baseline = baseline.run().context("run baseline")?;
            Ok((baseline, candidate))
        }
    }
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
    fs::write(path, json).with_context(|| format!("write {}", path.display()))
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
