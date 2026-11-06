//! Git-distributed modules (the module store): source, pin, tree digest,
//! install review, approval, update decisions and the git plans. Threat model:
//! plans/cmux-next/module-store-threat-model.md.

use cmux_app_manifest::module_store::{
    Approval, FileInput, GitSource, InstallPreview, MAX_FILE_BYTES, MAX_FILES, ModuleKind, Pin,
    TreeDigest, UpdateDecision, check_installed, decide_update, fetch_plan, is_public_host,
    ls_remote_plan, ls_tree_plan, parse_install_spec, parse_ls_remote, parse_ls_tree,
    review_install, validate_module_path,
};
use cmux_app_manifest::{ScopeClass, is_valid, validate_manifest};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

const SHA_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SHA_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const SHA_C: &str = "cccccccccccccccccccccccccccccccccccccccc";

fn gh() -> GitSource {
    GitSource::parse("https://github.com/acme/gmail").expect("source")
}

fn file<'a>(path: &'a str, bytes: &'a [u8]) -> FileInput<'a> {
    FileInput { path, executable: false, bytes }
}

fn digest(files: &[FileInput<'_>]) -> String {
    TreeDigest::from_files(files).expect("digest").digest().to_string()
}

/// A tree with the manifest file, `index.html` and any extra files.
fn tree(manifest: &Value, index: &[u8], extra: &[(&str, &[u8])]) -> TreeDigest {
    let raw = serde_json::to_vec(manifest).expect("json");
    let mut files = vec![file("cmux-app.json", &raw), file("index.html", index)];
    files.extend(extra.iter().map(|(p, b)| file(p, b)));
    TreeDigest::from_files(&files).expect("tree")
}

fn web_manifest() -> Value {
    json!({
        "manifestVersion": 2,
        "id": "acme/gmail",
        "name": "Gmail",
        "version": "1.0.0",
        "description": "Gmail in a tab",
        "repository": "https://github.com/acme/gmail",
        "engines": { "cmux": "^2.0" },
        "presentation": {
            "tab": true,
            "web": {
                "url": "https://mail.google.com/mail/u/0/",
                "origins": ["https://accounts.google.com"]
            }
        }
    })
}

fn offline_manifest() -> Value {
    json!({
        "manifestVersion": 2,
        "id": "acme/notes",
        "name": "Notes",
        "version": "0.1.0",
        "description": "An offline notes tab",
        "repository": "https://github.com/acme/notes",
        "engines": { "cmux": "^2.0" },
        "runtime": { "web": { "root": "web" } },
        "implements": { "cmux.pane/1": { "web": "web/index.html" } },
        "presentation": { "tab": true }
    })
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-module-store-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

fn has_config(args: &[String], pair: &str) -> bool {
    args.windows(2).any(|w| w[0] == "-c" && w[1] == pair)
}

fn has_env(env: &[(String, String)], key: &str, value: &str) -> bool {
    env.iter().any(|(k, v)| k == key && v == value)
}

// ---- source -------------------------------------------------------------

#[test]
fn module_store_accepts_https_and_ssh_forms_from_any_public_forge() {
    for input in [
        "https://github.com/acme/gmail",
        "https://github.com/acme/gmail.git",
        "https://gitlab.com/acme/platform/gmail",
        "https://codeberg.org/acme/gmail/",
        "https://git.example.org/acme/gmail",
        "git@github.com:acme/gmail.git",
        "ssh://git@gitlab.com/acme/gmail.git",
        "https://GitHub.com/Acme/Gmail",
    ] {
        GitSource::parse(input).unwrap_or_else(|e| panic!("{input} refused: {e}"));
    }
    let https = GitSource::parse("https://GitHub.com/Acme/Gmail.git").expect("https");
    assert_eq!(https.key(), "github.com/acme/gmail");
    assert_eq!(https.owner(), "acme");
    assert_eq!(https.display_url(), "https://github.com/Acme/Gmail");
    assert!(https.is_known_forge());
    let scp = GitSource::parse("git@github.com:acme/gmail.git").expect("scp");
    assert_eq!(scp.key(), https.key(), "ssh and https name the same module");
    assert_eq!(scp.clone_url(), "ssh://git@github.com/acme/gmail");
    assert_eq!(https.clone_url(), "https://github.com/Acme/Gmail");
    let subgroup = GitSource::parse("https://gitlab.com/acme/platform/gmail").expect("subgroup");
    assert_eq!(subgroup.key(), "gitlab.com/acme/platform/gmail");
    assert!(
        !GitSource::parse("https://git.example.org/acme/gmail").expect("other").is_known_forge()
    );
}

#[test]
fn module_store_rejects_unsafe_transports_and_option_smuggling() {
    for input in [
        "http://github.com/acme/gmail",
        "git://github.com/acme/gmail",
        "file:///Users/someone/repo",
        "ext::sh -c touch% /tmp/x",
        "/Users/lawrence/repo",
        "./repo",
        "ftp://github.com/acme/gmail",
        "javascript:alert(1)",
        "github.com/acme/gmail",
        "-oProxyCommand=x@github.com:acme/gmail",
        "ssh://evil@github.com/acme/gmail",
        "git@github.com/acme/gmail",
    ] {
        assert!(GitSource::parse(input).is_err(), "{input} must be refused");
    }
}

#[test]
fn module_store_rejects_credentials_ports_queries_and_encodings() {
    for input in [
        "https://user:secret@github.com/acme/gmail",
        "https://github.com:443/acme/gmail",
        "https://github.com/acme/gmail?x=1",
        "https://github.com/acme/gmail#frag",
        "https://github.com/acme%2Fgmail",
        "https://github.com/acme/gmail with space",
        "https://github.com/acme/gmail\u{0}",
        "https://github.com\\acme\\gmail",
    ] {
        assert!(GitSource::parse(input).is_err(), "{input} must be refused");
    }
}

#[test]
fn module_store_rejects_private_bare_and_ip_hosts() {
    for input in [
        "https://localhost/acme/gmail",
        "https://127.0.0.1/acme/gmail",
        "https://10.0.0.5/acme/gmail",
        "https://192.168.1.10/acme/gmail",
        "https://[::1]/acme/gmail",
        "https://mini.local/acme/gmail",
        "https://cmux-lawrences-mac-mini/acme/gmail",
        "https://git.corp.internal/acme/gmail",
        "https://gitlab.lan/acme/gmail",
        "https://printer.home.arpa/acme/gmail",
        "https://evil.test/acme/gmail",
    ] {
        assert!(GitSource::parse(input).is_err(), "{input} must be refused");
    }
    assert!(is_public_host("github.com"));
    assert!(is_public_host("api.example.org"));
    assert!(!is_public_host("localhost"));
    assert!(!is_public_host("fileserver"));
}

#[test]
fn module_store_requires_owner_and_repo_path_segments() {
    for input in [
        "https://github.com/acme",
        "https://github.com/",
        "https://github.com/acme/..",
        "https://github.com/acme/./gmail",
        "https://github.com/acme//gmail",
        "https://github.com/-acme/gmail",
        "https://github.com/acme/.hidden",
    ] {
        assert!(GitSource::parse(input).is_err(), "{input} must be refused");
    }
}

// ---- pin ----------------------------------------------------------------

#[test]
fn module_store_pin_is_a_full_commit_or_a_tag() {
    assert_eq!(Pin::parse(SHA_A).expect("sha1"), Pin::Commit(SHA_A.to_string()));
    let sha256 = "f".repeat(64);
    assert_eq!(Pin::parse(&sha256).expect("sha256"), Pin::Commit(sha256));
    assert_eq!(Pin::parse("v1.2.0").expect("tag"), Pin::Tag("v1.2.0".to_string()));
    assert_eq!(
        Pin::parse("release/2026.10").expect("nested tag"),
        Pin::Tag("release/2026.10".to_string())
    );
    // Syntax only: a branch named like this is refused later, when no tag resolves.
    assert_eq!(Pin::parse("main").expect("name"), Pin::Tag("main".to_string()));
    const UPPER40: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    for bad in [
        "",
        "abc1234",
        UPPER40,
        "-x",
        "a..b",
        "a//b",
        "x.lock",
        "x/",
        "v1@{0}",
        "HEAD",
        "has space",
    ] {
        assert!(Pin::parse(bad).is_err(), "{bad:?} must be refused");
    }
}

#[test]
fn module_store_install_spec_splits_source_and_pin() {
    let (source, pin) =
        parse_install_spec(&format!("https://github.com/acme/gmail#{SHA_A}")).expect("spec");
    assert_eq!(source.key(), "github.com/acme/gmail");
    assert_eq!(pin, Pin::Commit(SHA_A.to_string()));
    assert_eq!(
        parse_install_spec("https://github.com/acme/gmail").unwrap_err().code,
        "pin.required",
        "no pin, no install: a branch is never installed"
    );
    assert!(parse_install_spec("https://github.com/acme/gmail#v1#v2").is_err());
}

// ---- tree digest --------------------------------------------------------

#[test]
fn module_store_digest_is_order_independent_and_sha256_shaped() {
    let a = TreeDigest::from_files(&[file("a.js", b"1"), file("b/c.html", b"2")]).expect("a");
    let b = TreeDigest::from_files(&[file("b/c.html", b"2"), file("a.js", b"1")]).expect("b");
    assert_eq!(a.digest(), b.digest());
    assert!(a.digest().starts_with("sha256:"));
    assert_eq!(a.digest().len(), "sha256:".len() + 64);
    assert_eq!(a.files().len(), 2);
    assert!(a.has_file("b/c.html"));
    assert!(!a.has_file("missing.js"));
}

#[test]
fn module_store_digest_changes_with_bytes_mode_and_path() {
    let base = digest(&[file("a.js", b"1")]);
    assert_ne!(base, digest(&[file("a.js", b"2")]), "bytes");
    assert_ne!(base, digest(&[FileInput { path: "a.js", executable: true, bytes: b"1" }]), "mode");
    assert_ne!(base, digest(&[file("c.js", b"1")]), "path");
}

#[test]
fn module_store_digest_rejects_unsafe_and_confusable_paths() {
    for bad in [
        "../x.js",
        "/abs.js",
        "a//b.js",
        "a/./b.js",
        "a/../b.js",
        ".git/config",
        "a/.git/hooks/post-checkout",
        "A/.GIT/x",
        "a\\b.js",
        "a b.js",
        "\u{fc}n\u{ef}.js",
        "tab\tname",
        "trailing/",
        "",
        "nul\u{0}.js",
        "-dash.js",
        "a/-x.js",
    ] {
        assert!(validate_module_path(bad).is_err(), "{bad:?} must be refused");
        assert!(TreeDigest::from_files(&[file(bad, b"x")]).is_err(), "{bad:?} must not digest");
    }
    assert!(validate_module_path("web/index.html").is_ok());
    assert!(validate_module_path("assets/icon-2x.png").is_ok());
    // Case-only collisions are one file on macOS and Windows.
    assert!(TreeDigest::from_files(&[file("A.js", b"1"), file("a.js", b"2")]).is_err());
    assert!(TreeDigest::from_files(&[file("Readme", b"1"), file("readme", b"2")]).is_err());
}

#[test]
fn module_store_digest_enforces_count_and_size_limits() {
    let names: Vec<String> = (0..=MAX_FILES).map(|i| format!("f{i}.js")).collect();
    let inputs: Vec<FileInput<'_>> = names.iter().map(|n| file(n, b"x")).collect();
    assert!(TreeDigest::from_files(&inputs).is_err(), "more than {MAX_FILES} files");
    let big = vec![0u8; (MAX_FILE_BYTES + 1) as usize];
    assert!(TreeDigest::from_files(&[file("big.bin", &big)]).is_err(), "one file too big");
}

#[test]
fn module_store_digest_from_dir_matches_memory_and_refuses_symlinks() {
    let dir = scratch("dir-digest");
    std::fs::create_dir_all(dir.join("sub")).expect("sub");
    std::fs::write(dir.join("cmux-app.json"), b"{}").expect("manifest");
    std::fs::write(dir.join("sub/page.html"), b"<p>").expect("page");
    let from_disk = TreeDigest::from_dir(&dir).expect("from dir");
    let in_memory =
        TreeDigest::from_files(&[file("cmux-app.json", b"{}"), file("sub/page.html", b"<p>")])
            .expect("memory");
    assert_eq!(from_disk.digest(), in_memory.digest());

    #[cfg(unix)]
    {
        std::os::unix::fs::symlink("/etc/passwd", dir.join("leak")).expect("symlink");
        assert_eq!(
            TreeDigest::from_dir(&dir).unwrap_err().code,
            "tree.symlink",
            "a symlink can point outside the module"
        );
        std::fs::remove_file(dir.join("leak")).expect("unlink");
        std::fs::create_dir_all(dir.join(".git")).expect("git dir");
        assert!(TreeDigest::from_dir(&dir).is_err(), "a .git directory is refused");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

// ---- install review -----------------------------------------------------

#[test]
fn module_store_review_accepts_a_web_tab_and_lists_its_origins() {
    let m = web_manifest();
    let t = tree(&m, b"<html></html>", &[]);
    let p = review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_A, &t).expect("review");
    assert_eq!(p.id, "acme/gmail");
    assert_eq!(p.kind, ModuleKind::Web);
    assert_eq!(p.origins, vec!["https://mail.google.com", "https://accounts.google.com"]);
    assert_eq!(p.resolved_commit, SHA_A);
    assert_eq!(p.digest, t.digest());
    assert!(p.scopes.is_empty());
    assert!(p.warnings.iter().any(|w| w.code == "origins.network"));
}

#[test]
fn module_store_review_accepts_an_offline_tab_with_no_origins() {
    let m = offline_manifest();
    let t = tree(&m, b"<html></html>", &[("web/index.html", b"<p>")]);
    let p = review_install(&m, &gh(), &Pin::Tag("v1.0.0".to_string()), SHA_A, &t)
        .expect("offline review");
    assert_eq!(p.kind, ModuleKind::Offline);
    assert!(p.origins.is_empty(), "no URL and no net scope: no network origin");
    assert_eq!(p.pin, Pin::Tag("v1.0.0".to_string()));
}

#[test]
fn module_store_review_refuses_a_module_that_is_not_a_tab() {
    let mut m = web_manifest();
    m["presentation"]["tab"] = json!(false);
    let t = tree(&m, b"<html></html>", &[]);
    let issues = review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_A, &t)
        .expect_err("not a tab");
    assert!(issues.iter().any(|i| i.code == "module.notATab"), "{issues:?}");
}

#[test]
fn module_store_review_refuses_code_and_power_fields_a_module_may_not_declare() {
    let cases = [
        ("runtime", json!({ "main": "main.js" })),
        ("handles", json!({ "root": "Read your project" })),
        ("requires", json!({ "platforms": ["macos"] })),
        ("contributes", json!({ "toolbarItems": [] })),
        ("activation", json!(["onStartup"])),
        ("optionalScopes", json!({ "net:api.example.com": "Load data" })),
        ("drag", json!({ "provides": ["url"] })),
        ("settings", json!({ "type": "object", "properties": {} })),
    ];
    for (key, value) in cases {
        let mut m = web_manifest();
        m[key] = value;
        assert!(
            is_valid(&validate_manifest(&m)),
            "{key} must be schema-valid so the rule is what refuses it"
        );
        let t = tree(&m, b"<html></html>", &[]);
        let issues =
            review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_A, &t).expect_err(key);
        assert!(issues.iter().any(|i| i.code == "module.notAllowed"), "{key}: {issues:?}");
    }
    // A pane implementation other than a web page (native or JS export) is refused too.
    let mut m = offline_manifest();
    m["implements"] = json!({ "cmux.pane/1": { "export": "main" } });
    let t = tree(&m, b"<html></html>", &[]);
    let issues =
        review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_A, &t).expect_err("export");
    assert!(issues.iter().any(|i| i.code == "module.notAllowed"), "{issues:?}");
}

