use super::*;
use serde_json::{Value, json};
use std::cell::{Cell, RefCell};

#[derive(Default)]
struct Fake {
    sources: Vec<Repo>,
    installation: Vec<Repo>,
    install_url: RefCell<Option<String>>,
    error: RefCell<Option<Value>>,
    clones: Cell<usize>,
    records: RefCell<Vec<Value>>,
}
fn repo(name: &str, source: &str) -> Repo {
    Repo { full_name: name.into(), private: true, source: source.into() }
}
impl Backend for Fake {
    fn sources(&self) -> Result<Vec<Repo>, Failure> {
        Ok(self.sources.clone())
    }
    fn connector(&self, _: Option<&str>) -> Result<Catalog, Failure> {
        Ok(Catalog {
            repos: self.installation.clone(),
            install_url: self.install_url.borrow().clone(),
            disconnected: self.install_url.borrow().is_some(),
        })
    }
    fn attached(&self, _: &str) -> Result<Vec<Value>, Failure> {
        Ok(self.records.borrow().clone())
    }
    fn clone_repo(&self, session: &str, name: &str, _: Option<&str>) -> Result<Value, Failure> {
        self.clones.set(self.clones.get() + 1);
        if let Some(error) = self.error.borrow().as_ref() {
            return Err(engine::seed_failure(error));
        }
        Ok(
            json!({"state":"done","repo":name,"folder":format!("/home/cmux/chats/{session}/{}",name.rsplit('/').next().unwrap()),"head":"abcd"}),
        )
    }
    fn record(&self, _: &str, record: &Value) -> Result<(), Failure> {
        self.records.borrow_mut().push(record.clone());
        Ok(())
    }
}
fn args(name: &str) -> Value {
    json!({"session":"chat-1","repo":name})
}
#[test]
fn cloud_repo_local_then_recent_then_installation_and_ambiguity() {
    let mut fake = Fake {
        sources: vec![repo("me/project", "local"), repo("old/project", "recent")],
        installation: vec![repo("org/project", "installation")],
        ..Default::default()
    };
    assert_eq!(add(&fake, &args("project")).unwrap()["repo"], "me/project");
    fake.records.borrow_mut().clear();
    fake.sources.remove(0);
    assert_eq!(add(&fake, &args("project")).unwrap()["repo"], "old/project");
    fake.records.borrow_mut().clear();
    fake.sources.clear();
    assert_eq!(add(&fake, &args("project")).unwrap()["repo"], "org/project");
    fake.records.borrow_mut().clear();
    fake.installation.push(repo("two/project", "installation"));
    let error = add(&fake, &args("project")).unwrap_err().0;
    assert_eq!(error["code"], "repo.ambiguous");
    assert_eq!(error["choices"].as_array().unwrap().len(), 2);
    assert_eq!(fake.clones.get(), 3);
}
#[test]
fn cloud_repo_connect_then_same_add_resumes_without_message() {
    let fake = Fake {
        install_url: RefCell::new(Some("https://github.com/apps/cmux/installations/new".into())),
        ..Default::default()
    };
    let error = add(&fake, &args("project")).unwrap_err().0;
    assert_eq!(error["code"], "repo.needs_github");
    assert_eq!(error["retry"]["args"], args("project"));
    assert_eq!(error["retry"]["wait_action"], "cloud.repo.wait_github");
    assert!(error["message"].as_str().unwrap().contains("automatically"));
    let fake = Fake { installation: vec![repo("org/project", "installation")], ..fake };
    *fake.install_url.borrow_mut() = None;
    let done = add(&fake, &error["retry"]["args"]).unwrap();
    assert_eq!(done["state"], "done");
    assert_eq!(add(&fake, &args("project")).unwrap(), done);
    assert_eq!(fake.clones.get(), 1);
}
#[test]
fn cloud_repo_public_explicit_needs_no_connector() {
    let fake = Fake {
        install_url: RefCell::new(Some("https://github.com/install".into())),
        ..Default::default()
    };
    assert_eq!(
        add(&fake, &args("https://github.com/owner/public.git")).unwrap()["repo"],
        "owner/public"
    );
    assert_eq!(fake.records.borrow().len(), 1);
}
#[test]
fn cloud_repo_typed_seed_failures_have_next_action() {
    for code in [
        "seed.folder_not_empty",
        "seed.disk_full",
        "seed.clone_failed",
        "seed.bad_request",
        "seed.checkout_failed",
        "seed.unknown_job",
        "seed.unavailable",
        "seed.needs_github",
    ] {
        let fake = Fake {
            error: RefCell::new(Some(
                json!({"error_code":code,"install_url":"https://github.com/install"}),
            )),
            ..Default::default()
        };
        let error = add(&fake, &args("owner/repo")).unwrap_err().0;
        assert_eq!(
            error["code"],
            if code == "seed.needs_github" { "repo.needs_github" } else { code }
        );
        assert!(
            error["message"]
                .as_str()
                .unwrap()
                .to_ascii_lowercase()
                .contains(if code == "seed.needs_github" { "connect" } else { "retry" })
        );
        assert!(fake.records.borrow().is_empty());
    }
}
#[test]
fn cloud_repo_not_found_non_github_and_invalid_never_clone() {
    let fake = Fake::default();
    for (name, code) in [
        ("missing", "repo.not_found"),
        ("https://gitlab.com/o/r", "repo.not_github"),
        ("../escape", "seed.bad_request"),
        ("https://user:secret@github.com/o/r", "seed.bad_request"),
    ] {
        assert_eq!(add(&fake, &args(name)).unwrap_err().0["code"], code);
    }
    assert_eq!(
        add(&fake, &json!({"session":"../bad","repo":"o/r"})).unwrap_err().0["code"],
        "seed.bad_request"
    );
    assert_eq!(fake.clones.get(), 0);
}
#[test]
fn cloud_repo_list_deduplicates_and_filters_without_losing_connect() {
    let fake = Fake {
        sources: vec![repo("o/R", "local"), repo("o/r", "recent")],
        installation: vec![repo("o/r", "installation"), repo("o/other", "installation")],
        install_url: RefCell::new(Some("https://github.com/install".into())),
        ..Default::default()
    };
    let result = list(&fake, Some("o/r")).unwrap();
    assert_eq!(result["repos"].as_array().unwrap().len(), 1);
    assert_eq!(result["repos"][0]["source"], "local");
    assert_eq!(result["connect"]["install_url"], "https://github.com/install");
}
#[test]
fn cloud_repo_persists_chat_attachments_and_recent_sources() {
    let mux = crate::Mux::new_for_test("cloud-repos", crate::SurfaceOptions::default());
    store::sync(&mux, &json!({"repos":[repo("o/local","local")],"complete":true})).unwrap();
    let attached = json!({"state":"done","repo":"o/added","folder":"/home/cmux/chats/chat-1/added","head":"abcd"});
    store::record(&mux, "chat-1", &attached).unwrap();
    store::record(&mux, "chat-2", &attached).unwrap();
    assert_eq!(store::attached(&mux, "chat-1").unwrap(), vec![attached.clone()]);
    assert_eq!(store::attached(&mux, "chat-2").unwrap(), vec![attached]);
    let sources = store::sources(&mux).unwrap();
    assert_eq!(
        sources.iter().map(|r| r.source.as_str()).collect::<Vec<_>>(),
        vec!["local", "recent"]
    );
    assert!(store::sync(&mux, &json!({"repos":[],"complete":false})).is_err());
    assert_eq!(store::sources(&mux).unwrap(), sources);
}

