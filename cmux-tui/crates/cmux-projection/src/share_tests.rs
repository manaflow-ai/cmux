use std::net::TcpListener;
use std::os::unix::fs::symlink;
use std::sync::Arc;
use std::time::{Duration, Instant};

use super::*;
use crate::Fetch as _;
use crate::link::Link;

/// A home with a shareable `share/` (a file, a nested folder, secrets and links) and a secret
/// store; the policy is [`DENY`] with `~/share` as the one root.
fn home() -> (tempfile::TempDir, Policy) {
    let home = tempfile::Builder::new().prefix("home").tempdir().unwrap();
    let at = |rel: &str| home.path().join(rel);
    for dir in ["share/logs", "share/.ssh", "outside", ".config/gh", "share/deep/a"] {
        std::fs::create_dir_all(at(dir)).unwrap();
    }
    std::fs::write(at("share/readme.txt"), b"hello from b").unwrap();
    std::fs::write(at("share/logs/run.log"), b"line 1\nline 2\n").unwrap();
    std::fs::write(at("share/deep/a/file"), b"deep").unwrap();
    std::fs::write(at("share/.ssh/id_ed25519"), b"KEY").unwrap();
    std::fs::write(at("share/api-token.txt"), b"TOKEN").unwrap();
    std::fs::write(at("share/.env"), b"A=1").unwrap();
    std::fs::write(at("share/cert.pem"), b"PEM").unwrap();
    std::fs::write(at("outside/note"), b"outside").unwrap();
    std::fs::write(at(".config/gh/hosts.yml"), b"oauth").unwrap();
    symlink("readme.txt", at("share/link")).unwrap();
    symlink(at(".config/gh"), at("share/gh")).unwrap();
    let policy = Policy::new(home.path(), &["~/share"], DENY, &["~/.config/gh"]);
    (home, policy)
}

#[test]
fn glob_matches_as_fnmatch_does() {
    assert!(glob("*token*", "api-token.txt"));
    assert!(glob("*.pem", "cert.pem"));
    assert!(glob("id_rsa*", "id_rsa"));
    assert!(glob(".env.*", ".env.local"));
    assert!(glob("?a", "ba"));
    assert!(!glob("*.pem", "cert.pem.txt"));
    assert!(!glob(".env", ".envx"));
    assert!(!glob("*key*", "readme.txt"));
}

#[test]
fn the_policy_refuses_secrets_outside_and_links_into_secrets() {
    let (home, policy) = home();
    let h = home.path().display().to_string();
    assert!(policy.check("~/share").is_ok());
    assert!(policy.check("~/share/logs").is_ok());
    assert!(policy.check("~/share/.ssh").unwrap_err().contains("secret path"));
    assert!(policy.check("~/outside").unwrap_err().contains("outside the readable roots"));
    assert!(policy.check("~/share/../outside").unwrap_err().contains("outside"));
    assert!(policy.check("~/share/gh").unwrap_err().contains("secret path"));
    assert!(policy.check(&format!("{h}/.config/gh")).unwrap_err().contains("secret path"));
    assert!(policy.check("~/share/readme.txt").unwrap_err().contains("not a folder"));
    assert!(policy.check("share").unwrap_err().contains("not an absolute path"));
    assert!(policy.denied(Path::new("/x/Secrets/y")).is_some(), "case-insensitive");
}

#[test]
fn the_lane_vm_policy_is_machine_reads() {
    let policy = Policy::lane_vm(Path::new("/home/someone"));
    for secret in [
        "/home/someone/.ssh/id_rsa",
        "/home/someone/.config/gh/hosts.yml",
        "/home/someone/.claude/x",
        "/home/someone/Projects/app/.env",
        "/home/someone/.local/state/lane-gh-broker.sock",
        "/var/log/auth.log",
    ] {
        assert!(!policy.allows(Path::new(secret)), "{secret}");
    }
    assert!(policy.allows(Path::new("/home/someone/.local/state/x/log.jsonl")));
    assert!(policy.allows(Path::new("/var/log/syslog")));
    assert!(!policy.allows(Path::new("/etc/hostname")));
}

