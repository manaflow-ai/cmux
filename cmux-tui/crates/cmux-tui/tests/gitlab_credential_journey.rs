//! `cmux gitlab credential` end to end, with no network: a fake GitLab (git's
//! own smart-HTTP server, `git http-backend`, behind HTTP Basic auth on a
//! loopback port) holds a private repository. git clones it and pushes to it
//! through the helper, which reads the token the machine was given from
//! `~/.config/cmux/git-hosts/<host>`. Without the token, nothing is read.
#![cfg(target_os = "linux")]

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::{PermissionsExt as _, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;

const TOKEN: &str = "glpat-fake-journey-0000000000";
const REPO: &str = "group/private.git";

struct Dir(PathBuf);

impl Dir {
    fn new(label: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let path = std::env::temp_dir()
            .join(format!("cmux-gitlab-{label}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// The fake GitLab: every request must carry `oauth2:TOKEN`, else 401 with a
/// Basic challenge (what GitLab answers a private repository). An accepted
/// request runs `git http-backend` as CGI over `root`. One request per
/// connection; the thread ends with the test process.
fn serve(root: PathBuf) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let expected = format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(format!("oauth2:{TOKEN}"))
    );
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let _ = answer(stream, &root, &expected);
        }
    });
    port
}

fn answer(stream: TcpStream, root: &Path, expected: &str) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or("").to_owned();
    let target = parts.next().unwrap_or("").to_owned();
    let mut headers = Vec::new();
    loop {
        let mut header = String::new();
        reader.read_line(&mut header)?;
        let header = header.trim_end();
        if header.is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':') {
            headers.push((name.trim().to_ascii_lowercase(), value.trim().to_owned()));
        }
    }
    let header = |name: &str| {
        headers.iter().find(|(n, _)| n == name).map(|(_, v)| v.clone()).unwrap_or_default()
    };
    let mut body = Vec::new();
    if let Ok(length) = header("content-length").parse::<u64>() {
        reader.by_ref().take(length).read_to_end(&mut body)?;
    }
    let mut stream = stream;
    if header("authorization") != expected {
        return stream.write_all(
            b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"GitLab\"\r\n\
              Content-Length: 0\r\nConnection: close\r\n\r\n",
        );
    }
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));
    let mut child = Command::new("git")
        .arg("http-backend")
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_PROJECT_ROOT", root)
        .env("GIT_HTTP_EXPORT_ALL", "1")
        .env("REMOTE_USER", "oauth2")
        .env("REQUEST_METHOD", &method)
        .env("PATH_INFO", path)
        .env("QUERY_STRING", query)
        .env("CONTENT_TYPE", header("content-type"))
        .env("CONTENT_LENGTH", body.len().to_string())
        .env("HTTP_CONTENT_ENCODING", header("content-encoding"))
        .env("GIT_PROTOCOL", header("git-protocol"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    child.stdin.take().unwrap().write_all(&body)?;
    let out = child.wait_with_output()?.stdout;
    let split = out
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| (i, 4))
        .or_else(|| out.windows(2).position(|w| w == b"\n\n").map(|i| (i, 2)));
    let Some((at, gap)) = split else {
        return stream.write_all(b"HTTP/1.1 500 Bad CGI\r\nConnection: close\r\n\r\n");
    };
    let cgi = String::from_utf8_lossy(&out[..at]).into_owned();
    let mut status = "200 OK".to_owned();
    let mut response = String::new();
    for line in cgi.lines() {
        match line.split_once(':') {
            Some((name, value)) if name.eq_ignore_ascii_case("status") => {
                status = value.trim().to_owned();
            }
            Some(_) => response.push_str(&format!("{}\r\n", line.trim_end())),
            None => {}
        }
    }
    let rest = &out[at + gap..];
    stream.write_all(
        format!(
            "HTTP/1.1 {status}\r\n{response}Content-Length: {}\r\nConnection: close\r\n\r\n",
            rest.len()
        )
        .as_bytes(),
    )?;
    stream.write_all(rest)
}

