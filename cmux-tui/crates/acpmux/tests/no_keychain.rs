//! acpmux never asks the login keychain on its own (cx-hh0vu, cx-f4thx).
//! A tagged acpmux (cmux DEV sbp5d-v1) left a SecurityAgent keychain dialog
//! on a GUI test host after it died, and Lawrence saw "acpmux wants to use
//! your confidential information stored in "com.cmuxterm.coderouter"" for
//! every differently signed build. Rule (chief): a tagged, DEV or ad hoc
//! signed acpmux never touches the login keychain on its own; only an
//! explicit user action through the signed app may.
//!
//! Boundary: a dylib, built here with `cc` and loaded with
//! `DYLD_INSERT_LIBRARIES`, interposes the Security framework's keychain
//! item and keychain calls and the process spawn calls (`posix_spawn`,
//! `posix_spawnp`, `execve`, `execv`, `execvp`), and writes each one to a
//! log. It sees every call acpmux and its crates make (calls inside the
//! framework itself are not interposed), in every acpmux process that keeps
//! the variable (the daemon, its router, its agent hosts). The test fails on
//! any keychain call and on any `security` program start. A control program
//! proves the dylib records a keychain call and a spawn, so an empty log
//! means no call, not a dylib that never loaded.
//!
//! Covered: `acpmux router serve` (start, key mint, stop), and the daemon
//! with the app's settings (local router on, the login shell read, the agent
//! CLI health check with a Claude and a Codex CLI, whose sign-in checks used
//! to run `security` and `codex login status` with a keychain login) up to a
//! chat with a stand-in agent, then a second start that finds a login-shell
//! cache naming a secret (the Claude sign-in check at start).
#![cfg(target_os = "macos")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs a stand-in agent (fake_agent.py) and stand-in CLIs.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// Keychain calls and program starts, logged by every process that loads it.
const INTERPOSER: &str = r#"
#include <Security/Security.h>
#include <spawn.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
  __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
  _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
  { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

/* Read once at load: a forked child only uses open/write/close (no malloc). */
static char log_path[1024];

static size_t add(char *line, size_t n, size_t cap, const char *text) {
  while (text && *text && n + 2 < cap) line[n++] = *text++;
  return n;
}

static void put(const char *kind, const char *name, char *const argv[]) {
  if (!log_path[0]) return;
  char line[4096];
  size_t n = 0;
  n = add(line, n, sizeof line, kind);
  n = add(line, n, sizeof line, " ");
  n = add(line, n, sizeof line, name);
  for (int i = 0; argv && argv[i] && i < 64; i++) {
    n = add(line, n, sizeof line, "\x1f");
    n = add(line, n, sizeof line, argv[i]);
  }
  line[n++] = '\n';
  int fd = open(log_path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) return;
  (void)write(fd, line, n);
  close(fd);
}

__attribute__((constructor)) static void loaded(void) {
  const char *path = getenv("KEYCHAIN_CALL_LOG");
  if (path && strlen(path) < sizeof log_path) strcpy(log_path, path);
  put("loaded", getprogname(), NULL);
}

static void call(const char *name) { put("call", name, NULL); }

static OSStatus my_SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r) {
  call("SecItemCopyMatching"); return SecItemCopyMatching(q, r);
}
static OSStatus my_SecItemAdd(CFDictionaryRef a, CFTypeRef *r) {
  call("SecItemAdd"); return SecItemAdd(a, r);
}
static OSStatus my_SecItemUpdate(CFDictionaryRef q, CFDictionaryRef a) {
  call("SecItemUpdate"); return SecItemUpdate(q, a);
}
static OSStatus my_SecItemDelete(CFDictionaryRef q) {
  call("SecItemDelete"); return SecItemDelete(q);
}
DYLD_INTERPOSE(my_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(my_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(my_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(my_SecItemDelete, SecItemDelete)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus my_SecKeychainCopyDefault(SecKeychainRef *k) {
  call("SecKeychainCopyDefault"); return SecKeychainCopyDefault(k);
}
static OSStatus my_SecKeychainCopySearchList(CFArrayRef *l) {
  call("SecKeychainCopySearchList"); return SecKeychainCopySearchList(l);
}
static OSStatus my_SecKeychainOpen(const char *p, SecKeychainRef *k) {
  call("SecKeychainOpen"); return SecKeychainOpen(p, k);
}
static OSStatus my_SecKeychainUnlock(SecKeychainRef k, UInt32 l, const void *p, Boolean u) {
  call("SecKeychainUnlock"); return SecKeychainUnlock(k, l, p, u);
}
static OSStatus my_SecKeychainFindGenericPassword(CFTypeRef k, UInt32 sl, const char *s,
    UInt32 al, const char *a, UInt32 *pl, void **p, SecKeychainItemRef *i) {
  call("SecKeychainFindGenericPassword");
  return SecKeychainFindGenericPassword(k, sl, s, al, a, pl, p, i);
}
static OSStatus my_SecKeychainFindInternetPassword(CFTypeRef k, UInt32 sl, const char *s,
    UInt32 dl, const char *d, UInt32 al, const char *a, UInt32 pal, const char *pa,
    UInt16 po, SecProtocolType pr, SecAuthenticationType at, UInt32 *pl, void **p,
    SecKeychainItemRef *i) {
  call("SecKeychainFindInternetPassword");
  return SecKeychainFindInternetPassword(k, sl, s, dl, d, al, a, pal, pa, po, pr, at, pl, p, i);
}
static OSStatus my_SecKeychainAddGenericPassword(SecKeychainRef k, UInt32 sl, const char *s,
    UInt32 al, const char *a, UInt32 pl, const void *p, SecKeychainItemRef *i) {
  call("SecKeychainAddGenericPassword");
  return SecKeychainAddGenericPassword(k, sl, s, al, a, pl, p, i);
}
static OSStatus my_SecKeychainItemCopyContent(SecKeychainItemRef i, SecItemClass *c,
    SecKeychainAttributeList *l, UInt32 *n, void **d) {
  call("SecKeychainItemCopyContent"); return SecKeychainItemCopyContent(i, c, l, n, d);
}
static OSStatus my_SecKeychainItemDelete(SecKeychainItemRef i) {
  call("SecKeychainItemDelete"); return SecKeychainItemDelete(i);
}
DYLD_INTERPOSE(my_SecKeychainCopyDefault, SecKeychainCopyDefault)
DYLD_INTERPOSE(my_SecKeychainCopySearchList, SecKeychainCopySearchList)
DYLD_INTERPOSE(my_SecKeychainOpen, SecKeychainOpen)
DYLD_INTERPOSE(my_SecKeychainUnlock, SecKeychainUnlock)
DYLD_INTERPOSE(my_SecKeychainFindGenericPassword, SecKeychainFindGenericPassword)
DYLD_INTERPOSE(my_SecKeychainFindInternetPassword, SecKeychainFindInternetPassword)
DYLD_INTERPOSE(my_SecKeychainAddGenericPassword, SecKeychainAddGenericPassword)
DYLD_INTERPOSE(my_SecKeychainItemCopyContent, SecKeychainItemCopyContent)
DYLD_INTERPOSE(my_SecKeychainItemDelete, SecKeychainItemDelete)
#pragma clang diagnostic pop

static int my_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
    const posix_spawnattr_t *at, char *const argv[], char *const envp[]) {
  put("spawn", path, argv); return posix_spawn(pid, path, fa, at, argv, envp);
}
static int my_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
    const posix_spawnattr_t *at, char *const argv[], char *const envp[]) {
  put("spawn", file, argv); return posix_spawnp(pid, file, fa, at, argv, envp);
}
static int my_execve(const char *path, char *const argv[], char *const envp[]) {
  put("spawn", path, argv); return execve(path, argv, envp);
}
static int my_execv(const char *path, char *const argv[]) {
  put("spawn", path, argv); return execv(path, argv);
}
static int my_execvp(const char *file, char *const argv[]) {
  put("spawn", file, argv); return execvp(file, argv);
}
DYLD_INTERPOSE(my_posix_spawn, posix_spawn)
DYLD_INTERPOSE(my_posix_spawnp, posix_spawnp)
DYLD_INTERPOSE(my_execve, execve)
DYLD_INTERPOSE(my_execv, execv)
DYLD_INTERPOSE(my_execvp, execvp)
"#;

/// A program that makes one keychain call (on no item, so no keychain is
/// reached) and starts one program: the control.
const CONTROL: &str = r#"
#include <Security/Security.h>
#include <spawn.h>
#include <sys/wait.h>
int main(void) {
  /* No item: the call fails at once and reaches no keychain. */
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  SecKeychainItemDelete(NULL);
  pid_t pid;
  char *argv[] = { "true", NULL };
  char *envp[] = { NULL };
  if (posix_spawn(&pid, "/usr/bin/true", NULL, NULL, argv, envp) == 0) waitpid(pid, NULL, 0);
  return 0;
}
"#;

fn scratch(tag: &str) -> PathBuf {
    use std::os::unix::fs::DirBuilderExt;
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-k{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
    dir
}

/// Compile `source` with `cc` into `out` (`args`: the output kind).
fn cc(dir: &Path, name: &str, source: &str, out: &Path, args: &[&str]) {
    let src = dir.join(name);
    std::fs::write(&src, source).unwrap();
    let built = Command::new("/usr/bin/cc")
        .args(args)
        .arg("-framework")
        .arg("Security")
        .arg("-framework")
        .arg("CoreFoundation")
        .arg("-o")
        .arg(out)
        .arg(&src)
        .output()
        .expect("cc");
    assert!(built.status.success(), "cc {name}: {}", String::from_utf8_lossy(&built.stderr));
}

/// The interposer and a log file it writes; the control proves it works.
fn interposer(dir: &Path) -> PathBuf {
    let dylib = dir.join("keychain-calls.dylib");
    cc(dir, "keychain-calls.c", INTERPOSER, &dylib, &["-dynamiclib"]);
    let control = dir.join("control");
    cc(dir, "control.c", CONTROL, &control, &[]);
    let log = dir.join("control.log");
    let ran = Command::new(&control)
        .env_clear()
        .env("DYLD_INSERT_LIBRARIES", &dylib)
        .env("KEYCHAIN_CALL_LOG", &log)
        .env("HOME", daemon_env::home(dir))
        .status()
        .unwrap();
    assert!(ran.success());
    let seen = std::fs::read_to_string(&log).unwrap_or_default();
    assert!(seen.contains("call SecKeychainItemDelete"), "no keychain call recorded: {seen:?}");
    assert!(seen.contains("spawn /usr/bin/true"), "no program start recorded: {seen:?}");
    dylib
}

/// Ends a child if the test fails early.
struct Kill(Option<Child>);
impl Drop for Kill {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn ask(socket: &Path, request: Value) -> Value {
    let mut stream = UnixStream::connect(socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    stream.write_all(format!("{request}\n").as_bytes()).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|e| panic!("{request}: no reply ({e}): {line:?}"))
}

fn wait_for(path: &Path, what: &str) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while UnixStream::connect(path).is_err() {
        assert!(Instant::now() < deadline, "{what} never opened {}", path.display());
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// `acpmux router serve` starts, mints a key and stops with no keychain call.
#[test]
fn the_router_starts_mints_and_stops_with_no_keychain_call() {
    let dir = scratch("r");
    let dylib = interposer(&dir);
    let log = dir.join("router.log");
    let home = dir.join("acpmux");
    std::fs::create_dir_all(&home).unwrap();
    let socket = home.join("router").join("router.sock");
    let child = daemon_env::acpmux(&dir)
        .args(["router", "serve"])
        .env("ACPMUX_HOME", &home)
        .env("DYLD_INSERT_LIBRARIES", &dylib)
        .env("KEYCHAIN_CALL_LOG", &log)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut router = Kill(Some(child));
    wait_for(&socket, "the router");
    let status = ask(&socket, json!({"op": "status"}));
    assert_eq!(status["install_secret"], "ephemeral", "{status}");
    let minted = ask(
        &socket,
        json!({"op": "mint_key", "scope": {"harness": "fake", "session": "s1", "surfaces": [], "families": ["open_ai_chat"], "expires_at": 0}}),
    );
    assert!(minted["key"].is_string(), "no key minted: {minted}");
    assert_eq!(ask(&socket, json!({"op": "shutdown"}))["stopping"], json!(true));
    let mut child = router.0.take().unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "the router did not stop");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_no_keychain(&log, &["acpmux"]);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Whether a logged program start runs `security` (directly, or as a word
/// of a shell command line).
fn starts_security(fields: &[&str]) -> bool {
    fields.iter().any(|f| {
        let name = Path::new(f).file_name().and_then(|n| n.to_str()).unwrap_or("");
        name == "security"
            || f.contains("find-generic-password")
            || f.split(|c: char| c.is_whitespace() || c == ';' || c == '&' || c == '|')
                .any(|w| w == "security" || w == "/usr/bin/security")
    })
}

/// The log has no keychain call and no `security` start, and each process
/// named in `loaded` loaded the interposer (so its silence counts).
fn assert_no_keychain(log: &Path, loaded: &[&str]) -> String {
    let text = std::fs::read_to_string(log).unwrap_or_default();
    let mut bad = Vec::new();
    for line in text.lines() {
        let (kind, rest) = line.split_once(' ').unwrap_or((line, ""));
        let fields: Vec<&str> = rest.split('\u{1f}').collect();
        match kind {
            "call" => bad.push(line.replace('\u{1f}', " ")),
            "spawn" if starts_security(&fields) => bad.push(line.replace('\u{1f}', " ")),
            _ => {}
        }
    }
    assert!(bad.is_empty(), "acpmux asked the login keychain:\n{}", bad.join("\n"));
    for name in loaded {
        assert!(
            text.lines().any(|l| l == format!("loaded {name}")),
            "{name} never loaded the interposer:\n{text}"
        );
    }
    text
}

/// An executable shell script at `path`.
fn script(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A stand-in agent CLI: prints `version` for `--version`, logs every call.
fn cli(path: &Path, version: &str, calls: &Path) {
    let calls = daemon_env::sh_quote(calls.display());
    script(
        path,
        &format!(
            "#!/bin/sh\necho \"$(basename \"$0\") $*\" >> {calls}\n[ \"$1\" = --version ] && echo '{version}'\nexit 0\n"
        ),
    );
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
    /// The daemon's log, shown when a call fails.
    log: PathBuf,
}

impl Rpc {
    async fn connect(dir: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(dir.join("s.sock")).await.unwrap();
        let (rd, wr) = s.into_split();
        let log = dir.join("daemon.out");
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0, log }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.lines.next_line())
                .await
                .expect("the daemon answered in time")
                .unwrap()
                .expect("the daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                if v.get("error").is_some() {
                    let log = std::fs::read_to_string(&self.log).unwrap_or_default();
                    let tail: Vec<&str> = log.lines().rev().take(40).collect();
                    let tail: Vec<&str> = tail.into_iter().rev().collect();
                    panic!("{method} failed: {v}\ndaemon log:\n{}", tail.join("\n"));
                }
                return v["result"].clone();
            }
        }
    }
}

/// The daemon in `dir` as the app starts it (local router on, the login
/// shell read), with the interposer; returns after its readiness line.
fn start_daemon(dir: &Path, dylib: &Path, log: &Path) -> Kill {
    let mut child = daemon_env::command(dir, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "info"])
        .env("SHELL", dir.join("loginsh"))
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .env("ACPMUX_LOCAL_ROUTER", "1")
        .env("ACPMUX_CATALOG_FETCH", "0")
        .env("ACPMUX_REGISTRY_FETCH", "0")
        .env("ACPMUX_HEALTH_FETCH", "0")
        .env("ACPMUX_PROBE_HARNESSES", "fake")
        .env("DYLD_INSERT_LIBRARIES", dylib)
        .env("KEYCHAIN_CALL_LOG", log)
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(std::fs::File::create(dir.join("daemon.stderr")).unwrap())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut daemon = Kill(Some(child));
    // The readiness line, then the daemon's log (also on stdout) into daemon.out.
    let mut lines = BufReader::new(stdout).lines();
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut ready = false;
    for line in lines.by_ref() {
        assert!(Instant::now() < deadline, "the daemon never became ready");
        if serde_json::from_str::<Value>(&line.unwrap()).is_ok_and(|v| v["ready"] == true) {
            ready = true;
            break;
        }
    }
    if ready {
        let mut out = std::fs::File::create(dir.join("daemon.out")).unwrap();
        std::thread::spawn(move || {
            for line in lines.map_while(Result::ok) {
                let _ = writeln!(out, "{line}");
            }
        });
        return daemon;
    }
    let _ = daemon.0.take().map(|mut c| c.wait());
    panic!(
        "the daemon exited before it was ready: {}",
        std::fs::read_to_string(dir.join("daemon.stderr")).unwrap_or_default()
    );
}

/// `acpmux daemon shutdown --end-agents`, then the daemon's exit.
fn shutdown(dir: &Path, mut daemon: Kill) {
    let out = daemon_env::acpmux(dir)
        .args(["daemon", "shutdown", "--end-agents"])
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let mut child = daemon.0.take().unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "the daemon did not stop");
        std::thread::sleep(Duration::from_millis(20));
    }
    // The router stops with its last owner; its calls are logged by then.
    let socket = dir.join("router").join("router.sock");
    let deadline = Instant::now() + Duration::from_secs(10);
    while UnixStream::connect(&socket).is_ok() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The daemon's whole start (local router, login shell, agent CLI health