#[test]
fn a_listing_leaves_secrets_out_and_keeps_links_as_text() {
    let (_home, policy) = home();
    let shared = list(&policy, "~/share").unwrap();
    let manifest = &shared.manifest;
    for listed in ["readme.txt", "logs/run.log", "deep/a/file", "link", "gh"] {
        assert!(manifest.resolve(listed).is_some(), "{listed}");
    }
    for hidden in [".ssh", ".ssh/id_ed25519", "api-token.txt", ".env", "cert.pem"] {
        assert!(manifest.resolve(hidden).is_none(), "{hidden}");
    }
    assert_eq!(shared.hidden, 4);
    let gh = manifest.entry(manifest.resolve("gh").unwrap()).unwrap();
    assert_eq!(gh.kind, Kind::Link);
}

#[test]
fn a_link_out_of_the_root_is_never_followed_on_the_serving_side() {
    let (home, policy) = home();
    // Fake secrets outside the shared root, and links to them (absolute and relative).
    std::fs::create_dir_all(home.path().join("outside/fake-gh")).unwrap();
    std::fs::write(home.path().join("outside/fake-gh/hosts.yml"), b"FAKE").unwrap();
    symlink(home.path().join("outside/fake-gh"), home.path().join("share/out-abs")).unwrap();
    symlink("../outside/fake-gh", home.path().join("share/out-rel")).unwrap();
    symlink("../outside/note", home.path().join("share/out-file")).unwrap();
    let shared = list(&policy, "~/share").unwrap();
    let manifest = &shared.manifest;
    for link in ["out-abs", "out-rel", "out-file"] {
        let index = manifest.resolve(link).unwrap();
        assert_eq!(manifest.entry(index).unwrap().kind, Kind::Link, "{link} is listed as a link");
        // A link entry has no bytes on the serving side: its target is never opened.
        assert_eq!(shared.whole(index).status, wire::REFUSED, "{link}");
        assert_eq!(shared.read(index, 0, 64).status, wire::REFUSED, "{link}");
    }
    // Nothing below a link is listed, so nothing out there has an entry to ask for.
    for below in ["out-abs/hosts.yml", "out-rel/hosts.yml"] {
        assert!(manifest.resolve(below).is_none(), "{below}");
    }
    // Every entry served is a regular file inside the root.
    let root = std::fs::canonicalize(home.path().join("share")).unwrap();
    for (index, entry) in (0u32..).zip(shared.files.iter()) {
        if let Some(served) = entry {
            assert!(served.path.starts_with(&root), "{index}: {}", served.path.display());
        }
    }
    // A folder asked for through a link that leaves the root is refused by its resolved path.
    assert!(policy.check("~/share/out-abs").unwrap_err().contains("outside the readable roots"));
}

#[test]
fn a_read_answers_the_listed_file_and_refuses_one_swapped_for_a_secret() {
    let (home, policy) = home();
    let shared = list(&policy, "~/share").unwrap();
    let readme = shared.manifest.resolve("readme.txt").unwrap();
    assert_eq!(shared.read(readme, 6, 100), Part::ok(b"from b".to_vec()));
    assert_eq!(shared.whole(readme), Part::ok(b"hello from b".to_vec()));
    // A link entry and a folder have no bytes to serve.
    let gh = shared.manifest.resolve("gh").unwrap();
    assert_eq!(shared.whole(gh).status, wire::REFUSED);
    assert_eq!(shared.whole(u32::MAX).status, wire::REFUSED);

    let log = shared.manifest.resolve("logs/run.log").unwrap();
    let path = home.path().join("share/logs/run.log");
    std::fs::remove_file(&path).unwrap();
    symlink(home.path().join(".config/gh/hosts.yml"), &path).unwrap();
    assert_eq!(shared.whole(log).status, wire::CHANGED, "O_NOFOLLOW refuses the swapped link");

    // The folder above swapped for a link into the secret store: the open lands there.
    let logs = home.path().join("share/logs");
    std::fs::remove_file(&path).unwrap();
    std::fs::remove_dir(&logs).unwrap();
    std::fs::copy(home.path().join(".config/gh/hosts.yml"), home.path().join(".config/gh/run.log"))
        .unwrap();
    symlink(home.path().join(".config/gh"), &logs).unwrap();
    assert_eq!(shared.whole(log).status, wire::REFUSED);
}

