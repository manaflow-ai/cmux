//! The commit part of the build id. `build.rs` includes this file with
//! `#[path]`, and the library compiles it only under `cfg(test)` so its unit
//! tests run with `cargo test -p acpmux`. Keep it std-only: a build script
//! cannot use the crate's dependencies.
//!
//! A source archive has no `.git`, so it sets CMUX_GIT_SHORT_SHA to the commit
//! it was exported from. Git wins whenever it is available, so a checkout never
//! reports a commit other than its own.

/// Length of the hash in the build id, as `git rev-parse --short=9 HEAD`.
pub const SHORT_LEN: usize = 9;

/// Validates a CMUX_GIT_SHORT_SHA value: 7 to 40 lowercase hex characters.
pub fn validate(raw: &str) -> Result<&str, String> {
    let _ = raw;
    todo!()
}

/// Picks the hash for the build id from git's short hash (when git is
/// available) and a validated CMUX_GIT_SHORT_SHA. Returns the hash and a
/// warning when both exist and name different commits.
pub fn choose(git: Option<&str>, env: Option<&str>) -> (String, Option<String>) {
    let _ = (git, env);
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_accepts_7_to_40_lowercase_hex() {
        assert_eq!(validate("abcdef1"), Ok("abcdef1"));
        assert_eq!(validate("0123456789"), Ok("0123456789"));
        let full = "c8835be325a8ccec55bf13601bcfe871e2da8a20";
        assert_eq!(validate(full), Ok(full));
    }

    #[test]
    fn validate_rejects_everything_else() {
        for bad in [
            "",
            "abcdef",
            "c8835be325a8ccec55bf13601bcfe871e2da8a201",
            "C8835BE325A",
            "c8835be32g",
            " c8835be325",
            "c8835be325\n",
        ] {
            assert!(validate(bad).is_err(), "{bad:?} must be rejected");
        }
    }

    #[test]
    fn git_wins_and_env_is_ignored_when_it_agrees() {
        assert_eq!(choose(Some("c8835be32"), None), ("c8835be32".into(), None));
        assert_eq!(choose(Some("c8835be32"), Some("c8835be")), ("c8835be32".into(), None));
        let full = "c8835be325a8ccec55bf13601bcfe871e2da8a20";
        assert_eq!(choose(Some("c8835be32"), Some(full)), ("c8835be32".into(), None));
    }

    #[test]
    fn git_wins_with_a_warning_when_env_disagrees() {
        let (hash, warning) = choose(Some("c8835be32"), Some("1378641b3c0"));
        assert_eq!(hash, "c8835be32");
        let warning = warning.expect("a mismatch must warn");
        assert!(warning.contains("c8835be32") && warning.contains("1378641b3c0"), "{warning}");
    }

    #[test]
    fn env_is_used_without_git_and_matches_the_git_length() {
        let full = "c8835be325a8ccec55bf13601bcfe871e2da8a20";
        assert_eq!(choose(None, Some(full)), ("c8835be32".into(), None));
        assert_eq!(choose(None, Some("c8835be")), ("c8835be".into(), None));
    }

    #[test]
    fn nogit_without_either() {
        assert_eq!(choose(None, None), ("nogit".into(), None));
    }
}