/// `git ARGS` as the agent on the machine runs it: the person's config (the
/// test's), the helper the checkout or the command line names, no prompt.
fn agent_git(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new("git")
        .current_dir(cwd)
        .args(args)
        .env("HOME", home)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .output()
        .unwrap()
}

#[test]
fn a_private_gitlab_repo_clones_and_pushes_with_the_machine_token() {
    let dir = Dir::new("journey");
    let server = dir.0.join("gitlab");
    let bare = server.join(REPO);
    std::fs::create_dir_all(&bare).unwrap();
    git(&bare, &["init", "-q", "--bare", "-b", "main"]);
    git(&bare, &["config", "http.receivepack", "true"]);
    let seed = dir.0.join("seed");
    std::fs::create_dir_all(&seed).unwrap();
    git(&seed, &["init", "-q", "-b", "main"]);
    std::fs::write(seed.join("README"), "private\n").unwrap();
    git(&seed, &["add", "README"]);
    git(&seed, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "first"]);
    git(&seed, &["push", "-q", bare.to_str().unwrap(), "main"]);
    let port = serve(server);
    let authority = format!("127.0.0.1:{port}");
    let url = format!("http://{authority}/{REPO}");

    // The machine: `cmux` on PATH, its home with no token yet.
    let home = dir.0.join("home");
    let bin = dir.0.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    symlink(env!("CARGO_BIN_EXE_cmux-tui"), bin.join("cmux")).unwrap();
    let helper = format!(
        "credential.http://{authority}.helper=!'{}' gitlab credential",
        bin.join("cmux").display()
    );
    let work = home.join("work");
    std::fs::create_dir_all(&work).unwrap();

    let refused = agent_git(&home, &work, &["-c", &helper, "clone", "-q", &url, "nope"]);
    assert!(!refused.status.success(), "no token, no clone");
    let stderr = String::from_utf8_lossy(&refused.stderr);
    assert!(stderr.contains(&format!("no token for {authority}")), "{stderr}");

    // The token, as the daemon writes it (0600 under a 0700 folder).
    let tokens = home.join(".config/cmux/git-hosts");
    std::fs::create_dir_all(&tokens).unwrap();
    std::fs::set_permissions(&tokens, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::write(tokens.join(&authority), format!("{TOKEN}\n")).unwrap();
    std::fs::set_permissions(tokens.join(&authority), std::fs::Permissions::from_mode(0o600))
        .unwrap();

    let clone = agent_git(&home, &work, &["-c", &helper, "clone", "-q", &url, "private"]);
    assert!(clone.status.success(), "{}", String::from_utf8_lossy(&clone.stderr));
    let checkout = work.join("private");
    assert_eq!(std::fs::read_to_string(checkout.join("README")).unwrap(), "private\n");
    // The checkout keeps the helper, never the token: what the repo step writes.
    let key = format!("credential.http://{authority}.helper");
    let value = helper.split_once('=').unwrap().1;
    git(&checkout, &["config", "--local", &key, value]);
    let config = std::fs::read_to_string(checkout.join(".git/config")).unwrap();
    assert!(!config.contains(TOKEN), "the token is never written to the checkout");

    // The agent's own push, with nothing on its command line.
    std::fs::write(checkout.join("README"), "private\npushed from the machine\n").unwrap();
    git(&checkout, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-am", "push"]);
    let push = agent_git(&home, &checkout, &["push", "-q", "origin", "main"]);
    assert!(push.status.success(), "{}", String::from_utf8_lossy(&push.stderr));
    assert!(!String::from_utf8_lossy(&push.stderr).contains(TOKEN));
    assert_eq!(git(&bare, &["rev-parse", "main"]), git(&checkout, &["rev-parse", "HEAD"]));
}
