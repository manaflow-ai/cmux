//! `git-cache credential get|store|erase`: git asks credentials for the proxy's URL
//! (`http://127.0.0.1:PORT/github.com/OWNER/REPO.git`); this maps the request back to
//! `https://github.com/OWNER/REPO.git` and asks the machine's own helpers for it with
//! `git credential fill|approve|reject` (lane-gh-credential, `cmux github credential`, the
//! person's). Nothing is printed for any other URL. Never prompts.

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
    let mut cmd = Command::new("git");
    cmd.args(["credential", verb])
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_ASKPASS")
        .env_remove("SSH_ASKPASS")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let Ok(mut child) = cmd.spawn() else { return 0 };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(request.as_bytes());
    }
    let Ok(out) = child.wait_with_output() else { return 0 };
    if verb == "fill" && out.status.success() {
        let _ = std::io::stdout()
            .write_all(filter_answer(&String::from_utf8_lossy(&out.stdout)).as_bytes());
    }
    0
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
    fn answer_keeps_only_credentials() {
        let a = "protocol=https\nhost=github.com\npath=o/r.git\nusername=u\npassword=p\nquit=1\n";
        assert_eq!(filter_answer(a), "username=u\npassword=p\n");
    }
}
