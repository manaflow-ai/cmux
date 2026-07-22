use std::env;
use std::ffi::OsString;
use std::fmt;
use std::net::SocketAddr;
use std::str::FromStr;
use std::time::Duration;

use cmux_remote_protocol::{LaneToken, RelayPermission};

const DEFAULT_BIND: &str = "127.0.0.1:8787";
const DEFAULT_LEASE_SECONDS: u64 = 30;
const DEFAULT_JOIN_TIMEOUT_SECONDS: u64 = 15;
const DEFAULT_IDLE_TIMEOUT_SECONDS: u64 = 300;
const DEFAULT_HANDSHAKE_TIMEOUT_SECONDS: u64 = 10;
const DEFAULT_CONTROL_IDLE_TIMEOUT_SECONDS: u64 = 120;
const DEFAULT_HTTP_HEADER_TIMEOUT_SECONDS: u64 = 5;
const DEFAULT_HTTP_KEEPALIVE_TIMEOUT_SECONDS: u64 = 600;
const DEFAULT_JOIN_TICKET_TTL_SECONDS: u64 = 30;
const MAXIMUM_JOIN_TICKET_TTL_SECONDS: u64 = 300;
const DEFAULT_MAX_CONTROL_BYTES: usize = 16 * 1024;
const DEFAULT_MAX_FRAME_BYTES: usize = 64 * 1024;
const DEFAULT_MAX_QUEUE_FRAMES: usize = 128;
const DEFAULT_MAX_QUEUE_BYTES: usize = 2 * 1024 * 1024;
const DEFAULT_MAX_CONNECTIONS: usize = 1024;
const DEFAULT_MAX_HTTP_CONNECTIONS: usize = 2048;
const DEFAULT_MAX_HTTP_HEADER_BYTES: usize = 16 * 1024;
const DEFAULT_MAX_SLOTS: usize = 1024;
const DEFAULT_MAX_CIRCUITS: usize = 4096;
const DEFAULT_MAX_CONTROL_SOCKETS_PER_SLOT: usize = 64;
const DEFAULT_MAX_PENDING_CIRCUITS_PER_SLOT: usize = 64;
const DEFAULT_MAX_ACTIVE_CIRCUITS_PER_SLOT: usize = 256;
const DEFAULT_MAX_ALLOCATIONS_PER_SECOND_PER_SLOT: usize = 64;
const DEFAULT_TICKET_TTL_SECONDS: u64 = 300;
const DEFAULT_TICKET_ISSUER: &str = "cmux-relay";

#[derive(Clone)]
pub struct RelayConfig {
    pub bind: SocketAddr,
    pub lease_duration: Duration,
    pub join_timeout: Duration,
    pub idle_timeout: Duration,
    pub handshake_timeout: Duration,
    pub control_idle_timeout: Duration,
    pub http_header_timeout: Duration,
    pub http_keepalive_timeout: Duration,
    pub join_ticket_ttl: Duration,
    pub max_control_bytes: usize,
    pub max_frame_bytes: usize,
    pub max_queue_frames: usize,
    pub max_queue_bytes: usize,
    pub max_connections: usize,
    pub max_http_connections: usize,
    pub max_http_header_bytes: usize,
    pub max_slots: usize,
    pub max_circuits: usize,
    pub max_control_sockets_per_slot: usize,
    pub max_pending_circuits_per_slot: usize,
    pub max_active_circuits_per_slot: usize,
    pub max_allocations_per_second_per_slot: usize,
    pub ticket_secret: Option<Vec<u8>>,
    pub ticket_issuer: String,
    pub allow_open: bool,
}