/// with a Claude and a Codex CLI that keeps its login in the keychain), a
/// chat with a stand-in agent, and a second start that must decide whether
/// Claude signs in without the login shell: no keychain call and no
/// `security` start in any acpmux process, and no `codex login status`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_daemon_start_and_a_chat_start_make_no_keychain_call() {
    let dir = scratch("d");
    let dylib = interposer(&dir);
    let log = dir.join("calls.log");
    let cli_calls = dir.join("cli-calls.log");
    // The person's login shell sets a secret: its value is never cached, so
    // the second start asks whether Claude signs in without the shell.
    let home = daemon_env::home(&dir);
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join(".zshrc"), "export ANTHROPIC_API_KEY=sk-ant-test-login-shell\n")
        .unwrap();
    script(
        &dir.join("loginsh"),
        "#!/bin/sh\nfor a; do last=$a; done\n. \"$HOME/.zshrc\"\neval \"$last\"\n",
    );
    // A Claude CLI and a Codex CLI (by path, not on PATH, so no PATH harness
    // finds them); Codex keeps its login in the keychain.
    cli(&dir.join("bin").join("claude"), "2.1.0 (Claude Code)", &cli_calls);
    cli(&dir.join("bin").join("codex"), "codex-cli 0.50.0", &cli_calls);
    let codex_home = dir.join("codex-home");
    std::fs::create_dir_all(&codex_home).unwrap();
    std::fs::write(codex_home.join("config.toml"), "cli_auth_credentials_store = \"keyring\"\n")
        .unwrap();
    std::fs::write(
        dir.join("config.json"),
        json!({
            "harnesses": {
                // By path: the login PATH (system folders first) may hold
                // an older python3 than the one the stand-in needs.
                "fake": {"argv": [daemon_env::tool_dir(&[]).join("python3"), FAKE]},
                "cl": {"argv": [dir.join("bin").join("claude")]},
                "cx": {"argv": [dir.join("bin").join("codex")], "env": {"CODEX_HOME": codex_home}},
            },
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
        })
        .to_string(),
    )
    .unwrap();

    let daemon = start_daemon(&dir, &dylib, &log);
    let mut rpc = Rpc::connect(&dir).await;
    // The daemon's own health check (it shares the first one).
    let health = rpc.call("_acpmux/harness/health", json!({})).await;
    let row = |id: &str| {
        health["harnesses"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == id)
            .unwrap_or_else(|| panic!("no {id} row: {health}"))
            .clone()
    };
    assert_eq!(row("cl")["version"], "2.1.0", "{health}");
    assert_eq!(row("cl")["auth"], "unknown", "{health}");
    assert_eq!(row("cx")["version"], "0.50.0", "{health}");
    assert_eq!(row("cx")["auth"], "unknown", "{health}");
    // A chat start: a session and one prompt to the stand-in agent.
    let created = rpc.call("session/new", json!({"cwd": dir, "mcpServers": []})).await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    rpc.call(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": "hello"}]}),
    )
    .await;
    drop(rpc);
    shutdown(&dir, daemon);
    let text = assert_no_keychain(&log, &["acpmux"]);
    // The interposer saw the daemon's own program starts (the CLI checks).
    assert!(text.contains("claude\u{1f}") || text.contains("/bin/claude"), "{text}");
    let calls = std::fs::read_to_string(&cli_calls).unwrap_or_default();
    assert!(calls.contains("codex --version") && calls.contains("claude --version"), "{calls}");
    // `codex login status` reads a keychain login: never started (also not
    // from PATH, where it would fail).
    assert!(
        !text.contains("\u{1f}login\u{1f}status") && !calls.contains("login"),
        "a sign-in check ran `codex login status` with a keychain login:\n{text}\n{calls}"
    );
    assert!(
        std::fs::read_to_string(dir.join("login-env.json"))
            .unwrap_or_default()
            .contains("ANTHROPIC_API_KEY"),
        "the login shell cache names no secret"
    );

    // The second start finds the cache naming a secret this daemon lacks.
    std::fs::remove_file(&log).unwrap();
    let daemon = start_daemon(&dir, &dylib, &log);
    let mut rpc = Rpc::connect(&dir).await;
    rpc.call("_acpmux/status", json!({})).await;
    drop(rpc);
    shutdown(&dir, daemon);
    assert_no_keychain(&log, &["acpmux"]);
    let _ = std::fs::remove_dir_all(&dir);
}
