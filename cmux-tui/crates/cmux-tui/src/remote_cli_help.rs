use crate::localization::catalog;

pub(crate) fn requested(args: &[String]) -> bool {
    const VALUE_OPTIONS: &[&str] = &[
        "--invite-file",
        "--daemon",
        "--lanes",
        "--reconnect-attempts",
        "--reconnect-initial-ms",
        "--reconnect-max-ms",
        "--reconnect-attempt-timeout-ms",
        "--reconnect-jitter",
        "--heartbeat-interval-ms",
        "--heartbeat-timeout-ms",
        "--connect-timeout-seconds",
        "--device-name",
        "--state-dir",
        "--local-socket",
        "--relay-route",
        "--relay-slot",
        "--relay-ticket-file",
        "--relay-ticket-command",
        "--relay-ticket-command-arg",
        "--iroh-relay",
        "--iroh-address",
        "--iroh-path",
        "--session",
        "--ssh-binary",
        "--remote-binary",
        "--remote-state-dir",
        "--ssh-arg",
        "--workspace-root",
        "--host",
        "--port",
        "--listen",
        "--scheme",
        "--request",
        "--ttl",
        "--advertise",
        "--admin-socket",
        "--link-socket",
        "--mux-socket",
        "--destination",
    ];

    let mut index = 0;
    let mut requested = false;
    while index < args.len() {
        match args[index].as_str() {
            "-h" | "--help" => {
                requested = true;
                index += 1;
            }
            option
                if is_inline_secret_option(option, "--invite")
                    || is_inline_secret_option(option, "--relay-ticket") =>
            {
                return false;
            }
            option if VALUE_OPTIONS.contains(&option) => index += 2,
            _ => index += 1,
        }
    }
    requested
}

fn is_inline_secret_option(argument: &str, option: &str) -> bool {
    argument == option
        || argument.strip_prefix(option).is_some_and(|suffix| suffix.starts_with('='))
}

pub(crate) fn help(command: Option<&str>) -> &'static str {
    let client = &catalog().remote_client;
    match command {
        Some("connect") => client.connect_help,
        Some("ssh") => client.ssh_help,
        Some("forward") => client.forward_help,
        Some("rpc") => client.rpc_help,
        Some("enroll") => client.enroll_help,
        Some("known-daemons") => client.known_daemons_help,
        Some("remote-probe") => client.remote_probe_help,
        Some("remote-link") => client.remote_link_help,
        Some("remote-stop") => catalog().remote.remote_stop_help,
        Some("install-self") => client.install_self_help,
        Some("remote") => client.remote_lifecycle_help,
        _ => client.command_help,
    }
}
