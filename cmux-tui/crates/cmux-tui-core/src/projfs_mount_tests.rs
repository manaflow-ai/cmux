//! `projfs.mount|unmount` with a stand-in helper (a shell script): who may call, the work-root
//! rule, the helper's answer passed through, and a helper that never answers.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use super::*;

/// A temporary work root, removed on drop.
struct Root {
    path: PathBuf,
}

impl Root {
    fn new(label: &str) -> Self {
        let mut random = [0u8; 6];
        getrandom::fill(&mut random).unwrap();
        let suffix: String = random.iter().map(|b| format!("{b:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-projfs-mount-{label}-{suffix}"));
        std::fs::create_dir_all(&path).unwrap();
        let path = std::fs::canonicalize(path).unwrap();
        for dir in ["chat/at", "chat/state"] {
            std::fs::create_dir_all(path.join(dir)).unwrap();
        }
        std::fs::write(path.join("chat/state/manifest.cmpf"), b"CMPF").unwrap();
        Self { path }
    }

    fn at(&self, relative: &str) -> String {
        self.path.join(relative).to_str().unwrap().to_owned()
    }

    fn params(&self) -> Value {
        json!({
            "mount": "p-1",
            "manifest": self.at("chat/state/manifest.cmpf"),
            "at": self.at("chat/at"),
            "state": self.at("chat/state"),
        })
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// A helper that runs `mount` for `projfs mount …` and `unmount` for `projfs unmount …`, each a
/// shell script with the helper's arguments as `$1`, `$2`, ….
fn helper(mount: &str, unmount: &str) -> HelperCommand {
    helper_with_upper(mount, unmount, "exit 9")
}

/// [`helper`], with `upper` the script for `projfs upper …`.
fn helper_with_upper(mount: &str, unmount: &str, upper: &str) -> HelperCommand {
    let (mount, unmount, upper) = (mount.to_owned(), unmount.to_owned(), upper.to_owned());
    Arc::new(move |args: &[String]| {
        let script = match args.first().map(String::as_str) {
            Some("mount") => &mount,
            Some("upper") => &upper,
            _ => &unmount,
        };
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script).arg("sh").args(args);
        Ok(command)
    })
}

fn mounter(root: &Root, mount: &str, unmount: &str, ready_wait: Duration) -> Mounter {
    let roots = Roots::new([root.path.clone()]);
    Mounter::with_waits(roots, helper(mount, unmount), ready_wait, Duration::from_secs(10))
}

fn line(cmd: &str, params: &Value) -> String {
    let mut request = params.clone();
    request["id"] = json!(7);
    request["cmd"] = json!(cmd);
    request.to_string()
}

/// The Mac that mounts these tests' folders, and another paired install on the same machine.
const MAC: &str = "remote_mac";
const OTHER: &str = "remote_other";

fn call(mounter: &Mounter, cmd: &str, params: &Value) -> Value {
    call_as(mounter, MAC, cmd, params)
}

fn call_as(mounter: &Mounter, principal: &str, cmd: &str, params: &Value) -> Value {
    let caller = Caller::Remote(principal.into());
    answer_line(Some(mounter), caller, Some(Path::new("/run/d.sock")), &line(cmd, params))
}

const READY: &str = r#"echo '{"ok":true,"mount":"p-1","at":"x","entries":3,"bytes":9,"ms":{}}'"#;
const UNMOUNTED: &str = r#"echo '{"ok":true,"unmounted":true}'"#;

#[test]
fn only_the_mac_over_the_link_may_mount_and_only_on_a_cloud_host() {
    let root = Root::new("callers");
    let mounter = mounter(&root, READY, UNMOUNTED, Duration::from_secs(10));
    for caller in [Caller::Local, Caller::Denied] {
        let label = format!("{caller:?}");
        let answer =
            answer_line(Some(&mounter), caller, None, &line("projfs.mount", &root.params()));
        assert_eq!(answer["error_code"], "projfs.permission_denied", "{label}");
    }
    let mac = Caller::Remote(MAC.into());
    let answer = answer_line(None, mac, None, &line("projfs.unmount", &root.params()));
    assert_eq!(answer["error_code"], "projfs.unavailable");
    assert_eq!(answer["id"], 7);
    assert_eq!(frame_command(&line("projfs.next", &json!({}))), None);
    assert_eq!(frame_command(&line("projfs.mount", &json!({}))), Some("projfs.mount"));
}

#[test]
fn a_ready_helper_is_answered_as_it_spoke_and_gets_the_paths_and_the_socket() {
    let root = Root::new("ready");
    let args_file = root.at("args");
    let script = format!("printf '%s\\n' \"$@\" > '{args_file}'; {READY}");
    let mounter = mounter(&root, &script, UNMOUNTED, Duration::from_secs(10));
    let answer = call(&mounter, "projfs.mount", &root.params());
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["data"]["ok"], true);
    assert_eq!(answer["data"]["entries"], 3);
    let args = std::fs::read_to_string(&args_file).unwrap();
    let expected = [
        "mount".to_owned(),
        "--mount".into(),
        "p-1".into(),
        "--manifest".into(),
        root.at("chat/state/manifest.cmpf"),
        "--at".into(),
        root.at("chat/at"),
        "--state".into(),
        root.at("chat/state"),
        "--socket".into(),
        "/run/d.sock".into(),
    ];
    assert_eq!(args.lines().collect::<Vec<_>>(), expected);
    let unmount = json!({ "at": root.at("chat/at"), "state": root.at("chat/state") });
    let answer = call(&mounter, "projfs.unmount", &unmount);
    assert_eq!(answer["data"], json!({ "ok": true, "unmounted": true }));
}

