use super::*;

use std::io::BufRead as _;
use std::net::TcpListener;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

const URL: &str = "https://github.com/acme/widget.git";

fn sh(dir: &Path, args: &[&str]) -> String {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@example.com")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@example.com")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// A source repo on `main` with one commit.
fn source(root: &Path) -> PathBuf {
    let repo = root.join("source");
    std::fs::create_dir_all(&repo).unwrap();
    sh(&repo, &["init", "--quiet", "--initial-branch", "main"]);
    commit(&repo, "a.txt", "one");
    repo
}

fn commit(repo: &Path, file: &str, text: &str) -> String {
    let path = repo.join(file);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, text).unwrap();
    sh(repo, &["add", "-A"]);
    sh(repo, &["commit", "--quiet", "-m", text]);
    sh(repo, &["rev-parse", "HEAD"])
}

struct Fixture {
    root: tempfile::TempDir,
    store: DirStore,
    source: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let source = source(root.path());
        let store = DirStore { root: root.path().join("store") };
        Self { root, store, source }
    }

    fn publish_at(&self, now: SystemTime) -> Published {
        let work = tempfile::tempdir_in(self.root.path()).unwrap();
        publish(
            &self.store,
            &Publish {
                source: self.source.to_str().unwrap(),
                url: URL,
                branch: "main",
                default: true,
                max_age: Duration::from_secs(3600),
                max_increment: 1 << 20,
                now,
                work: work.path(),
            },
        )
        .unwrap()
    }

    fn publish(&self) -> Published {
        self.publish_at(SystemTime::now())
    }

    fn fetch(&self, name: &str, branch: Option<&str>) -> (PathBuf, Fetched) {
        let dir = self.root.path().join(name);
        let fetched = fetch(&self.store, URL, branch, &dir, STREAMS).unwrap();
        (dir, fetched)
    }
}

fn checked_out(fetched: &Fetched) -> &str {
    match fetched {
        Fetched::Checkout { commit, .. } => commit,
        Fetched::Unknown { why } => panic!("unknown: {why}"),
    }
}

#[test]
fn keys_name_the_repo_and_escape_the_branch() {
    assert_eq!(repo_path(URL).as_deref(), Some("github.com/acme/widget"));
    assert_eq!(repo_path("acme/widget").as_deref(), Some("github.com/acme/widget"));
    assert_eq!(repo_path("https://GitLab.com/g/sub/n/").as_deref(), Some("gitlab.com/g/sub/n"));
    assert_eq!(repo_path("https://user:pw@github.com/a/b"), None);
    assert_eq!(repo_path("https://github.com/a/../b"), None);
    assert_eq!(repo_path("/local/path"), None);
    assert_eq!(branch_segment("feat-cmux-next"), "feat-cmux-next");
    assert_eq!(branch_segment("lane/x y"), "lane~2Fx~20y");
    assert_eq!(branch_segment(".."), "~2E~2E");
    assert_eq!(
        manifest_key(URL, "lane/a").unwrap(),
        "repo-archive/v1/github.com/acme/widget/lane~2Fa/manifest.json"
    );
}

#[test]
fn an_archive_checks_out_the_branch_with_its_origin() {
    let fixture = Fixture::new();
    let tip = sh(&fixture.source, &["rev-parse", "HEAD"]);
    let Published::Archive { commit, .. } = fixture.publish() else { panic!("no archive") };
    assert_eq!(commit, tip);
    // No branch named: the store's default (HEAD.json).
    let (dir, fetched) = fixture.fetch("vm", None);
    assert_eq!(checked_out(&fetched), tip);
    assert_eq!(std::fs::read_to_string(dir.join("a.txt")).unwrap(), "one");
    assert_eq!(sh(&dir, &["remote", "get-url", "origin"]), URL);
    assert_eq!(sh(&dir, &["rev-parse", "--abbrev-ref", "@{u}"]), "origin/main");
    assert_eq!(sh(&dir, &["rev-parse", "--is-shallow-repository"]), "true");
    assert_eq!(sh(&dir, &["status", "--porcelain"]), "");
    assert!(!dir.join(".cmux-archive.part").exists());
    assert!(!dir.join(".git/hooks").exists());
}

