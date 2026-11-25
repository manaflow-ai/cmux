//! End to end with real git: a fake GitHub (`git upload-pack` behind Basic auth), the proxy
//! in front of it, and clones through the proxy. Proves a warm clone never reaches upstream's
//! upload-pack, and a caller upstream refuses gets nothing from the cache even when the
//! mirror holds every object it asks for.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use axum::Router;
use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use tokio::io::AsyncWriteExt;

const GOOD: &str = "Basic Z29vZDp0b2tlbg==";
const OTHER: &str = "Basic YmFkOnRva2Vu";

struct Fake {
    repo: PathBuf,
    /// Fetches (not ls-refs) upstream's upload-pack answered.
    upload_posts: AtomicU64,
}

fn git_cmd() -> std::process::Command {
    let mut cmd = std::process::Command::new("git");
    cmd.env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t");
    cmd
}

fn git_ok(dir: &Path, args: &[&str]) -> String {
    let out = git_cmd().arg("-C").arg(dir).args(args).output().unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

async fn fake(State(fake): State<Arc<Fake>>, req: Request) -> Response {
    let path = req.uri().path().to_owned();
    let v2 = req
        .headers()
        .get("git-protocol")
        .is_some_and(|v| v.to_str().unwrap_or("").contains("version=2"));
    if req.headers().get(header::AUTHORIZATION).map(|v| v.as_bytes()) != Some(GOOD.as_bytes()) {
        return (
            StatusCode::UNAUTHORIZED,
            [(header::WWW_AUTHENTICATE, "Basic realm=\"GitHub\"")],
            "",
        )
            .into_response();
    }
    let mut cmd = tokio::process::Command::new("git");
    cmd.env("GIT_CONFIG_GLOBAL", "/dev/null").env("GIT_CONFIG_NOSYSTEM", "1");
    if v2 {
        cmd.env("GIT_PROTOCOL", "version=2");
    }
    if path == "/o/r.git/info/refs" {
        let out = cmd
            .args(["upload-pack", "--stateless-rpc", "--advertise-refs"])
            .arg(&fake.repo)
            .output()
            .await
            .unwrap();
        let mut body = Vec::new();
        if !v2 {
            body.extend_from_slice(b"001e# service=git-upload-pack\n0000");
        }
        body.extend_from_slice(&out.stdout);
        return ([(header::CONTENT_TYPE, "application/x-git-upload-pack-advertisement")], body)
            .into_response();
    }
    if path == "/o/r.git/git-upload-pack" {
        let gzip = req.headers().get(header::CONTENT_ENCODING).is_some();
        let raw = axum::body::to_bytes(req.into_body(), 64 << 20).await.unwrap();
        let input = if gzip {
            use std::io::Read;
            let mut v = Vec::new();
            flate2::read::GzDecoder::new(&raw[..]).read_to_end(&mut v).unwrap();
            v
        } else {
            raw.to_vec()
        };
        if matches!(
            cmux_git_cache::pkt::classify(&input, v2),
            cmux_git_cache::pkt::Request::Fetch { .. }
        ) {
            fake.upload_posts.fetch_add(1, Ordering::SeqCst);
        }
        let mut child = cmd
            .args(["upload-pack", "--stateless-rpc"])
            .arg(&fake.repo)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(&input).await.unwrap();
        drop(stdin);
        let out = child.wait_with_output().await.unwrap();
        return (
            [(header::CONTENT_TYPE, "application/x-git-upload-pack-result")],
            Body::from(out.stdout),
        )
            .into_response();
    }
    StatusCode::NOT_FOUND.into_response()
}

async fn listen(router: Router) -> SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    addr
}

struct World {
    _tmp: tempfile::TempDir,
    tmp: PathBuf,
    fake: Arc<Fake>,
    proxy: SocketAddr,
    head: String,
}

async fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().to_owned();
    let work = root.join("work");
    std::fs::create_dir_all(&work).unwrap();
    git_ok(&work, &["init", "-q", "-b", "main"]);
    for i in 0..3 {
        std::fs::write(work.join(format!("f{i}")), format!("content {i}\n").repeat(100)).unwrap();
        git_ok(&work, &["add", "."]);
        git_ok(&work, &["commit", "-q", "-m", &format!("c{i}")]);
    }
    let head = git_ok(&work, &["rev-parse", "HEAD"]);
    let bare = root.join("upstream.git");
    git_ok(&root, &["clone", "-q", "--bare", work.to_str().unwrap(), bare.to_str().unwrap()]);
    let fake = Arc::new(Fake { repo: bare, upload_posts: AtomicU64::new(0) });
    let upstream = listen(Router::new().fallback(self::fake).with_state(fake.clone())).await;
    let mut cfg = cmux_git_cache::Config::new(root.join("cache"));
    cfg.upstream = format!("http://{upstream}");
    cfg.tenant = "team-a".to_owned();
    let state = cmux_git_cache::State::new(cfg).unwrap();
    let proxy = listen(cmux_git_cache::router(state)).await;
    World { _tmp: tmp, tmp: root, fake, proxy, head }
}

