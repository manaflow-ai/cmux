//! `cmux hosts`: the hosts declared in cmux-next.json (`machines.hosts`,
//! `cmux_config::hosts`, CMUX-673), and
//! which of them answer from here. Both verbs read the file in process, so
//! they work with cmux quit.

use std::io::Write;
use std::time::{Duration, Instant};

use cmux_config::hosts::{self, HostDecl};
use cmux_config::value::value_at;
use serde_json::json;

use super::OutputMode;
use super::hosts_check::{self, DEFAULT_TIMEOUT, MAX_TIMEOUT, Status};

const USAGE: &str = "\
cmux hosts: the computers declared in ~/.config/cmux/cmux-next.json, under machines.hosts:
  \"machines\": { \"hosts\": [ { \"label\": \"studio\", \"endpoints\": [\"studio.local\", \"ssh://leo@100.64.0.7:2222\"], \"icon\": \"desktopcomputer\" } ] }
  cmux hosts [list] [--json]                         the declared hosts, and any entry that is not one
  cmux hosts check [LABEL...] [--timeout SECS] [--json]
      which hosts answer from here: every endpoint at once, each with up to SECS (default 3)
      reachable: an ssh server answered; down: a machine answered, but not ssh;
      unreachable: nothing answered (it may work from another network); unchecked: ssh goes through a proxy";

/// Handles `cmux hosts` before the daemon grammar.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "hosts" {
        return None;
    }
    Some(run(global.output, rest))
}

#[derive(Debug, PartialEq)]
enum Request {
    List,
    Check { labels: Vec<String>, timeout: Duration },
    Help,
}

fn parse(rest: &[String]) -> Result<Request, String> {
    let words: Vec<&str> =
        rest.iter().map(String::as_str).filter(|word| *word != "--json").collect();
    match words.split_first() {
        None | Some((&"list" | &"ls", [])) => Ok(Request::List),
        Some((&"help" | &"-h" | &"--help", _)) => Ok(Request::Help),
        Some((&"check", args)) => {
            let mut labels = Vec::new();
            let mut timeout = DEFAULT_TIMEOUT;
            let mut args = args.iter();
            while let Some(arg) = args.next() {
                let seconds = match arg.strip_prefix("--timeout=") {
                    Some(value) => Some(value),
                    None if *arg == "--timeout" => {
                        Some(*args.next().ok_or("--timeout needs SECS")?)
                    }
                    None => None,
                };
                match seconds {
                    Some(value) => {
                        let secs: f64 = value
                            .parse()
                            .map_err(|_| format!("--timeout {value}: not a number"))?;
                        if !(secs > 0.0 && secs <= MAX_TIMEOUT.as_secs_f64()) {
                            return Err(format!(
                                "--timeout takes 0 to {} seconds",
                                MAX_TIMEOUT.as_secs()
                            ));
                        }
                        timeout = Duration::from_secs_f64(secs);
                    }
                    None if arg.starts_with('-') => return Err(format!("unknown option {arg}")),
                    None => labels.push((*arg).to_owned()),
                }
            }
            Ok(Request::Check { labels, timeout })
        }
        Some((verb, _)) => Err(format!("unknown verb {verb}")),
    }
}

fn run(output: OutputMode, rest: &[String]) -> i32 {
    let request = match parse(rest) {
        Ok(Request::Help) => {
            println!("{USAGE}");
            return 0;
        }
        Ok(request) => request,
        Err(error) => {
            eprintln!("cmux hosts: {error}\n\n{USAGE}");
            return 2;
        }
    };
    let (declared, problems) = match read_declared() {
        Ok(read) => read,
        Err(error) => {
            eprintln!("cmux hosts: {error}");
            return 1;
        }
    };
    let json = matches!(output, OutputMode::Json | OutputMode::JsonLines);
    match request {
        Request::List => {
            if json {
                println!("{}", json!({ "hosts": declared, "problems": problems }));
            } else {
                print_list(&declared, &problems, output);
            }
            0
        }
        Request::Check { labels, timeout } => {
            let mut chosen = Vec::new();
            for label in &labels {
                match hosts::find(&declared, label) {
                    Some(host) => chosen.push(host.clone()),
                    None => {
                        eprintln!("cmux hosts: no host is called {label:?} (cmux hosts list)");
                        return 2;
                    }
                }
            }
            if labels.is_empty() {
                chosen = declared;
            }
            let started = Instant::now();
            let results = hosts_check::check_all(&chosen, timeout, &hosts_check::ssh_probe());
            let wall_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
            if let Err(error) = write_check(
                &results,
                &problems,
                timeout,
                wall_ms,
                output,
                &mut std::io::stdout().lock(),
                &mut std::io::stderr().lock(),
            ) {
                eprintln!("cmux hosts: {error}");
                return 1;
            }
            0
        }
        Request::Help => 0,
    }
}

/// The declared hosts and the problems of the entries that are not hosts.
/// No file, or no `machines.hosts`, is no hosts.
fn read_declared() -> Result<(Vec<HostDecl>, Vec<String>), String> {
    let path = cmux_config::config_path();
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((Vec::new(), Vec::new()));
        }
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    let root =
        cmux_config::jsonc::parse(&text).map_err(|error| format!("{}: {error}", path.display()))?;
    let at: Vec<String> = hosts::PATH.iter().map(|part| (*part).to_owned()).collect();
    Ok(match value_at(&root, &at) {
        Some(value) => hosts::parse(value),
        None => (Vec::new(), Vec::new()),
    })
}

