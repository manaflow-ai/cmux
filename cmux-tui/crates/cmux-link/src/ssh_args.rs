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
pub fn background_ssh_arguments(
    port: Option<u16>,
    extra_args: &[String],
    destination: &str,
) -> Vec<String> {
    let mut arguments = vec!["-T".to_owned()];
    if let Some(port) = port {
        arguments.extend(["-p".to_owned(), port.to_string()]);
    }
    let overrides = forwarding_overrides(extra_args);
    arguments.extend(overrides.iter().map(|argument| (*argument).to_owned()));
    let (extra, has_separator) = normalized_caller_arguments(extra_args, !overrides.is_empty());
    arguments.extend(extra);
    if !has_separator {
        arguments.push("--".to_owned());
    }
    arguments.push(destination.to_owned());
    arguments
}

/// Preserves option values and a caller's separator while removing direct
/// forwarding-enable flags from runs that must keep agent and X11 forwarding off.
/// `-A`, `-X`, and `-Y` override an earlier `-o`, unlike repeated `-o` keywords.
fn normalized_caller_arguments(extra_args: &[String], forwarding_off: bool) -> (Vec<String>, bool) {
    let mut normalized = Vec::with_capacity(extra_args.len());
    let mut arguments = extra_args.iter();
    while let Some(argument) = arguments.next() {
        if argument == "--" {
            normalized.push(argument.clone());
            normalized.extend(arguments.cloned());
            return (normalized, true);
        }
        let Some(flags) = argument.strip_prefix('-').filter(|flags| !flags.is_empty()) else {
            normalized.push(argument.clone());
            continue;
        };
        let mut kept = String::from("-");
        for (index, flag) in flags.char_indices() {
            if forwarding_off && matches!(flag, 'A' | 'X' | 'Y') {
                continue;
            }
            kept.push(flag);
            if u8::try_from(flag).is_ok_and(|flag| FLAGS_WITH_VALUE.contains(&flag)) {
                let attached = &flags[index + flag.len_utf8()..];
                kept.push_str(attached);
                normalized.push(kept);
                kept = String::from("-");
                if attached.is_empty()
                    && let Some(value) = arguments.next()
                {
                    normalized.push(value.clone());
                }
                break;
            }
        }
        if kept.len() > 1 {
            normalized.push(kept);
        }
    }
    (normalized, false)
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
        let mut control_path_disabled = false;
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
                let attached = &flags[index + flag.len_utf8()..];
                let value = if attached.is_empty() {
                    arguments.next().map(String::as_str)
                } else {
                    Some(attached)
                };
                match flag {
                    'L' | 'R' | 'D' => forwards_ports = true,
                    'S' => {
                        control_path_disabled |=
                            value.is_some_and(|value| value.eq_ignore_ascii_case("none"));
                    }
                    'o' => {
                        if let Some((keyword, value)) = value.and_then(option_keyword_and_value) {
                            if keyword.eq_ignore_ascii_case("ControlMaster") {
                                control_master.get_or_insert(value);
                            } else if keyword.eq_ignore_ascii_case("ControlPath") {
                                control_path_disabled |= value.eq_ignore_ascii_case("none");
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
        Self {
            can_become_master: master_flag || (!pinned_off && !control_path_disabled),
            forwards_ports,
        }
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
            &["-o", "ControlMaster=auto", "-o", "ControlPath=none"],
            &["-S", "none", "-o", "ControlMaster=auto"],
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

    #[test]
    fn hardened_ssh_argv_forwarding_off_drops_forwarding_flags() {
        // `-A`, `-X` and `-Y` turn forwarding on whatever an earlier `-o`
        // said, so a run with forwarding off drops them, including from a
        // group of flags.
        let cases: &[(&[&str], &[&str])] = &[
            (&["-o", "ControlMaster=no", "-A"], &["-o", "ControlMaster=no"]),
            (&["-o", "ControlMaster=no", "-X", "-Y"], &["-o", "ControlMaster=no"]),
            (&["-qAY", "-o", "ControlMaster=no"], &["-q", "-o", "ControlMaster=no"]),
            (&["-Ao", "ControlMaster=no"], &["-o", "ControlMaster=no"]),
            (&["-o", "ControlMaster=no", "-Ai", "key"], &["-o", "ControlMaster=no", "-i", "key"]),
        ];
        for (extra, kept) in cases {
            assert_eq!(arguments(extra), expected(ALL_OFF, kept), "{extra:?}");
        }
        // A flag's value stays: `-A` after `-l` is a login name and `A`
        // after `-i` is a file.
        let extra = ["-l", "-A", "-iA", "-o", "ControlMaster=no"];
        assert_eq!(arguments(&extra), expected(ALL_OFF, &extra));
        let extra = ["-o", "ControlMaster=no", "-L", "8080:localhost:80", "-XA"];
        assert_eq!(arguments(&extra), expected(AGENT_AND_X11_OFF, &extra[..4]));
        // A run that can become the shared master keeps them.
        for extra in [&["-A", "-X"][..], &["-o", "ControlMaster=no", "-MY"]] {
            assert_eq!(arguments(extra), expected(&[], extra), "{extra:?}");
        }
    }

    #[test]
    fn hardened_ssh_argv_keeps_one_option_separator() {
        // A caller whose options already end with `--` gets no second one,
        // which OpenSSH would read as the destination.
        let cases: &[(&[&str], &[&str])] = &[
            (&[], &["-o", "ControlMaster=auto", "--"]),
            (ALL_OFF, &["-o", "ControlMaster=no", "--"]),
        ];
        for (overrides, extra) in cases {
            let one_separator = ["-T", "-p", "2222"]
                .iter()
                .chain(*overrides)
                .chain(*extra)
                .chain(&["alice@example.com"])
                .map(|argument| (*argument).to_owned())
                .collect::<Vec<_>>();
            assert_eq!(arguments(extra), one_separator, "{extra:?}");
        }
        // `-l` reads that `--` as a login name, so options still need ending.
        assert_eq!(arguments(&["-l", "--"]), expected(&[], &["-l", "--"]));
    }
}