#[test]
fn a_helper_refusal_is_passed_through_with_its_code() {
    let root = Root::new("refusal");
    let script =
        r#"echo '{"ok":false,"code":"no_fuse","message":"the FUSE mount failed"}'; exit 1"#;
    let mounter = mounter(&root, script, UNMOUNTED, Duration::from_secs(10));
    let answer = call(&mounter, "projfs.mount", &root.params());
    assert_eq!(answer["ok"], true, "the op answered; the helper refused");
    assert_eq!(
        answer["data"],
        json!({ "ok": false, "code": "no_fuse", "message": "the FUSE mount failed" })
    );
    let silent = mounter_with(&root, "exit 3");
    assert_eq!(call(&silent, "projfs.mount", &root.params())["error_code"], "projfs.helper_failed");
    let noise = mounter_with(&root, "echo not json");
    assert_eq!(call(&noise, "projfs.mount", &root.params())["error_code"], "projfs.helper_failed");
}

fn mounter_with(root: &Root, mount: &str) -> Mounter {
    mounter(root, mount, UNMOUNTED, Duration::from_secs(10))
}

#[test]
fn paths_outside_the_work_roots_are_refused_before_any_helper_runs() {
    let root = Root::new("outside");
    let ran = root.at("ran");
    let mounter = mounter_with(&root, &format!("touch '{ran}'; {READY}"));
    let outside = Root::new("elsewhere");
    std::os::unix::fs::symlink(outside.path.join("chat"), root.path.join("link")).unwrap();
    let cases = [
        ("manifest", outside.at("chat/state/manifest.cmpf")),
        ("at", "chat/at".to_owned()),
        ("at", format!("{}/../{}", root.at("chat"), "chat/at")),
        ("at", root.at("link/at")),
        ("state", root.at("link/state")),
        ("state", root.at("")),
        ("at", root.at("chat/state/manifest.cmpf")),
        ("manifest", root.at("chat/at")),
        ("state", root.at("chat/missing")),
    ];
    for (key, path) in cases {
        let mut params = root.params();
        params[key] = json!(path);
        let answer = call(&mounter, "projfs.mount", &params);
        assert_eq!(answer["error_code"], "projfs.outside_roots", "{key} {path}: {answer}");
    }
    let mut params = root.params();
    params["mount"] = json!("../x");
    assert_eq!(call(&mounter, "projfs.mount", &params)["error_code"], "projfs.bad_request");
    params = root.params();
    params["extra"] = json!(1);
    assert_eq!(call(&mounter, "projfs.mount", &params)["error_code"], "projfs.bad_request");
    let unmount = json!({ "at": root.at("link/at"), "state": root.at("chat/state") });
    assert_eq!(call(&mounter, "projfs.unmount", &unmount)["error_code"], "projfs.outside_roots");
    assert!(!Path::new(&ran).exists(), "no helper ran for a refused request");
}

