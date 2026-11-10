//! `cmux vm redo`: what it carries from the old VM, what it refuses, and the steps it runs.

use serde_json::json;

use super::super::vm_ready::tests::{Fake, config, listed, row};
use super::{Redo, machine_name, parse, redo, size_of};

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// The app's `cloud machine-status`: the record's size (`cpu`, `memory_mb`) and idle pause (`idle_pause_minutes`,
/// from the record's `idle_policy`), no live `cpus` (the app server's stats are its state only).
fn status(title: &str, cpu: u64, idle: u64) -> serde_json::Value {
    json!({"machine_id": "vm-old", "title": title, "status": "running", "state": "running", "cpu": cpu,
           "memory_mb": cpu * 2048, "idle_pause_minutes": idle})
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

/// F1: `--confirm=false` is refused, never read as `--confirm`.
#[test]
fn a_valued_confirm_is_refused() {
    for word in ["--confirm=false", "--confirm=true", "--confirm="] {
        assert_eq!(
            parse(&strings(&["vm", "redo", "dev", word])),
            Some(Err("--confirm takes no value".to_owned())),
            "{word}"
        );
    }
}

/// F3: creation's sizes, by memory first (a create sends memory; xlarge is 12 vCPU made, 16 resized).
#[test]
fn sizes_by_memory_then_vcpus() {
    assert_eq!(size_of(Some(4_096), Some(2)), Some("small"));
    assert_eq!(size_of(Some(24_576), Some(12)), Some("xlarge"));
    assert_eq!(size_of(Some(24_576), Some(16)), Some("xlarge"));
    assert_eq!(size_of(None, Some(12)), Some("xlarge"));
    assert_eq!(size_of(None, Some(16)), Some("xlarge"));
    assert_eq!(size_of(None, Some(8)), Some("large"));
    assert_eq!(size_of(Some(1_000), Some(2)), None);
    assert_eq!(size_of(None, Some(3)), None);
    assert_eq!(size_of(None, None), None);
}

/// F2: a name `new-machine --name` takes, from any title.
#[test]
fn names_new_machine_takes() {
    assert_eq!(machine_name("dev", "vm-1"), "dev");
    assert_eq!(machine_name("Cloud Machine", "vm-1"), "Cloud-Machine");
    assert_eq!(machine_name("  my  box! ", "vm-1"), "my-box");
    assert_eq!(machine_name("-x", "vm-1"), "x");
    assert_eq!(machine_name(&"a".repeat(80), "vm-1"), "a".repeat(64));
    assert_eq!(machine_name("日本", "vm-1"), "vm-1");
    assert_eq!(machine_name("true", "vm-1"), "vm-1");
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
fn a_repo_takes_the_place_of_this_folders_config_and_an_off_idle_pause_stays_off() {
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
            "--persistent",
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

/// F2: the app's default name "Cloud Machine" (a space, which `new-machine --name` refuses) is made again as
/// `Cloud-Machine`, and the answer says what it was.
#[test]
fn a_name_new_machine_refuses_is_made_one_it_takes() {
    let mut fake = Fake::new(vec![
        (
            "list-machines",
            vec![
                listed(&[row("vm-old", "Cloud Machine", "running")]),
                listed(&[row("vm-new", "Cloud-Machine", "running")]),
            ],
        ),
        ("machine-status", vec![status("Cloud Machine", 4, 15)]),
        ("kill-machine", vec![json!({})]),
        ("new-machine", vec![json!({"machine_id": "vm-new"})]),
        ("deliver-secrets", vec![json!({"status": "delivered", "delivered": []})]),
        ("set-idle-pause", vec![json!({})]),
    ]);
    let request = Redo { confirm: true, ..Redo::default() };
    let answer = redo(&mut fake, &request, None).unwrap();
    assert_eq!(answer["renamed_from"], "Cloud Machine");
    assert_eq!(
        fake.ran[3],
        strings(&["cloud", "new-machine", "--name", "Cloud-Machine", "--size", "medium", "--json"])
    );
}

/// F2: an unreadable `--machine-config` or a malformed `--repo` is refused before anything, so no kill-machine.
#[test]
fn an_unreadable_config_or_a_malformed_repo_deletes_nothing() {
    for request in [
        Redo {
            confirm: true,
            machine_config: Some("/nonexistent/cmux-vm-redo/machine.toml".into()),
            ..Redo::default()
        },
        Redo { confirm: true, repo: Some("not a repo".into()), ..Redo::default() },
    ] {
        let mut fake = Fake::new(vec![
            ("list-machines", vec![listed(&[row("vm-old", "dev", "running")])]),
            ("machine-status", vec![status("dev", 4, 0)]),
            ("kill-machine", vec![json!({})]),
        ]);
        let error = redo(&mut fake, &request, None).unwrap_err();
        assert_eq!(error["code"], "usage.invalid", "{request:?}");
        assert!(!fake.verbs().contains(&"kill-machine".to_owned()), "{request:?}");
    }
}

/// F4: an idle pause that was Off (0, persistent) is Off again: the create is `--persistent`, and an older app's
/// `idle_pause` diagnostics still count.
#[test]
fn an_idle_pause_that_was_off_stays_off() {
    let mut fake = Fake::new(vec![
        (
            "list-machines",
            vec![
                listed(&[row("vm-old", "api", "running")]),
                listed(&[row("vm-new", "api", "running")]),
            ],
        ),
        ("machine-status", vec![status("api", 8, 0)]),
        ("kill-machine", vec![json!({})]),
        ("new-machine", vec![json!({"machine_id": "vm-new"})]),
        ("deliver-secrets", vec![json!({"status": "delivered", "delivered": []})]),
    ]);
    let request = Redo { confirm: true, ..Redo::default() };
    let answer = redo(&mut fake, &request, None).unwrap();
    assert_eq!(answer["idle_pause_minutes"], 0);
    assert_eq!(
        fake.ran[3],
        strings(&[
            "cloud",
            "new-machine",
            "--name",
            "api",
            "--size",
            "large",
            "--persistent",
            "--json"
        ])
    );
    assert!(!fake.verbs().contains(&"set-idle-pause".to_owned()));

    let older = json!({"machine_id": "vm-old", "title": "api", "status": "running", "idle_pause": {"minutes": 60}});
    let mut fake = Fake::new(vec![
        (
            "list-machines",
            vec![
                listed(&[row("vm-old", "api", "running")]),
                listed(&[row("vm-new", "api", "running")]),
            ],
        ),
        ("machine-status", vec![older]),
        ("kill-machine", vec![json!({})]),
        ("new-machine", vec![json!({"machine_id": "vm-new"})]),
        ("deliver-secrets", vec![json!({"status": "delivered", "delivered": []})]),
        ("set-idle-pause", vec![json!({})]),
    ]);
    let answer = redo(&mut fake, &request, None).unwrap();
    assert_eq!(answer["idle_pause_minutes"], 60);
    assert_eq!(fake.ran.last().unwrap()[5], "60");
}
