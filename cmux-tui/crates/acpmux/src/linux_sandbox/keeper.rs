//! Own the sandbox command and its host-side services in one process.
//!
//! Claude may be a daemon child or live in an agent host that survives daemon
//! restarts (including auto-updates). The proxy and notification supervisor
//! must live exactly as long as Claude: tying them to the daemon would lose
//! networking and could hang notified syscalls or undermine fail-closed handling.
//! A keeper owns the handoff socketpair, starts bwrap with unchanged standard
//! streams, and owns services until bwrap exits. SpawnPlan and both spawn paths
//! therefore need no additional descriptor plumbing.
//!
//! Red-test scaffold: every invocation refuses with 125 before spawning anything.
//! Linux remote chains remain refused in Bound::for_session until G2.
#![allow(dead_code)] // Red-test scaffold; remove with the implementation.

use std::ffi::OsString;
use std::net::{SocketAddr, TcpListener};
use std::os::fd::OwnedFd;
use std::path::PathBuf;
use std::process::ExitStatus;

use super::bwrap::Paths;

#[derive(Debug)]
struct Options {
    paths: Paths,
    bwrap: PathBuf,
    proxy_port: u16,
    api: Option<SocketAddr>,
    program: String,
    args: Vec<String>,
}

fn parse(_args: Vec<OsString>) -> Result<Options, String> {
    Err("keeper option parsing is not implemented".into())
}

fn validate_handoff(
    _payload: &[u8],
    _fds: Vec<OwnedFd>,
    _proxy_port: u16,
    _api_port: Option<u16>,
) -> Result<Vec<TcpListener>, String> {
    Err("keeper handoff validation is not implemented".into())
}

fn exit_code(_status: ExitStatus) -> i32 {
    125
}

pub(crate) fn main(_args: Vec<OsString>) -> ! {
    eprintln!("remote sandbox keeper: not implemented");
    std::process::exit(125) // crash-allow: pre-runtime helper must refuse, never run unsandboxed
}