#[test]
fn cloud_repo_recovery_strips_wire_fields_and_access_denial_names_org() {
    let fake = Fake {
        install_url: RefCell::new(Some("https://github.com/install".into())),
        ..Default::default()
    };
    let error = add(
        &fake,
        &json!({"id":7,"cmd":"cloud.repo.add","session":"chat-1","repo":"missing","ref":"main"}),
    )
    .unwrap_err()
    .0;
    assert_eq!(error["retry"]["args"], json!({"session":"chat-1","repo":"missing","ref":"main"}));
    let fake = Fake {
        sources: vec![repo("org/private", "local")],
        error: RefCell::new(Some(
            json!({"error_code":"repo.no_access","install_url":"https://github.com/install"}),
        )),
        ..Default::default()
    };
    let error = add(&fake, &args("private")).unwrap_err().0;
    assert_eq!(error["code"], "repo.no_access");
    assert_eq!(error["org"], "org");
    assert_eq!(error["install_url"], "https://github.com/install");
}

#[test]
fn cloud_repo_remote_gate_never_exports_mac_projects_or_accepts_lookalike_commands() {
    use crate::server::RemoteGate;
    let peer =
        crate::server::RemotePeer { install: "i".into(), user: "u".into(), team: "t".into() };
    for cmd in [
        "cloud.repo.add",
        "cloud.repo.list",
        "cloud.repo.attached",
        "cloud.repo.sync",
        "cloud.repo.wait_github",
    ] {
        assert!(
            crate::server::FsGate.admit(&peer, &json!({"cmd":cmd,"session":"chat"}).to_string())
        );
    }
    for value in [
        json!({"cmd":"cloud.repo.local"}),
        json!({"cmd":"cloud.repo.remember"}),
        json!({"cmd":"cloud.repo.addx"}),
        json!({"cmd":"cloud.repo.add","protocol":"cmux.protocol/2"}),
        json!({"cmd":"ping","note":"cloud.repo.add"}),
    ] {
        assert!(!crate::server::FsGate.admit(&peer, &value.to_string()));
    }
}

