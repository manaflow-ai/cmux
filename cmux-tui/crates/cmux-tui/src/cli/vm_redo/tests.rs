//! `cmux vm redo`: what it carries from the old VM, what it refuses, and the steps it runs.

use serde_json::json;

use super::super::vm_ready::tests::{Fake, config, listed, row};
use super::{Redo, parse, redo, size_of};

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn status(title: &str, cpus: u64, idle: u64) -> serde_json::Value {
    json!({"machine_id": "vm-old", "title": title, "status": "running", "cpus": cpus, "idle_pause": {"minutes": idle}})
}

#[test]
fn its_words() {
    assert_eq!(parse(&strings(&["vm", "rm", "dev"])), None);
    assert_eq!(
        parse(&strings(&[
            "vm",
            "redo",
            "dev",
            "--confirm",
            "--machine-config=m.toml",
            "--timeout",
            "90"
        ])),
        Some(Ok(Redo {
            named: Some("dev".into()),
            confirm: true,
            machine_config: Some("m.toml".into()),
            repo: None,
            timeout: Some(std::time::Duration::from_secs(90)),
        }))
    );
    assert_eq!(parse(&strings(&["cloud", "redo"])), Some(Ok(Redo::default())));
    assert!(matches!(parse(&strings(&["vm", "redo", "a", "b"])), Some(Err(_))));
    assert!(matches!(parse(&strings(&["vm", "redo", "--repo"])), Some(Err(_))));
}

#[test]
fn sizes_by_vcpus() {
    assert_eq!(size_of(Some(2)), Some("small"));
    assert_eq!(size_of(Some(16)), Some("xlarge"));
    assert_eq!(size_of(Some(3)), None);
    assert_eq!(size_of(None), None);
}

#[test]
fn without_confirm_nothing_is_deleted() {
    let mut fake = Fake::new(vec![
        ("list-machines", vec![listed(&[row("vm-old", "dev", "running")])]),
        ("machine-status", vec![status("dev", 4, 0)]),
    ]);
    let request = Redo { named: Some("dev".into()), ..Redo::default() };
    let error = redo(&mut fake, &request, None).unwrap_err();
    assert_eq!(error["code"], "usage.confirm");
    assert_eq!(error["details"]["next"], "cmux vm redo vm-old --confirm");
    assert_eq!(fake.verbs(), strings(&["list-machines", "machine-status"]));
}

#[test]
fn the_same_vm_again_with_its_size_idle_pause_and_this_folders_machine_config() {
    let mut fake = Fake::new(vec![
        (
            "list-machines",
            vec![
                listed(&[row("vm-old", "dev", "running")]),
                // The old VM is still listed under the same name while it goes: never taken for the new one.
                listed(&[row("vm-old", "dev", "running"), row("vm-new", "dev", "provisioning")]),
                listed(&[row("vm-new", "dev", "running")]),
            ],
        ),
        ("machine-status", vec![status("dev", 8, 30)]),
        ("kill-machine", vec![json!({"machine_id": "vm-old"})]),
        ("new-machine", vec![json!({"pending": true})]),
        ("file-read", vec![config("done")]),
        (
            "deliver-secrets",
            vec![json!({"status": "unchanged", "delivered": [], "missing": ["API_KEY"]})],
        ),
        ("set-idle-pause", vec![json!({"machine_id": "vm-new", "idle_pause_minutes": 30})]),
    ]);
    let request = Redo { named: Some("dev".into()), confirm: true, ..Redo::default() };
    let answer = redo(&mut fake, &request, Some("/work/.cmux/machine.toml".into())).unwrap();
    assert_eq!(answer["machine_id"], "vm-new");
    assert_eq!(answer["replaced"], "vm-old");
    assert_eq!(answer["size"], "large");
    assert_eq!(answer["idle_pause_minutes"], 30);
    assert_eq!(answer["secrets"]["missing"], json!(["API_KEY"]));
    assert_eq!(
        fake.verbs(),
        strings(&[
            "list-machines",
            "machine-status",
            "kill-machine",
            "new-machine",
            "list-machines",
            "list-machines",
            "file-read",
            "deliver-secrets",
            "set-idle-pause",
        ])
    );
    assert_eq!(
        fake.ran[2],
        strings(&["cloud", "kill-machine", "--target", "machine:vm-old", "--confirm", "--json"])
    );
    assert_eq!(
        fake.ran[3],
        strings(&[
            "cloud",
            "new-machine",
            "--name",
            "dev",
            "--size",
            "large",
            "--machine-config",
            "/work/.cmux/machine.toml",
            "--json",
        ])
    );
    assert_eq!(
        fake.ran[8],
        strings(&[
            "cloud",
            "set-idle-pause",
            "--target",
            "machine:vm-new",
            "--minutes",
            "30",
            "--json"
        ])
    );
}

#[test]
fn a_repo_takes_the_place_of_this_folders_config_and_no_idle_pause_stays_none() {
    let mut fake = Fake::new(vec![
        (
            "list-machines",
            vec![
                listed(&[row("vm-old", "api", "running")]),
                listed(&[row("vm-new", "api", "running")]),
            ],
        ),
        ("machine-status", vec![status("api", 2, 0)]),
        ("kill-machine", vec![json!({})]),
        ("new-machine", vec![json!({"machine_id": "vm-new"})]),
        ("file-read", vec![config("done")]),
        ("deliver-secrets", vec![json!({"status": "delivered", "delivered": ["API_KEY"]})]),
    ]);
    let request = Redo { confirm: true, repo: Some("o/r".into()), ..Redo::default() };
    let answer = redo(&mut fake, &request, Some("/work/.cmux/machine.toml".into())).unwrap();
    assert_eq!(answer["machine_id"], "vm-new");
    assert_eq!(
        fake.ran[3],
        strings(&[
            "cloud",
            "new-machine",
            "--name",
            "api",
            "--size",
            "small",
            "--repo",
            "o/r",
            "--json"
        ])
    );
    assert!(!fake.verbs().contains(&"set-idle-pause".to_owned()));
}

#[test]
fn a_name_it_does_not_know_is_refused_before_anything_is_deleted() {
    let mut fake =
        Fake::new(vec![("list-machines", vec![listed(&[row("vm-old", "dev", "running")])])]);
    let request = Redo { named: Some("nope".into()), confirm: true, ..Redo::default() };
    let error = redo(&mut fake, &request, None).unwrap_err();
    assert_eq!(error["code"], "cloud.unknown_machine");
    assert_eq!(fake.verbs(), strings(&["list-machines"]));
}
