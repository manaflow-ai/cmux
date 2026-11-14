use super::*;
use std::os::unix::fs::PermissionsExt as _;

const TOKEN: &str = "glpat-fake0000000000000000";

struct Home(PathBuf);

impl Home {
    fn new(label: &str) -> Self {
        let path = std::env::temp_dir().join(format!("cmux-gitlab-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(path.join(TOKENS_DIR)).unwrap();
        Self(path)
    }

    fn token(&self, host: &str, text: &str, mode: u32) -> PathBuf {
        let path = self.0.join(TOKENS_DIR).join(host);
        std::fs::write(&path, text).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
        path
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn ask(protocol: &str, host: &str) -> String {
    format!("protocol={protocol}\nhost={host}\npath=group/sub/project.git\n\n")
}

#[test]
fn a_host_with_a_token_gets_it_over_https() {
    let home = Home::new("get");
    home.token("gitlab.com", &format!("{TOKEN}\n"), 0o600);
    let (out, note) = credential_get(&ask("https", "gitlab.com"), &home.0);
    assert_eq!(out, format!("username=oauth2\npassword={TOKEN}\n"));
    assert_eq!(note, None);
    // A self-hosted GitLab on its own port has its own file.
    home.token("git.example.com:8443", TOKEN, 0o600);
    let (out, _) = credential_get(&ask("https", "git.example.com:8443"), &home.0);
    assert!(out.ends_with(&format!("password={TOKEN}\n")));
}

#[test]
fn plain_http_github_and_unknown_hosts_get_nothing() {
    let home = Home::new("refuse");
    home.token("gitlab.com", TOKEN, 0o600);
    home.token("github.com", TOKEN, 0o600);
    assert_eq!(credential_get(&ask("http", "gitlab.com"), &home.0).0, "");
    assert_eq!(credential_get(&ask("ssh", "gitlab.com"), &home.0).0, "");
    assert_eq!(credential_get(&ask("https", "github.com"), &home.0), (String::new(), None));
    let (out, note) = credential_get(&ask("https", "codeberg.org"), &home.0);
    assert_eq!(out, "");
    assert!(note.unwrap().contains("no token for codeberg.org"));
    // Loopback http is allowed (a local test server).
    home.token("127.0.0.1:9000", TOKEN, 0o600);
    assert!(credential_get(&ask("http", "127.0.0.1:9000"), &home.0).0.contains(TOKEN));
    // A name that only starts like a loopback address gets nothing over plain http.
    home.token("127.attacker.example", TOKEN, 0o600);
    assert_eq!(credential_get(&ask("http", "127.attacker.example"), &home.0).0, "");
    assert!(credential_get(&ask("https", "127.attacker.example"), &home.0).0.contains(TOKEN));
}

#[test]
fn unsafe_files_and_names_are_refused_without_their_content() {
    let home = Home::new("unsafe");
    home.token("gitlab.com", TOKEN, 0o644);
    let (out, note) = credential_get(&ask("https", "gitlab.com"), &home.0);
    assert_eq!(out, "");
    let note = note.unwrap();
    assert!(note.contains("0600") && !note.contains(TOKEN), "{note}");
    home.token("gitlab.com", &format!("{TOKEN}\nsecond line\n"), 0o600);
    let (out, note) = credential_get(&ask("https", "gitlab.com"), &home.0);
    assert_eq!(out, "");
    assert!(!note.unwrap().contains(TOKEN));
    // A symlink to a readable file is not followed.
    let target = home.token("elsewhere", TOKEN, 0o600);
    let link = home.0.join(TOKENS_DIR).join("gitlab.example.org");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    assert_eq!(credential_get(&ask("https", "gitlab.example.org"), &home.0).0, "");
    for bad in ["../x", "a/b", "", ".hidden", "Host:", "h:99999x"] {
        assert_eq!(token_path(&home.0, bad), None, "{bad}");
    }
}