async fn clone(w: &World, name: &str, auth: Option<&str>, protocol: &str) -> bool {
    let url = format!("http://{}/github.com/o/r.git", w.proxy);
    let dest = w.tmp.join(name);
    let auth = auth.map(str::to_owned);
    let protocol = protocol.to_owned();
    tokio::task::spawn_blocking(move || {
        let mut cmd = git_cmd();
        cmd.args(["-c", &format!("protocol.version={protocol}")]);
        if let Some(a) = auth {
            cmd.args(["-c", &format!("http.extraHeader=Authorization: {a}")]);
        }
        cmd.args(["clone", "-q", &url]).arg(&dest).stderr(Stdio::null()).status().unwrap().success()
    })
    .await
    .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn warm_clone_is_local_and_denied_caller_gets_nothing() {
    for protocol in ["2", "0"] {
        let w = world().await;
        assert!(clone(&w, "a", Some(GOOD), protocol).await, "cold clone v{protocol}");
        assert_eq!(git_ok(&w.tmp.join("a"), &["rev-parse", "HEAD"]), w.head);
        let after_cold = w.fake.upload_posts.load(Ordering::SeqCst);
        assert!(after_cold >= 1, "the cold clone filled the mirror from upstream");

        assert!(clone(&w, "b", Some(GOOD), protocol).await, "warm clone v{protocol}");
        assert_eq!(git_ok(&w.tmp.join("b"), &["rev-parse", "HEAD"]), w.head);
        assert_eq!(
            w.fake.upload_posts.load(Ordering::SeqCst),
            after_cold,
            "warm clone v{protocol} reached upstream's upload-pack"
        );

        // The mirror holds every object; a caller upstream refuses still gets nothing.
        assert!(
            !clone(&w, "c", Some(OTHER), protocol).await,
            "a refused caller cloned v{protocol}"
        );
        assert!(!clone(&w, "d", None, protocol).await, "an anonymous caller cloned v{protocol}");
        assert!(!w.tmp.join("c/f0").exists() && !w.tmp.join("d/f0").exists());
    }
}

/// A raw fetch for an object the mirror has, straight at upload-pack (no ref advertisement
/// first, so no grant): the refused caller gets upstream's 401 and no pack.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn raw_fetch_without_access_gets_no_pack() {
    let w = world().await;
    assert!(clone(&w, "a", Some(GOOD), "2").await);
    let body = format!(
        "{}{}0001{}{}{}0000",
        cmux_git_cache::pkt::encode("command=fetch\n"),
        cmux_git_cache::pkt::encode("object-format=sha1\n"),
        cmux_git_cache::pkt::encode("no-progress\n"),
        cmux_git_cache::pkt::encode(&format!("want {}\n", w.head)),
        cmux_git_cache::pkt::encode("done\n"),
    );
    let client = reqwest::Client::new();
    let url = format!("http://{}/github.com/o/r.git/git-upload-pack", w.proxy);
    for auth in [Some(OTHER), None] {
        let mut req = client
            .post(&url)
            .header("git-protocol", "version=2")
            .header("content-type", "application/x-git-upload-pack-request")
            .body(body.clone());
        if let Some(a) = auth {
            req = req.header("authorization", a);
        }
        let resp = req.send().await.unwrap();
        assert_eq!(resp.status().as_u16(), 401);
        let bytes = resp.bytes().await.unwrap();
        assert!(!bytes.windows(4).any(|w| w == b"PACK"), "a refused caller got a pack");
    }
    // The allowed caller, the same request: served from the mirror (a pack, no new upstream fetch).
    let before = w.fake.upload_posts.load(Ordering::SeqCst);
    let resp = client
        .post(&url)
        .header("git-protocol", "version=2")
        .header("authorization", GOOD)
        .body(body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status().as_u16(), 200);
    let bytes = resp.bytes().await.unwrap();
    assert!(bytes.windows(4).any(|w| w == b"PACK"));
    assert_eq!(w.fake.upload_posts.load(Ordering::SeqCst), before);
}

/// pushInsteadOf keeps a push on its own URL while fetches go to the proxy.
#[test]
fn include_rewrites_fetch_and_keeps_push() {
    let tmp = tempfile::tempdir().unwrap();
    let inc = tmp.path().join("inc");
    cmux_git_cache::gitconfig::write_include(
        &inc,
        &cmux_git_cache::gitconfig::include_text(4000, "!true"),
    )
    .unwrap();
    let repo = tmp.path().join("r");
    git_ok(tmp.path(), &["init", "-q", repo.to_str().unwrap()]);
    git_ok(&repo, &["config", "include.path", inc.to_str().unwrap()]);
    for (url, path) in [
        ("https://github.com/o/r.git", "o/r.git"),
        ("git@github.com:o/r.git", "o/r.git"),
        ("ssh://git@github.com/o/r.git", "o/r.git"),
    ] {
        git_ok(&repo, &["remote", "add", &format!("x{}", path.len() + url.len()), url]);
        let name = format!("x{}", path.len() + url.len());
        assert_eq!(
            git_ok(&repo, &["remote", "get-url", &name]),
            format!("http://127.0.0.1:4000/github.com/{path}")
        );
        assert_eq!(git_ok(&repo, &["remote", "get-url", "--push", &name]), url);
    }
    // Other hosts are untouched.
    git_ok(&repo, &["remote", "add", "gl", "https://gitlab.com/o/r.git"]);
    assert_eq!(git_ok(&repo, &["remote", "get-url", "gl"]), "https://gitlab.com/o/r.git");
}