#[test]
fn a_helper_that_prints_nothing_in_time_is_ended_and_its_mount_undone() {
    let root = Root::new("timeout");
    let (pid_file, undone) = (root.at("pid"), root.at("undone"));
    let hang = format!("echo $$ > '{pid_file}'; exec tail -f /dev/null");
    let unmount = format!("touch '{undone}'; {UNMOUNTED}");
    let mounter = mounter(&root, &hang, &unmount, Duration::from_millis(500));
    let answer = call(&mounter, "projfs.mount", &root.params());
    assert_eq!(answer["error_code"], "projfs.helper_timeout", "{answer}");
    let pid: libc::pid_t = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    // SAFETY: signal 0 only asks whether the process exists.
    let alive = unsafe { libc::kill(pid, 0) } == 0;
    assert!(!alive, "the hung helper was ended and reaped");
    assert!(Path::new(&undone).exists(), "what the hung helper mounted was unmounted");
}

fn upper_mounter(root: &Root, upper: &str, wait: Duration, max_bytes: usize) -> Mounter {
    let roots = Roots::new([root.path.clone()]);
    let command = helper_with_upper(READY, UNMOUNTED, upper);
    Mounter::with_waits(roots, command, Duration::from_secs(10), Duration::from_secs(10))
        .with_upper_bounds(wait, max_bytes)
}

const CHANGES: &str = r#"echo '{"ok":true,"changes":[{"kind":"file","path":"a.txt"},{"kind":"symlink","link":"../x","path":"l"},{"from":"/old","kind":"redirect","path":"d"}]}'"#;

#[test]
fn the_upper_layer_is_answered_as_the_helper_printed_it_with_the_state_it_was_given() {
    let root = Root::new("upper");
    let args_file = root.at("args");
    let script = format!("printf '%s\\n' \"$@\" > '{args_file}'; {CHANGES}");
    let mounter = upper_mounter(&root, &script, Duration::from_secs(10), MAX_UPPER_BYTES);
    let params = json!({ "state": root.at("chat/state") });
    let answer = call(&mounter, "projfs.upper", &params);
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(
        answer["data"]["changes"][1],
        json!({"kind": "symlink", "link": "../x", "path": "l"})
    );
    assert_eq!(answer["data"]["changes"].as_array().unwrap().len(), 3);
    let args = std::fs::read_to_string(&args_file).unwrap();
    assert_eq!(args.lines().collect::<Vec<_>>(), ["upper", "--state", &root.at("chat/state")]);
    // The helper's own refusal is passed through, as for a mount.
    let refusing = upper_mounter(
        &root,
        r#"echo '{"ok":false,"code":"io","message":"cannot read"}'; exit 1"#,
        Duration::from_secs(10),
        MAX_UPPER_BYTES,
    );
    let answer = call(&refusing, "projfs.upper", &params);
    assert_eq!(answer["data"], json!({"ok": false, "code": "io", "message": "cannot read"}));
}

#[test]
fn the_upper_layer_is_the_macs_over_the_link_only_and_inside_the_roots() {
    let root = Root::new("upper-gate");
    let ran = root.at("ran");
    let mounter = upper_mounter(
        &root,
        &format!("touch '{ran}'; {CHANGES}"),
        Duration::from_secs(10),
        MAX_UPPER_BYTES,
    );
    let params = json!({ "state": root.at("chat/state") });
    for caller in [Caller::Local, Caller::Denied] {
        let label = format!("{caller:?}");
        let answer = answer_line(Some(&mounter), caller, None, &line("projfs.upper", &params));
        assert_eq!(answer["error_code"], "projfs.permission_denied", "{label}");
    }
    let outside = Root::new("upper-elsewhere");
    std::os::unix::fs::symlink(outside.path.join("chat"), root.path.join("link")).unwrap();
    for state in [outside.at("chat/state"), root.at("link/state"), root.at(""), "chat/state".into()]
    {
        let answer = call(&mounter, "projfs.upper", &json!({ "state": state }));
        assert_eq!(answer["error_code"], "projfs.outside_roots", "{state}: {answer}");
    }
    let extra = json!({ "state": root.at("chat/state"), "at": root.at("chat/at") });
    assert_eq!(call(&mounter, "projfs.upper", &extra)["error_code"], "projfs.bad_request");
    assert!(!Path::new(&ran).exists(), "no helper ran for a refused request");
    assert_eq!(frame_command(&line("projfs.upper", &params)), Some("projfs.upper"));
}