impl Default for RelayConfig {
    fn default() -> Self {
        Self {
            bind: DEFAULT_BIND.parse().expect("default relay bind address is valid"),
            lease_duration: Duration::from_secs(DEFAULT_LEASE_SECONDS),
            join_timeout: Duration::from_secs(DEFAULT_JOIN_TIMEOUT_SECONDS),
            idle_timeout: Duration::from_secs(DEFAULT_IDLE_TIMEOUT_SECONDS),
            handshake_timeout: Duration::from_secs(DEFAULT_HANDSHAKE_TIMEOUT_SECONDS),
            control_idle_timeout: Duration::from_secs(DEFAULT_CONTROL_IDLE_TIMEOUT_SECONDS),
            http_header_timeout: Duration::from_secs(DEFAULT_HTTP_HEADER_TIMEOUT_SECONDS),
            http_keepalive_timeout: Duration::from_secs(DEFAULT_HTTP_KEEPALIVE_TIMEOUT_SECONDS),
            join_ticket_ttl: Duration::from_secs(DEFAULT_JOIN_TICKET_TTL_SECONDS),
            max_control_bytes: DEFAULT_MAX_CONTROL_BYTES,
            max_frame_bytes: DEFAULT_MAX_FRAME_BYTES,
            max_queue_frames: DEFAULT_MAX_QUEUE_FRAMES,
            max_queue_bytes: DEFAULT_MAX_QUEUE_BYTES,
            max_connections: DEFAULT_MAX_CONNECTIONS,
            max_http_connections: DEFAULT_MAX_HTTP_CONNECTIONS,
            max_http_header_bytes: DEFAULT_MAX_HTTP_HEADER_BYTES,
            max_slots: DEFAULT_MAX_SLOTS,
            max_circuits: DEFAULT_MAX_CIRCUITS,
            max_control_sockets_per_slot: DEFAULT_MAX_CONTROL_SOCKETS_PER_SLOT,
            max_pending_circuits_per_slot: DEFAULT_MAX_PENDING_CIRCUITS_PER_SLOT,
            max_active_circuits_per_slot: DEFAULT_MAX_ACTIVE_CIRCUITS_PER_SLOT,
            max_allocations_per_second_per_slot: DEFAULT_MAX_ALLOCATIONS_PER_SECOND_PER_SLOT,
            ticket_secret: None,
            ticket_issuer: DEFAULT_TICKET_ISSUER.into(),
            allow_open: false,
        }
    }
}

impl RelayConfig {
    pub fn from_environment() -> Result<Self, ConfigError> {
        let mut config = Self::default();
        config.apply_environment(|name| env::var(name).ok())?;
        Ok(config)
    }

