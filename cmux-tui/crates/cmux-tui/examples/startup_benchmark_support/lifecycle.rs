use std::collections::BTreeSet;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde::Serialize;

use super::{Scenario, TargetKind, duration_ns};

static ROOT_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Default, Serialize)]
pub struct PhaseMetric {
    pub count: usize,
    pub wall_ns: u64,
}

impl PhaseMetric {
    pub fn completed(duration: Duration) -> Result<Self> {
        Ok(Self { count: 1, wall_ns: duration_ns(duration)? })
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct RunPhases {
    pub prepare: PhaseMetric,
    pub measured_event: PhaseMetric,
    pub validation: PhaseMetric,
    pub process_exit: PhaseMetric,
    pub thread_join: PhaseMetric,
    pub fixture_cleanup: PhaseMetric,
    pub root_deferral: PhaseMetric,
    pub final_reclaim: PhaseMetric,
}

impl RunPhases {
    fn validate_sample(&self) -> Result<()> {
        for (name, phase) in
            [("measured-event", &self.measured_event), ("process-exit", &self.process_exit)]
        {
            if phase.count != 1 {
                bail!("sample {name} count is {}, expected 1", phase.count);
            }
        }
        if self.thread_join.count > 1 {
            bail!("sample thread-join count is {}, expected at most 1", self.thread_join.count);
        }
        if self.final_reclaim.count != 0 || self.final_reclaim.wall_ns != 0 {
            bail!("sample performed final reclamation before evidence publication");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum SampleKind {
    Warmup,
    Measured,
    Profile,
}

impl SampleKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Warmup => "warmup",
            Self::Measured => "measured",
            Self::Profile => "profile",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
struct TargetLifecycle {
    target: TargetKind,
    phases: RunPhases,
}

#[derive(Debug, Clone, Serialize)]
struct PairCheckpoint {
    scenario: Scenario,
    kind: SampleKind,
    index: usize,
    first: TargetKind,
    baseline: TargetLifecycle,
    candidate: TargetLifecycle,
}

#[derive(Debug, Clone, Serialize)]
struct ProfileCheckpoint {
    scenario: Scenario,
    kind: SampleKind,
    sample: TargetLifecycle,
}

#[derive(Debug, Clone, Serialize)]
struct FixtureLifecycle {
    target: TargetKind,
    scenario: Scenario,
    activity: String,
    phases: RunPhases,
}

#[derive(Debug, Serialize)]
struct LifecycleDocument<'a> {
    schema_version: u32,
    fixture_parent_name: String,
    report_written_before_reclamation: bool,
    deferred_roots: &'a [String],
    fixtures: &'a [FixtureLifecycle],
    pairs: &'a [PairCheckpoint],
    profiles: &'a [ProfileCheckpoint],
}

pub struct FixtureRoot {
    parent: PathBuf,
    path: Option<PathBuf>,
    next_run_id: u64,
    quiescent: bool,
}

fn fixture_root_name(process: u32, sequence: u64) -> String {
    format!("r-{process:010}-{sequence:020}")
}

fn run_directory_name(id: u64) -> String {
    format!("run-{id:020}")
}

pub fn longest_control_socket_path(parent: &Path) -> PathBuf {
    parent
        .join(fixture_root_name(u32::MAX, u64::MAX))
        .join(run_directory_name(u64::MAX))
        .join("mux.sock")
}

impl FixtureRoot {
    pub fn new(parent: &Path) -> Result<Self> {
        let process = std::process::id();
        loop {
            let sequence = ROOT_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let name = fixture_root_name(process, sequence);
            let path = parent.join(name);
            match fs::create_dir(&path) {
                Ok(()) => {
                    return Ok(Self {
                        parent: parent.to_path_buf(),
                        path: Some(path),
                        next_run_id: 1,
                        quiescent: false,
                    });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error).context("create benchmark fixture root"),
            }
        }
    }

    pub fn path(&self) -> &Path {
        self.path.as_deref().expect("fixture root was already deferred")
    }

    pub fn mark_quiescent(&mut self) {
        self.quiescent = true;
    }

    pub fn next_run_path(&mut self) -> Result<(PathBuf, u64)> {
        let id = self.next_run_id;
        let path = self.path().join(run_directory_name(id));
        fs::create_dir(&path)?;
        self.next_run_id = self.next_run_id.checked_add(1).context("run id overflow")?;
        Ok((path, id))
    }

    pub fn defer(&mut self, recorder: &mut LifecycleRecorder) -> Result<PhaseMetric> {
        if !self.quiescent {
            bail!("cannot defer a fixture root before child and reader cleanup completes");
        }
        let started = Instant::now();
        {
            let path = self.path.as_ref().context("fixture root was already deferred")?;
            if path.parent() != Some(self.parent.as_path())
                || self.parent != recorder.fixture_parent
            {
                bail!("fixture root is outside the configured reclamation parent");
            }
            recorder.accept_root(path)?;
        }
        let _transferred_path = self.path.take().expect("validated fixture root disappeared");
        PhaseMetric::completed(started.elapsed())
    }
}

pub struct LifecycleRecorder {
    fixture_parent: PathBuf,
    output_dir: PathBuf,
    deferred_roots: Vec<String>,
    fixtures: Vec<FixtureLifecycle>,
    pairs: Vec<PairCheckpoint>,
    profiles: Vec<ProfileCheckpoint>,
}

impl LifecycleRecorder {
    pub fn new(fixture_parent: PathBuf, output_dir: PathBuf) -> Result<Self> {
        fs::create_dir_all(output_dir.join("lifecycle-checkpoints"))?;
        Ok(Self {
            fixture_parent,
            output_dir,
            deferred_roots: Vec::new(),
            fixtures: Vec::new(),
            pairs: Vec::new(),
            profiles: Vec::new(),
        })
    }

    pub fn fixture_parent(&self) -> &Path {
        &self.fixture_parent
    }

    pub fn record_fixture(
        &mut self,
        target: TargetKind,
        scenario: Scenario,
        activity: &str,
        phases: RunPhases,
    ) {
        self.fixtures.push(FixtureLifecycle {
            target,
            scenario,
            activity: activity.to_string(),
            phases,
        });
    }

    pub fn record_pair(
        &mut self,
        scenario: Scenario,
        kind: SampleKind,
        index: usize,
        first: TargetKind,
        baseline: &RunPhases,
        candidate: &RunPhases,
    ) -> Result<()> {
        baseline.validate_sample()?;
        candidate.validate_sample()?;
        let expected_first =
            if index.is_multiple_of(2) { TargetKind::Baseline } else { TargetKind::Candidate };
        if first != expected_first {
            bail!("pair {index} starts with {first:?}, expected {expected_first:?}");
        }
        let checkpoint = PairCheckpoint {
            scenario,
            kind,
            index,
            first,
            baseline: TargetLifecycle { target: TargetKind::Baseline, phases: baseline.clone() },
            candidate: TargetLifecycle { target: TargetKind::Candidate, phases: candidate.clone() },
        };
        let name = format!("{}-{}-{index:020}.json", scenario.as_str(), kind.as_str());
        write_new_json(&self.output_dir.join("lifecycle-checkpoints").join(name), &checkpoint)?;
        self.pairs.push(checkpoint);
        Ok(())
    }

    pub fn record_profile(
        &mut self,
        target: TargetKind,
        scenario: Scenario,
        phases: &RunPhases,
    ) -> Result<()> {
        phases.validate_sample()?;
        self.profiles.push(ProfileCheckpoint {
            scenario,
            kind: SampleKind::Profile,
            sample: TargetLifecycle { target, phases: phases.clone() },
        });
        Ok(())
    }

    pub fn persist_final(&self, required_reports: &[PathBuf], file_name: &str) -> Result<()> {
        for report in required_reports {
            if !report.is_file() {
                bail!("required report was not durable before reclamation: {}", report.display());
            }
        }
        let root_names = self.deferred_roots.iter().collect::<BTreeSet<_>>();
        if root_names.len() != self.deferred_roots.len() {
            bail!("deferred fixture roots are not unique");
        }
        let parent_name = self
            .fixture_parent
            .file_name()
            .and_then(|name| name.to_str())
            .context("fixture parent has no portable name")?
            .to_string();
        let document = LifecycleDocument {
            schema_version: 1,
            fixture_parent_name: parent_name,
            report_written_before_reclamation: true,
            deferred_roots: &self.deferred_roots,
            fixtures: &self.fixtures,
            pairs: &self.pairs,
            profiles: &self.profiles,
        };
        write_new_json(&self.output_dir.join(file_name), &document)
    }

    fn accept_root(&mut self, path: &Path) -> Result<()> {
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .context("fixture root has no portable name")?
            .to_string();
        if self.deferred_roots.iter().any(|existing| existing == &name) {
            bail!("fixture root {name} was deferred more than once");
        }
        self.deferred_roots.push(name);
        Ok(())
    }
}

fn write_new_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .with_context(|| format!("create lifecycle evidence {}", path.display()))?;
    serde_json::to_writer_pretty(&mut file, value)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn complete_phases() -> RunPhases {
        RunPhases {
            measured_event: PhaseMetric { count: 1, wall_ns: 10 },
            process_exit: PhaseMetric { count: 1, wall_ns: 20 },
            thread_join: PhaseMetric { count: 1, wall_ns: 30 },
            ..RunPhases::default()
        }
    }

    #[test]
    fn root_transfer_requires_quiescent_ownership_and_preserves_fresh_roots() {
        let parent = tempfile::tempdir().unwrap();
        let output = tempfile::tempdir().unwrap();
        let mut recorder =
            LifecycleRecorder::new(parent.path().to_path_buf(), output.path().to_path_buf())
                .unwrap();
        let mut first = FixtureRoot::new(parent.path()).unwrap();
        let first_path = first.path().to_path_buf();
        let second = FixtureRoot::new(parent.path()).unwrap();
        assert_ne!(first_path, second.path());
        assert!(first.defer(&mut recorder).is_err());
        first.mark_quiescent();
        assert_eq!(first.defer(&mut recorder).unwrap().count, 1);
    }

    #[test]
    fn rejected_root_transfer_preserves_ownership_for_a_valid_recorder() {
        let parent = tempfile::tempdir().unwrap();
        let other_parent = tempfile::tempdir().unwrap();
        let output = tempfile::tempdir().unwrap();
        let mut wrong_recorder =
            LifecycleRecorder::new(other_parent.path().to_path_buf(), output.path().to_path_buf())
                .unwrap();
        let mut recorder =
            LifecycleRecorder::new(parent.path().to_path_buf(), output.path().to_path_buf())
                .unwrap();
        let mut root = FixtureRoot::new(parent.path()).unwrap();
        let root_path = root.path().to_path_buf();
        root.mark_quiescent();

        assert!(root.defer(&mut wrong_recorder).is_err());
        assert_eq!(root.path(), root_path);
        assert_eq!(root.defer(&mut recorder).unwrap().count, 1);
    }

    #[test]
    fn checkpoints_enforce_pair_order_and_persist_complete_diagnostics() {
        let parent = tempfile::tempdir().unwrap();
        let output = tempfile::tempdir().unwrap();
        let mut recorder =
            LifecycleRecorder::new(parent.path().to_path_buf(), output.path().to_path_buf())
                .unwrap();
        let phases = complete_phases();
        assert!(
            recorder
                .record_pair(
                    Scenario::Cold,
                    SampleKind::Measured,
                    0,
                    TargetKind::Candidate,
                    &phases,
                    &phases,
                )
                .is_err()
        );
        recorder
            .record_pair(
                Scenario::Cold,
                SampleKind::Measured,
                0,
                TargetKind::Baseline,
                &phases,
                &phases,
            )
            .unwrap();
        assert!(
            output
                .path()
                .join("lifecycle-checkpoints/cold-measured-00000000000000000000.json")
                .is_file()
        );
    }

    #[test]
    fn final_diagnostics_require_report_before_reclamation_authorization() {
        let parent = tempfile::tempdir().unwrap();
        let output = tempfile::tempdir().unwrap();
        let recorder =
            LifecycleRecorder::new(parent.path().to_path_buf(), output.path().to_path_buf())
                .unwrap();
        let report = output.path().join("startup-benchmark.json");
        assert!(
            recorder
                .persist_final(std::slice::from_ref(&report), "startup-lifecycle.json")
                .is_err()
        );
        fs::write(&report, b"{}\n").unwrap();
        recorder.persist_final(&[report], "startup-lifecycle.json").unwrap();
        let diagnostic = fs::read_to_string(output.path().join("startup-lifecycle.json")).unwrap();
        assert!(diagnostic.contains("\"report_written_before_reclamation\": true"));
    }
}
