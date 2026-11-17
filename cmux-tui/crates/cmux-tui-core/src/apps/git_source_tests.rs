//! Git source rules with no network: reference forms, the ref list, the
//! release choice, extraction limits, the id and engines rules. The fake
//! transport and fixture builders are shared with the supervisor tests
//! (`supervisor_git_tests.rs`).

use std::collections::HashMap;
use std::sync::Mutex;

use serde_json::{Value, json};

use super::*;

/// A transport answering from a URL map; everything else is a 404.
#[derive(Default)]
pub(crate) struct FakeGit {
    pub answers: Mutex<HashMap<String, (u16, Vec<u8>)>>,
    pub gets: Mutex<Vec<String>>,
    pub posts: Mutex<Vec<(String, Value)>>,
}

impl FakeGit {
    pub fn answer(&self, url: &str, status: u16, body: Vec<u8>) {
        self.answers.lock().unwrap().insert(url.to_string(), (status, body));
    }

    /// Serves `owner/repo` on github.com: `refs` (name, sha) and `HEAD`,
    /// and a tarball per commit.
    pub fn serve(
        &self,
        owner: &str,
        repo: &str,
        head: &str,
        refs: &[(&str, &str)],
        trees: &[(&str, Vec<u8>)],
    ) {
        let mut lines = vec![(head.to_string(), "HEAD".to_string())];
        lines.extend(refs.iter().map(|(name, sha)| (sha.to_string(), name.to_string())));
        let url =
            format!("https://github.com/{owner}/{repo}.git/info/refs?service=git-upload-pack");
        self.answer(&url, 200, pkt_lines(&lines));
        for (commit, tar) in trees {
            let url = format!("https://codeload.github.com/{owner}/{repo}/tar.gz/{commit}");
            self.answer(&url, 200, tar.clone());
        }
    }
}

impl GitTransport for FakeGit {
    fn get(&self, url: &str, _accept: &str, limit: u64) -> Result<(u16, Vec<u8>), String> {
        self.gets.lock().unwrap().push(url.to_string());
        let answer = self.answers.lock().unwrap().get(url).cloned().unwrap_or((404, Vec::new()));
        if answer.1.len() as u64 > limit {
            return Err(format!("{url}: larger than the limit"));
        }
        Ok(answer)
    }

    fn git_archive(&self, clone_url: &str, commit: &str, _limit: u64) -> Result<Vec<u8>, String> {
        self.get(&format!("git:{clone_url}#{commit}"), "", u64::MAX).and_then(|(status, body)| {
            if status == 200 { Ok(body) } else { Err("git: not found".into()) }
        })
    }

    fn post_json(&self, url: &str, body: &Value) -> Result<(), String> {
        self.posts.lock().unwrap().push((url.to_string(), body.clone()));
        Ok(())
    }
}

/// A smart-HTTP ref advertisement.
pub(crate) fn pkt_lines(refs: &[(String, String)]) -> Vec<u8> {
    let pkt = |text: &str| format!("{:04x}{text}", text.len() + 4);
    let mut out = pkt("# service=git-upload-pack\n");
    out.push_str("0000");
    for (i, (sha, name)) in refs.iter().enumerate() {
        let caps = if i == 0 { "\0multi_ack symref=HEAD:refs/heads/main" } else { "" };
        out.push_str(&pkt(&format!("{sha} {name}{caps}\n")));
    }
    out.push_str("0000");
    out.into_bytes()
}

/// A gzipped tar with every file under `top/`.
pub(crate) fn tarball(top: &str, files: &[(&str, &str)]) -> Vec<u8> {
    let mut builder = tar::Builder::new(Vec::new());
    for (name, body) in files {
        let mut header = tar::Header::new_gnu();
        header.set_size(body.len() as u64);
        header.set_mode(0o644);
        header.set_entry_type(tar::EntryType::Regular);
        let path = if top.is_empty() { name.to_string() } else { format!("{top}/{name}") };
        builder.append_data(&mut header, path, body.as_bytes()).unwrap();
    }
    let tar = builder.into_inner().unwrap();
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    std::io::Write::write_all(&mut gz, &tar).unwrap();
    gz.finish().unwrap()
}

