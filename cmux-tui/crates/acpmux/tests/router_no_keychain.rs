//! The local router and the daemon never call the macOS Keychain (cx-f4thx):
//! a Keychain read from acpmux showed "acpmux wants to use your confidential
//! information stored in "com.cmuxterm.coderouter" in your keychain", again
//! for every differently signed build. The router's install secret is random
//! and in memory, so nothing in acpmux needs the Keychain at start, at a key
//! mint or at a relay check.
//!
//! Boundary: a dylib, built here with `cc` and loaded with
//! `DYLD_INSERT_LIBRARIES`, interposes the Security framework's Keychain
//! item and keychain calls and writes each call's name to a file. It sees
//! every call acpmux and its crates make into Security (calls inside the
//! framework itself are not interposed). A control program proves the
//! interposer records a call, so an empty log means no call, not a dylib that
//! never loaded.
#![cfg(target_os = "macos")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// The Keychain calls a keychain read or write goes through.
const INTERPOSER: &str = r#"
#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
  __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
  _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
  { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

static void note(const char *name) {
  const char *path = getenv("KEYCHAIN_CALL_LOG");
  if (!path) return;
  FILE *f = fopen(path, "a");
  if (!f) return;
  fprintf(f, "%s\n", name);
  fclose(f);
}

static OSStatus my_SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r) {
  note("SecItemCopyMatching"); return SecItemCopyMatching(q, r);
}
static OSStatus my_SecItemAdd(CFDictionaryRef a, CFTypeRef *r) {
  note("SecItemAdd"); return SecItemAdd(a, r);
}
static OSStatus my_SecItemUpdate(CFDictionaryRef q, CFDictionaryRef a) {
  note("SecItemUpdate"); return SecItemUpdate(q, a);
}
static OSStatus my_SecItemDelete(CFDictionaryRef q) {
  note("SecItemDelete"); return SecItemDelete(q);
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus my_SecKeychainCopyDefault(SecKeychainRef *k) {
  note("SecKeychainCopyDefault"); return SecKeychainCopyDefault(k);
}
static OSStatus my_SecKeychainFindGenericPassword(CFTypeRef k, UInt32 sl, const char *s,
    UInt32 al, const char *a, UInt32 *pl, void **p, SecKeychainItemRef *i) {
  note("SecKeychainFindGenericPassword");
  return SecKeychainFindGenericPassword(k, sl, s, al, a, pl, p, i);
}
static OSStatus my_SecKeychainAddGenericPassword(SecKeychainRef k, UInt32 sl, const char *s,
    UInt32 al, const char *a, UInt32 pl, const void *p, SecKeychainItemRef *i) {
  note("SecKeychainAddGenericPassword");
  return SecKeychainAddGenericPassword(k, sl, s, al, a, pl, p, i);
}
DYLD_INTERPOSE(my_SecKeychainCopyDefault, SecKeychainCopyDefault)
DYLD_INTERPOSE(my_SecKeychainFindGenericPassword, SecKeychainFindGenericPassword)
DYLD_INTERPOSE(my_SecKeychainAddGenericPassword, SecKeychainAddGenericPassword)
#pragma clang diagnostic pop
DYLD_INTERPOSE(my_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(my_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(my_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(my_SecItemDelete, SecItemDelete)
"#;

/// A program that makes one Keychain call: the interposer's control.
const CONTROL: &str = r#"
#include <Security/Security.h>
int main(void) {
  const void *keys[] = { kSecClass, kSecAttrService };
  const void *values[] = { kSecClassGenericPassword, CFSTR("cmux.router-no-keychain.control") };
  CFDictionaryRef q = CFDictionaryCreate(NULL, keys, values, 2, NULL, NULL);
  CFTypeRef r = NULL;
  SecItemCopyMatching(q, &r);
  return 0;
}
"#;

fn scratch(tag: &str) -> PathBuf {
    use std::os::unix::fs::DirBuilderExt;
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-nokc-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
    std::fs::canonicalize(&dir).unwrap()
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
    assert!(seen.contains("SecItemCopyMatching"), "the interposer recorded nothing: {seen:?}");
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

/// `acpmux router serve` starts, mints a key and stops with no Keychain call.
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
    let calls = std::fs::read_to_string(&log).unwrap_or_default();
    assert!(calls.is_empty(), "the router called the Keychain: {calls}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The daemon (with the app's local router on) starts and stops with no
/// Keychain call, also in the router it starts.
#[test]
fn the_daemon_and_its_local_router_start_with_no_keychain_call() {
    let dir = scratch("d");
    let dylib = interposer(&dir);
    let log = dir.join("daemon.log");
    let home = dir.join("acpmux");
    std::fs::create_dir_all(&home).unwrap();
    let socket = home.join("s.sock");
    let child = daemon_env::acpmux(&dir)
        .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOCAL_ROUTER", "1")
        .env("ACPMUX_LOGIN_ENV", "0")
        .env("ACPMUX_CATALOG_FETCH", "0")
        .env("ACPMUX_REGISTRY_FETCH", "0")
        .env("DYLD_INSERT_LIBRARIES", &dylib)
        .env("KEYCHAIN_CALL_LOG", &log)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut daemon = Kill(Some(child));
    let stdout = daemon.0.as_mut().unwrap().stdout.take().unwrap();
    let mut lines = BufReader::new(stdout).lines();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        assert!(Instant::now() < deadline, "the daemon never became ready");
        let line = lines.next().expect("the daemon exited before it was ready").unwrap();
        if line.contains("\"ready\":true") {
            break;
        }
    }
    // The router the daemon started answers, so its start ran too.
    wait_for(&home.join("router").join("router.sock"), "the daemon's router");
    let status = ask(&home.join("router").join("router.sock"), json!({"op": "status"}));
    assert_eq!(status["install_secret"], "ephemeral", "{status}");
    drop(daemon);
    // The router stops with its owner; its calls are in the log by then.
    std::thread::sleep(Duration::from_millis(500));
    let calls = std::fs::read_to_string(&log).unwrap_or_default();
    assert!(calls.is_empty(), "the daemon or its router called the Keychain: {calls}");
    let _ = std::fs::remove_dir_all(&dir);
}
