//! `remote enroll` and `known-daemons`: enrollment admin actions and their
//! arguments, relay tickets for a new invitation, and the admin socket's replies.

use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EnrollAdminAction {
    Status,
    Create,
    Pending,
    Approve,
    Deny,
    Devices,
    Connections,
    Revoke,
    Disconnect,
}

impl EnrollAdminAction {
    fn parse(action: &str) -> anyhow::Result<Self> {
        match action {
            "status" => Ok(Self::Status),
            "create" => Ok(Self::Create),
            "pending" => Ok(Self::Pending),
            "approve" => Ok(Self::Approve),
            "deny" => Ok(Self::Deny),
            "devices" => Ok(Self::Devices),
            "connections" => Ok(Self::Connections),
            "revoke" => Ok(Self::Revoke),
            "disconnect" => Ok(Self::Disconnect),
            other => Err(anyhow!(catalog().remote_client.unknown_action("enroll", other))),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Status => "status",
            Self::Create => "create",
            Self::Pending => "pending",
            Self::Approve => "approve",
            Self::Deny => "deny",
            Self::Devices => "devices",
            Self::Connections => "connections",
            Self::Revoke => "revoke",
            Self::Disconnect => "disconnect",
        }
    }

    fn positional_arity(self) -> usize {
        match self {
            Self::Approve | Self::Deny | Self::Revoke => 1,
            Self::Disconnect => 2,
            Self::Status | Self::Create | Self::Pending | Self::Devices | Self::Connections => 0,
        }
    }
}

enum InvitationTicketArg {
    File(PathBuf),
}

pub(super) struct EnrollAdminArgs {
    action: EnrollAdminAction,
    pub(super) positionals: Vec<String>,
    pub(super) session: String,
    state_dir: Option<PathBuf>,
    admin_socket: Option<PathBuf>,
    pub(super) json: bool,
    ttl_seconds: u64,
    advertised_routes: Vec<String>,
    relay_routes: Vec<String>,
    relay_slots: Vec<String>,
    relay_tickets: Vec<InvitationTicketArg>,
}

pub(super) fn parse_enroll_admin_args(args: &[String]) -> anyhow::Result<EnrollAdminArgs> {
    let (action, mut index) = match args.first() {
        Some(action) => (EnrollAdminAction::parse(action)?, 1),
        None => (EnrollAdminAction::Status, 0),
    };
    let mut parsed = EnrollAdminArgs {
        action,
        positionals: Vec::new(),
        session: "main".into(),
        state_dir: None,
        admin_socket: None,
        json: false,
        ttl_seconds: 300,
        advertised_routes: Vec::new(),
        relay_routes: Vec::new(),
        relay_slots: Vec::new(),
        relay_tickets: Vec::new(),
    };
    let mut seen = BTreeSet::new();
    let mut options_ended = false;
    while index < args.len() {
        let argument = &args[index];
        index += 1;
        if !options_ended && argument == "--" {
            options_ended = true;
            continue;
        }
        if options_ended || !argument.starts_with("--") {
            parsed.positionals.push(argument.clone());
            continue;
        }
        match argument.as_str() {
            "--session" => {
                require_unique_flag(&mut seen, "--session")?;
                parsed.session = strict_option_value(args, &mut index, "--session")?;
            }
            "--state-dir" => {
                require_unique_flag(&mut seen, "--state-dir")?;
                parsed.state_dir =
                    Some(strict_option_value(args, &mut index, "--state-dir")?.into());
            }
            "--admin-socket" => {
                require_unique_flag(&mut seen, "--admin-socket")?;
                parsed.admin_socket =
                    Some(strict_option_value(args, &mut index, "--admin-socket")?.into());
            }
            "--json" => {
                require_unique_flag(&mut seen, "--json")?;
                parsed.json = true;
            }
            "--ttl" => {
                require_create_action(action, "--ttl")?;
                require_unique_flag(&mut seen, "--ttl")?;
                parsed.ttl_seconds =
                    strict_option_value(args, &mut index, "--ttl")?.parse().map_err(|_| {
                        anyhow!(catalog().remote_client.invalid_option_value("--ttl", "seconds"))
                    })?;
                if parsed.ttl_seconds == 0 {
                    return Err(anyhow!(catalog().remote_client.option_must_be_positive("--ttl")));
                }
            }
            "--advertise" => {
                require_create_action(action, "--advertise")?;
                parsed.advertised_routes.push(strict_option_value(
                    args,
                    &mut index,
                    "--advertise",
                )?);
            }
            "--relay-route" => {
                require_create_action(action, "--relay-route")?;
                parsed.relay_routes.push(strict_option_value(args, &mut index, "--relay-route")?);
            }
            "--relay-slot" => {
                require_create_action(action, "--relay-slot")?;
                parsed.relay_slots.push(strict_option_value(args, &mut index, "--relay-slot")?);
            }
            option if is_inline_secret_option(option, "--relay-ticket") => {
                return Err(anyhow!(catalog().remote_client.inline_enroll_relay_ticket_rejected));
            }
            "--relay-ticket-file" => {
                require_create_action(action, "--relay-ticket-file")?;
                parsed.relay_tickets.push(InvitationTicketArg::File(
                    strict_option_value(args, &mut index, "--relay-ticket-file")?.into(),
                ));
            }
            option => {
                return Err(anyhow!(
                    catalog()
                        .remote_client
                        .unknown_option_for_command(option, &format!("enroll {}", action.name()))
                ));
            }
        }
    }
    let expected = action.positional_arity();
    if parsed.positionals.len() != expected {
        return Err(anyhow!(catalog().remote_client.enroll_arity(action.name(), expected)));
    }
    Ok(parsed)
}