#[test]
fn a_moved_branch_publishes_an_increment_a_vm_applies() {
    let fixture = Fixture::new();
    let first = sh(&fixture.source, &["rev-parse", "HEAD"]);
    fixture.publish();
    assert_eq!(fixture.publish(), Published::Unchanged { commit: first.clone() });
    commit(&fixture.source, "b/b.txt", "two");
    let tip = commit(&fixture.source, "a.txt", "three");
    let Published::Increment { from, to, .. } = fixture.publish() else { panic!("no increment") };
    assert_eq!((from.as_str(), to.as_str()), (first.as_str(), tip.as_str()));
    assert_eq!(fixture.publish(), Published::Unchanged { commit: tip.clone() });
    let (dir, fetched) = fixture.fetch("vm", Some("main"));
    let Fetched::Checkout { archive, increment_skipped, .. } = &fetched else { panic!() };
    assert_eq!((archive.as_str(), increment_skipped), (first.as_str(), &None));
    assert_eq!(checked_out(&fetched), tip);
    assert_eq!(std::fs::read_to_string(dir.join("a.txt")).unwrap(), "three");
    assert_eq!(std::fs::read_to_string(dir.join("b/b.txt")).unwrap(), "two");
    assert_eq!(sh(&dir, &["rev-parse", "origin/main"]), tip);
    assert_eq!(sh(&dir, &["status", "--porcelain"]), "");
}

#[test]
fn a_force_push_or_an_old_archive_makes_a_new_archive() {
    let fixture = Fixture::new();
    fixture.publish();
    sh(&fixture.source, &["checkout", "--quiet", "--orphan", "other"]);
    let tip = commit(&fixture.source, "c.txt", "rewritten");
    sh(&fixture.source, &["branch", "--quiet", "-M", "main"]);
    let Published::Archive { commit: archived, why, .. } = fixture.publish() else {
        panic!("no archive")
    };
    assert_eq!(archived, tip);
    assert!(why.contains("no ancestor"), "{why}");
    let next = commit(&fixture.source, "c.txt", "later");
    let later = SystemTime::now() + Duration::from_secs(7200);
    let Published::Archive { commit: archived, why, .. } = fixture.publish_at(later) else {
        panic!()
    };
    assert_eq!(archived, next);
    assert!(why.contains("old"), "{why}");
    let (_, fetched) = fixture.fetch("vm", Some("main"));
    assert_eq!(checked_out(&fetched), next);
}

#[test]
fn a_quiet_branch_rewrites_its_old_archive() {
    let fixture = Fixture::new();
    let Published::Archive { commit: first, .. } = fixture.publish() else { panic!("no archive") };
    assert_eq!(fixture.publish(), Published::Unchanged { commit: first.clone() });
    let later = SystemTime::now() + Duration::from_secs(7200);
    let Published::Archive { commit: again, why, .. } = fixture.publish_at(later) else {
        panic!("an old archive of an unmoved branch was not rewritten")
    };
    assert_eq!(again, first);
    assert!(why.contains("old"), "{why}");
    let (_, fetched) = fixture.fetch("vm", Some("main"));
    assert_eq!(checked_out(&fetched), first);
}

#[test]
fn an_increment_needing_history_the_archive_lacks_makes_a_new_archive() {
    let fixture = Fixture::new();
    let base = sh(&fixture.source, &["rev-parse", "HEAD"]);
    commit(&fixture.source, "a.txt", "two");
    fixture.publish();
    // A side branch from before the archive's commit, merged after it.
    sh(&fixture.source, &["checkout", "--quiet", "-b", "side", &base]);
    commit(&fixture.source, "side.txt", "side");
    sh(&fixture.source, &["checkout", "--quiet", "main"]);
    sh(&fixture.source, &["merge", "--quiet", "--no-edit", "side"]);
    let tip = sh(&fixture.source, &["rev-parse", "HEAD"]);
    let Published::Archive { commit: archived, why, .. } = fixture.publish() else {
        panic!("no archive")
    };
    assert_eq!(archived, tip);
    assert!(why.contains("older than the archive"), "{why}");
}

