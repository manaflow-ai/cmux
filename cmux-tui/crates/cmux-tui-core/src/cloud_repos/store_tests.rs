use super::*;

fn mux(name: &str) -> std::sync::Arc<Mux> {
    Mux::new_for_test(name, crate::SurfaceOptions::default())
}
fn repo(name: &str, source: &str) -> Value {
    json!({"fullName":name,"private":true,"source":source})
}
fn attachment(repo: &str, session: &str) -> Value {
    let name = repo.split_once('/').unwrap().1;
    json!({"state":"done","repo":repo,"folder":format!("/home/cmux/chats/{session}/{name}"),"head":"abcdef0123456789"})
}

#[test]
fn cloud_repo_remember_keeps_local_catalog_and_updates_recent_once() {
    let mux = mux("cloud-repo-remember");
    sync(&mux, &json!({"repos":[repo("o/local","local")]})).unwrap();
    let one = attachment("o/added", "chat-1");
    assert_eq!(
        remember(&mux, &json!({"session":"chat-1","attachment":one})).unwrap(),
        json!({"remembered":true})
    );
    remember(&mux, &json!({"session":"chat-1","attachment":one})).unwrap();
    assert_eq!(attached(&mux, "chat-1").unwrap(), vec![one]);
    let catalog = sources(&mux).unwrap();
    assert_eq!(catalog.len(), 2);
    assert_eq!(catalog[0].full_name, "o/local");
    assert_eq!(catalog[0].source, "local");
    assert_eq!(catalog[1].full_name, "o/added");
    assert_eq!(catalog[1].source, "recent");
}

#[test]
fn cloud_repo_recent_sync_merges_case_insensitively_and_forces_recent_source() {
    let mux = mux("cloud-repo-recent-sync");
    record(&mux, "chat-1", &attachment("o/Added", "chat-1")).unwrap();
    let input = json!({"repos":[],"recent":[repo("o/added","local"),repo("o/other","installation"),repo("O/OTHER","local")]});
    sync(&mux, &input).unwrap();
    sync(&mux, &input).unwrap();
    let catalog = sources(&mux).unwrap();
    assert_eq!(
        catalog.iter().map(|r| r.full_name.as_str()).collect::<Vec<_>>(),
        vec!["o/Added", "o/other"]
    );
    assert!(catalog.iter().all(|r| r.source == "recent"));
    sync(&mux, &json!({"repos":[]})).unwrap();
    assert_eq!(sources(&mux).unwrap(), catalog);
}

#[test]
fn cloud_repo_recent_reaches_new_machine_without_copying_chat_attachments() {
    let mac = mux("cloud-repo-mac-recent");
    remember(&mac, &json!({"session":"chat-1","attachment":attachment("o/project","chat-1")}))
        .unwrap();
    let machine = mux("cloud-repo-new-machine-recent");
    sync(&machine, &json!({"repos":[],"recent":sources(&mac).unwrap()})).unwrap();
    assert_eq!(sources(&machine).unwrap()[0].full_name, "o/project");
    assert!(attached(&machine, "chat-1").unwrap().is_empty());
}

#[test]
fn cloud_repo_pending_exposes_only_running_progress_for_this_chat() {
    let mux = mux("cloud-repo-progress");
    let progress = json!({"received_bytes":1024,"objects":2,"total_objects":4});
    set_job(
        &mux,
        "chat-1",
        "repo",
        Some(&json!({
            "job":"internal-id", "repo":"o/repo", "ref":"main", "state":"running",
            "phase":"clone", "progress":progress, "notes":["lfs_unavailable"]
        })),
    )
    .unwrap();
    let rows = pending(&mux, "chat-1").unwrap();
    assert_eq!(
        rows,
        vec![json!({"repo":"o/repo","state":"running","phase":"clone",
        "progress":progress,"notes":["lfs_unavailable"]})]
    );
    assert!(pending(&mux, "chat-2").unwrap().is_empty());
    set_job(&mux, "chat-1", "repo", Some(&json!({"repo":"o/repo","state":"done"}))).unwrap();
    assert!(pending(&mux, "chat-1").unwrap().is_empty());
}

#[test]
fn cloud_repo_remember_rejects_invalid_attachment_without_mutating_catalog() {
    let mux = mux("cloud-repo-invalid-remember");
    let good = attachment("o/repo", "chat-1");
    let mut cases = vec![json!({"session":"../chat-1","attachment":good})];
    for (key, value) in [
        ("state", json!("running")),
        ("repo", json!("../repo")),
        ("folder", json!("/home/cmux/chats/other/repo")),
        ("folder", json!("/home/cmux/../chats/chat-1/repo")),
        ("folder", json!("relative/chats/chat-1/repo")),
        ("head", json!("")),
        ("head", json!("not a hash")),
    ] {
        let mut bad = good.clone();
        bad[key] = value;
        cases.push(json!({"session":"chat-1","attachment":bad}));
    }
    for input in cases {
        assert!(remember(&mux, &input).is_err());
    }
    assert!(sources(&mux).unwrap().is_empty());
    assert!(attached(&mux, "chat-1").unwrap().is_empty());
    assert!(
        sync(&mux, &json!({"repos":[repo("o/local","local")],"recent":[repo("../bad","recent")]}))
            .is_err()
    );
    assert!(sources(&mux).unwrap().is_empty());
}

#[test]
fn cloud_repo_install_links_are_checked_on_sync_and_when_reading_old_records() {
    let mux = mux("cloud-repo-install-link-validation");
    let trusted = "https://github.com/apps/cmux/installations/new?state=mac";
    for url in crate::cloud_repos::tests::UNSAFE_INSTALL_URLS {
        let failure = sync(&mux, &json!({"repos":[],"install_url":url})).unwrap_err().0;
        assert_eq!(failure["code"], "seed.bad_request");
        assert!(install_url(&mux).unwrap().is_none());
        assert!(load(&mux).unwrap().0.get("install_url").is_none());
    }
    sync(&mux, &json!({"repos":[],"install_url":trusted})).unwrap();
    for url in crate::cloud_repos::tests::UNSAFE_INSTALL_URLS {
        assert!(sync(&mux, &json!({"repos":[],"install_url":url})).is_err());
        assert_eq!(install_url(&mux).unwrap().as_deref(), Some(trusted));
    }
    // Old versions could persist links that the new writer rejects. Reading
    // one must not expose it or prevent a validated connector fallback.
    for url in crate::cloud_repos::tests::UNSAFE_INSTALL_URLS {
        change(&mux, |doc| {
            doc.set("install_url", json!(url));
        })
        .unwrap();
        assert!(install_url(&mux).unwrap().is_none());
    }
}