/// A tar entry whose name is written raw (no path checks), for hostile archives.
fn raw_tar(entries: &[(&[u8], tar::EntryType, &str)]) -> Vec<u8> {
    let mut builder = tar::Builder::new(Vec::new());
    for (name, kind, body) in entries {
        let mut header = tar::Header::new_old();
        header.as_old_mut().name[..name.len()].copy_from_slice(name);
        header.set_size(body.len() as u64);
        header.set_mode(0o644);
        header.set_entry_type(*kind);
        if *kind == tar::EntryType::Symlink {
            header.set_link_name("/etc/passwd").unwrap();
        }
        header.set_cksum();
        builder.append(&header, body.as_bytes()).unwrap();
    }
    builder.into_inner().unwrap()
}

/// A valid v2 manifest of `id` asking for `scopes`.
pub(crate) fn manifest(id: &str, version: &str, scopes: Value) -> String {
    json!({
        "manifestVersion": 2, "id": id, "name": "Hello", "version": version,
        "description": "Says hello", "engines": {"cmux": "^2.0"},
        "repository": format!("https://github.com/{}/hello", id.split('/').next().unwrap_or_default()),
        "runtime": {"main": "main.js"}, "files": ["main.js"], "scopes": scopes,
        "implements": {"cmux.section/1": {"export": "render", "title": "Hello"}}
    })
    .to_string()
}

pub(crate) const MAIN_JS: &str = "var __cmuxAppExports = {render() {}};";

/// A repository tarball holding one app at its root.
pub(crate) fn app_tarball(id: &str, version: &str, scopes: Value) -> Vec<u8> {
    tarball(
        "hello-abc",
        &[
            ("cmux-app.json", &manifest(id, version, scopes)),
            ("main.js", MAIN_JS),
            ("README.md", "# Hello"),
        ],
    )
}