fn print_list(declared: &[HostDecl], problems: &[String], output: OutputMode) {
    if output != OutputMode::Quiet {
        if declared.is_empty() {
            println!("No hosts. Add one under machines.hosts in cmux-next.json (cmux hosts help).");
        }
        let width = declared.iter().map(|host| host.label.chars().count()).max().unwrap_or(0);
        for host in declared {
            println!("{:width$}  {}", host.label, host.endpoints.join(", "));
        }
    }
    for problem in problems {
        eprintln!("{problem}");
    }
}

/// Check diagnostics follow list diagnostics: embedded in JSON, stderr in text
/// and quiet modes. Invalid declarations must not disappear from an empty check.
fn write_check(
    results: &[hosts_check::HostResult],
    problems: &[String],
    timeout: Duration,
    wall_ms: u64,
    output: OutputMode,
    stdout: &mut impl Write,
    stderr: &mut impl Write,
) -> std::io::Result<()> {
    if matches!(output, OutputMode::Json | OutputMode::JsonLines) {
        let timeout_ms = u64::try_from(timeout.as_millis()).unwrap_or(u64::MAX);
        return writeln!(
            stdout,
            "{}",
            json!({
                "hosts": results, "problems": problems, "timeoutMs": timeout_ms, "wallMs": wall_ms
            })
        );
    }
    for problem in problems {
        writeln!(stderr, "{problem}")?;
    }
    if output == OutputMode::Quiet {
        return Ok(());
    }
    if results.is_empty() {
        return writeln!(
            stdout,
            "No hosts to check. Add one under machines.hosts in cmux-next.json (cmux hosts help)."
        );
    }
    let label_width = results.iter().map(|r| r.label.chars().count()).max().unwrap_or(5).max(5);
    let endpoint_width =
        results.iter().map(|r| r.endpoint.chars().count()).max().unwrap_or(8).max(8);
    writeln!(
        stdout,
        "{:label_width$}  {:11}  {:endpoint_width$}  DETAIL",
        "LABEL", "STATUS", "ENDPOINT"
    )?;
    for r in results {
        let status = match r.status {
            Status::Reachable => "reachable",
            Status::Down => "down",
            Status::Unchecked => "unchecked",
            Status::Unreachable => "unreachable",
        };
        writeln!(
            stdout,
            "{:label_width$}  {status:11}  {:endpoint_width$}  {}",
            r.label, r.endpoint, r.detail
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn verbs_parse() {
        assert_eq!(parse(&[]), Ok(Request::List));
        assert_eq!(parse(&words("list --json")), Ok(Request::List));
        assert_eq!(
            parse(&words("check studio --timeout 1.5 --json")),
            Ok(Request::Check {
                labels: vec!["studio".into()],
                timeout: Duration::from_millis(1500)
            })
        );
        assert_eq!(
            parse(&words("check")),
            Ok(Request::Check { labels: vec![], timeout: DEFAULT_TIMEOUT })
        );
        assert!(parse(&words("check --timeout 99")).is_err());
        assert!(parse(&words("check --bogus")).is_err());
        assert!(parse(&words("frobnicate")).is_err());
    }

    #[test]
    fn check_reports_invalid_declarations_even_when_none_can_be_probed() {
        for configuration in [json!([{"label": "broken", "endpoints": []}]), json!("not a list")] {
            let (declared, problems) = hosts::parse(&configuration);
            assert!(declared.is_empty());
            assert!(!problems.is_empty());
            for output in
                [OutputMode::Json, OutputMode::JsonLines, OutputMode::Human, OutputMode::Quiet]
            {
                let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
                write_check(&[], &problems, DEFAULT_TIMEOUT, 0, output, &mut stdout, &mut stderr)
                    .expect("write check");
                if matches!(output, OutputMode::Json | OutputMode::JsonLines) {
                    let value: serde_json::Value = serde_json::from_slice(&stdout).expect("json");
                    assert_eq!(value["hosts"], json!([]));
                    assert_eq!(value["problems"], json!(problems));
                    assert_eq!(value["timeoutMs"], 3000);
                    assert!(stderr.is_empty());
                } else {
                    assert_eq!(
                        String::from_utf8(stderr).expect("utf8"),
                        problems.join("\n") + "\n"
                    );
                    if output == OutputMode::Quiet {
                        assert!(stdout.is_empty());
                    }
                }
            }
        }
    }

    #[test]
    fn check_keeps_valid_results_alongside_invalid_declaration_diagnostics() {
        let (declared, problems) = hosts::parse(&json!([
            {"label": "studio", "endpoint": "studio"},
            {"label": "broken", "endpoints": []}
        ]));
        let probe: hosts_check::Probe =
            std::sync::Arc::new(|endpoint, _, _| hosts_check::EndpointResult {
                endpoint: endpoint.into(),
                status: Status::Reachable,
                detail: "SSH-2.0-example".into(),
                ms: Some(0),
            });
        let results = hosts_check::check_all(&declared, DEFAULT_TIMEOUT, &probe);
        let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
        write_check(
            &results,
            &problems,
            DEFAULT_TIMEOUT,
            1,
            OutputMode::Json,
            &mut stdout,
            &mut stderr,
        )
        .expect("write check");
        let value: serde_json::Value = serde_json::from_slice(&stdout).expect("json");
        assert_eq!(value["hosts"][0]["label"], "studio");
        assert_eq!(value["hosts"][0]["status"], "reachable");
        assert_eq!(value["problems"], json!(problems));
        assert_eq!(value["wallMs"], 1);
        assert!(stderr.is_empty());
    }
}
