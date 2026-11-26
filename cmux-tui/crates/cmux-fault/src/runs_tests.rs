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

    let failed = Runs::new("seed 3 fails", "true")
        .run(|seed, _| {
            if seed == 3 {
                panic!("broke");
            }
            Ok(())
        })
        .unwrap_err()
        .0;
    assert!(failed.contains("(seeds 3)") && failed.contains("CMUX_FAULT_SEED=3"), "{failed}");
    assert!(failed.contains("panicked: broke"), "{failed}");
}
