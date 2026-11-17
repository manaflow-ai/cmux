//! `cmux-gcp-machine`: the Labs GCP machine provider's command line, for the
//! acceptance run (create, stop, start, snapshot, delete in a real project)
//! before the app's New machine sheet calls the same library.
//!
//! ```text
//! cmux-gcp-machine plan   --key K --project P --zone Z --image I [--machine-type T] [--disk-gb N] [--idle-minutes N]
//! cmux-gcp-machine create --key K --project P --zone Z --image I ... --token-fd N [--wait]
//! cmux-gcp-machine start|stop|snapshot|delete --key K --machine M --project P --zone Z --token-fd N [--wait]
//! cmux-gcp-machine observe --machine M --project P --zone Z --token-fd N
//! cmux-gcp-machine pending --project P
//! ```
//!
//! The token comes from a descriptor the caller opened (`--token-fd 3`
//! with `3< <(mint-a-token)`), never argv or the environment. Every call but
//! `plan` and `pending` is refused while `labs.gcpMachineProvider` is off.

use cmux_machine_provider::{
    AccessToken, CreateSpec, CurlTransport, GcpProvider, IdempotencyKey, Ledger, MachineProvider,
    Op, Outcome, ProviderError, Request, gcp, labs,
};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(out) => {
            println!("{out}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("cmux-gcp-machine: {e}");
            ExitCode::from(match e {
                ProviderError::Indeterminate(_) => 75,
                ProviderError::Conflict(_) => 69,
                _ => 1,
            })
        }
    }
}

fn run(args: &[String]) -> Result<String, ProviderError> {
    let refused = |m: &str| ProviderError::Refused(m.to_owned());
    let (verb, rest) = args.split_first().ok_or_else(|| refused("usage: see --help"))?;
    if verb == "--help" || verb == "-h" {
        return Ok(include_str!("main.rs")
            .lines()
            .skip_while(|l| !l.starts_with("//! ```text"))
            .skip(1)
            .take_while(|l| !l.starts_with("//! ```"))
            .map(|l| l.trim_start_matches("//! "))
            .collect::<Vec<_>>()
            .join("\n"));
    }
    let flags = parse_flags(rest)?;
    let get = |name: &str| flags.get(name).map(String::as_str);
    let need = |name: &str| get(name).ok_or_else(|| refused(&format!("--{name} is required")));
    let project = need("project")?;
    if !gcp::valid_name(project) {
        return Err(refused(&format!("project {project:?} is not a GCP project id")));
    }
    let ledger_path = match get("ledger") {
        Some(path) => PathBuf::from(path),
        None => default_ledger(project)?,
    };
    if verb == "pending" {
        let ledger = Ledger::open(&ledger_path).map_err(|e| refused(&e.to_string()))?;
        let rows: Vec<_> = ledger
            .pending()
            .into_iter()
            .map(|(key, op, machine)| serde_json::json!({"key": key, "op": op, "machine": machine}))
            .collect();
        return Ok(serde_json::to_string_pretty(&rows).unwrap_or_default());
    }
    let spec = || -> Result<CreateSpec, ProviderError> {
        let number = |name: &str, default: u32| {
            get(name).map_or(Ok(default), |v| v.parse().map_err(|_| refused(&format!("--{name}"))))
        };
        Ok(CreateSpec {
            image: need("image")?.to_owned(),
            machine_type: get("machine-type").unwrap_or("e2-standard-4").to_owned(),
            zone: need("zone")?.to_owned(),
            disk_gb: number("disk-gb", 50)?,
            idle_grace_minutes: number("idle-minutes", 30)?,
            labels: BTreeMap::new(),
        })
    };
    let zone = need("zone")?;
    if verb == "plan" || verb == "cost" {
        // Nothing leaves this machine, and no provider is made: the sheet's
        // preview.
        let spec = spec()?;
        spec.validate()?;
        let key = IdempotencyKey::new(need("key").unwrap_or("preview"))?;
        let machine = gcp::machine_name(&key);
        return Ok(serde_json::to_string_pretty(&serde_json::json!({
            "project": project,
            "machine": machine,
            "insert": gcp::insert_body(&key, &machine, &spec),
            "cost": gcp::cost_estimate(&spec),
        }))
        .unwrap_or_default());
    }
    let enabled = labs::require()?;
    let fd: u32 = need("token-fd")?.parse().map_err(|_| refused("--token-fd takes a number"))?;
    let mut provider = GcpProvider::new(
        enabled,
        project,
        zone,
        AccessToken::from_fd(fd)?,
        Box::new(CurlTransport::default()),
    )?;
    provider.wait = flags.contains_key("wait");
    if verb == "observe" {
        let state = provider.observe(need("machine")?)?;
        return Ok(serde_json::to_string(&state).unwrap_or_default());
    }
    let op = match verb.as_str() {
        "create" => Op::Create,
        "start" => Op::Start,
        "stop" => Op::Stop,
        "snapshot" => Op::Snapshot,
        "delete" => Op::Delete,
        other => return Err(refused(&format!("unknown command {other:?}"))),
    };
    let request = match op {
        Op::Create => Request::create(spec()?),
        _ => Request::on(op, need("machine")?),
    };
    let key = IdempotencyKey::new(need("key")?)?;
    let mut ledger = Ledger::open(&ledger_path).map_err(|e| refused(&e.to_string()))?;
    let outcome = ledger.run(&provider, &key, &request)?;
    let how = match &outcome {
        Outcome::Committed(_) => "committed",
        Outcome::Replayed(_) => "replayed",
        Outcome::Reconciled(_) => "reconciled",
    };
    Ok(serde_json::to_string_pretty(
        &serde_json::json!({ "outcome": how, "receipt": outcome.receipt() }),
    )
    .unwrap_or_default())
}

fn parse_flags(args: &[String]) -> Result<HashMap<String, String>, ProviderError> {
    let mut flags = HashMap::new();
    let mut iter = args.iter().peekable();
    while let Some(arg) = iter.next() {
        let Some(name) = arg.strip_prefix("--") else {
            return Err(ProviderError::Refused(format!("unexpected argument {arg:?}")));
        };
        let value = match iter.peek() {
            Some(next) if !next.starts_with("--") => iter.next().cloned().unwrap_or_default(),
            _ => String::new(),
        };
        flags.insert(name.to_owned(), value);
    }
    Ok(flags)
}

/// `~/.local/state/cmux/machine-provider/gcp-<project>.jsonl`.
/// Refused with no `HOME` (it would land in the working directory).
fn default_ledger(project: &str) -> Result<PathBuf, ProviderError> {
    let home = std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from);
    let home = home.ok_or_else(|| ProviderError::Refused("no HOME: pass --ledger".into()))?;
    Ok(home.join(".local/state/cmux/machine-provider").join(format!("gcp-{project}.jsonl")))
}
