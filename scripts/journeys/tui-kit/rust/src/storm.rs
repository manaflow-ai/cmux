//! The L1 CLI storm's calls (load_profiles.py L1, compiled): the same weighted mix of `cmux` CLI
//! commands and app-socket reads, on one shared schedule (call n is due at start + n / rate), from N
//! worker threads. Each worker closes only the tabs it made.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};
use std::time::Duration;

/// (kind, weight): load_profiles.py `L1_KINDS`.
pub const KINDS: [(&str, u32); 13] = [
    ("workspace.list", 3),
    ("pane.list", 2),
    ("tab.list", 3),
    ("terminal.list", 2),
    ("snapshot.get", 2),
    ("tab.create", 2),
    ("tab.close", 2),
    ("terminal.write", 4),
    ("screen.read", 4),
    ("notify", 1),
    ("status.set", 3),
    ("progress.set", 3),
    ("log.append", 3),
];

/// splitmix64: a small seeded generator (the mix is seeded, not Python's sequence).
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed ^ 0x9e37_79b9_7f4a_7c15)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    pub fn below(&mut self, n: u64) -> u64 {
        if n == 0 {
            0
        } else {
            self.next_u64() % n
        }
    }

    pub fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1_u64 << 53) as f64
    }

    /// A kind from the weighted mix.
    pub fn pick(&mut self) -> &'static str {
        let total: u32 = KINDS.iter().map(|(_, w)| w).sum();
        let mut r = self.below(u64::from(total));
        for (kind, w) in KINDS {
            if r < u64::from(w) {
                return kind;
            }
            r -= u64::from(w);
        }
        "log.append"
    }
}

/// Where the storm calls: the CLI, the sockets and the profile's own workspace.
#[derive(Clone)]
pub struct Target {
    pub cli: String,
    pub daemon_socket: String,
    pub app_socket: String,
    pub home: String,
    pub workspace: String,
    pub pane: String,
    pub terminal: String,
}

pub struct Outcome {
    pub ok: bool,
    pub error: Option<String>,
    pub tab_made: Option<String>,
}

/// The `"tab_id": "..."` value in the CLI's JSON answer (no JSON parser: one field is needed).
pub fn tab_id(json: &str) -> Option<String> {
    let at = json.find("\"tab_id\"")?;
    let rest = json.get(at + "\"tab_id\"".len()..)?;
    let rest = rest
        .trim_start()
        .strip_prefix(':')?
        .trim_start()
        .strip_prefix('"')?;
    let end = rest.find('"')?;
    rest.get(..end).map(str::to_string)
}

impl Target {
    /// One CLI command: `cmux --socket D --app-socket A --json ARGS` with HOME and a plain PATH.
    pub fn cli(&self, args: &[String]) -> Outcome {
        let out = Command::new(&self.cli)
            .arg("--socket")
            .arg(&self.daemon_socket)
            .arg("--app-socket")
            .arg(&self.app_socket)
            .arg("--json")
            .args(args)
            .env_clear()
            .env("HOME", &self.home)
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("CMUX_QUIET", "1")
            .stdin(Stdio::null())
            .output();
        match out {
            Err(e) => Outcome {
                ok: false,
                error: Some(format!("spawn: {e}")),
                tab_made: None,
            },
            Ok(out) if out.status.success() => Outcome {
                ok: true,
                error: None,
                tab_made: tab_id(&String::from_utf8_lossy(&out.stdout)),
            },
            Ok(out) => {
                let mut text = String::from_utf8_lossy(&out.stdout).into_owned();
                text.push_str(&String::from_utf8_lossy(&out.stderr));
                Outcome {
                    ok: false,
                    error: Some(format!(
                        "exit {:?}: {}",
                        out.status.code(),
                        text.trim().chars().take(200).collect::<String>()
                    )),
                    tab_made: None,
                }
            }
        }
    }

    /// One app-socket request (one JSON line out, one back); ok when the reply says `"ok": true`.
    pub fn rpc(&self, method: &str) -> Outcome {
        let run = || -> std::io::Result<String> {
            let mut conn = UnixStream::connect(&self.app_socket)?;
            conn.set_read_timeout(Some(Duration::from_secs(30)))?;
            conn.write_all(
                format!("{{\"id\": 1, \"method\": \"{method}\", \"params\": {{}}}}\n").as_bytes(),
            )?;
            let mut line = String::new();
            BufReader::new(conn).read_line(&mut line)?;
            Ok(line)
        };
        match run() {
            Ok(line) if line.contains("\"ok\": true") || line.contains("\"ok\":true") => Outcome {
                ok: true,
                error: None,
                tab_made: None,
            },
            Ok(line) => Outcome {
                ok: false,
                error: Some(line.chars().take(200).collect()),
                tab_made: None,
            },
            Err(e) => Outcome {
                ok: false,
                error: Some(e.to_string()),
                tab_made: None,
            },
        }
    }
}

