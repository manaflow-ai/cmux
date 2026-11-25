use super::*;

fn apps(n: usize) -> Vec<String> {
    (0..n).map(|i| format!("local/app{i:02}")).collect()
}

/// Answers as a person would when `culprit` is the extension that breaks cmux.
fn run_to_the_end(mut bisect: Bisect, culprit: &str) -> Bisect {
    for _ in 0..64 {
        if bisect.found().is_some() {
            return bisect;
        }
        if bisect.runs(culprit) { bisect.bad() } else { bisect.good() }
    }
    panic!("no answer after 64 steps: {bisect:?}");
}

#[test]
fn every_culprit_is_named_in_at_most_log2_steps() {
    for n in 1..=20 {
        for culprit in apps(n) {
            let bisect = run_to_the_end(Bisect::start(apps(n)).expect("suspects"), &culprit);
            assert_eq!(bisect.found(), Some(culprit.as_str()), "n={n}");
            let bound = usize::BITS - (n - 1).leading_zeros();
            assert!(bisect.steps <= bound, "n={n} took {} steps", bisect.steps);
            assert!(bisect.trial.is_empty(), "nothing runs once it is named");
        }
    }
}

#[test]
fn the_first_half_runs_and_the_rest_is_held() {
    let bisect = Bisect::start(vec!["c".into(), "a".into(), "b".into(), "a".into()]).unwrap();
    assert_eq!(bisect.suspects, vec!["a", "b", "c"], "sorted, no duplicates");
    assert_eq!(bisect.trial, vec!["a", "b"]);
    assert!(bisect.runs("a") && !bisect.runs("c"));
    let json = bisect.json();
    assert_eq!(json["running"], serde_json::json!(["a", "b"]));
    assert_eq!(json["held"], serde_json::json!(["c"]));
    assert!(json.get("found").is_none());
}

#[test]
fn no_suspect_is_no_bisect_and_one_is_named_at_once() {
    assert_eq!(Bisect::start(Vec::new()), None);
    let one = Bisect::start(vec!["local/only".into()]).unwrap();
    assert_eq!(one.found(), Some("local/only"));
    assert_eq!(one.json()["found"], "local/only");
}

#[test]
fn answers_after_it_is_named_change_nothing() {
    let mut bisect = run_to_the_end(Bisect::start(apps(4)).unwrap(), "local/app02");
    let named = bisect.clone();
    bisect.good();
    bisect.bad();
    assert_eq!(bisect, named);
}

#[test]
fn the_record_survives_a_restart_and_reset_removes_it() {
    let dir = std::env::temp_dir().join(format!("bisect-{}", std::process::id()));
    let bisect = Bisect::start(apps(5)).unwrap();
    save(Some(&dir), Some(&bisect)).unwrap();
    assert_eq!(load(Some(&dir)), Some(bisect));
    save(Some(&dir), None).unwrap();
    assert_eq!(load(Some(&dir)), None);
    save(Some(&dir), None).expect("removing a missing record is fine");
    let _ = std::fs::remove_dir_all(&dir);
}