#[test]
fn module_store_review_allows_only_the_v1_scope_list() {
    for scope in
        ["fs:read", "actions:run", "terminal:backend", "sidebar_layout:write", "project:read"]
    {
        let mut m = web_manifest();
        m["scopes"] = json!({ scope: "why" });
        let t = tree(&m, b"<html></html>", &[]);
        let issues =
            review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_A, &t).expect_err(scope);
        assert!(issues.iter().any(|i| i.code == "scope.notAllowed"), "{scope}: {issues:?}");
    }
    let mut m = web_manifest();
    m["scopes"] = json!({
        "storage:local": "Remember your settings",
        "net:api.example.com": "Load your inbox"
    });
    let t = tree(&m, b"<html></html>", &[]);
    let p = review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_A, &t)
        .expect("allowed scopes");
    let class_of = |s: &str| p.scopes.iter().find(|g| g.scope == s).map(|g| g.class);
    assert_eq!(class_of("storage:local"), Some(ScopeClass::Standard));
    assert_eq!(class_of("net:api.example.com"), Some(ScopeClass::Sensitive));
    assert!(
        p.origins.contains(&"https://api.example.com".to_string()),
        "a net scope is a declared origin the user sees"
    );
}

#[test]
fn module_store_review_rejects_wildcard_and_unsafe_origins() {
    let mut m = web_manifest();
    m["presentation"]["web"]["origins"] = json!(["https://*.googleusercontent.com"]);
    let t = tree(&m, b"<html></html>", &[]);
    let issues = review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_A, &t)
        .expect_err("wildcard origin");
    assert!(issues.iter().any(|i| i.code == "origin.wildcard"), "{issues:?}");

    let mut m = web_manifest();
    m["presentation"]["web"]["url"] = json!("https://localhost/app");
    let t = tree(&m, b"<html></html>", &[]);
    let issues = review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_A, &t)
        .expect_err("private origin");
    assert!(issues.iter().any(|i| i.code == "origin.host"), "{issues:?}");

    let mut m = web_manifest();
    m["scopes"] = json!({ "net:*.example.com": "anything" });
    let t = tree(&m, b"<html></html>", &[]);
    assert!(review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_A, &t).is_err());
}