fn temp(name: &str) -> PathBuf {
    let mut bytes = [0u8; 6];
    getrandom::fill(&mut bytes).unwrap();
    let dir = std::env::temp_dir().join(format!("cmux-git-{name}-{}", hex(&bytes)));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const T: &str = "cccccccccccccccccccccccccccccccccccccccc";

#[test]
fn references_parse_in_every_accepted_form_and_refuse_the_rest() {
    let parsed = |text: &str| RepoRef::parse(text).map(|r| (r.canonical(), r.git_ref));
    assert_eq!(parsed("github.com/Octo/hello"), Ok(("github.com/Octo/hello".into(), None)));
    assert_eq!(
        parsed("https://github.com/octo/hello.git"),
        Ok(("github.com/octo/hello".into(), None))
    );
    assert_eq!(
        parsed("github.com/octo/hello@v1.2.0"),
        Ok(("github.com/octo/hello".into(), Some("v1.2.0".into())))
    );
    assert_eq!(
        parsed("https://github.com/octo/tools/tree/main/apps/clock"),
        Ok(("github.com/octo/tools/apps/clock".into(), Some("main".into())))
    );
    assert_eq!(
        parsed("gitlab.com/octo/tools/-/tree/dev/clock"),
        Ok(("gitlab.com/octo/tools/clock".into(), Some("dev".into())))
    );
    assert_eq!(
        parsed("codeberg.org/octo/hello/sub@feature/x"),
        Ok(("codeberg.org/octo/hello/sub".into(), Some("feature/x".into())))
    );
    for bad in [
        "http://github.com/octo/hello",
        "git@github.com:octo/hello",
        "github.com/octo",
        "localhost/octo/hello",
        "127.0.0.1/octo/hello",
        "github.com/octo/hello/../x",
        "github.com/octo/hello/.git",
        "github.com/octo/hello@--upload-pack=x",
        "github.com/octo/hello@a..b",
        "github.com/oc to/hello",
    ] {
        assert!(RepoRef::parse(bad).is_err(), "{bad} parses");
    }
    assert!(RepoRef::looks_like("github.com/octo/hello"));
    assert!(!RepoRef::looks_like("octo/hello"));
    assert!(!RepoRef::looks_like("cmux/app-store"));
    let reference = RepoRef::parse("example.org/octo/hello").unwrap();
    assert_eq!(reference.archive_url(A), None, "any other host is fetched with git");
    assert_eq!(
        RepoRef::parse("gitlab.com/octo/hello").unwrap().archive_url(A).unwrap(),
        format!("https://gitlab.com/octo/hello/-/archive/{A}/hello-{A}.tar.gz")
    );
}

#[test]
fn the_ref_list_resolves_branches_tags_and_the_default_branch() {
    let refs = Refs::parse(&pkt_lines(&[
        (A.into(), "HEAD".into()),
        (A.into(), "refs/heads/main".into()),
        (B.into(), "refs/heads/dev".into()),
        (T.into(), "refs/tags/v1.0.0".into()),
        (B.into(), "refs/tags/v1.0.0^{}".into()),
        (A.into(), "refs/tags/0.9.0".into()),
    ]))
    .unwrap();
    assert_eq!(refs.resolve(None), Ok((A.into(), None)));
    assert_eq!(refs.resolve(Some("dev")), Ok((B.into(), None)));
    assert_eq!(
        refs.resolve(Some("v1.0.0")),
        Ok((B.into(), Some("v1.0.0".into()))),
        "annotated tags peel"
    );
    assert_eq!(refs.tag_objects.get("refs/tags/v1.0.0"), Some(&T.to_string()));
    assert_eq!(refs.resolve(Some(&A.to_uppercase())), Ok((A.into(), None)));
    assert!(refs.resolve(Some("nope")).is_err());
    assert_eq!(refs.newest_version_tag().as_deref(), Some("v1.0.0"));
    assert_eq!(refs.tag_at(A, "0.9.0").as_deref(), Some("0.9.0"));
    let dumb =
        Refs::parse(format!("{A}\trefs/heads/main\n{B}\trefs/tags/1.0.0\n").as_bytes()).unwrap();
    assert_eq!(dumb.commits.get("refs/tags/1.0.0"), Some(&B.to_string()));
}

#[test]
fn an_install_picks_the_latest_release_asset_then_a_version_tag_then_the_branch() {
    let git = FakeGit::default();
    let reference = RepoRef::parse("github.com/octo/hello").unwrap();
    let refs = Refs::parse(&pkt_lines(&[
        (A.into(), "HEAD".into()),
        (A.into(), "refs/heads/main".into()),
        (B.into(), "refs/tags/1.1.0".into()),
    ]))
    .unwrap();
    // No release: the newest version tag.
    let resolved = resolve(&git, &reference, &refs).unwrap();
    assert_eq!(
        (resolved.commit.as_str(), resolved.tag.as_deref(), resolved.asset),
        (B, Some("1.1.0"), None)
    );
    // A release with the built package: its asset, pinned with its digest.
    let release = json!({"tag_name": "1.1.0", "assets": [
        {"name": "cmux-app.v2.json", "browser_download_url": "https://example.com/m"},
        {"name": RELEASE_ASSET, "browser_download_url": "https://example.com/pkg", "digest": "sha256:ABC"}
    ]});
    git.answer(
        "https://api.github.com/repos/octo/hello/releases/latest",
        200,
        release.to_string().into_bytes(),
    );
    let resolved = resolve(&git, &reference, &refs).unwrap();
    assert_eq!(resolved.commit, B);
    assert_eq!(
        resolved.asset,
        Some(Asset { url: "https://example.com/pkg".into(), sha256: Some("abc".into()) })
    );
    // A branch is that branch's tree.
    let branch = RepoRef::parse("github.com/octo/hello@main").unwrap();
    assert_eq!(
        resolve(&git, &branch, &refs).unwrap(),
        Resolved { commit: A.into(), tag: None, asset: None }
    );
    // No tags at all: the default branch.
    let bare = Refs::parse(&pkt_lines(&[(A.into(), "HEAD".into())])).unwrap();
    let other = RepoRef::parse("codeberg.org/octo/hello").unwrap();
    assert_eq!(resolve(&git, &other, &bare).unwrap().commit, A);
    // An asset whose bytes do not match the release's digest is refused.
    git.answer("https://example.com/pkg", 200, b"not the package".to_vec());
    let asset = Asset { url: "https://example.com/pkg".into(), sha256: Some("00".into()) };
    assert!(download_asset(&git, &asset).unwrap_err().contains("sha256"));
}

#[test]
fn extraction_keeps_the_package_directory_and_its_digest_is_stable() {
    let tar = tarball(
        "tools-abc",
        &[
            ("README.md", "top"),
            ("apps/clock/cmux-app.json", "{}"),
            ("apps/clock/main.js", "x"),
            ("apps/other/x", "y"),
        ],
    );
    let (one, two) = (temp("one"), temp("two"));
    let first = extract(&tar, "apps/clock", &one).unwrap();
    let second = extract(&tar, "apps/clock", &two).unwrap();
    assert_eq!(first, second);
    assert!(one.join("cmux-app.json").is_file() && one.join("main.js").is_file());
    assert!(!one.join("README.md").exists() && !one.join("x").exists());
    assert!(extract(&tar, "apps/missing", &temp("three")).unwrap_err().contains("apps/missing"));
    // A release package with its files at the root.
    let root = temp("release");
    extract_release(&tarball("", &[("cmux-app.json", "{}"), ("main.js", "x")]), &root).unwrap();
    assert!(root.join("cmux-app.json").is_file());
    for dir in [one, two, root] {
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[test]
fn extraction_refuses_escapes_and_oversized_archives_and_skips_links() {
    let escape = raw_tar(&[(b"top/../../evil", tar::EntryType::Regular, "x")]);
    let dest = temp("escape");
    assert!(extract(&escape, "", &dest).unwrap_err().contains("leaves the archive"));
    assert!(!dest.parent().unwrap().join("evil").exists());
    let absolute = raw_tar(&[(b"/top/etc", tar::EntryType::Regular, "x")]);
    assert!(extract(&absolute, "", &temp("absolute")).is_err());
    let link = raw_tar(&[
        (b"top/link", tar::EntryType::Symlink, ""),
        (b"top/a.txt", tar::EntryType::Regular, "a"),
    ]);
    let linked = temp("link");
    extract(&link, "", &linked).unwrap();
    assert!(linked.join("a.txt").is_file());
    assert!(std::fs::symlink_metadata(linked.join("link")).is_err(), "symlinks are never written");
    let big = tarball("top", &[("a", "0123456789"), ("b", "0123456789")]);
    assert!(extract_with(&big, "", &temp("big"), true, 15).unwrap_err().contains("larger than"));
    let _ = std::fs::remove_dir_all(linked);
    let _ = std::fs::remove_dir_all(dest);
}

#[test]
fn a_repository_app_id_starts_with_its_owner() {
    assert_eq!(check_id("octo/hello", "Octo"), Ok(()));
    assert!(check_id("someone/hello", "octo").is_err());
    assert!(check_id("cmux/hello", "octo").is_err());
    assert!(check_id("manaflow-ai/hello", "octo").is_err());
    assert_eq!(check_id("cmux/hello", "manaflow-ai"), Ok(()));
    assert!(check_id("local/hello", "local").is_err());
}

#[test]
fn engines_refuse_a_newer_platform_or_release() {
    let with = |range: &str| json!({"engines": {"cmux": range}});
    assert_eq!(check_engines(&with("^2.0"), "0.0.0"), Ok(()));
    assert!(check_engines(&with("^3.0"), "0.0.0").unwrap_err().contains("needs a newer cmux"));
    assert!(check_engines(&with(">=2.1"), "0.0.0").is_err());
    assert_eq!(check_engines(&with(">=0.70.0"), "0.0.0"), Ok(()), "a dev build is not a release");
    assert_eq!(check_engines(&with(">=0.70.0"), "0.71.2"), Ok(()));
    assert!(
        check_engines(&with(">=0.70.0"), "0.69.9").unwrap_err().contains("requires cmux >=0.70.0")
    );
    assert_eq!(check_engines(&with("whatever"), "0.1.0"), Ok(()));
    assert_eq!(check_engines(&json!({}), "0.1.0"), Ok(()));
}