#[test]
fn a_file_changed_since_the_listing_answers_changed() {
    let (home, policy) = home();
    let shared = list(&policy, "~/share").unwrap();
    let readme = shared.manifest.resolve("readme.txt").unwrap();
    std::fs::write(home.path().join("share/readme.txt"), b"a longer text than before").unwrap();
    assert_eq!(shared.read(readme, 0, 10).status, wire::CHANGED);
}

fn server(policy: Policy, allow: &str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    let allow = Arc::new(Allow::parse(allow).unwrap());
    std::thread::spawn(move || serve_on(listener, Arc::new(policy), allow));
    addr
}

#[test]
fn a_dial_lists_the_folder_and_its_reads_come_over_the_link() {
    let (_home, policy) = home();
    let addr = server(policy, "127.0.0.0/8");
    let dialed = dial(&addr, "~/share", None).unwrap();
    let manifest = dialed.manifest.unwrap();
    assert_eq!(dialed.head["hidden"], 4);
    let readme = manifest.resolve("readme.txt").unwrap();
    let link = Arc::new(Link::new(Duration::from_secs(2)));
    {
        let link = link.clone();
        std::thread::spawn(move || link.serve(dialed.reader, dialed.writer));
    }
    let start = Instant::now();
    while !link.attached() {
        assert!(start.elapsed() < Duration::from_secs(5));
        std::thread::yield_now();
    }
    assert_eq!(link.read(readme, 0, 5).unwrap(), b"hello");
    assert_eq!(link.batch(&[readme])[0].as_deref().unwrap(), b"hello from b");
    // A ask for an entry the listing never served is refused on the serving side.
    assert_eq!(link.read(0, 0, 5), Err(crate::FetchError::Refused));

    // A redial with the mounted digest gets no listing again; a stale one is told to remount.
    let again = dial(&addr, "~/share", Some(&dialed.digest)).unwrap();
    assert!(again.manifest.is_none());
    let stale = dial(&addr, "~/share", Some("0000")).err().unwrap();
    assert_eq!(stale.code, "share.changed");
}

#[test]
fn the_server_refuses_secret_folders_and_peers_it_does_not_admit() {
    let (_home, policy) = home();
    let addr = server(policy.clone(), "127.0.0.1");
    let refused = dial(&addr, "~/share/.ssh", None).err().unwrap();
    assert_eq!(refused.code, "share.refused");
    assert!(refused.error.contains("secret path"), "{}", refused.error);
    let outside = dial(&addr, "~/outside", None).err().unwrap();
    assert_eq!(outside.code, "share.refused");

    let closed = server(policy, "10.0.0.0/8");
    let error = dial(&closed, "~/share", None).err().unwrap();
    assert_eq!(error.code, "share.not_allowed");
}

#[test]
fn allow_parses_addresses_and_blocks() {
    let allow = Allow::parse("10.138.0.0/20, 192.168.1.7").unwrap();
    assert!(allow.admits("10.138.15.216".parse().unwrap()));
    assert!(!allow.admits("10.138.16.1".parse().unwrap()));
    assert!(allow.admits("192.168.1.7".parse().unwrap()));
    assert!(!allow.admits("192.168.1.8".parse().unwrap()));
    assert!(allow.admits("::ffff:10.138.1.1".parse().unwrap()));
    assert!(Allow::parse("10.0.0.0/33").is_err());
    assert!(Allow::parse("").unwrap().is_empty());
    assert!(serve("0.0.0.0:7481", Policy::lane_vm(Path::new("/")), allow).is_err());
}