#[test]
fn module_store_review_binds_the_publisher_to_the_repository_owner() {
    let mut m = web_manifest();
    m["id"] = json!("other/gmail");
    let t = tree(&m, b"<html></html>", &[]);
    let issues = review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_A, &t)
        .expect_err("impostor");
    assert!(issues.iter().any(|i| i.code == "identity.publisherMismatch"), "{issues:?}");

    let mut m = web_manifest();
    m["id"] = json!("cmux/gmail");
    let source = GitSource::parse("https://github.com/cmux/gmail").expect("source");
    let t = tree(&m, b"<html></html>", &[]);
    let issues = review_install(&m, &source, &Pin::Commit(SHA_A.to_string()), SHA_A, &t)
        .expect_err("reserved");
    assert!(issues.iter().any(|i| i.code == "identity.reserved"), "{issues:?}");
}

#[test]
fn module_store_review_requires_the_manifest_inside_the_tree() {
    let m = web_manifest();
    let no_manifest = TreeDigest::from_files(&[file("index.html", b"<p>")]).expect("tree");
    let issues = review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_A, &no_manifest)
        .expect_err("no manifest");
    assert!(issues.iter().any(|i| i.code == "manifest.missing"), "{issues:?}");
}

#[test]
fn module_store_review_pin_must_match_the_resolved_commit() {
    let m = web_manifest();
    let t = tree(&m, b"<p>", &[]);
    let issues =
        review_install(&m, &gh(), &Pin::Commit(SHA_A.to_string()), SHA_B, &t).expect_err("moved");
    assert!(issues.iter().any(|i| i.code == "pin.moved"), "{issues:?}");
    // A tag may resolve to any commit; the approval records which one.
    let p = review_install(&m, &gh(), &Pin::Tag("v1.0.0".to_string()), SHA_B, &t).expect("tag");
    assert_eq!(p.resolved_commit, SHA_B);
}

