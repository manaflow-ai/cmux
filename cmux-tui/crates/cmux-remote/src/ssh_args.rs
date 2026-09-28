//! Arguments for the non-interactive `ssh` runs this crate starts.

/// Arguments for a non-interactive `ssh` run, up to and including the
/// destination. The caller appends the remote command.
pub(crate) fn background_ssh_arguments(
    port: Option<u16>,
    extra_args: &[String],
    destination: &str,
) -> Vec<String> {
    let mut arguments = vec!["-T".to_owned()];
    if let Some(port) = port {
        arguments.extend(["-p".to_owned(), port.to_string()]);
    }
    arguments.extend(extra_args.iter().cloned());
    arguments.push(destination.to_owned());
    arguments
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
