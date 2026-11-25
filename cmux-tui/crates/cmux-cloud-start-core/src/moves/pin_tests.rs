use super::*;

fn answer(ok: bool, commit: &str, sha: &str, target: &str) -> String {
    format!(r#"{{"ok":{ok},"commit":"{commit}","sha256":"{sha}","target":"{target}"}}"#)
}

/// The pin is the app bundle's own manifest; anything that is not plain hex is refused.
#[test]
fn the_pin_comes_from_the_bundled_manifest_only() {
    let sha = "C".repeat(64);
    let d = "d".repeat(40);
    let good = format!(
        r#"{{"commit":"{d}","binaries":{{"cmux-tui-x86_64-unknown-linux-musl":"{sha}","cmux-tui-aarch64-unknown-linux-musl":"x"}}}}"#
    );
    assert_eq!(from_manifest(&good), Some(Pin { commit: d.clone(), sha256: sha.to_lowercase() }));
    assert_eq!(
        from_manifest(&format!(
            r#"{{"commit":"d; rm -rf /","binaries":{{"cmux-tui-x86_64-unknown-linux-musl":"{sha}"}}}}"#
        )),
        None
    );
    assert_eq!(from_manifest(&format!(r#"{{"commit":"{d}","binaries":{{}}}}"#)), None);
    assert_eq!(from_manifest("{corrupt"), None);
}

/// A DEV build ships no manifest: `cmux link machine pin` names the pin. Anything but a
/// well-formed ok line for the Cloud target is none.
#[test]
fn a_dev_build_takes_the_pin_its_cli_names() {
    let (commit, sha) = ("e".repeat(40), "f".repeat(64));
    let good = answer(true, &commit, &sha, TARGET);
    assert_eq!(
        from_answer(&format!("noise\n{good}\n")),
        Some(Pin { commit: commit.clone(), sha256: sha.clone() })
    );
    assert_eq!(from_answer(&answer(false, &commit, &sha, TARGET)), None);
    assert_eq!(from_answer(&answer(true, &commit, &sha, "aarch64-unknown-linux-musl")), None);
    assert_eq!(from_answer(&answer(true, "e; rm -rf /", &sha, TARGET)), None);
    assert_eq!(from_answer(&answer(true, &commit, &sha.to_uppercase(), TARGET)), None);
    assert_eq!(
        from_answer(r#"{"ok":false,"error_code":"machine_update_unavailable","error":"none"}"#),
        None
    );
}

/// The exec path runs only for the build this app pins.
#[test]
fn the_exec_path_runs_only_for_the_pinned_build() {
    let pin = Pin { commit: "b".repeat(40), sha256: "a".repeat(64) };
    assert_eq!(for_build(&"B".repeat(12), pin.clone()), Some(pin.clone()));
    assert_eq!(for_build(&format!("{}ff", "b".repeat(40)), pin.clone()), Some(pin.clone()));
    assert_eq!(for_build(&"c".repeat(12), pin.clone()), None);
    assert_eq!(for_build("bbbbbb", pin), None, "too short to name a build");
}

#[test]
fn hex_is_lowercase_digits_of_the_count() {
    assert!(is_hex(&"0a".repeat(20), 40));
    assert!(!is_hex(&"0A".repeat(20), 40));
    assert!(!is_hex("abc", 40));
}