// ---- approval and integrity ---------------------------------------------

fn preview(
    manifest: &Value,
    source: &GitSource,
    pin: Pin,
    commit: &str,
    t: &TreeDigest,
) -> InstallPreview {
    review_install(manifest, source, &pin, commit, t).expect("review")
}

#[test]
fn module_store_approval_covers_only_the_reviewed_bytes() {
    let m = web_manifest();
    let t = tree(&m, b"<p>", &[]);
    let reviewed = preview(&m, &gh(), Pin::Tag("v1.0.0".to_string()), SHA_A, &t);
    let approval = Approval::for_preview(&reviewed);
    assert!(approval.covers(&reviewed).is_ok());

    let moved = preview(&m, &gh(), Pin::Tag("v1.0.0".to_string()), SHA_B, &t);
    assert_eq!(approval.covers(&moved).unwrap_err().code, "pin.moved", "the tag moved");

    let mut m2 = m.clone();
    m2["description"] = json!("changed after review");
    let t2 = tree(&m2, b"<p>", &[]);
    let changed = preview(&m2, &gh(), Pin::Tag("v1.0.0".to_string()), SHA_A, &t2);
    assert_eq!(approval.covers(&changed).unwrap_err().code, "digest.mismatch");

    let fork = GitSource::parse("https://github.com/acme/gmail-fork").expect("fork");
    let other = preview(&m, &fork, Pin::Tag("v1.0.0".to_string()), SHA_A, &t);
    assert_eq!(approval.covers(&other).unwrap_err().code, "source.changed");
}

