//! Arguments for the non-interactive `ssh` runs this crate starts.

/// Agent and X11 forwarding off, for a run that sets up its own port forward.
const AGENT_AND_X11_OFF: &[&str] = &["-o", "ForwardAgent=no", "-o", "ForwardX11=no"];
/// Agent, X11 and port forwarding off.
const ALL_FORWARDING_OFF: &[&str] =
    &["-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes"];
/// `ssh` flags that take a value, from OpenSSH's getopt string.
const FLAGS_WITH_VALUE: &[u8] = b"BDEFIJLOPQRSWbceilmopw";

/// Arguments for a non-interactive `ssh` run, up to and including the
/// destination. The caller appends the remote command.
///
/// `--` ends option parsing, so the destination can't be read as an option.
/// OpenSSH keeps the first value it reads for each `-o` keyword, so the
/// forwarding overrides go before the caller's options.
pub(crate) fn background_ssh_arguments(
    port: Option<u16>,
    extra_args: &[String],
    destination: &str,
) -> Vec<String> {
    let mut arguments = vec!["-T".to_owned()];
    if let Some(port) = port {
        arguments.extend(["-p".to_owned(), port.to_string()]);
    }
    arguments
        .extend(forwarding_overrides(extra_args).iter().map(|argument| (*argument).to_owned()));
    arguments.extend(extra_args.iter().cloned());
    arguments.extend(["--".to_owned(), destination.to_owned()]);
    arguments
}

/// Forwarding overrides for a run with the caller's `extra_args`.
///
/// Unless the caller pins `ControlMaster=no`, the run can become the shared
/// master: the app's carrier passes `ControlMaster=auto`, and so can the
/// user's ssh_config. Interactive sessions that reuse a master get its agent,
/// X11 and port forwarding, so such a run keeps forwarding as configured.
fn forwarding_overrides(extra_args: &[String]) -> &'static [&'static str] {
    let options = CallerOptions::parse(extra_args);
    if options.can_become_master {
        &[]
    } else if options.forwards_ports {
        AGENT_AND_X11_OFF
    } else {
        ALL_FORWARDING_OFF
    }
}

/// What the caller's options say about connection sharing and forwarding.
struct CallerOptions {
    can_become_master: bool,
    forwards_ports: bool,
}

impl CallerOptions {
    /// Reads options the way OpenSSH does: flags group after one `-`, a
    /// flag's value is the rest of its word or the next argument, `-M` wins
    /// over any `ControlMaster`, and the first `-o` value for a keyword wins.
    fn parse(extra_args: &[String]) -> Self {
        let mut master_flag = false;
        let mut control_master = None;
        let mut forwards_ports = false;
        let mut arguments = extra_args.iter();
        while let Some(argument) = arguments.next() {
            if argument == "--" {
                break;
            }
            let Some(flags) = argument.strip_prefix('-') else { continue };
            for (index, flag) in flags.char_indices() {
                if !u8::try_from(flag).is_ok_and(|flag| FLAGS_WITH_VALUE.contains(&flag)) {
                    master_flag |= flag == 'M';
                    continue;
                }
                let attached = &flags[index + 1..];
                let value = if attached.is_empty() {
                    arguments.next().map(String::as_str)
                } else {
                    Some(attached)
                };
                match flag {
                    'L' | 'R' | 'D' => forwards_ports = true,
                    'o' => {
                        if let Some((keyword, value)) = value.and_then(option_keyword_and_value) {
                            if keyword.eq_ignore_ascii_case("ControlMaster") {
                                control_master.get_or_insert(value);
                            } else if ["LocalForward", "RemoteForward", "DynamicForward"]
                                .iter()
                                .any(|forward| keyword.eq_ignore_ascii_case(forward))
                            {
                                forwards_ports = true;
                            }
                        }
                    }
                    _ => {}
                }
                break;
            }
        }
        let pinned_off = control_master.is_some_and(|value: &str| {
            value.eq_ignore_ascii_case("no") || value.eq_ignore_ascii_case("false")
        });
        Self { can_become_master: master_flag || !pinned_off, forwards_ports }
    }
}

/// Splits an `-o` value the way ssh_config does: the keyword ends at the
/// first `=` or whitespace, and the value is the next word.
fn option_keyword_and_value(option: &str) -> Option<(&str, &str)> {
    let option = option.trim_start();
    let (keyword, rest) = option.split_at(
        option.find(|character: char| character == '=' || character.is_ascii_whitespace())?,
    );
    let rest = rest.trim_start();
    let value = rest.strip_prefix('=').unwrap_or(rest).split_ascii_whitespace().next()?;
    Some((keyword, value.trim_matches('"')))
}

#[cfg(test)]
mod tests {
    use super::*;

    const AGENT_AND_X11_OFF: &[&str] = &["-o", "ForwardAgent=no", "-o", "ForwardX11=no"];
    const ALL_OFF: &[&str] =
        &["-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes"];

    fn arguments(extra: &[&str]) -> Vec<String> {
        let extra = extra.iter().map(|argument| (*argument).to_owned()).collect::<Vec<_>>();
        background_ssh_arguments(Some(2222), &extra, "alice@example.com")
    }

    fn expected(overrides: &[&str], extra: &[&str]) -> Vec<String> {
        ["-T", "-p", "2222"]
            .iter()
            .chain(overrides)
            .chain(extra)
            .chain(&["--", "alice@example.com"])
            .map(|argument| (*argument).to_owned())
            .collect()
    }

    #[test]
    fn hardened_ssh_argv_ends_options_before_the_destination() {
        assert_eq!(arguments(&[]), expected(&[], &[]));
    }

    #[test]
    fn hardened_ssh_argv_forwarding_follows_control_master() {
        // A run that can become the shared master keeps forwarding as
        // configured, including when `-M` overrides `ControlMaster=no` and
        // when an earlier `ControlMaster` value wins.
        for extra in [
            &["-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/cmux-ssh-%C"][..],
            &["-o", "ControlMaster=no", "-M"],
            &["-TMo", "ControlMaster=no"],
            &["-o", "ControlMaster=auto", "-o", "ControlMaster=no"],
        ] {
            assert_eq!(arguments(extra), expected(&[], extra), "{extra:?}");
        }
        // A run pinned to `ControlMaster=no` turns all forwarding off. `-l`
        // consumes the next argument, so that `-M` is a login name.
        for extra in [
            &["-o", "ControlMaster=no"][..],
            &["-oControlMaster no"],
            &["-o", "controlmaster = False"],
            &["-l", "-M", "-o", "ControlMaster=no"],
        ] {
            assert_eq!(arguments(extra), expected(ALL_OFF, extra), "{extra:?}");
        }
        // One that sets up its own port forward keeps that forward.
        for extra in [
            &["-o", "ControlMaster=no", "-L", "8080:localhost:80"][..],
            &["-o", "ControlMaster=no", "-R8080:localhost:80"],
            &["-o", "ControlMaster=no", "-D", "1080"],
            &["-o", "ControlMaster=no", "-o", "LocalForward 8080 localhost:80"],
        ] {
            assert_eq!(arguments(extra), expected(AGENT_AND_X11_OFF, extra), "{extra:?}");
        }
    }
}