// Shared hostile-link corpus exercises the same validator at every boundary.
pub(super) const UNSAFE_INSTALL_URLS: &[&str] = &[
    "",
    "http://github.com/apps/cmux",
    "javascript:alert(1)",
    "https://evil.example/apps/cmux",
    "https://github.com.evil.example/apps/cmux",
    "https://github.com@evil.example/apps/cmux",
    "https://user@github.com/apps/cmux",
    "https://@github.com/apps/cmux",
    "https://user:secret@github.com/apps/cmux",
    "https://github.com:444/apps/cmux",
    "https://github.com/apps/cmux\n",
    "https://git\thub.com/apps/cmux",
    "https://github.com/apps/\rcmux",
    " https://github.com/apps/cmux",
];

#[test]
fn cloud_repo_install_link_validation_and_engine_outputs_share_one_policy() {
    for url in
        ["https://github.com/apps/cmux/installations/new", "https://github.com:443/apps/cmux"]
    {
        assert!(engine::valid_install_url(url));
        assert_eq!(Failure::needs_github(url).0["install_url"], url);
    }
    for url in UNSAFE_INSTALL_URLS {
        assert!(!engine::valid_install_url(url), "{url:?}");
        let failure = Failure::needs_github(url).0;
        assert_eq!(failure["code"], "seed.bad_request");
        assert!(failure.get("install_url").is_none());
        assert!(failure["message"].as_str().unwrap().contains("Mac"));
        let fake = Fake { install_url: RefCell::new(Some((*url).into())), ..Default::default() };
        let listed = list(&fake, None).unwrap();
        assert_eq!(listed["repos"], json!([]));
        assert!(listed.get("connect").is_none());
        let failure = add(&fake, &args("project")).unwrap_err().0;
        assert_eq!(failure["code"], "seed.bad_request");
        assert!(failure.get("install_url").is_none());
        for code in ["seed.needs_github", "repo.needs_github", "seed.no_access", "repo.no_access"] {
            let failure = engine::seed_failure(&json!({"error_code":code,"install_url":url})).0;
            assert!(failure.get("install_url").is_none(), "{code}: {failure}");
            assert!(!failure["message"].as_str().unwrap().is_empty());
        }
    }
}

#[test]
fn cloud_repo_list_keeps_local_and_installation_rows_without_an_unsafe_connect_link() {
    let fake = Fake {
        sources: vec![repo("local/tool", "local")],
        installation: vec![repo("org/other", "installation")],
        install_url: RefCell::new(Some("https://evil.example/install".into())),
        ..Default::default()
    };
    let listed = list(&fake, None).unwrap();
    assert_eq!(listed["repos"].as_array().unwrap().len(), 2);
    assert_eq!(listed["repos"][0]["fullName"], "local/tool");
    assert_eq!(listed["repos"][1]["fullName"], "org/other");
    assert!(listed.get("connect").is_none());
    assert_eq!(add(&fake, &args("other")).unwrap()["repo"], "org/other");
    let failure = add(&fake, &args("missing")).unwrap_err().0;
    assert_eq!(failure["code"], "seed.bad_request");
    assert!(failure["message"].as_str().unwrap().contains("refresh"));
}