#[test]
fn module_store_installed_bytes_that_changed_are_refused() {
    let m = web_manifest();
    let t = tree(&m, b"<p>", &[]);
    let recorded = t.digest().to_string();
    assert!(check_installed(&recorded, &t).is_ok());
    let edited = tree(&m, b"<p>tampered</p>", &[]);
    assert_eq!(check_installed(&recorded, &edited).unwrap_err().code, "digest.tampered");
}

// ---- updates ------------------------------------------------------------

#[test]
fn module_store_update_never_applies_silently() {
    let m = web_manifest();
    let t = tree(&m, b"<p>", &[]);
    let installed = preview(&m, &gh(), Pin::Tag("v1.0.0".to_string()), SHA_A, &t);
    let same = preview(&m, &gh(), Pin::Tag("v1.0.0".to_string()), SHA_A, &t);
    assert_eq!(decide_update(&installed, &same), UpdateDecision::UpToDate);

    // Same bytes under a new commit still asks: the pinned identity changed.
    let newer_commit = preview(&m, &gh(), Pin::Tag("v1.0.1".to_string()), SHA_B, &t);
    assert!(matches!(decide_update(&installed, &newer_commit), UpdateDecision::NeedsApproval(_)));

    let fork = GitSource::parse("https://github.com/acme/gmail-fork").expect("fork");
    let moved_repo = preview(&m, &fork, Pin::Tag("v1.0.0".to_string()), SHA_A, &t);
    match decide_update(&installed, &moved_repo) {
        UpdateDecision::Refused(r) => assert_eq!(r.code, "source.changed"),
        other => panic!("a moved repository must be refused, got {other:?}"),
    }

    let mut renamed = m;
    renamed["id"] = json!("acme/gmail2");
    let t3 = tree(&renamed, b"<p>", &[]);
    let other_id = preview(&renamed, &gh(), Pin::Tag("v2.0.0".to_string()), SHA_C, &t3);
    match decide_update(&installed, &other_id) {
        UpdateDecision::Refused(r) => assert_eq!(r.code, "identity.changed"),
        other => panic!("a changed id must be refused, got {other:?}"),
    }
}