fn require_create_action(action: EnrollAdminAction, option: &str) -> anyhow::Result<()> {
    if action != EnrollAdminAction::Create {
        return Err(anyhow!(catalog().remote_client.option_create_only(option)));
    }
    Ok(())
}

pub(super) fn run_enroll(
    args: &[String],
    load_config: impl FnOnce() -> crate::config::StartupConfigSnapshot,
) -> anyhow::Result<()> {
    if args.first().is_some_and(|action| action == "connect") {
        return run_connect(&args[1..], None, load_config);
    }
    let parsed = parse_enroll_admin_args(args)?;
    let admin_socket = parsed.admin_socket.clone().unwrap_or_else(|| {
        load_runtime_info(&parsed.session, parsed.state_dir.as_deref())
            .map(|runtime| runtime.admin_socket)
            .or_else(|_| {
                daemon_paths(&parsed.session, parsed.state_dir.as_deref())
                    .map(|(_, _, admin)| admin)
            })
            .unwrap_or_else(|_| PathBuf::from("/nonexistent"))
    });
    let request = match parsed.action {
        EnrollAdminAction::Status => AdminRequest::Status,
        EnrollAdminAction::Create => AdminRequest::CreateInvitation {
            ttl_seconds: parsed.ttl_seconds,
            route_hints: parsed.advertised_routes.clone(),
            relay_access: invitation_relay_access(&parsed)?,
        },
        EnrollAdminAction::Pending => AdminRequest::Pending,
        EnrollAdminAction::Approve => {
            AdminRequest::Approve { invitation_id: parsed.positionals[0].clone() }
        }
        EnrollAdminAction::Deny => {
            AdminRequest::Deny { invitation_id: parsed.positionals[0].clone() }
        }
        EnrollAdminAction::Devices => AdminRequest::Devices,
        EnrollAdminAction::Connections => AdminRequest::Connections,
        EnrollAdminAction::Revoke => {
            AdminRequest::Revoke { device_id: parsed.positionals[0].clone() }
        }
        EnrollAdminAction::Disconnect => AdminRequest::Disconnect {
            device_id: parsed.positionals[0].clone(),
            session_id: parsed.positionals[1].clone(),
        },
    };
    let response = tokio_runtime()?.block_on(call_admin(&admin_socket, &request))?;
    print_admin_response(parsed.action.name(), response, parsed.json)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum KnownDaemonsAction {
    List,
    Forget(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct KnownDaemonsArgs {
    pub(super) action: KnownDaemonsAction,
    pub(super) state_dir: Option<PathBuf>,
    pub(super) json: bool,
}

pub(super) fn parse_known_daemons_args(args: &[String]) -> anyhow::Result<KnownDaemonsArgs> {
    let mut state_dir = None;
    let mut json = false;
    let mut seen = BTreeSet::new();
    let mut positionals = Vec::new();
    let mut options_ended = false;
    let mut index = 0;
    while index < args.len() {
        let argument = &args[index];
        index += 1;
        if !options_ended && argument == "--" {
            options_ended = true;
            continue;
        }
        if options_ended || !argument.starts_with("--") {
            positionals.push(argument.clone());
            continue;
        }
        match argument.as_str() {
            "--state-dir" => {
                require_unique_flag(&mut seen, "--state-dir")?;
                state_dir = Some(strict_option_value(args, &mut index, "--state-dir")?.into());
            }
            "--json" => {
                require_unique_flag(&mut seen, "--json")?;
                json = true;
            }
            // A global --socket names a session; pinned identities are this client's.
            "--socket" => _ = strict_option_value(args, &mut index, "--socket")?,
            option => {
                return Err(anyhow!(
                    catalog().remote_client.unknown_option_for_command(option, "known-daemons")
                ));
            }
        }
    }
    let action = match positionals.as_slice() {
        [] => KnownDaemonsAction::List,
        [action] if action == "list" => KnownDaemonsAction::List,
        [action, fingerprint] if action == "forget" => {
            KnownDaemonsAction::Forget(fingerprint.clone())
        }
        [action, ..] if action == "forget" => {
            return Err(anyhow!(catalog().remote_client.known_forget_arity));
        }
        [action, ..] => {
            return Err(anyhow!(catalog().remote_client.unknown_action("known-daemons", action)));
        }
    };
    Ok(KnownDaemonsArgs { action, state_dir, json })
}

pub(super) fn run_known_daemons(args: &[String]) -> anyhow::Result<()> {
    let parsed = parse_known_daemons_args(args)?;
    let messages = &catalog().remote_client;
    let client_root = parsed
        .state_dir
        .or_else(default_state_dir)
        .ok_or_else(|| anyhow!(messages.known_state_dir_unavailable))?
        .join("client");
    let store = ClientIdentityStore::load_or_create(client_root)?;
    if let KnownDaemonsAction::Forget(fingerprint) = parsed.action {
        let forgotten = tokio_runtime()?.block_on(store.forget_daemon(&fingerprint))?;
        if !forgotten {
            return Err(anyhow!(messages.known_daemon_not_known(&fingerprint)));
        }
        if parsed.json {
            println!(
                "{}",
                serde_json::json!({
                    "forgotten": true,
                    "fingerprint": fingerprint,
                })
            );
        } else {
            println!("{}", messages.known_daemon_forgotten(&fingerprint));
        }
        return Ok(());
    }
    let daemons = tokio_runtime()?.block_on(store.known_daemons());
    if parsed.json {
        println!("{}", serde_json::to_string_pretty(&daemons)?);
        return Ok(());
    }
    if daemons.is_empty() {
        println!("{}", messages.known_daemons_empty);
        return Ok(());
    }
    for daemon in daemons {
        println!(
            "{}\t{}\t{}",
            daemon.name,
            daemon.fingerprint,
            match daemon.auth {
                KnownDaemonAuth::Enrolled => messages.known_daemon_auth_enrolled,
                KnownDaemonAuth::Carrier => messages.known_daemon_auth_carrier,
            }
        );
        for route in daemon.route_hints {
            println!("  {route}");
        }
    }
    Ok(())
}

pub(super) fn invitation_relay_access(
    args: &EnrollAdminArgs,
) -> anyhow::Result<Vec<EnrollmentRelayAccess>> {
    if args.relay_routes.is_empty() && args.relay_slots.is_empty() && args.relay_tickets.is_empty()
    {
        return Ok(Vec::new());
    }
    if args.relay_routes.len() != args.relay_slots.len()
        || args.relay_routes.len() != args.relay_tickets.len()
    {
        return Err(anyhow!(
            "each invitation relay needs one --relay-route, one --relay-slot, and one --relay-ticket-file"
        ));
    }
    if args.relay_routes.len() > 2 {
        return Err(anyhow!("an invitation supports at most two relay bootstrap routes"));
    }

    args.relay_routes
        .iter()
        .zip(&args.relay_slots)
        .zip(&args.relay_tickets)
        .map(|((route, slot), source)| {
            let InvitationTicketArg::File(path) = source;
            let ticket = read_invitation_ticket_file(path)?;
            Ok(EnrollmentRelayAccess { route: route.clone(), slot: slot.clone(), ticket })
        })
        .collect()
}

pub(super) fn read_invitation_ticket_file(path: &Path) -> anyhow::Result<String> {
    Ok(cmux_remote::secret_file::read_owner_only_string(path, 4 * 1024 + 2)
        .with_context(|| format!("could not read relay ticket file {}", path.display()))?
        .trim()
        .to_string())
}

fn print_admin_response(action: &str, response: AdminResponse, json: bool) -> anyhow::Result<()> {
    if !response.ok {
        return Err(anyhow!(response.error.unwrap_or_else(|| "admin request failed".into())));
    }
    let result = response.result.unwrap_or(Value::Null);
    if json {
        println!("{}", serde_json::to_string_pretty(&result)?);
    } else if action == "create" {
        println!("{}", result["uri"].as_str().ok_or_else(|| anyhow!("missing invitation URI"))?);
    } else {
        println!("{}", serde_json::to_string_pretty(&result)?);
    }
    Ok(())
}
