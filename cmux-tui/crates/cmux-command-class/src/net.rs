//! Network commands. One reaching the machine's own loopback or a local unix
//! socket needs the machine (that's where its server listens); one saving a
//! file into the workspace writes; one running a local program (a proxy
//! command, an askpass) needs the machine.

use crate::rules::is_sink;
use crate::tools::{Opt, scan};
use crate::{Classification, CommandClass, Verdict};

use CommandClass::{FileWrite, Machine, Network};

/// Where a download "to `-`" goes: stdout, or nowhere.
fn is_stdout(path: &str) -> bool {
    path == "-" || is_sink(path)
}

/// The host of a URL or `[user@]host[:port][/path]`.
fn host_of(target: &str) -> &str {
    let rest = target.split_once("://").map_or(target, |(_, rest)| rest);
    let rest = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let rest = rest.rsplit_once('@').map_or(rest, |(_, host)| host);
    match rest.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or_default(),
        None => rest.split(':').next().unwrap_or_default(),
    }
}

/// Whether a host name or address is this machine itself.
pub(crate) fn is_loopback(host: &str) -> bool {
    let host = host.trim_end_matches('.');
    host.eq_ignore_ascii_case("localhost")
        || (host.len() > 10
            && host
                .as_bytes()
                .get(host.len().saturating_sub(10)..)
                .is_some_and(|end| end.eq_ignore_ascii_case(b".localhost")))
        || host.starts_with("127.")
        || matches!(host, "::1" | "0.0.0.0" | "0" | "::" | "0:0:0:0:0:0:0:1" | "::ffff:127.0.0.1")
        || host.eq_ignore_ascii_case("host.docker.internal")
}

fn targets_loopback(target: &str) -> bool {
    is_loopback(host_of(target))
}

/// curl's short options that take a value.
const CURL_SHORT_VALUED: &str = "AbcCdDeEFHKmoPQrtTuUwxXyYz";

#[rustfmt::skip]
const CURL_LONG_VALUED: &[&str] = &[
    "output", "dump-header", "cookie-jar", "trace", "trace-ascii", "stderr", "libcurl",
    "etag-save", "hsts", "alt-svc", "config", "proxy", "preproxy", "socks4", "socks4a", "socks5",
    "socks5-hostname", "unix-socket", "abstract-unix-socket", "write-out", "url", "connect-to",
    "resolve", "header", "data", "data-raw", "data-binary", "data-urlencode", "form", "cookie",
    "user", "user-agent", "referer", "request", "upload-file", "output-dir", "max-time",
    "connect-timeout", "retry", "cacert", "cert", "key", "interface", "json", "range",
    "proxy-user", "variable", "etag-compare",
];

/// `curl` is network, unless it saves a file into the workspace or talks
/// to this machine.
pub(crate) fn curl(tail: &[&str]) -> Classification {
    let mut verdict = Verdict::default();
    verdict.add(Network, "curl");
    let urls = scan(tail, CURL_SHORT_VALUED, CURL_LONG_VALUED, |opt, value| {
        let value = value.unwrap_or_default();
        let saves = |verdict: &mut Verdict| {
            if !is_stdout(value) {
                verdict.add(FileWrite, "curl -o");
            }
        };
        match opt {
            Opt::Short('O') | Opt::Long("remote-name" | "remote-name-all") => {
                verdict.add(FileWrite, "curl -o");
            }
            Opt::Short('o' | 'D' | 'c')
            | Opt::Long(
                "output" | "dump-header" | "cookie-jar" | "trace" | "trace-ascii" | "stderr"
                | "libcurl" | "etag-save" | "hsts" | "alt-svc",
            ) => saves(&mut verdict),
            Opt::Short('w') | Opt::Long("write-out") if value.contains("%output{") => {
                verdict.add(FileWrite, "curl -o");
            }
            // A config file can set any option, including a socket or an output.
            Opt::Short('K') | Opt::Long("config") => verdict.add(Machine, "curl -K"),
            Opt::Long("unix-socket" | "abstract-unix-socket") => {
                verdict.add(Machine, "curl --unix-socket");
            }
            Opt::Short('x')
            | Opt::Long(
                "proxy" | "preproxy" | "socks4" | "socks4a" | "socks5" | "socks5-hostname",
            )
            | Opt::Long("url")
                if targets_loopback(value) =>
            {
                verdict.add(Machine, "curl localhost");
            }
            Opt::Long("connect-to" | "resolve") if value.split(':').any(is_loopback) => {
                verdict.add(Machine, "curl localhost");
            }
            _ => {}
        }
    });
    if urls.iter().any(|url| targets_loopback(url)) {
        verdict.add(Machine, "curl localhost");
    }
    verdict.finish()
}

