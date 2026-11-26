/// interim-coord, 11-25: `cloud chat status --target vm:vm_...` was refused ("machine must be
/// machine:<id>"), though `vm:` is the form `cmux chat --on` and the machine list print.
#[test]
fn machine_id_takes_vm_and_machine_forms() {
    for form in
        ["machine:vm_55575f236c97ed2e811d", "vm:vm_55575f236c97ed2e811d", "vm_55575f236c97ed2e811d"]
    {
        assert_eq!(super::machine_id(form).as_deref(), Some("vm_55575f236c97ed2e811d"), "{form}");
    }
    assert_eq!(super::machine_id("vm:"), None);
    assert_eq!(super::machine_id("vm:a b"), None);
}
use super::*;

/// The prelude and a step run in a real `sh` against a stand-in `cmux-cua` that logs each
/// call and answers like the real one (exit 0, a refusal as a `"code"` field or a line);
/// `mode` picks a misbehaviour. None when this host has no `python3` (the machine image has it).
fn run_on_stub_desktop(op: &str, arguments: Value, mode: &str) -> Option<(i32, String, String)> {
    if cmux_process::Command::new("python3").arg("-c").arg("").status().is_err() {
        eprintln!("skipped: no python3 on this host");
        return None;
    }
    let dir =
        std::env::temp_dir().join(format!("cloud-computer-{}-{op}-{mode}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let log = dir.join("calls.log");
    let stub = format!(
        r#"#!/bin/sh
[ "$1" = status ] && exit 0
echo "$2 $3" >> {log}
case "{mode}:$2" in
  *:get_config) printf '%s\n' '{{' '  "capture_scope": "window"' '}}' ;;
  *:list_windows) printf '%s\n' '{{"windows":[{{"pid":null,"window_id":1,"x":0,"y":0,"width":1280,"height":800,"z_index":2,"is_on_screen":true}},{{"pid":42,"window_id":7,"x":100,"y":50,"width":800,"height":600,"z_index":1,"is_on_screen":true}}]}}' ;;
  *:press_key) printf '%s\n' '{{' '  "code": "background_unavailable"' '}}' ;;
  crash:click) echo 'thread main panicked' >&2; exit 101 ;;
  garbage:click) echo 'Socket /home/cmux/.cache/cmux-cua/cmux-cua.sock not found' ;;
  *) echo '{{"ok":true}}' ;;
esac
"#,
        log = log.display()
    );
    let bin = dir.join("cmux-cua");
    std::fs::write(&bin, stub).unwrap();
    std::fs::set_permissions(&bin, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let step = desktop_step(op, arguments.as_object().unwrap()).unwrap();
    // The machine's bin dir becomes the stand-in's.
    let prelude = DESKTOP_PRELUDE.replace("/opt/cmux/current/bin", &dir.display().to_string());
    let output = cmux_process::Command::new("sh")
        .arg("-c")
        .arg(format!("{prelude}{}", step.script))
        .output()
        .unwrap();
    Some((
        output.status.code().unwrap_or(-1),
        std::fs::read_to_string(&log).unwrap_or_default(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    ))
}

#[test]
fn input_on_a_window_goes_to_the_frontmost_app_window_there_in_its_own_coordinates() {
    let drag = json!({"op": "drag", "x": 300, "y": 200, "to_x": 2000, "to_y": 10});
    let Some((code, calls, stderr)) = run_on_stub_desktop("drag", drag, "") else { return };
    assert_eq!(code, 0, "{stderr}");
    let sent = calls.lines().find(|line| line.starts_with("drag ")).expect(&calls);
    let sent: Value = serde_json::from_str(sent.trim_start_matches("drag ")).unwrap();
    // The pid-less cursor overlay is skipped; window 7 spans 100..900 x 50..650, and the end
    // point is kept inside it.
    assert_eq!(
        sent,
        json!({"from_x": 200, "from_y": 150, "to_x": 799, "to_y": 0, "pid": 42,
               "window_id": 7, "delivery_mode": "foreground"})
    );

    let scroll = json!({"op": "scroll", "x": 5, "y": 5, "direction": "down"});
    let Some((code, calls, stderr)) = run_on_stub_desktop("scroll", scroll, "") else { return };
    assert_eq!(code, 1, "no app window at 5,5: {calls}");
    assert!(stderr.contains("no app window there"), "{stderr}");
    assert!(!calls.contains("scroll "), "nothing scrolled: {calls}");
}

#[test]
fn the_step_uses_desktop_scope_and_gives_the_daemon_its_own_back() {
    let click = json!({"op": "click", "x": 3, "y": 4});
    let Some((code, calls, stderr)) = run_on_stub_desktop("click", click, "") else { return };
    assert_eq!(code, 0, "{stderr}");
    let lines = calls.lines().collect::<Vec<_>>();
    assert_eq!(
        lines,
        [
            "get_config {}",
            "set_config {\"capture_scope\":\"desktop\"}",
            "click {\"button\":\"left\",\"x\":3,\"y\":4}",
            "set_config {\"capture_scope\":\"window\"}",
        ],
        "{calls}"
    );
}

#[test]
fn a_refusal_a_crash_or_an_unknown_answer_fails_the_step() {
    let key = json!({"op": "key", "keys": "Return"});
    let Some((code, _, stderr)) = run_on_stub_desktop("key", key, "") else { return };
    assert_eq!(code, 1);
    assert!(
        stderr.contains("cmux-cua press_key") && stderr.contains("background_unavailable"),
        "{stderr}"
    );
    for mode in ["crash", "garbage"] {
        let click = json!({"op": "click", "x": 3, "y": 4});
        let Some((code, _, stderr)) = run_on_stub_desktop("click", click, mode) else { return };
        assert_eq!(code, 1, "{mode}: {stderr}");
        assert!(stderr.contains("cmux-cua click"), "{mode}: {stderr}");
    }
}

#[test]
fn move_moves_the_real_pointer() {
    let step =
        desktop_step("move", json!({"op": "move", "x": 5, "y": 6}).as_object().unwrap()).unwrap();
    assert_eq!(step.script, "pointer_to 5 6");
}

#[test]
fn open_url_opens_one_quoted_word_in_chrome() {
    let step = desktop_step(
        "open_url",
        json!({"op": "open_url", "url": "https://a.test/?q=x&y='1'"}).as_object().unwrap(),
    )
    .unwrap();
    assert_eq!(step.script, r#"chief_chrome 'https://a.test/?q=x&y='\''1'\'''"#);
}

#[test]
fn every_description_stays_short() {
    for tool in descriptors() {
        let description = tool["description"].as_str().unwrap();
        assert!(description.len() < 300, "{}: {} chars", tool["name"], description.len());
    }
}
