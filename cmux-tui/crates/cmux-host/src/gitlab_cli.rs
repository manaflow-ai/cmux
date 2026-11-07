//! `cmux gitlab credential get|store|erase` on a cmux Cloud machine: a git
//! credential helper for GitLab and every other git host that is not
//! GitHub (GitHub has `cmux github credential`, with tokens the Cloud agent
//! mints).
//!
//! The person's token for a host arrives sealed to the machine over the
//! carrier (`secrets-v1`) and the daemon writes it to
//! `~/.config/cmux/git-hosts/<host>` (0600, one line). `get` reads that file
//! for the host git names and answers `username=oauth2` and
//! `password=<token>` (GitLab takes any username with a personal, group or
//! project access token; `oauth2` is the one its docs use). `store` and
//! `erase` do nothing: the file is the daemon's, and git never writes it.
//!
//! The token lives only in that file, this process and the git process it
//! answers. Nothing here prints it anywhere but the credential protocol's
//! stdout. It goes over https only; plain http only to a loopback host
//! (tests). A file that is a symlink, not ours, readable by anyone else or
//! not one plain line is refused, with a note on stderr that names the
//! file, never its content.

use std::io::{Read as _, Write as _};
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

use crate::github_cli::parse_credential_input;

const USAGE: &str = "usage: cmux gitlab credential get|store|erase";
/// Under `$HOME`: one file per host, named by its authority (`gitlab.com`,
/// `git.example.com:8443`).
pub const TOKENS_DIR: &str = ".config/cmux/git-hosts";
/// The longest token read (GitLab's are well under 100 bytes).
const MAX_TOKEN_BYTES: u64 = 4096;

/// The file that holds `authority`'s token, or None when the name is not a
/// plain lowercase host with an optional port (no path, no `..`).
#[must_use]
pub fn token_path(home: &Path, authority: &str) -> Option<PathBuf> {
    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (host, Some(port)),
        None => (authority, None),
    };
    let host_ok = !host.is_empty()
        && host.len() <= 253
        && !host.starts_with(['.', '-'])
        && !host.contains("..")
        && host
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'-');
    let port_ok =
        port.is_none_or(|p| !p.is_empty() && p.len() <= 5 && p.bytes().all(|b| b.is_ascii_digit()));
    (host_ok && port_ok).then(|| home.join(TOKENS_DIR).join(authority))
}

/// `localhost` or a loopback address, with any port.
/// Parsed as an address: `127.attacker.example` is a name, not loopback.
fn loopback(authority: &str) -> bool {
    let host = authority.rsplit_once(':').map_or(authority, |(host, _)| host);
    host == "localhost" || host.parse::<std::net::Ipv4Addr>().is_ok_and(|ip| ip.is_loopback())
}

/// GitHub's hosts go to `cmux github credential`, never here.
fn github(authority: &str) -> bool {
    let host = authority.rsplit_once(':').map_or(authority, |(host, _)| host);
    host == "github.com" || host.ends_with(".github.com")
}

/// Reads the token file: a regular file of this user, not a symlink, with
/// no group or other bits, one line of printable ASCII. Errors name the
/// rule broken, never the content.
fn read_token(path: &Path) -> Result<Option<String>, String> {
    let file = match std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(format!("cannot open {} (a symlink is refused)", path.display())),
    };
    let meta = file.metadata().map_err(|_| format!("cannot read {}", path.display()))?;
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    if !meta.is_file() || meta.uid() != uid || meta.mode() & 0o077 != 0 {
        return Err(format!("{} must be a 0600 file of this user", path.display()));
    }
    let mut text = String::new();
    file.take(MAX_TOKEN_BYTES + 1)
        .read_to_string(&mut text)
        .map_err(|_| format!("{} is not text", path.display()))?;
    let token = text.strip_suffix('\n').unwrap_or(&text);
    if token.is_empty()
        || token.len() as u64 > MAX_TOKEN_BYTES
        || !token.bytes().all(|b| b.is_ascii_graphic())
    {
        return Err(format!("{} must hold one token on one line", path.display()));
    }
    Ok(Some(token.to_owned()))
}

/// The helper's answer to git's `get` request `input`, with tokens under
/// `home`: what goes to stdout (empty when this helper has nothing for the
/// host, so git tries its next helper) and a note for stderr.
#[must_use]
pub fn credential_get(input: &str, home: &Path) -> (String, Option<String>) {
    let desc = parse_credential_input(input);
    let field = |k: &str| desc.get(k).and_then(serde_json::Value::as_str).unwrap_or("");
    let authority = field("host").to_ascii_lowercase();
    let secure = match field("protocol") {
        "https" => true,
        "http" => loopback(&authority),
        _ => false,
    };
    if !secure || github(&authority) {
        return (String::new(), None);
    }
    let Some(path) = token_path(home, &authority) else {
        return (String::new(), Some(format!("{authority} is not a plain host name")));
    };
    match read_token(&path) {
        Ok(Some(token)) => (format!("username=oauth2\npassword={token}\n"), None),
        Ok(None) => (String::new(), Some(format!("no token for {authority} on this machine"))),
        Err(note) => (String::new(), Some(note)),
    }
}

fn usage(why: &str) -> u8 {
    eprintln!("cmux gitlab: {why}\n{USAGE}");
    2
}

fn credential(args: &[String]) -> u8 {
    match args {
        [op] if op == "get" => {}
        // The daemon owns the token file: nothing to store or erase.
        [op] if op == "store" || op == "erase" => {
            let _ = std::io::copy(&mut std::io::stdin(), &mut std::io::sink());
            return 0;
        }
        _ => return usage("credential takes get, store or erase"),
    }
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        return 1;
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        eprintln!("cmux gitlab credential: HOME is not set");
        return 0;
    };
    let (out, note) = credential_get(&input, &home);
    if let Some(note) = note {
        eprintln!("cmux gitlab credential: {note}");
    }
    let _ = std::io::stdout().write_all(out.as_bytes());
    0
}

/// `cmux gitlab ARGS`; its exit code.
pub fn run(args: &[String]) -> u8 {
    let Some((verb, rest)) = args.split_first() else { return usage("missing verb") };
    match verb.as_str() {
        "credential" => credential(rest),
        "--help" | "-h" | "help" => {
            println!("{USAGE}");
            0
        }
        other => usage(&format!("unknown verb {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt as _;

    const TOKEN: &str = "glpat-fake0000000000000000";

    struct Home(PathBuf);

    impl Home {
        fn new(label: &str) -> Self {
            let path =
                std::env::temp_dir().join(format!("cmux-gitlab-{label}-{}", std::process::id()));
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
}