#[rustfmt::skip]
const WGET_LONG_VALUED: &[&str] = &[
    "output-file", "append-output", "output-document", "directory-prefix", "execute",
    "input-file", "base", "tries", "timeout", "wait", "quota", "user-agent", "level", "domains",
    "include-directories", "exclude-directories", "accept", "reject", "header", "user",
    "password", "post-data", "post-file", "body-data", "method", "use-askpass",
];

/// `wget` saves into the workspace unless it writes to stdout or only checks.
pub(crate) fn wget(tail: &[&str]) -> Classification {
    let mut verdict = Verdict::default();
    let mut output: Option<&str> = None;
    let mut spider = false;
    let urls = scan(tail, "oaOPeiBtTwQUlDIXAR", WGET_LONG_VALUED, |opt, value| match opt {
        Opt::Short('O') | Opt::Long("output-document") => output = value,
        Opt::Short('o' | 'a') | Opt::Long("output-file" | "append-output")
            if !value.is_some_and(is_sink) =>
        {
            verdict.add(FileWrite, "wget -o");
        }
        // wgetrc commands can set any option, including the output.
        Opt::Short('e') | Opt::Long("execute") => verdict.add(FileWrite, "wget -e"),
        Opt::Long("use-askpass") => verdict.add(Machine, "wget --use-askpass"),
        Opt::Long("spider") => spider = true,
        _ => {}
    });
    if urls.iter().any(|url| targets_loopback(url)) {
        verdict.add(Machine, "wget localhost");
    }
    if !spider && !output.is_some_and(is_stdout) {
        verdict.add(FileWrite, "wget");
    }
    verdict.add(Network, "wget");
    verdict.finish()
}

/// The host of an scp or rsync path (`[user@]host:path`, `host::module`), or
/// `None` for a local path.
fn remote_host(path: &str) -> Option<&str> {
    let (host, _) = path.split_once(':')?;
    (!host.contains('/')).then_some(host_of(host))
}

/// `-o` options of ssh and scp that run a local program.
fn runs_local_program(option: &str) -> bool {
    let key = option.split(['=', ' ']).next().unwrap_or_default().to_ascii_lowercase();
    matches!(
        key.as_str(),
        "proxycommand" | "localcommand" | "permitlocalcommand" | "knownhostscommand"
    )
}

/// `ssh host cmd` runs on the remote host: network. It needs the machine
/// when the host is this machine, when it forwards a port (the listener is
/// local), or when an option runs a local program.
pub(crate) fn ssh(name: &str, tail: &[&str]) -> Classification {
    let mut verdict = Verdict::default();
    let positionals = scan(tail, "BbcDEeFIiJLlmOoPpQRSWw", &[], |opt, value| match opt {
        Opt::Short('L' | 'R' | 'D' | 'w') => verdict.add(Machine, format!("{name} -L")),
        Opt::Short('o') if value.is_some_and(runs_local_program) => {
            verdict.add(Machine, format!("{name} -o"));
        }
        Opt::Short('F' | 'S') => verdict.add(Machine, format!("{name} -F")),
        _ => {}
    });
    if positionals.first().is_some_and(|host| targets_loopback(host)) {
        verdict.add(Machine, format!("{name} localhost"));
    }
    verdict.add(Network, name);
    verdict.finish()
}

/// `scp` to a remote host is network; `scp` to a local path writes it.
pub(crate) fn scp(tail: &[&str]) -> Classification {
    let mut verdict = Verdict::default();
    let paths = scan(tail, "cFiJlPoSXD", &[], |opt, value| match opt {
        Opt::Short('o') if value.is_some_and(runs_local_program) => verdict.add(Machine, "scp -o"),
        Opt::Short('S' | 'F') => verdict.add(Machine, "scp -S"),
        _ => {}
    });
    if paths.iter().filter_map(|path| remote_host(path)).any(is_loopback) {
        verdict.add(Machine, "scp localhost");
    }
    match paths.last() {
        Some(dest) if remote_host(dest).is_none() => verdict.add(FileWrite, "scp"),
        _ => verdict.add(Network, "scp"),
    }
    verdict.finish()
}

/// `rsync` writes its destination; a remote shell other than ssh, or a
/// loopback host, needs the machine.
pub(crate) fn rsync(tail: &[&str]) -> Classification {
    let mut verdict = Verdict::default();
    let paths = scan(
        tail,
        "eBfMT",
        &["rsh", "rsync-path", "filter", "exclude", "include"],
        |opt, value| {
            if matches!(opt, Opt::Short('e') | Opt::Long("rsh"))
                && value.and_then(|v| v.split_whitespace().next()) != Some("ssh")
            {
                verdict.add(Machine, "rsync -e");
            }
        },
    );
    if paths.iter().filter_map(|path| remote_host(path)).any(is_loopback) {
        verdict.add(Machine, "rsync localhost");
    }
    verdict.add(FileWrite, "rsync");
    verdict.finish()
}