#[test]
fn an_unknown_repo_or_branch_writes_nothing() {
    let fixture = Fixture::new();
    let (dir, fetched) = fixture.fetch("vm", None);
    assert!(matches!(fetched, Fetched::Unknown { .. }));
    fixture.publish();
    let (_, fetched) = fixture.fetch("vm", Some("nope"));
    assert!(matches!(fetched, Fetched::Unknown { .. }));
    assert!(!dir.exists());
}

#[test]
fn a_damaged_archive_fails_and_leaves_no_folder() {
    let fixture = Fixture::new();
    fixture.publish();
    let key = manifest_key(URL, "main").unwrap();
    let mut manifest: Manifest =
        serde_json::from_slice(&fixture.store.get(&key).unwrap().unwrap()).unwrap();
    manifest.archive.sha256 = "0".repeat(64);
    fixture.store.put_bytes(&key, &serde_json::to_vec(&manifest).unwrap()).unwrap();
    let dir = fixture.root.path().join("vm");
    let error = fetch(&fixture.store, URL, Some("main"), &dir, STREAMS).unwrap_err();
    assert!(format!("{error:#}").contains("SHA-256"), "{error:#}");
    assert!(!dir.exists());
}

#[test]
fn a_lost_increment_is_skipped_and_the_archive_still_checks_out() {
    let fixture = Fixture::new();
    let first = sh(&fixture.source, &["rev-parse", "HEAD"]);
    fixture.publish();
    commit(&fixture.source, "a.txt", "two");
    let Published::Increment { .. } = fixture.publish() else { panic!() };
    let key = manifest_key(URL, "main").unwrap();
    let manifest: Manifest =
        serde_json::from_slice(&fixture.store.get(&key).unwrap().unwrap()).unwrap();
    std::fs::remove_file(fixture.store.root.join(&manifest.increment.unwrap().object.key)).unwrap();
    let (_, fetched) = fixture.fetch("vm", Some("main"));
    let Fetched::Checkout { increment_skipped, .. } = &fetched else { panic!() };
    assert!(increment_skipped.is_some());
    assert_eq!(checked_out(&fetched), first);
}

#[test]
fn the_store_is_off_unless_configured() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("repo-archive.json");
    let none = |_: &str| None;
    assert_eq!(configured_store(&none, &config), None);
    std::fs::write(&config, r#"{"store":"file:///s"}"#).unwrap();
    assert_eq!(configured_store(&none, &config).as_deref(), Some("file:///s"));
    let env = |name: &str| (name == "CMUX_REPO_ARCHIVE_STORE").then(|| "/e".to_owned());
    assert_eq!(configured_store(&env, &config).as_deref(), Some("/e"));
}

#[test]
fn the_machine_config_carries_the_read_key_after_the_env_and_the_s3_file() {
    let machine = serde_json::json!({"store": "https://a.example/b", "access_key_id": "vm", "secret_access_key": "vs"});
    let file = serde_json::json!({"access_key_id": "file", "secret_access_key": " "});
    let none = |_: &str| None;
    let id = "CMUX_PROJECTION_S3_ACCESS_KEY_ID";
    let secret = "CMUX_PROJECTION_S3_SECRET_ACCESS_KEY";
    let blank = serde_json::Value::Null;
    assert_eq!(store_setting(id, &none, &blank, &machine).as_deref(), Some("vm"));
    assert_eq!(store_setting(id, &none, &file, &machine).as_deref(), Some("file"));
    // A blank value in the S3 file does not hide the machine's.
    assert_eq!(store_setting(secret, &none, &file, &machine).as_deref(), Some("vs"));
    let env = |name: &str| (name == "CMUX_PROJECTION_S3_ACCESS_KEY_ID").then(|| "env".to_owned());
    assert_eq!(store_setting(id, &env, &file, &machine).as_deref(), Some("env"));
    assert_eq!(store_setting("AWS_REGION", &none, &file, &machine), None);
    assert_eq!(store_setting(id, &none, &blank, &blank), None);
}