#[test]
fn module_store_update_review_lists_what_changed() {
    let m = web_manifest();
    let t = tree(&m, b"<p>", &[]);
    let installed = preview(&m, &gh(), Pin::Tag("v1.0.0".to_string()), SHA_A, &t);

    let mut next = m;
    next["version"] = json!("1.1.0");
    next["scopes"] = json!({ "net:api.example.com": "Sync" });
    next["presentation"]["web"]["origins"] =
        json!(["https://accounts.google.com", "https://cdn.example.org"]);
    let t2 = tree(&next, b"<p>v2</p>", &[("new.js", b"x")]);
    let upgrade = preview(&next, &gh(), Pin::Tag("v1.1.0".to_string()), SHA_B, &t2);

    match decide_update(&installed, &upgrade) {
        UpdateDecision::NeedsApproval(r) => {
            assert_eq!(r.from_version, "1.0.0");
            assert_eq!(r.to_version, "1.1.0");
            assert_eq!(r.added_origins, vec!["https://cdn.example.org", "https://api.example.com"]);
            assert_eq!(r.removed_origins, Vec::<String>::new());
            assert!(r.added_scopes.iter().any(|g| g.scope == "net:api.example.com"));
            assert_eq!(r.added_files, vec!["new.js"]);
            assert_eq!(r.removed_files, Vec::<String>::new());
            assert_eq!(r.changed_files, vec!["cmux-app.json", "index.html"]);
            assert!(!r.kind_changed);
        }
        other => panic!("expected an approval request, got {other:?}"),
    }
}