/// Table loops stop at finite input exhaustion. Socket connects have a two-second
/// deadline; listeners are only inspected, never accepted, and all fds are RAII-owned.
#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{TcpStream, UdpSocket};
    use std::os::unix::ffi::OsStringExt;
    use std::os::unix::process::ExitStatusExt;
    use std::time::Duration;

    const REQUIRED: [&str; 12] = [
        "--cwd",
        "/work",
        "--tmpdir",
        "/scratch",
        "--home",
        "/home/person",
        "--claude-tmp-project",
        "/claude-tmp/project",
        "--claude-project",
        "/home/person/.claude/projects/project",
        "--proxy-port",
        "3128",
    ];

    fn argv(extra: &[&str]) -> Vec<OsString> {
        REQUIRED
            .into_iter()
            .chain(extra.iter().copied())
            .chain(["--", "/bin/sh", "-c", "printf '%s' \"$1\"", "sh", "a b"])
            .map(OsString::from)
            .collect()
    }

    #[test]
    fn options_canonical_round_trip() {
        let options = parse(argv(&[])).unwrap();
        assert_eq!(options.bwrap, PathBuf::from("/usr/bin/bwrap"));
        assert_eq!(options.proxy_port, 3128);
        assert_eq!(options.api, None);
        let paths = [
            &options.paths.cwd,
            &options.paths.tmp,
            &options.paths.home,
            &options.paths.claude_tmp_project,
            &options.paths.claude_project,
        ];
        let mut round_trip = Vec::new();
        for (pair, path) in REQUIRED.chunks_exact(2).take(5).zip(paths) {
            assert_eq!(path, &PathBuf::from(pair[1]));
            round_trip.extend([OsString::from(pair[0]), path.as_os_str().to_owned()]);
        }
        round_trip.extend([OsString::from("--proxy-port"), options.proxy_port.to_string().into()]);
        round_trip.extend([OsString::from("--"), options.program.into()]);
        round_trip.extend(options.args.into_iter().map(OsString::from));
        assert_eq!(round_trip, argv(&[]));
        assert!(parse(round_trip).is_ok());
        for (flag, address) in
            [("--api-loopback-v4", "127.0.0.1:31415"), ("--api-loopback-v6", "[::1]:31415")]
        {
            let options =
                parse(argv(&["--bwrap", "/opt/bwrap", "--api-port", "31415", flag])).unwrap();
            assert_eq!(options.bwrap, PathBuf::from("/opt/bwrap"));
            assert_eq!(options.api, Some(address.parse().unwrap()));
        }
    }

    #[test]
    fn options_refuse_missing_duplicate_and_unknown_flags() {
        for pair in REQUIRED.chunks_exact(2) {
            let mut missing = argv(&[]);
            let at = missing.iter().position(|v| v == pair[0]).unwrap();
            missing.drain(at..at + 2);
            assert!(parse(missing).is_err(), "missing {}", pair[0]);
            assert!(parse(argv(pair)).is_err(), "duplicate {}", pair[0]);
        }
        for extra in [
            vec!["--wat", "1"],
            vec!["--proxy-port=3128"],
            vec!["--bwrap", "/a", "--bwrap", "/b"],
            vec!["--api-port", "31415", "--api-port", "31415", "--api-loopback-v4"],
            vec!["--api-port", "31415", "--api-loopback-v4", "--api-loopback-v4"],
            vec!["--api-port", "31415", "--api-loopback-v6", "--api-loopback-v6"],
            vec!["--api-port", "31415", "--api-loopback-v4", "--api-loopback-v6"],
            vec!["--api-port", "31415"],
            vec!["--api-loopback-v4"],
            vec!["--api-loopback-v6"],
        ] {
            assert!(parse(argv(&extra)).is_err(), "{extra:?}");
        }
        for flag in REQUIRED.chunks_exact(2).map(|p| p[0]).chain(["--api-port", "--bwrap"]) {
            assert!(parse(vec![flag.into()]).is_err(), "{flag} at EOF");
            assert!(parse(vec![flag.into(), "--".into(), "/bin/true".into()]).is_err());
        }
        assert!(parse(Vec::new()).is_err());
        assert!(parse(REQUIRED.into_iter().map(OsString::from).collect()).is_err());
        let mut missing_program = argv(&[]);
        missing_program.truncate(REQUIRED.len() + 1);
        assert!(parse(missing_program).is_err());
    }

    #[test]
    fn options_refuse_invalid_values_before_spawn() {
        for index in [1, 3, 5, 7, 9, 13] {
            for bad in ["relative", "", "/a/../b", "/bad\0path"] {
                let mut values = argv(&[]);
                values[index] = bad.into();
                assert!(parse(values).is_err(), "argument {index}: {bad:?}");
            }
        }
        assert!(parse(argv(&["--bwrap", "relative"])).is_err());
        for bad in ["0", "65536", "-1", "+80", " 80", "80x", ""] {
            let mut values = argv(&[]);
            values[11] = bad.into();
            assert!(parse(values).is_err(), "proxy {bad:?}");
            assert!(parse(argv(&["--api-port", bad, "--api-loopback-v4"])).is_err());
        }
        assert!(parse(argv(&["--api-port", "3128", "--api-loopback-v4"])).is_err());
        let mut values = argv(&[]);
        values.push(OsString::from_vec(vec![0xff]));
        assert!(parse(values).is_err());
        let mut values = argv(&[]);
        values.push("arg\0tail".into());
        assert!(parse(values).is_err());
    }

    fn listener(address: &str) -> (OwnedFd, u16) {
        let listener = TcpListener::bind((address, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        (listener.into(), port)
    }

    fn payload(proxy: u16, api: Option<u16>) -> Vec<u8> {
        format!("{}\n", serde_json::json!({"proxy": proxy, "api": api})).into_bytes()
    }

    #[test]
    fn handoff_accepts_exact_proxy_and_optional_api_listeners() {
        for with_api in [false, true] {
            let (proxy, port) = listener("127.0.0.1");
            let (api, api_port) = listener("127.0.0.1");
            let expected_api = with_api.then_some(api_port);
            let mut fds = vec![proxy];
            if with_api {
                fds.push(api);
            }
            let listeners =
                validate_handoff(&payload(port, expected_api), fds, port, expected_api).unwrap();
            assert_eq!(listeners.len(), if with_api { 2 } else { 1 });
            assert_eq!(listeners[0].local_addr().unwrap().to_string(), format!("127.0.0.1:{port}"));
            if with_api {
                assert_eq!(listeners[1].local_addr().unwrap().port(), api_port);
            }
        }
    }

    #[test]
    fn handoff_refuses_wrong_counts_ports_and_order() {
        assert!(validate_handoff(&payload(3128, None), vec![], 3128, None).is_err());
        for count in [1, 2, 3] {
            let (proxy, port) = listener("127.0.0.1");
            let (api, api_port) = listener("127.0.0.1");
            let mut fds = vec![proxy];
            if count > 1 {
                fds.push(api);
            }
            if count > 2 {
                fds.push(listener("127.0.0.1").0);
            }
            let expected_api = (count != 2).then_some(api_port);
            assert!(
                validate_handoff(&payload(port, expected_api), fds, port, expected_api).is_err()
            );
        }
        let (proxy, port) = listener("127.0.0.1");
        let (api, api_port) = listener("127.0.0.1");
        assert!(
            validate_handoff(
                &payload(port, Some(api_port)),
                vec![api, proxy],
                port,
                Some(api_port)
            )
            .is_err()
        );
        let (fd, port) = listener("127.0.0.1");
        let wrong = if port == 65535 { 65534 } else { port + 1 };
        assert!(validate_handoff(&payload(wrong, None), vec![fd], wrong, None).is_err());
    }

    #[test]
    fn handoff_refuses_invalid_json_and_mismatched_json_ports() {
        for text in [
            "",
            "{",
            "{}",
            "[]",
            "null",
            "{\"proxy\":PORT}",
            "{\"proxy\":0,\"api\":null}",
            "{\"proxy\":65536,\"api\":null}",
            "{\"proxy\":\"PORT\",\"api\":null}",
            "{\"proxy\":PORT,\"api\":null,\"extra\":1}",
        ] {
            let (fd, port) = listener("127.0.0.1");
            let text = text.replace("PORT", &port.to_string());
            assert!(validate_handoff(text.as_bytes(), vec![fd], port, None).is_err(), "{text}");
        }
        let (fd, port) = listener("127.0.0.1");
        let duplicate = format!("{{\"proxy\":{port},\"proxy\":{port},\"api\":null}}\n");
        assert!(validate_handoff(duplicate.as_bytes(), vec![fd], port, None).is_err());
        let (fd, port) = listener("127.0.0.1");
        assert!(validate_handoff(&payload(port, Some(port)), vec![fd], port, None).is_err());
    }

    #[test]
    fn handoff_refuses_nonlisteners_and_other_bind_addresses() {
        let file: OwnedFd = std::fs::File::open("/dev/null").unwrap().into();
        let udp = UdpSocket::bind("127.0.0.1:0").unwrap();
        let udp_port = udp.local_addr().unwrap().port();
        let tcp = TcpListener::bind("127.0.0.1:0").unwrap();
        let stream =
            TcpStream::connect_timeout(&tcp.local_addr().unwrap(), Duration::from_secs(2)).unwrap();
        let stream_port = stream.local_addr().unwrap().port();
        for (fd, port) in [(file, 3128), (udp.into(), udp_port), (stream.into(), stream_port)] {
            assert!(validate_handoff(&payload(port, None), vec![fd], port, None).is_err());
        }
        for address in ["0.0.0.0", "127.0.0.2"] {
            let (fd, port) = listener(address);
            assert!(validate_handoff(&payload(port, None), vec![fd], port, None).is_err());
        }
    }

    #[test]
    fn child_exit_status_mapping() {
        for code in [0, 1, 7, 125, 127, 255] {
            assert_eq!(exit_code(ExitStatus::from_raw(code << 8)), code);
        }
        for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP, libc::SIGKILL] {
            assert_eq!(exit_code(ExitStatus::from_raw(signal)), 128 + signal);
        }
        assert_eq!(exit_code(ExitStatus::from_raw(libc::SIGSEGV | 0x80)), 128 + libc::SIGSEGV);
    }
}
