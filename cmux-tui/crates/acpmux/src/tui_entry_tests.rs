use super::pick_handoff;
use std::fs;

fn file(path: &std::path::Path) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, b"").unwrap();
}

fn yes(_: &std::path::Path) -> bool {
    true
}

#[test]
fn a_cmux_without_acpmux_is_passed_over() {
    // A lane VM's cmux client answers `cmux acp` with "unknown resource scope": skip it.
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("bin/acpmux");
    let client = dir.path().join("bin/cmux");
    let multicall = dir.path().join("app/cmux");
    file(&exe);
    file(&client);
    file(&multicall);
    let path = Some(dir.path().join("app").into_os_string());
    let carries = |p: &std::path::Path| p == multicall.as_path();
    assert_eq!(
        pick_handoff(false, None, Some(&exe), path.clone(), carries),
        Some(multicall.clone())
    );
    assert_eq!(pick_handoff(false, None, Some(&exe), path, |_: &std::path::Path| false), None);
}

#[test]
fn a_headless_acpmux_hands_off_to_the_cmux_beside_it_before_one_on_path() {
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("bin/acpmux");
    let sibling = dir.path().join("bin/cmux");
    let other = dir.path().join("other/cmux");
    file(&exe);
    file(&sibling);
    file(&other);
    let path = Some(dir.path().join("other").into_os_string());
    assert_eq!(pick_handoff(false, None, Some(&exe), path.clone(), yes), Some(sibling.clone()));
    fs::remove_file(&sibling).unwrap();
    assert_eq!(pick_handoff(false, None, Some(&exe), path.clone(), yes), Some(other.clone()));
    // ACPMUX_TUI wins; a missing one is skipped.
    let named = dir.path().join("named-cmux");
    assert_eq!(
        pick_handoff(false, Some(named.clone().into_os_string()), Some(&exe), path.clone(), yes),
        Some(other.clone())
    );
    file(&named);
    assert_eq!(
        pick_handoff(false, Some(named.clone().into_os_string()), Some(&exe), path.clone(), yes),
        Some(named)
    );
}

#[test]
fn a_handed_off_process_and_this_executable_itself_never_hand_off() {
    let dir = tempfile::tempdir().unwrap();
    let exe = dir.path().join("cmux");
    file(&exe);
    let path = Some(dir.path().as_os_str().to_owned());
    // The only `cmux` is this executable (a headless build named cmux): no loop.
    assert_eq!(pick_handoff(false, None, Some(&exe), path.clone(), yes), None);
    let other = dir.path().join("b/cmux");
    file(&other);
    assert_eq!(
        pick_handoff(true, None, Some(&exe), Some(other.parent().unwrap().into()), yes),
        None
    );
    assert_eq!(pick_handoff(false, None, None, None, yes), None);
}