#[test]
fn module_store_update_flags_a_downgrade() {
    let mut newer = web_manifest();
    newer["version"] = json!("1.1.0");
    let t_new = tree(&newer, b"<p>", &[]);
    let installed = preview(&newer, &gh(), Pin::Tag("v1.1.0".to_string()), SHA_B, &t_new);
    let t_old = tree(&web_manifest(), b"<p>", &[]);
    let older = preview(&web_manifest(), &gh(), Pin::Tag("v1.0.0".to_string()), SHA_A, &t_old);
    match decide_update(&installed, &older) {
        UpdateDecision::NeedsApproval(r) => {
            assert!(r.warnings.iter().any(|w| w.code == "update.downgrade"), "{:?}", r.warnings);
        }
        other => panic!("a downgrade still needs approval, got {other:?}"),
    }
}

// ---- git plans ----------------------------------------------------------

#[test]
fn module_store_fetch_plans_refuse_config_prompts_and_option_injection() {
    let https = GitSource::parse("https://github.com/acme/gmail").expect("https");
    let plan = fetch_plan(&https, SHA_A, Path::new("/tmp/stage")).expect("plan");
    let sep = plan.args.iter().position(|a| a == "--").expect("-- before the url");
    assert_eq!(plan.args.get(sep + 1).map(String::as_str), Some("https://github.com/acme/gmail"));
    assert!(has_config(&plan.args, "protocol.allow=never"));
    assert!(has_config(&plan.args, "protocol.https.allow=always"));
    assert!(!has_config(&plan.args, "protocol.ssh.allow=always"));
    assert!(has_config(&plan.args, "core.hooksPath=/dev/null"));
    assert!(has_config(&plan.args, "credential.helper="), "no credential helper runs");
    assert!(has_config(&plan.args, "transfer.fsckObjects=true"));
    assert!(plan.args.iter().any(|a| a == "fetch"));
    assert!(has_env(&plan.env, "GIT_TERMINAL_PROMPT", "0"));
    assert!(has_env(&plan.env, "GIT_CONFIG_NOSYSTEM", "1"));
    assert!(has_env(&plan.env, "GIT_CONFIG_GLOBAL", "/dev/null"));

    let ssh = GitSource::parse("git@github.com:acme/gmail.git").expect("ssh");
    let plan = fetch_plan(&ssh, SHA_A, Path::new("/tmp/stage")).expect("ssh plan");
    assert!(has_config(&plan.args, "protocol.ssh.allow=always"));
    assert!(!has_config(&plan.args, "protocol.https.allow=always"));

    assert!(
        fetch_plan(&https, "--upload-pack=touch /tmp/x", Path::new("/tmp/stage")).is_err(),
        "a commit that is not a full SHA never reaches git"
    );
    assert!(ls_tree_plan(SHA_A, Path::new("/tmp/stage")).is_ok());
    assert!(ls_tree_plan("HEAD", Path::new("/tmp/stage")).is_err());
}

