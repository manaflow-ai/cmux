//! The person's GitHub sign-in for `cmux customize use OWNER/REPO@REF`: a
//! private fork's release is readable only signed in. The token comes from
//! `GH_TOKEN` or `GITHUB_TOKEN`, else `gh auth token` (asked once, with a
//! short limit; no `gh` means no token). It goes only to github.com and
//! api.github.com, is never printed and never stored (not in the library
//! entry, not in layer.json).

use std::io::Read as _;
use std::time::Duration;

/// How long `gh auth token` may take before the fetch goes on without it.
const GH_LIMIT: Duration = Duration::from_secs(3);

/// Where GitHub is: the two origins a token may go to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct GitHub {
    /// The site (`https://github.com`): release download links.
    pub web: String,
    /// The REST API (`https://api.github.com`).
    pub api: String,
}

impl Default for GitHub {
    fn default() -> GitHub {
        GitHub { web: "https://github.com".to_owned(), api: "https://api.github.com".to_owned() }
    }
}

impl GitHub {
    /// Whether `url` is on one of GitHub's two origins (and so may carry the
    /// token). A prefix match on the origin and its `/`, so
    /// `https://github.com.example` or `https://api.github.com@x` never is.
    pub(super) fn owns(&self, url: &str) -> bool {
        [&self.web, &self.api].iter().any(|origin| {
            url.strip_prefix(origin.as_str()).is_some_and(|rest| rest.starts_with('/'))
        })
    }
}

/// The token: `GH_TOKEN`, else `GITHUB_TOKEN`, else what `gh` says.
pub(super) fn token() -> Option<String> {
    token_from(|name| std::env::var(name).ok(), gh_token)
}

pub(super) fn token_from(
    env: impl Fn(&str) -> Option<String>,
    gh: impl FnOnce() -> Option<String>,
) -> Option<String> {
    ["GH_TOKEN", "GITHUB_TOKEN"]
        .iter()
        .find_map(|name| env(name).map(|value| value.trim().to_owned()).filter(valid))
        .or_else(|| gh().map(|value| value.trim().to_owned()).filter(valid))
}

/// A token goes into a header: one line of printable ASCII.
fn valid(token: &String) -> bool {
    !token.is_empty() && token.len() <= 1024 && token.bytes().all(|b| b.is_ascii_graphic())
}

/// `gh auth token --hostname github.com`, given [`GH_LIMIT`] to answer.
fn gh_token() -> Option<String> {
    let mut child = cmux_process::Command::new("gh")
        .args(["auth", "token", "--hostname", "github.com"])
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .ok()?;
    // A token is far smaller than a pipe's buffer, so `gh` never waits on
    // this read; one that runs past the limit is ended when `child` drops.
    let status = child.wait_timeout(GH_LIMIT).ok()??;
    if !status.success() {
        return None;
    }
    let mut out = String::new();
    child.stdout.take()?.take(4096).read_to_string(&mut out).ok()?;
    Some(out)
}

/// A private release's asset reads through the API, not its download link.
/// `release` is `/repos/{repo}/releases/tags/{tag}`'s answer: the API URL of
/// the asset called `name`, when it is on GitHub's API origin.
pub(super) fn asset_url(
    github: &GitHub,
    release: &serde_json::Value,
    name: &str,
) -> Option<String> {
    release
        .get("assets")?
        .as_array()?
        .iter()
        .find(|asset| asset.get("name").and_then(serde_json::Value::as_str) == Some(name))?
        .get("url")?
        .as_str()
        .filter(|url| url.starts_with(&format!("{}/", github.api)))
        .map(str::to_owned)
}

#[cfg(test)]
pub(super) mod tests {
    use std::io::Read as _;

    use serde_json::json;

    use super::*;

    #[test]
    fn only_github_origins_may_carry_the_token() {
        let github = GitHub::default();
        for url in [
            "https://github.com/o/r/releases/download/t/layer.json",
            "https://api.github.com/repos/o/r/releases/tags/t",
        ] {
            assert!(github.owns(url), "{url}");
        }
        for url in [
            "https://files.cmux.com/cmux-next-web/pr/1/latest.json",
            "https://github.com.example/o/r",
            "https://api.github.com@evil.example/x",
            "https://objects.githubusercontent.com/x",
            "http://github.com/o/r",
            "https://github.com",
        ] {
            assert!(!github.owns(url), "{url}");
        }
    }

