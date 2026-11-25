//! `git-cache credential get|store|erase`: git asks credentials for the proxy's URL
//! (`http://127.0.0.1:PORT/github.com/OWNER/REPO.git`); this maps the request back to
//! `https://github.com/OWNER/REPO.git` and asks the machine's own helpers for it with
//! `git credential fill|approve|reject` (lane-gh-credential, `cmux github credential`, the
//! person's). Nothing is printed for any other URL. Never prompts.
//!
//! It also carries the chat's `CMUX_GIT_CACHE` switch (`switch`): with the switch off it
//! answers the off marker, and with no credential of the person's the anonymous marker, so the
//! proxy's challenge always gets an answer. `store` and `erase` of a marker do nothing.

use cmux_process::{Command, Stdio};
use std::io::{Read, Write};

/// The rewritten request, or `None` when it is not one of the proxy's github.com paths.
pub fn map_request(input: &str) -> Option<String> {
    let mut path = None;
    let mut rest = Vec::new();
    for line in input.lines() {
        if line.is_empty() {
            break;
        }
        let (key, value) = line.split_once('=')?;
        match key {
            "protocol" | "host" => {}
            "path" => path = Some(value.to_owned()),
            _ => rest.push(line.to_owned()),
        }
    }
    let gh_path = path?.strip_prefix("github.com/")?.to_owned();
    let mut out = format!("protocol=https\nhost=github.com\npath={gh_path}\n");
    for line in rest {
        out.push_str(&line);
        out.push('\n');
    }
    Some(out)
}

/// Keeps only what a helper answer may carry back to git.
pub fn filter_answer(answer: &str) -> String {
    answer
        .lines()
        .filter(|l| {
            l.split_once('=').is_some_and(|(k, _)| {
                matches!(
                    k,
                    "username"
                        | "password"
                        | "password_expiry_utc"
                        | "oauth_refresh_token"
                        | "authtype"
                        | "credential"
                )
            })
        })
        .map(|l| format!("{l}\n"))
        .collect()
}

pub fn run(op: &str) -> u8 {
    let verb = match op {
        "get" => "fill",
        "store" => "approve",
        "erase" => "reject",
        _ => return 0,
    };
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        return 0;
    }
    let Some(request) = map_request(&input) else { return 0 };
    if crate::switch::names_marker(&input) {
        return 0;
    }
    let mut cmd = Command::new("git");
    cmd.args(["credential", verb])
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_ASKPASS")
        .env_remove("SSH_ASKPASS")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let filled = cmd.spawn().ok().and_then(|mut child| {
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(request.as_bytes());
        }
        let out = child.wait_with_output().ok()?;
        out.status.success().then(|| filter_answer(&String::from_utf8_lossy(&out.stdout)))
    });
    if verb == "fill" {
        let answer = if crate::switch::env_off() {
            crate::switch::off_answer(filled.as_deref())
        } else {
            fill_answer(filled)
        };
        let _ = std::io::stdout().write_all(answer.as_bytes());
    }
    0
}

/// What `get` prints: the person's credential, or the anonymous marker when they have none.
pub fn fill_answer(filled: Option<String>) -> String {
    filled
        .filter(|a| a.lines().any(|l| l.starts_with("password=")))
        .unwrap_or_else(|| crate::switch::marker(crate::switch::ANON_USER))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_proxy_path_to_github() {
        let req = "protocol=http\nhost=127.0.0.1:47380\npath=github.com/o/r.git\nusername=x\n\n";
        assert_eq!(
            map_request(req).unwrap(),
            "protocol=https\nhost=github.com\npath=o/r.git\nusername=x\n"
        );
        assert!(map_request("protocol=http\nhost=127.0.0.1:1\npath=gitlab.com/o/r\n").is_none());
        assert!(map_request("protocol=http\nhost=127.0.0.1:1\n").is_none());
    }

    #[test]
    fn no_credential_answers_anonymous() {
        assert_eq!(fill_answer(None), "username=cmux-git-cache-anon\npassword=x\n");
        assert_eq!(fill_answer(Some(String::new())), "username=cmux-git-cache-anon\npassword=x\n");
        assert_eq!(
            fill_answer(Some("username=u\npassword=p\n".into())),
            "username=u\npassword=p\n"
        );
    }

    #[test]
    fn answer_keeps_only_credentials() {
        let a = "protocol=https\nhost=github.com\npath=o/r.git\nusername=u\npassword=p\nquit=1\n";
        assert_eq!(filter_answer(a), "username=u\npassword=p\n");
    }
}
