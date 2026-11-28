use super::Runs;

#[test]
fn every_seed_runs_and_a_failure_names_its_seed() {
    let ran = std::sync::Mutex::new(Vec::new());
    let passed = Runs::new("all pass", "true").run(|seed, trace| {
        trace.note(format!("seed {seed}"));
        ran.lock().unwrap().push(seed);
        Ok(())
    });
    assert!(passed.is_ok());
    let mut ran = ran.into_inner().unwrap();
    ran.sort_unstable();
    assert_eq!(ran, Runs::new("all pass", "true").seeds());

    // The failing seed comes from the seeds this invocation runs: the daily probe sets
    // CMUX_FAULT_SEED_BASE (day of year x 1000), and a replay sets CMUX_FAULT_SEED.
    let seeds = Runs::new("one seed fails", "true").seeds();
    let bad = seeds[3.min(seeds.len() - 1)];
    let failed = Runs::new("one seed fails", "true")
        .run(|seed, _| {
            if seed == bad {
                panic!("broke");
            }
            Ok(())
        })
        .unwrap_err()
        .0;
    assert!(
        failed.contains(&format!("(seeds {bad})"))
            && failed.contains(&format!("CMUX_FAULT_SEED={bad}")),
        "{failed}"
    );
    assert!(failed.contains("panicked: broke"), "{failed}");
}