    fn apply_environment(
        &mut self,
        lookup: impl Fn(&str) -> Option<String>,
    ) -> Result<(), ConfigError> {
        if let Some(value) = lookup("CMUX_RELAY_BIND") {
            self.bind = parse_value("CMUX_RELAY_BIND", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_LEASE_SECONDS") {
            self.lease_duration = parse_duration("CMUX_RELAY_LEASE_SECONDS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_JOIN_TIMEOUT_SECONDS") {
            self.join_timeout = parse_duration("CMUX_RELAY_JOIN_TIMEOUT_SECONDS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_IDLE_TIMEOUT_SECONDS") {
            self.idle_timeout = parse_duration("CMUX_RELAY_IDLE_TIMEOUT_SECONDS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_HANDSHAKE_TIMEOUT_SECONDS") {
            self.handshake_timeout =
                parse_duration("CMUX_RELAY_HANDSHAKE_TIMEOUT_SECONDS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_CONTROL_IDLE_TIMEOUT_SECONDS") {
            self.control_idle_timeout =
                parse_duration("CMUX_RELAY_CONTROL_IDLE_TIMEOUT_SECONDS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_HTTP_HEADER_TIMEOUT_SECONDS") {
            self.http_header_timeout =
                parse_duration("CMUX_RELAY_HTTP_HEADER_TIMEOUT_SECONDS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_HTTP_KEEPALIVE_TIMEOUT_SECONDS") {
            self.http_keepalive_timeout =
                parse_duration("CMUX_RELAY_HTTP_KEEPALIVE_TIMEOUT_SECONDS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_JOIN_TICKET_TTL_SECONDS") {
            self.join_ticket_ttl = parse_duration("CMUX_RELAY_JOIN_TICKET_TTL_SECONDS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_CONTROL_BYTES") {
            self.max_control_bytes = parse_value("CMUX_RELAY_MAX_CONTROL_BYTES", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_FRAME_BYTES") {
            self.max_frame_bytes = parse_value("CMUX_RELAY_MAX_FRAME_BYTES", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_QUEUE_FRAMES") {
            self.max_queue_frames = parse_value("CMUX_RELAY_MAX_QUEUE_FRAMES", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_QUEUE_BYTES") {
            self.max_queue_bytes = parse_value("CMUX_RELAY_MAX_QUEUE_BYTES", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_CONNECTIONS") {
            self.max_connections = parse_value("CMUX_RELAY_MAX_CONNECTIONS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_HTTP_CONNECTIONS") {
            self.max_http_connections = parse_value("CMUX_RELAY_MAX_HTTP_CONNECTIONS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_HTTP_HEADER_BYTES") {
            self.max_http_header_bytes = parse_value("CMUX_RELAY_MAX_HTTP_HEADER_BYTES", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_SLOTS") {
            self.max_slots = parse_value("CMUX_RELAY_MAX_SLOTS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_CIRCUITS") {
            self.max_circuits = parse_value("CMUX_RELAY_MAX_CIRCUITS", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_CONTROL_SOCKETS_PER_SLOT") {
            self.max_control_sockets_per_slot =
                parse_value("CMUX_RELAY_MAX_CONTROL_SOCKETS_PER_SLOT", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_PENDING_CIRCUITS_PER_SLOT") {
            self.max_pending_circuits_per_slot =
                parse_value("CMUX_RELAY_MAX_PENDING_CIRCUITS_PER_SLOT", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_ACTIVE_CIRCUITS_PER_SLOT") {
            self.max_active_circuits_per_slot =
                parse_value("CMUX_RELAY_MAX_ACTIVE_CIRCUITS_PER_SLOT", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_MAX_ALLOCATIONS_PER_SECOND_PER_SLOT") {
            self.max_allocations_per_second_per_slot =
                parse_value("CMUX_RELAY_MAX_ALLOCATIONS_PER_SECOND_PER_SLOT", &value)?;
        }
        if let Some(value) = lookup("CMUX_RELAY_HMAC_SECRET") {
            self.ticket_secret = Some(value.into_bytes());
        }
        if let Some(value) = lookup("CMUX_RELAY_ISSUER") {
            self.ticket_issuer = value;
        }
        if let Some(value) = lookup("CMUX_RELAY_ALLOW_OPEN") {
            self.allow_open = parse_bool("CMUX_RELAY_ALLOW_OPEN", &value)?;
        }
        Ok(())
    }

    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.lease_duration.is_zero()
            || self.join_timeout.is_zero()
            || self.idle_timeout.is_zero()
            || self.handshake_timeout.is_zero()
            || self.control_idle_timeout.is_zero()
            || self.http_header_timeout.is_zero()
            || self.http_keepalive_timeout.is_zero()
            || self.join_ticket_ttl.is_zero()
        {
            return Err(ConfigError::new("relay durations must be greater than zero"));
        }
        if self.join_ticket_ttl.as_secs() > MAXIMUM_JOIN_TICKET_TTL_SECONDS {
            return Err(ConfigError::new(format!(
                "relay join ticket TTL cannot exceed {MAXIMUM_JOIN_TICKET_TTL_SECONDS} seconds"
            )));
        }
        if self.lease_duration.as_secs() > u64::from(u32::MAX) {
            return Err(ConfigError::new("relay lease does not fit the wire protocol"));
        }
        if self.max_control_bytes == 0
            || self.max_frame_bytes == 0
            || self.max_http_header_bytes == 0
        {
            return Err(ConfigError::new("relay message limits must be greater than zero"));
        }
        if self.max_queue_frames == 0 {
            return Err(ConfigError::new("relay queue must hold at least one frame"));
        }
        if self.max_connections == 0
            || self.max_http_connections == 0
            || self.max_slots == 0
            || self.max_circuits == 0
            || self.max_control_sockets_per_slot == 0
            || self.max_pending_circuits_per_slot == 0
            || self.max_active_circuits_per_slot == 0
            || self.max_allocations_per_second_per_slot == 0
        {
            return Err(ConfigError::new("relay resource limits must be greater than zero"));
        }
        if self.max_queue_bytes < self.max_frame_bytes {
            return Err(ConfigError::new(
                "relay queue byte limit must be at least the frame byte limit",
            ));
        }
        if self.ticket_secret.as_ref().is_some_and(|secret| secret.len() < 32) {
            return Err(ConfigError::new("CMUX_RELAY_HMAC_SECRET must contain at least 32 bytes"));
        }
        if self.ticket_issuer.is_empty()
            || self.ticket_issuer.len() > 256
            || self.ticket_issuer.contains('\n')
        {
            return Err(ConfigError::new(
                "CMUX_RELAY_ISSUER must contain 1 to 256 bytes without newline",
            ));
        }
        if !self.bind.ip().is_loopback() && self.ticket_secret.is_none() && !self.allow_open {
            return Err(ConfigError::new(
                "refusing a non-loopback open relay; configure CMUX_RELAY_HMAC_SECRET or pass --allow-open",
            ));
        }
        Ok(())
    }
}

#[derive(Clone)]
pub enum RelayCommand {
    Serve(RelayConfig),
    Ticket {
        secret: Vec<u8>,
        issuer: String,
        permission: RelayPermission,
        slot: String,
        lane: Option<LaneToken>,
        generation: Option<u64>,
        ttl: Duration,
    },
    Help,
}

impl RelayCommand {
    pub fn from_process() -> Result<Self, ConfigError> {
        let config = RelayConfig::from_environment()?;
        Self::parse(config, env::args_os().skip(1))
    }

    pub fn parse(
        mut config: RelayConfig,
        arguments: impl IntoIterator<Item = OsString>,
    ) -> Result<Self, ConfigError> {
        let mut args = arguments.into_iter().peekable();
        let mut command = "serve".to_owned();
        if let Some(first) = args.peek().and_then(|value| value.to_str())
            && !first.starts_with('-')
        {
            command = args.next().unwrap().to_string_lossy().into_owned();
        }

        if command == "help" {
            return Ok(Self::Help);
        }
        if command == "ticket" {
            return Self::parse_ticket(config, args);
        }
        if command != "serve" {
            return Err(ConfigError::new(format!("unknown command {command:?}")));
        }

        while let Some(argument) = args.next() {
            let argument = argument.to_string_lossy();
            match argument.as_ref() {
                "-h" | "--help" => return Ok(Self::Help),
                "--allow-open" => config.allow_open = true,
                "--bind" => config.bind = parse_next("--bind", &mut args)?,
                "--lease-seconds" => {
                    config.lease_duration =
                        Duration::from_secs(parse_next("--lease-seconds", &mut args)?);
                }
                "--join-timeout-seconds" => {
                    config.join_timeout =
                        Duration::from_secs(parse_next("--join-timeout-seconds", &mut args)?);
                }
                "--idle-timeout-seconds" => {
                    config.idle_timeout =
                        Duration::from_secs(parse_next("--idle-timeout-seconds", &mut args)?);
                }
                "--handshake-timeout-seconds" => {
                    config.handshake_timeout =
                        Duration::from_secs(parse_next("--handshake-timeout-seconds", &mut args)?);
                }
                "--control-idle-timeout-seconds" => {
                    config.control_idle_timeout = Duration::from_secs(parse_next(
                        "--control-idle-timeout-seconds",
                        &mut args,
                    )?);
                }
                "--http-header-timeout-seconds" => {
                    config.http_header_timeout = Duration::from_secs(parse_next(
                        "--http-header-timeout-seconds",
                        &mut args,
                    )?);
                }
                "--http-keepalive-timeout-seconds" => {
                    config.http_keepalive_timeout = Duration::from_secs(parse_next(
                        "--http-keepalive-timeout-seconds",
                        &mut args,
                    )?);
                }
                "--join-ticket-ttl-seconds" => {
                    config.join_ticket_ttl =
                        Duration::from_secs(parse_next("--join-ticket-ttl-seconds", &mut args)?);
                }
                "--max-control-bytes" => {
                    config.max_control_bytes = parse_next("--max-control-bytes", &mut args)?;
                }
                "--max-frame-bytes" => {
                    config.max_frame_bytes = parse_next("--max-frame-bytes", &mut args)?;
                }
                "--max-queue-frames" => {
                    config.max_queue_frames = parse_next("--max-queue-frames", &mut args)?;
                }
                "--max-queue-bytes" => {
                    config.max_queue_bytes = parse_next("--max-queue-bytes", &mut args)?;
                }
                "--max-connections" => {
                    config.max_connections = parse_next("--max-connections", &mut args)?;
                }
                "--max-http-connections" => {
                    config.max_http_connections = parse_next("--max-http-connections", &mut args)?;
                }
                "--max-http-header-bytes" => {
                    config.max_http_header_bytes =
                        parse_next("--max-http-header-bytes", &mut args)?;
                }
                "--max-slots" => {
                    config.max_slots = parse_next("--max-slots", &mut args)?;
                }
                "--max-circuits" => {
                    config.max_circuits = parse_next("--max-circuits", &mut args)?;
                }
                "--max-control-sockets-per-slot" => {
                    config.max_control_sockets_per_slot =
                        parse_next("--max-control-sockets-per-slot", &mut args)?;
                }
                "--max-pending-circuits-per-slot" => {
                    config.max_pending_circuits_per_slot =
                        parse_next("--max-pending-circuits-per-slot", &mut args)?;
                }
                "--max-active-circuits-per-slot" => {
                    config.max_active_circuits_per_slot =
                        parse_next("--max-active-circuits-per-slot", &mut args)?;
                }
                "--max-allocations-per-second-per-slot" => {
                    config.max_allocations_per_second_per_slot =
                        parse_next("--max-allocations-per-second-per-slot", &mut args)?;
                }
                "--issuer" => {
                    config.ticket_issuer = parse_next_string("--issuer", &mut args)?;
                }
                other => return Err(ConfigError::new(format!("unknown option {other:?}"))),
            }
        }
        config.validate()?;
        Ok(Self::Serve(config))
    }

    fn parse_ticket(
        config: RelayConfig,
        mut args: impl Iterator<Item = OsString>,
    ) -> Result<Self, ConfigError> {
        let mut permission = None;
        let mut slot = None;
        let mut lane = None;
        let mut generation = None;
        let mut ttl = Duration::from_secs(DEFAULT_TICKET_TTL_SECONDS);
        let secret = config.ticket_secret;
        while let Some(argument) = args.next() {
            let argument = argument.to_string_lossy();
            match argument.as_ref() {
                "-h" | "--help" => return Ok(Self::Help),
                "--permission" => {
                    let value = parse_next_string("--permission", &mut args)?;
                    permission = Some(match value.as_str() {
                        "register" => RelayPermission::Register,
                        "connect" => RelayPermission::Connect,
                        _ => {
                            return Err(ConfigError::new(
                                "--permission must be register or connect",
                            ));
                        }
                    });
                }
                "--slot" => slot = Some(parse_next_string("--slot", &mut args)?),
                "--lane" => {
                    lane = Some(LaneToken(parse_next_string("--lane", &mut args)?));
                }
                "--generation" => {
                    generation = Some(parse_next("--generation", &mut args)?);
                }
                "--ttl-seconds" => {
                    ttl = Duration::from_secs(parse_next("--ttl-seconds", &mut args)?);
                }
                other => return Err(ConfigError::new(format!("unknown ticket option {other:?}"))),
            }
        }
        let secret = secret
            .ok_or_else(|| ConfigError::new("ticket generation requires CMUX_RELAY_HMAC_SECRET"))?;
        if secret.len() < 32 {
            return Err(ConfigError::new("HMAC ticket secret must contain at least 32 bytes"));
        }
        let permission = permission
            .ok_or_else(|| ConfigError::new("ticket generation requires --permission"))?;
        let slot = slot.ok_or_else(|| ConfigError::new("ticket generation requires --slot"))?;
        if slot.is_empty() || slot.len() > 256 {
            return Err(ConfigError::new("ticket slot must contain 1 to 256 bytes"));
        }
        if ttl.is_zero() {
            return Err(ConfigError::new("ticket TTL must be greater than zero"));
        }
        if permission == RelayPermission::Register && (lane.is_some() || generation.is_some()) {
            return Err(ConfigError::new("register tickets cannot bind a lane or generation"));
        }
        Ok(Self::Ticket {
            secret,
            issuer: config.ticket_issuer,
            permission,
            slot,
            lane,
            generation,
            ttl,
        })
    }

    pub const fn help() -> &'static str {
        "cmux-relay [serve] [OPTIONS]\n\
         cmux-relay ticket --permission register|connect --slot SLOT [OPTIONS]\n\n\
         Serve options:\n\
           --bind ADDR                       Bind address (CMUX_RELAY_BIND)\n\
           --lease-seconds N                 Daemon control lease\n\
           --join-timeout-seconds N          Pending circuit timeout\n\
           --idle-timeout-seconds N          Paired circuit idle timeout\n\
           --handshake-timeout-seconds N     First control message timeout\n\
           --control-idle-timeout-seconds N  Authenticated control socket idle timeout\n\
           --http-header-timeout-seconds N   Complete HTTP header deadline\n\
           --http-keepalive-timeout-seconds N  Raw socket idle deadline after HTTP headers\n\
           --join-ticket-ttl-seconds N       Minted join ticket TTL (maximum 300)\n\
           --max-control-bytes N             Maximum JSON control bytes\n\
           --max-frame-bytes N               Maximum opaque binary frame bytes\n\
           --max-queue-frames N              Per-socket queued message limit\n\
           --max-queue-bytes N               Per-socket queued binary byte limit\n\
           --max-connections N               Concurrent WebSocket limit\n\
           --max-http-connections N          Concurrent raw TCP/HTTP limit\n\
           --max-http-header-bytes N          Maximum initial HTTP header bytes\n\
           --max-slots N                     Registered daemon slot limit\n\
           --max-circuits N                  Pending and paired circuit limit\n\
           --max-control-sockets-per-slot N   Daemon and client control sockets per slot\n\
           --max-pending-circuits-per-slot N  Pending circuits per slot\n\
           --max-active-circuits-per-slot N   Paired circuits per slot\n\
           --max-allocations-per-second-per-slot N  Sliding one-second allocation limit\n\
           --issuer NAME                     HMAC ticket issuer (CMUX_RELAY_ISSUER)\n\
           --allow-open                      Permit an unauthenticated non-loopback relay\n\n\
         Ticket options: --lane TOKEN, --generation N, --ttl-seconds N.\n\
         Set CMUX_RELAY_HMAC_SECRET to validate provider tickets and mint join tickets.\n\
         Endpoints: /healthz, /v1/relay, and /ws\n"
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError {
    message: String,
}

impl ConfigError {
    fn new(message: impl Into<String>) -> Self {
        Self { message: message.into() }
    }
}

impl fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ConfigError {}

fn parse_duration(name: &str, value: &str) -> Result<Duration, ConfigError> {
    Ok(Duration::from_secs(parse_value(name, value)?))
}

fn parse_bool(name: &str, value: &str) -> Result<bool, ConfigError> {
    match value {
        "1" | "true" | "yes" => Ok(true),
        "0" | "false" | "no" => Ok(false),
        _ => Err(ConfigError::new(format!("{name} must be true, false, 1, 0, yes, or no"))),
    }
}

fn parse_value<T>(name: &str, value: &str) -> Result<T, ConfigError>
where
    T: FromStr,
    T::Err: fmt::Display,
{
    value.parse().map_err(|error| ConfigError::new(format!("invalid {name}: {error}")))
}

fn parse_next<T>(option: &str, args: &mut impl Iterator<Item = OsString>) -> Result<T, ConfigError>
where
    T: FromStr,
    T::Err: fmt::Display,
{
    let value = parse_next_string(option, args)?;
    parse_value(option, &value)
}

fn parse_next_string(
    option: &str,
    args: &mut impl Iterator<Item = OsString>,
) -> Result<String, ConfigError> {
    args.next()
        .map(|value| value.to_string_lossy().into_owned())
        .ok_or_else(|| ConfigError::new(format!("{option} requires a value")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_loopback_open_relay_requires_an_explicit_override() {
        let config =
            RelayConfig { bind: "0.0.0.0:8787".parse().unwrap(), ..RelayConfig::default() };
        assert!(config.validate().is_err());
    }

    #[test]
    fn command_line_overrides_defaults() {
        let command = RelayCommand::parse(
            RelayConfig::default(),
            [
                "--bind",
                "127.0.0.1:9000",
                "--max-frame-bytes",
                "1024",
                "--max-queue-bytes",
                "2048",
                "--http-header-timeout-seconds",
                "7",
                "--max-control-sockets-per-slot",
                "9",
                "--max-allocations-per-second-per-slot",
                "11",
            ]
            .map(OsString::from),
        )
        .unwrap();
        let RelayCommand::Serve(config) = command else {
            panic!("expected serve command");
        };
        assert_eq!(config.bind, "127.0.0.1:9000".parse().unwrap());
        assert_eq!(config.max_frame_bytes, 1024);
        assert_eq!(config.max_queue_bytes, 2048);
        assert_eq!(config.http_header_timeout, Duration::from_secs(7));
        assert_eq!(config.max_control_sockets_per_slot, 9);
        assert_eq!(config.max_allocations_per_second_per_slot, 11);
    }

    #[test]
    fn allow_open_flag_is_applied_before_security_validation() {
        let config =
            RelayConfig { bind: "0.0.0.0:8787".parse().unwrap(), ..RelayConfig::default() };
        let command = RelayCommand::parse(config, [OsString::from("--allow-open")]).unwrap();
        assert!(matches!(command, RelayCommand::Serve(config) if config.allow_open));
    }
}
