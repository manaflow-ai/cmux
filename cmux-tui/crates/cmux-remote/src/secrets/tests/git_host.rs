//! `git-host-tokens-v1`: the person's own token for one git host.

use super::*;

const HOST: &str = "github.com";

fn token_file(fixture: &Fixture) -> std::path::PathBuf {
    files::git_hosts_dir(&fixture.home).join(HOST)
}

#[test]
fn a_git_host_token_is_written_0600_in_a_0700_folder_and_removed() {
    let fixture = fixture(&[]);
    let token = format!("gho_{}", random_hex(18));
    let item = fixture.seal(Purpose::GitHost, HOST, &token);
    assert!(fixture.secrets.replace_git_host_token(HOST, Some(&item)).unwrap());
    let path = token_file(&fixture);
    assert_eq!(std::fs::read_to_string(&path).unwrap(), format!("{token}\n"));
    assert_eq!(mode(&path), 0o600);
    assert_eq!(mode(&files::git_hosts_dir(&fixture.home)), 0o700);
    // The same sealed item again is a replay.
    let again = fixture.secrets.replace_git_host_token(HOST, Some(&item)).unwrap_err();
    assert!(again.message.starts_with("replay"), "{}", again.message);
    // Forget removes it; a second forget is fine.
    assert!(!fixture.secrets.replace_git_host_token(HOST, None).unwrap());
    assert!(!path.exists());
    assert!(!fixture.secrets.replace_git_host_token(HOST, None).unwrap());
    assert_no_value(&[&token], &fixture.logs());
}

#[test]
fn a_git_host_token_needs_its_purpose_its_host_and_one_plain_line() {
    let fixture = fixture(&["GITHUB_TOKEN"]);
    let token = format!("gho_{}", random_hex(18));
    // Sealed as a machine secret: does not open as a git host token.
    let wrong_purpose = fixture.seal(Purpose::Secret, HOST, &token);
    let error = fixture.secrets.replace_git_host_token(HOST, Some(&wrong_purpose)).unwrap_err();
    assert!(error.message.starts_with("open-failed"), "{}", error.message);
    // Named for another host than the request's.
    let other = fixture.seal(Purpose::GitHost, "gitlab.com", &token);
    let error = fixture.secrets.replace_git_host_token(HOST, Some(&other)).unwrap_err();
    assert!(error.message.starts_with("bad-name"), "{}", error.message);
    // Not one plain line.
    for bad in ["two\nlines", "a space", ""] {
        let item = fixture.seal(Purpose::GitHost, HOST, bad);
        let error = fixture.secrets.replace_git_host_token(HOST, Some(&item)).unwrap_err();
        assert!(error.message.starts_with("bad-value"), "{}", error.message);
    }
    // A host that is not a file name.
    for host in ["../x", "a/b", "UPPER.com", ".hidden"] {
        let item = fixture.seal(Purpose::GitHost, host, &token);
        let error = fixture.secrets.replace_git_host_token(host, Some(&item)).unwrap_err();
        assert!(error.message.starts_with("bad-name"), "{}", error.message);
    }
    assert!(!token_file(&fixture).exists());
    assert_no_value(&[&token], &fixture.logs());
}

#[test]
fn a_symlinked_git_hosts_folder_is_never_written_through() {
    let fixture = fixture(&[]);
    let elsewhere = fixture.home.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    std::fs::create_dir_all(fixture.home.join(".config/cmux")).unwrap();
    std::os::unix::fs::symlink(&elsewhere, files::git_hosts_dir(&fixture.home)).unwrap();
    let item = fixture.seal(Purpose::GitHost, HOST, "gho_x");
    assert!(fixture.secrets.replace_git_host_token(HOST, Some(&item)).is_err());
    assert!(!elsewhere.join(HOST).exists());
    assert!(fixture.secrets.replace_git_host_token(HOST, None).is_err());
}