fn s(text: &str) -> String {
    text.to_string()
}

/// The argv (after the global flags) of one call of `kind`, as load_profiles.py L1 makes it; None for
/// snapshot.get (an app-socket read) and for tab.close when the worker has no tab of its own.
pub fn argv(
    kind: &str,
    t: &Target,
    worker: usize,
    n: u64,
    close: Option<&str>,
    unit: f64,
) -> Option<Vec<String>> {
    let (ws, pane, term) = (t.workspace.as_str(), t.pane.as_str(), t.terminal.as_str());
    Some(match kind {
        "workspace.list" => vec![s("workspace"), s("list")],
        "pane.list" => vec![s("pane"), s("list"), s("--workspace"), s(ws)],
        "tab.list" => vec![s("tab"), s("list"), s("--pane"), s(pane)],
        "terminal.list" => vec![s("terminal"), s("list"), s("--pane"), s(pane)],
        "tab.create" => vec![
            s("tab"),
            s("create"),
            s("terminal"),
            s("--workspace"),
            s(ws),
            s("--pane"),
            s(pane),
            s("--name"),
            format!("storm-{worker}-{n}"),
        ],
        "tab.close" => vec![s("tab"), s(close?), s("close")],
        "terminal.write" => vec![
            s("terminal"),
            s(term),
            s("write"),
            s("--text"),
            format!("echo storm {worker} {n}\n"),
        ],
        "screen.read" => vec![s("terminal"), s(term), s("screen"), s("read")],
        "notify" => vec![
            s("notify"),
            s("--title"),
            format!("tk-load {n}"),
            s("--body"),
            format!("storm worker {worker}"),
            s("--workspace"),
            s(ws),
            s("--desktop"),
            s("false"),
        ],
        "status.set" => vec![
            s("workspace"),
            s(ws),
            s("status"),
            s("set"),
            format!("storm{worker}"),
            format!("call {n}"),
        ],
        "progress.set" => vec![
            s("workspace"),
            s(ws),
            s("progress"),
            s("set"),
            format!("{unit:.2}"),
            s("--label"),
            s("storm"),
        ],
        "log.append" => vec![
            s("workspace"),
            s(ws),
            s("log"),
            s("append"),
            format!("storm {worker} call {n}"),
            s("--level"),
            s("info"),
            s("--source"),
            s("tk-load"),
        ],
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target() -> Target {
        Target {
            cli: "/x/cmux".into(),
            daemon_socket: "/x/d.sock".into(),
            app_socket: "/x/a.sock".into(),
            home: "/x".into(),
            workspace: "ws_1".into(),
            pane: "pane_2".into(),
            terminal: "term_3".into(),
        }
    }

    #[test]
    #[ignore = "run by scripts/measure/tui-kit-selftest.sh"]
    fn mix_is_seeded_and_weighted() {
        let mut a = Rng::new(7);
        let mut b = Rng::new(7);
        let seq: Vec<&str> = (0..50).map(|_| a.pick()).collect();
        assert_eq!(seq, (0..50).map(|_| b.pick()).collect::<Vec<_>>());
        let mut counts = std::collections::BTreeMap::new();
        let mut r = Rng::new(1);
        for _ in 0..34_000 {
            *counts.entry(r.pick()).or_insert(0_u32) += 1;
        }
        let notify = counts.get("notify").copied().unwrap_or(0);
        let write = counts.get("terminal.write").copied().unwrap_or(0);
        assert!((800..1200).contains(&notify), "{notify}");
        assert!((3600..4400).contains(&write), "{write}");
    }

    #[test]
    #[ignore = "run by scripts/measure/tui-kit-selftest.sh"]
    fn argv_shapes() {
        let t = target();
        assert_eq!(argv("tab.close", &t, 0, 1, None, 0.5), None);
        assert_eq!(
            argv("tab.close", &t, 0, 1, Some("tab_9"), 0.5),
            Some(vec![s("tab"), s("tab_9"), s("close")])
        );
        assert_eq!(argv("snapshot.get", &t, 0, 1, None, 0.5), None);
        let notify = argv("notify", &t, 2, 5, None, 0.5).unwrap_or_default();
        assert!(notify.ends_with(&[s("--desktop"), s("false")]));
        assert_eq!(
            tab_id(r#"{"value": {"tab_id": "tab_77", "pane_id": "pane_2"}}"#),
            Some(s("tab_77"))
        );
        assert_eq!(tab_id(r#"{"value":{"tab_id":"tab_8"}}"#), Some(s("tab_8")));
    }
}
