//! A DEV build's harness profiles never reach a shipped build (hq#2569 item
//! 11). A dogfood lane on a capture mini put a fake ACP agent (`p4rtfake`,
//! models m1 and m2) in the user harness folder `~/.config/cmux/harnesses`
//! for its DEV build, and cmux NEXT's model picker on that mini showed it as
//! a harness named "P". The user folder is per user, not per build, so per-
//! build isolation (cx-is1kf) did not cover it.
//!
//! Through the real binary, with one HOME and the acpmux homes the builds
//! use (`BuildIdentity::acpmux_home`): a DEV build (and an old
//! `~/.acpmux/tags/<tag>` home) adds and lists harnesses in a folder of its
//! own home, and NIGHTLY, cmux NEXT and release keep the user folder.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent; `harness add` only writes a file.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use cmux_agent_pane_policy::build_identity::BuildIdentity;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-buildiso-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(daemon_env::home(&root)).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

/// `acpmux args` as the build whose acpmux home is `acpmux_home`. No
/// `XDG_CONFIG_HOME`: the user folder is `$HOME/.config/cmux/harnesses`, as
/// on a real Mac. No daemon runs (the socket is absent).
fn run(root: &Path, acpmux_home: &Path, args: &[&str]) -> Output {
    let mut cmd: Command = daemon_env::acpmux(root);
    cmd.env("ACPMUX_HOME", acpmux_home)
        .env("ACPMUX_SOCKET", root.join("none.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null());
    cmd.args(args).output().expect("run acpmux")
}

fn text(out: &Output) -> String {
    format!("{} {}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr))
}

/// The harness ids `acpmux harness list` gives for that build.
fn listed(root: &Path, acpmux_home: &Path) -> Vec<String> {
    let out = run(root, acpmux_home, &["--json", "harness", "list"]);
    assert!(out.status.success(), "list failed: {}", text(&out));
    let list: Value = serde_json::from_slice(&out.stdout).unwrap();
    list["harnesses"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|row| row["id"].as_str().map(str::to_owned))
        .collect()
}

#[test]
fn a_dev_builds_harness_never_shows_in_a_shipped_build() {
    let root = scratch();
    let home = daemon_env::home(&root);
    let acpmux_root = home.join(".acpmux");
    let builds = acpmux_root.join("builds");
    let dev = builds.join("com.cmuxterm.app.debug.p4rt");
    let tag = acpmux_root.join("tags").join("next");
    let nightly = acpmux_root.clone();
    let next = builds.join("com.cmuxterm.app.nightly.cmux-next");
    let release = builds.join("com.cmuxterm.app");
    // A shipped bundle that ships a tag its id does not end in has a key
    // `<bundle id>--<tag>`; it is still that shipped build.
    let tagged = |id: &str| BuildIdentity::new(Some(id), Some("lab")).acpmux_home(&home);
    let rc_tagged = tagged("com.cmuxterm.app.rc");
    let release_tagged = tagged("com.cmuxterm.app");
    for h in [&rc_tagged, &release_tagged] {
        assert!(h.to_string_lossy().ends_with("--lab"), "not a tagged key: {h:?}");
    }
    let shared = home.join(".config").join("cmux").join("harnesses");

    // The person's own harness, in the user folder.
    std::fs::create_dir_all(&shared).unwrap();
    std::fs::write(
        shared.join("mine.toml"),
        "schema = 1\nid = \"mine\"\nname = \"Mine\"\ncommand = \"/bin/echo\"\n",
    )
    .unwrap();

    // A DEV build adds a fake agent: the profile lands in its own home.
    let out = run(&root, &dev, &["--json", "harness", "add", "p4rtfake", "--command", FAKE]);
    assert!(out.status.success(), "add failed: {}", text(&out));
    let added: Value = serde_json::from_slice(&out.stdout).unwrap();
    let path = PathBuf::from(added["path"].as_str().unwrap_or_default());
    assert!(path.starts_with(&dev), "a DEV build wrote {path:?}, outside its home {dev:?}");
    assert!(!shared.join("p4rtfake.toml").exists(), "the DEV fake landed in the user folder");

    // An old tag home (`ACPMUX_HOME=~/.acpmux/tags/<tag>`) is a DEV home too.
    let out = run(&root, &tag, &["--json", "harness", "add", "tagfake", "--command", FAKE]);
    assert!(out.status.success(), "add failed: {}", text(&out));
    assert!(!shared.join("tagfake.toml").exists(), "the tag home's fake landed in the user folder");

    // Each DEV home lists its own fake and not the person's harnesses.
    let dev_list = listed(&root, &dev);
    assert!(dev_list.contains(&"p4rtfake".into()), "DEV lost its own harness: {dev_list:?}");
    assert!(!dev_list.contains(&"tagfake".into()), "DEV lists another home's: {dev_list:?}");
    assert!(!dev_list.contains(&"mine".into()), "DEV reads the user folder: {dev_list:?}");
    let tag_list = listed(&root, &tag);
    assert!(tag_list.contains(&"tagfake".into()), "the tag home lost its harness: {tag_list:?}");
    assert!(!tag_list.contains(&"p4rtfake".into()), "{tag_list:?}");

    // Shipped builds list the person's harness and no DEV fake.
    for (name, acpmux_home) in [
        ("NIGHTLY", &nightly),
        ("cmux NEXT", &next),
        ("release", &release),
        ("tagged RC", &rc_tagged),
        ("tagged release", &release_tagged),
    ] {
        let ids = listed(&root, acpmux_home);
        assert!(ids.contains(&"mine".into()), "{name} lost the user's harness: {ids:?}");
        for fake in ["p4rtfake", "tagfake"] {
            assert!(!ids.contains(&fake.into()), "{name} lists the DEV fake {fake}: {ids:?}");
        }
    }

    let _ = std::fs::remove_dir_all(&root);
}
