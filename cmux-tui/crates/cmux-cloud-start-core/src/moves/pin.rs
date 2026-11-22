//! The app's pinned Linux build for a Cloud machine too old to update in place (the legacy exec
//! update): the commit the machine's daemon reports once it runs it, and the binary's SHA-256.
//! Both reach a shell on the machine, so anything that is not plain lowercase hex is refused.
//!
//! The pin is the app bundle's own manifest (`Resources/bin/cmux-tui-ssh/manifest.json`, the one
//! `cmux link machine update` reads). A DEV build ships none; its `cmux` client then names the pin
//! itself (`cmux link machine pin`, cmux-tui `link/machine_pin.rs`).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// The Rust target of every Cloud machine's binary (x86_64, the release's static build).
pub const TARGET: &str = "x86_64-unknown-linux-musl";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pin {
    /// The build's commit: the `build` its daemon reports.
    pub commit: String,
    /// SHA-256 of the binary.
    pub sha256: String,
}

/// `count` lowercase hex digits.
pub fn is_hex(text: &str, count: usize) -> bool {
    text.len() == count
        && text.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// The pin in a `cmux-tui-ssh/manifest.json`: `commit` (40 hex) and the x86_64 Linux binary's
/// digest (64 hex), both lower-cased.
pub fn from_manifest(manifest: &str) -> Option<Pin> {
    #[derive(Deserialize)]
    struct Manifest {
        commit: String,
        binaries: BTreeMap<String, String>,
    }
    let manifest: Manifest = serde_json::from_str(manifest).ok()?;
    let sha256 = manifest.binaries.get(&format!("cmux-tui-{TARGET}"))?.to_lowercase();
    let commit = manifest.commit.to_lowercase();
    (is_hex(&commit, 40) && is_hex(&sha256, 64)).then_some(Pin { commit, sha256 })
}

/// The pin in `cmux link machine pin`'s output: its last line,
/// `{"ok":true,"commit":..,"sha256":..,"target":"x86_64-unknown-linux-musl"}`. Any other answer
/// (`ok` false, another target, a value that is not lowercase hex) is none.
pub fn from_answer(answer: &str) -> Option<Pin> {
    #[derive(Deserialize)]
    struct Answer {
        ok: bool,
        commit: Option<String>,
        sha256: Option<String>,
        target: Option<String>,
    }
    let line = answer.lines().rev().find(|line| !line.trim().is_empty())?;
    let answer: Answer = serde_json::from_str(line).ok()?;
    let (commit, sha256) = (answer.commit?, answer.sha256?);
    (answer.ok
        && answer.target.as_deref() == Some(TARGET)
        && is_hex(&commit, 40)
        && is_hex(&sha256, 64))
    .then_some(Pin { commit, sha256 })
}

/// The bundled pin when it is `build`'s (a manifest of another build is not this app's): `build`,
/// lower-cased and at least 7 characters, and the pin's commit, one a prefix of the other.
pub fn for_build(build: &str, bundled: Pin) -> Option<Pin> {
    let build = build.to_lowercase();
    (build.len() >= 7 && (bundled.commit.starts_with(&build) || build.starts_with(&bundled.commit)))
        .then_some(bundled)
}

#[cfg(test)]
mod tests {
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
        assert_eq!(
            from_manifest(&good),
            Some(Pin { commit: d.clone(), sha256: sha.to_lowercase() })
        );
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
}