/// A public bucket over HTTP that answers ranged GETs from `root`, counting them.
fn serve(root: PathBuf, ranged: Arc<AtomicUsize>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let root = root.clone();
            let ranged = Arc::clone(&ranged);
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                let path = line.split_whitespace().nth(1).unwrap_or("/").to_owned();
                let mut range = None;
                loop {
                    let mut header = String::new();
                    reader.read_line(&mut header).unwrap();
                    if header.trim().is_empty() {
                        break;
                    }
                    if let Some(value) = header.to_ascii_lowercase().strip_prefix("range: bytes=") {
                        let (a, b) = value.trim().split_once('-').unwrap();
                        range = Some((a.parse::<usize>().unwrap(), b.parse::<usize>().unwrap()));
                    }
                }
                let (status, body) = match std::fs::read(root.join(path.trim_start_matches('/'))) {
                    Ok(bytes) => match range {
                        Some((a, b)) => {
                            ranged.fetch_add(1, Ordering::SeqCst);
                            ("206 Partial Content", bytes[a..=b].to_vec())
                        }
                        None => ("200 OK", bytes),
                    },
                    Err(_) => ("404 Not Found", Vec::new()),
                };
                let head = format!(
                    "HTTP/1.1 {status}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.write_all(&body);
            });
        }
    });
    base
}

#[test]
fn a_bucket_is_read_in_ranged_streams() {
    let fixture = Fixture::new();
    for index in 0..20 {
        commit(&fixture.source, &format!("f{index}.txt"), &format!("{index}").repeat(4000));
    }
    fixture.publish();
    let ranged = Arc::new(AtomicUsize::new(0));
    let base = serve(fixture.store.root.clone(), Arc::clone(&ranged));
    let store = open(&base, &|_| None).unwrap();
    let dir = fixture.root.path().join("vm");
    let fetched = fetch(store.as_ref(), URL, None, &dir, STREAMS).unwrap();
    assert_eq!(checked_out(&fetched), sh(&fixture.source, &["rev-parse", "HEAD"]));
    assert_eq!(ranged.load(Ordering::SeqCst), STREAMS);
    assert_eq!(std::fs::read_to_string(dir.join("f3.txt")).unwrap(), "3".repeat(4000));
    // An unsigned bucket cannot be written.
    assert!(store.put_bytes("x", b"y").is_err());
}

#[test]
fn a_blobless_mirror_takes_the_blobs_from_its_origin() {
    let mut fixture = Fixture::new();
    commit(&fixture.source, "big.txt", &"x".repeat(10_000));
    sh(&fixture.source, &["config", "uploadpack.allowFilter", "true"]);
    let mirror = fixture.root.path().join("mirror.git");
    let origin = format!("file://{}", fixture.source.display());
    sh(
        fixture.root.path(),
        &["clone", "--quiet", "--bare", "--filter=blob:none", &origin, mirror.to_str().unwrap()],
    );
    sh(&mirror, &["config", "remote.origin.promisor", "true"]);
    let tip = sh(&fixture.source, &["rev-parse", "HEAD"]);
    fixture.source = mirror;
    let Published::Archive { commit: archived, .. } = fixture.publish() else { panic!() };
    assert_eq!(archived, tip);
    let (dir, fetched) = fixture.fetch("vm", None);
    assert_eq!(checked_out(&fetched), tip);
    assert_eq!(std::fs::read_to_string(dir.join("big.txt")).unwrap(), "x".repeat(10_000));
}