#[test]
fn a_mount_its_upper_layer_and_its_unmount_are_its_principals_alone() {
    let root = Root::new("owner");
    let (ran, undone) = (root.at("ran"), root.at("undone"));
    let upper = format!("touch '{ran}'; {CHANGES}");
    let unmount = format!("touch '{undone}'; {UNMOUNTED}");
    let roots = Roots::new([root.path.clone()]);
    let command = helper_with_upper(READY, &unmount, &upper);
    let mounter =
        Mounter::with_waits(roots, command, Duration::from_secs(10), Duration::from_secs(10));
    assert_eq!(call(&mounter, "projfs.mount", &root.params())["data"]["ok"], true);
    let state = json!({ "state": root.at("chat/state") });
    let both = json!({ "at": root.at("chat/at"), "state": root.at("chat/state") });
    // What a folder that is not there answers.
    let missing = call(&mounter, "projfs.upper", &json!({ "state": root.at("chat/missing") }));
    assert_eq!(missing["error_code"], "projfs.outside_roots");
    let mut again = root.params();
    again["mount"] = json!("p-2");
    for (cmd, params) in [
        ("projfs.upper", &state),
        ("projfs.unmount", &both),
        ("projfs.mount", &root.params()),
        ("projfs.mount", &again),
    ] {
        let theirs = call_as(&mounter, OTHER, cmd, params);
        assert_eq!(theirs["error_code"], missing["error_code"], "{cmd}: {theirs}");
        assert_eq!(theirs["error"], missing["error"], "{cmd}: {theirs}");
    }
    assert!(!Path::new(&ran).exists(), "no upper read ran for another principal");
    assert!(!Path::new(&undone).exists(), "no unmount ran for another principal");
    assert_eq!(call(&mounter, "projfs.upper", &state)["ok"], true);
    assert!(Path::new(&ran).exists());
    // The owner unmounts: the folders are free for whoever mounts them next.
    assert_eq!(call(&mounter, "projfs.unmount", &both)["data"]["ok"], true);
    assert_eq!(call_as(&mounter, OTHER, "projfs.mount", &root.params())["data"]["ok"], true);
}

#[test]
fn a_change_list_past_the_bound_is_refused_with_its_count() {
    let root = Root::new("upper-big");
    // 500 changes of about 40 bytes: past a 4 KiB bound.
    let script = r#"printf '{"ok":true,"changes":['; i=0; while [ $i -lt 500 ]; do [ $i -gt 0 ] && printf ','; printf '{"kind":"file","path":"f%04d"}' $i; i=$((i+1)); done; printf ']}\n'"#;
    let mounter = upper_mounter(&root, script, Duration::from_secs(10), 4096);
    let answer = call(&mounter, "projfs.upper", &json!({ "state": root.at("chat/state") }));
    assert_eq!(answer["error_code"], "projfs.too_many_changes", "{answer}");
    assert!(answer["error"].as_str().unwrap().contains("500 paths"), "{answer}");
    let fits = upper_mounter(&root, script, Duration::from_secs(10), 64 * 1024);
    let answer = call(&fits, "projfs.upper", &json!({ "state": root.at("chat/state") }));
    assert_eq!(answer["data"]["changes"].as_array().map(Vec::len), Some(500), "{answer}");
}

#[test]
fn an_upper_read_that_does_not_answer_in_time_is_ended() {
    let root = Root::new("upper-hang");
    let pid_file = root.at("pid");
    let hang = format!("echo $$ > '{pid_file}'; exec tail -f /dev/null");
    let mounter = upper_mounter(&root, &hang, Duration::from_millis(500), MAX_UPPER_BYTES);
    let answer = call(&mounter, "projfs.upper", &json!({ "state": root.at("chat/state") }));
    assert_eq!(answer["error_code"], "projfs.helper_timeout", "{answer}");
    let pid: libc::pid_t = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    // SAFETY: signal 0 only asks whether the process exists.
    assert!(unsafe { libc::kill(pid, 0) } != 0, "the hung reader was ended and reaped");
    let silent = upper_mounter(&root, "exit 0", Duration::from_secs(10), MAX_UPPER_BYTES);
    let answer = call(&silent, "projfs.upper", &json!({ "state": root.at("chat/state") }));
    assert_eq!(answer["error_code"], "projfs.helper_failed", "{answer}");
}