#[test]
fn module_store_ls_remote_plan_asks_for_the_tag_and_its_peeled_commit() {
    let src = GitSource::parse("https://github.com/acme/gmail").expect("src");
    let plan = ls_remote_plan(&src, &Pin::Tag("v1.0.0".to_string())).expect("tag plan");
    let sep = plan.args.iter().position(|a| a == "--").expect("--");
    assert_eq!(plan.args.get(sep + 1).map(String::as_str), Some("https://github.com/acme/gmail"));
    assert!(plan.args.iter().any(|a| a == "refs/tags/v1.0.0^{}"));
    assert!(
        ls_remote_plan(&src, &Pin::Commit(SHA_A.to_string())).is_none(),
        "a commit pin needs no lookup"
    );
}

#[test]
fn module_store_ls_remote_prefers_the_peeled_commit_of_an_annotated_tag() {
    let annotated = format!("{SHA_A}\trefs/tags/v1.0.0\n{SHA_B}\trefs/tags/v1.0.0^{{}}\n");
    assert_eq!(
        parse_ls_remote(&annotated, &Pin::Tag("v1.0.0".to_string())).expect("annotated"),
        SHA_B
    );
    let light = format!("{SHA_C}\trefs/tags/v2\n");
    assert_eq!(parse_ls_remote(&light, &Pin::Tag("v2".to_string())).expect("light"), SHA_C);
    let branch = format!("{SHA_A}\trefs/heads/main\n");
    assert_eq!(
        parse_ls_remote(&branch, &Pin::Tag("main".to_string())).unwrap_err().code,
        "pin.notFound",
        "a branch is never installed"
    );
    assert!(parse_ls_remote("garbage line", &Pin::Tag("v1".to_string())).is_err());
}

#[test]
fn module_store_ls_tree_accepts_only_regular_blobs() {
    let ok = format!("100644 blob {SHA_A}\tREADME.md\u{0}100755 blob {SHA_B}\tbin/run.sh\u{0}");
    let entries = parse_ls_tree(ok.as_bytes()).expect("blobs");
    assert_eq!(entries.len(), 2);
    assert!(!entries[0].executable);
    assert!(entries[1].executable);
    assert_eq!(entries[1].path, "bin/run.sh");

    let link = format!("120000 blob {SHA_A}\tlink\u{0}");
    assert_eq!(parse_ls_tree(link.as_bytes()).unwrap_err().code, "tree.symlink");
    let submodule = format!("160000 commit {SHA_A}\tvendor\u{0}");
    assert_eq!(parse_ls_tree(submodule.as_bytes()).unwrap_err().code, "tree.submodule");
    let odd_mode = format!("100664 blob {SHA_A}\tx\u{0}");
    assert_eq!(parse_ls_tree(odd_mode.as_bytes()).unwrap_err().code, "tree.mode");
    let escape = format!("100644 blob {SHA_A}\t../x\u{0}");
    assert!(parse_ls_tree(escape.as_bytes()).is_err());
    let bad_object = "100644 blob xyz\tx\u{0}";
    assert!(parse_ls_tree(bad_object.as_bytes()).is_err());
}