    #[test]
    fn the_token_comes_from_the_env_first_then_gh_once() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |name: &str| pairs.iter().find(|(k, _)| *k == name).map(|(_, v)| (*v).to_owned())
        };
        let never = || -> Option<String> { panic!("gh asked although the env has a token") };
        assert_eq!(
            token_from(env(&[("GH_TOKEN", "a"), ("GITHUB_TOKEN", "b")]), never),
            Some("a".into())
        );
        assert_eq!(token_from(env(&[("GITHUB_TOKEN", "b\n")]), never), Some("b".into()));
        assert_eq!(
            token_from(env(&[("GH_TOKEN", "")]), || Some("gho_x\n".into())),
            Some("gho_x".into())
        );
        assert_eq!(token_from(env(&[]), || None), None);
        assert_eq!(token_from(env(&[]), || Some("two words".into())), None);
    }

    #[test]
    fn an_asset_url_is_the_apis_and_only_the_apis() {
        let github = GitHub::default();
        let release = json!({"assets": [
            {"name": "web-bundles.tar.gz", "url": "https://api.github.com/repos/o/r/releases/assets/2",
             "browser_download_url": "https://github.com/o/r/releases/download/t/web-bundles.tar.gz"},
            {"name": "layer.json", "url": "https://elsewhere.example/repos/o/r/releases/assets/1"},
        ]});
        assert_eq!(
            asset_url(&github, &release, "web-bundles.tar.gz").as_deref(),
            Some("https://api.github.com/repos/o/r/releases/assets/2")
        );
        assert_eq!(asset_url(&github, &release, "layer.json"), None);
        assert_eq!(asset_url(&github, &release, "profile.json"), None);
    }

    /// One request a fake server saw: its path and its headers (names
    /// lowercased).
    #[derive(Debug, Clone)]
    pub(crate) struct Seen {
        pub path: String,
        pub headers: Vec<(String, String)>,
    }

    impl Seen {
        pub(crate) fn header(&self, name: &str) -> Option<&str> {
            self.headers.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
        }
    }

    pub(crate) type Log = std::sync::Arc<std::sync::Mutex<Vec<Seen>>>;

    /// A server on a local port that answers `reply(seen)`: status, extra
    /// headers and body.
    pub(crate) fn fake(
        reply: impl Fn(&Seen) -> (u16, Vec<(String, String)>, Vec<u8>) + Send + 'static,
    ) -> (String, Log) {
        use std::io::Write as _;
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let log: Log = Log::default();
        let seen_log = std::sync::Arc::clone(&log);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut buffer = Vec::new();
                let mut chunk = [0_u8; 8192];
                while !buffer.windows(4).any(|w| w == b"\r\n\r\n") {
                    let n = stream.read(&mut chunk).unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    buffer.extend_from_slice(&chunk[..n]);
                }
                let head = String::from_utf8_lossy(&buffer).to_string();
                let mut lines = head.split("\r\n");
                let path = lines
                    .next()
                    .unwrap_or_default()
                    .split(' ')
                    .nth(1)
                    .unwrap_or_default()
                    .to_owned();
                let headers = lines
                    .filter_map(|line| line.split_once(':'))
                    .map(|(n, v)| (n.trim().to_ascii_lowercase(), v.trim().to_owned()))
                    .collect();
                let seen = Seen { path, headers };
                seen_log.lock().unwrap().push(seen.clone());
                let (status, extra, body) = reply(&seen);
                let mut out = format!(
                    "HTTP/1.1 {status} X\r\ncontent-length: {}\r\nconnection: close\r\n",
                    body.len()
                );
                for (name, value) in extra {
                    out.push_str(&format!("{name}: {value}\r\n"));
                }
                out.push_str("\r\n");
                let _ = stream.write_all(out.as_bytes());
                let _ = stream.write_all(&body);
            }
        });
        (origin, log)
    }

    fn fork() -> super::super::pr::Published {
        super::super::pr::Published::Fork { repo: "o/r".into(), reference: "look/one".into() }
    }

    /// A private fork signed in: the release through the API, each asset
    /// through its API URL as octet-stream, the token on every GitHub request
    /// and on none to another host, also after a redirect there.
    #[test]
    fn a_private_fork_reads_through_the_api_and_the_token_stays_on_github() {
        let (elsewhere, elsewhere_log) = fake(|_| (200, vec![], b"archive".to_vec()));
        let target = elsewhere.clone();
        let (origin, log) = fake(move |seen| {
            let authed = seen.header("authorization") == Some("Bearer tok_1");
            let octet = seen.header("accept") == Some("application/octet-stream");
            match seen.path.as_str() {
                "/repos/o/r/releases/tags/cmux-web-layer-look--one" if authed => {
                    let origin = seen.header("host").map(|h| format!("http://{h}")).unwrap();
                    let body = json!({"assets": [
                        {"name": "layer.json", "url": format!("{origin}/repos/o/r/releases/assets/1")},
                        {"name": "web-bundles.tar.gz", "url": format!("{origin}/repos/o/r/releases/assets/2")},
                    ]});
                    (200, vec![], body.to_string().into_bytes())
                }
                "/repos/o/r/releases/assets/1" if authed && octet => {
                    (200, vec![], br#"{"head":"h"}"#.to_vec())
                }
                "/repos/o/r/releases/assets/2" if authed && octet => {
                    (302, vec![("location".into(), format!("{target}/signed/blob"))], vec![])
                }
                _ => (404, vec![], vec![]),
            }
        });
        let github = GitHub { web: origin.clone(), api: origin.clone() };
        let http = super::super::pr::Http::for_test(github, Some("tok_1")).unwrap();
        let source = fork();
        let layer = super::super::pr::fork_asset(&http, &source, "layer.json", 1 << 20).unwrap();
        assert_eq!(layer.as_deref(), Some(&br#"{"head":"h"}"#[..]));
        let archive =
            super::super::pr::fork_asset(&http, &source, "web-bundles.tar.gz", 1 << 20).unwrap();
        assert_eq!(archive.as_deref(), Some(&b"archive"[..]));
        assert_eq!(
            super::super::pr::fork_asset(&http, &source, "profile.json", 1 << 20).unwrap(),
            None
        );
        // A host that is not GitHub's never gets it, asked straight either.
        assert!(http.get(&format!("{elsewhere}/other"), 1 << 20).unwrap().is_some());
        let seen = log.lock().unwrap().clone();
        assert!(seen.iter().all(|s| s.header("authorization") == Some("Bearer tok_1")), "{seen:?}");
        assert!(!seen.iter().any(|s| s.path.contains("/releases/download/")), "{seen:?}");
        let other = elsewhere_log.lock().unwrap().clone();
        assert_eq!(other.len(), 2, "{other:?}");
        assert!(other.iter().all(|s| s.header("authorization").is_none()), "{other:?}");
    }

    /// No token: the public download link, as before, and no header.
    #[test]
    fn a_public_fork_without_a_token_reads_the_download_link() {
        let (origin, log) = fake(|seen| match seen.path.as_str() {
            "/o/r/releases/download/cmux-web-layer-look--one/layer.json" => {
                (200, vec![], b"{}".to_vec())
            }
            _ => (404, vec![], vec![]),
        });
        let github = GitHub { web: origin.clone(), api: origin.clone() };
        let http = super::super::pr::Http::for_test(github, None).unwrap();
        let got = super::super::pr::fork_asset(&http, &fork(), "layer.json", 1 << 20).unwrap();
        assert_eq!(got.as_deref(), Some(&b"{}"[..]));
        let seen = log.lock().unwrap().clone();
        assert_eq!(seen.len(), 1, "{seen:?}");
        assert!(seen[0].header("authorization").is_none());
    }

    /// A token GitHub refuses (expired, revoked) still reads a public fork.
    #[test]
    fn a_refused_token_falls_back_to_the_public_link() {
        let (origin, _log) = fake(|seen| match seen.path.as_str() {
            "/repos/o/r/releases/tags/cmux-web-layer-look--one" => (401, vec![], vec![]),
            "/o/r/releases/download/cmux-web-layer-look--one/layer.json" => {
                (200, vec![], b"{}".to_vec())
            }
            _ => (404, vec![], vec![]),
        });
        let github = GitHub { web: origin.clone(), api: origin.clone() };
        let http = super::super::pr::Http::for_test(github, Some("stale")).unwrap();
        let got = super::super::pr::fork_asset(&http, &fork(), "layer.json", 1 << 20).unwrap();
        assert_eq!(got.as_deref(), Some(&b"{}"[..]));
    }
}
