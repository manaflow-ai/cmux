//! The cmux CLI (installed in the app as `Contents/Resources/bin/cmux`) and
//! its sibling binaries embed only browser ids and names. The app's browser
//! registry also lists each browser's data directories, profile file names
//! and Keychain service names; none of that is in a client binary
//! (`scripts/ci/check-browser-data-import-absent.sh` checks the same
//! patterns over the whole app bundle).

use regex::bytes::Regex;

#[test]
fn client_binaries_carry_no_browser_data_targets() {
    // cmux's own "cmux Safe Storage" item would not match: the pattern needs
    // capitalized words before "Safe Storage".
    let pattern = Regex::new(
        r#"([A-Z][A-Za-z0-9]*( [A-Z][A-Za-z0-9]*)* Safe Storage)|Login Data|logins\.json|key4\.db|cookies\.sqlite|places\.sqlite|Network/Cookies|Cookies\.binarycookies|dataDirectories"#,
    )
    .unwrap();
    let mut found = Vec::new();
    for bin in [
        env!("CARGO_BIN_EXE_cmux-tui"),
        env!("CARGO_BIN_EXE_cmux-tui-hook"),
        env!("CARGO_BIN_EXE_cmux-tui-host"),
    ] {
        let bytes = std::fs::read(bin).unwrap_or_else(|error| panic!("read {bin}: {error}"));
        let mut hits: Vec<String> = pattern
            .find_iter(&bytes)
            .map(|hit| String::from_utf8_lossy(hit.as_bytes()).into_owned())
            .collect();
        hits.sort();
        hits.dedup();
        if !hits.is_empty() {
            found.push(format!("{bin}: {hits:?}"));
        }
    }
    assert!(found.is_empty(), "browser data targets in client binaries:\n{}", found.join("\n"));
}
