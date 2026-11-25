//! The acpmux binary carries `<version> (<build id>)` as one string, where
//! every acpmux updater finds it. `host update` and `host self-update` read
//! the build id out of the new binary's bytes without running it, with the
//! first `<digit> (<build id>)` they meet (`embedded_build`,
//! `src/cli/host_update.rs`). That scan runs in the old, installed binary, so
//! the new binary has to keep the string where the oldest updater looks: when
//! cmux#28776 moved the version text to run time, only the bare build id was
//! left, the scan took rustc's `rustc version 1.95.0 (<hash> <date>)` and
//! every Linux self-update failed as a push mismatch.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts nothing; it only reads the binary.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

/// The scan as acpmux updaters before acpmux-build-id's `STAMP` ran it: the
/// first `<digit> (<hash>[+dirty.<fp>] <date>)`.
fn old_updater_scan(bytes: &[u8]) -> Option<String> {
    let mut from = 0;
    while let Some(i) = bytes[from..].windows(2).position(|w| w == b" (") {
        let at = from + i;
        from = at + 2;
        if at == 0 || !bytes[at - 1].is_ascii_digit() {
            continue;
        }
        let rest = &bytes[from..bytes.len().min(from + 80)];
        let Some(end) = rest.iter().position(|&b| b == b')') else { continue };
        let Ok(text) = std::str::from_utf8(&rest[..end]) else { continue };
        let Some((head, date)) = text.split_once(' ') else { continue };
        let hash = head.split_once('+').map_or(head, |(h, _)| h);
        let hex = hash.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
        let date_ok = date.len() == 10
            && date
                .bytes()
                .enumerate()
                .all(|(i, b)| if i == 4 || i == 7 { b == b'-' } else { b.is_ascii_digit() });
        if (7..=40).contains(&hash.len()) && hex && date_ok {
            return Some(text.to_owned());
        }
    }
    None
}

#[test]
fn the_binary_holds_its_version_and_build_id_as_one_string_an_old_updater_finds() {
    let bytes = std::fs::read(daemon_env::bin()).unwrap();
    let build = acpmux::hub::build();
    let line = format!("{} ({build})", acpmux::hub::VERSION);
    assert!(
        bytes.windows(line.len()).any(|w| w == line.as_bytes()),
        "the acpmux binary does not contain `{line}` as one string"
    );
    if build.split_once(' ').is_some_and(|(hash, _)| hash.len() >= 7) {
        assert_eq!(old_updater_scan(&bytes).as_deref(), Some(build));
    }
}
