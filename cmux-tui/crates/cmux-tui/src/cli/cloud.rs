//! Cloud control through the signed-in app, with interactive connections in this
//! Rust process. The app owns authentication, route selection and the shared hub.
//! No Swift CLI subprocess, system tunnel, or second WireGuard identity is used.

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, UsageError};
use crate::localization::catalog;

mod internal;
use internal::{AppFailure, Operation};

pub(super) enum Plan {
    Request { method: Operation, params: Value, view: View },
    Tui { vm: String },
}

pub(super) enum View {
    List,
    Text,
    Json,
}

pub(super) fn parse(args: &[String]) -> Result<Plan, UsageError> {
    let words = args.iter().map(String::as_str).collect::<Vec<_>>();
    let request = |method, params, view| Ok(Plan::Request { method, params, view });
    let valid_id = |value: &str| !value.is_empty() && !value.starts_with('-');
    match words.as_slice() {
        ["ls" | "list"] => request(Operation::List, json!({}), View::List),
        ["tui", vm] if valid_id(vm) => Ok(Plan::Tui { vm: (*vm).into() }),
        ["tree", rest @ ..] => {
            let mut params = json!({});
            for value in rest {
                if *value == "--refresh" && params.get("refresh").is_none() {
                    params["refresh"] = json!(true);
                } else if valid_id(value) && params.get("machine").is_none() {
                    params["machine"] = json!(value);
                } else {
                    return Err(usage());
                }
            }
            request(Operation::Catalog, params, View::Json)
        }
        ["terminal", "new", vm, rest @ ..] if valid_id(vm) => {
            let mut params = json!({"id":vm,"open":false});
            match rest {
                [] => {}
                ["--name", name] if !name.is_empty() => params["name"] = json!(name),
                _ => return Err(usage()),
            }
            request(Operation::TerminalNew, params, View::Json)
        }
        ["terminal", action @ ("read" | "close"), vm, terminal]
            if valid_id(vm) && valid_id(terminal) =>
        {
            request(
                if *action == "read" { Operation::TerminalRead } else { Operation::TerminalClose },
                json!({"id":vm,"terminal_id":terminal}),
                if *action == "read" { View::Text } else { View::Json },
            )
        }
        ["terminal", "send", vm, terminal, rest @ ..] if valid_id(vm) && valid_id(terminal) => {
            let mut params = json!({"id":vm,"terminal_id":terminal});
            let mut text = Vec::new();
            let mut tail = rest.iter().copied();
            while let Some(value) = tail.next() {
                match value {
                    "--" => {
                        text.extend(tail);
                        break;
                    }
                    "--keys" if params.get("keys").is_none() => {
                        let keys = tail.next().ok_or_else(usage)?;
                        let keys = keys.split(',').map(str::trim).collect::<Vec<_>>();
                        if keys.iter().any(|key| key.is_empty() || key.starts_with('-')) {
                            return Err(usage());
                        }
                        params["keys"] = json!(keys);
                    }
                    value if value.starts_with('-') => return Err(usage()),
                    value => text.push(value),
                }
            }
            let text = text.join(" ");
            if !text.is_empty() {
                params["text"] = json!(text);
            }
            if params.get("text").is_none() && params.get("keys").is_none() {
                return Err(usage());
            }
            request(Operation::TerminalWrite, params, View::Json)
        }
        _ => Err(usage()),
    }
}

fn usage() -> UsageError {
    UsageError::new(catalog().cloud_vm.help)
}

pub(super) fn run(global: GlobalArgs, plan: Plan) -> i32 {
    if global.session.is_some()
        || global.machine.is_some()
        || (matches!(plan, Plan::Tui { .. }) && global.output != OutputMode::Human)
    {
        return super::wire::print_local_error(
            &json!({"code":"usage.invalid","message":catalog().cloud_vm.invalid_globals}),
            global.output,
            2,
        );
    }
    #[cfg(unix)]
    let result = run_unix(&global, plan);
    #[cfg(not(unix))]
    let result: anyhow::Result<i32> = {
        let _ = plan;
        Err(anyhow::anyhow!(catalog().cloud_vm.unix_required))
    };
    match result {
        Ok(code) => code,
        Err(error) => {
            let code = error
                .downcast_ref::<AppFailure>()
                .map_or("cloud.failed", |error| error.code.as_str());
            super::wire::print_local_error(
                &json!({"code":code,"message":format!("{error:#}")}),
                global.output,
                1,
            )
        }
    }
}

#[cfg(unix)]
fn run_unix(global: &GlobalArgs, plan: Plan) -> anyhow::Result<i32> {
    use std::io::Write;
    use std::path::PathBuf;
    use std::time::Duration;

    let socket = global
        .socket
        .clone()
        .or_else(|| {
            std::env::var_os("CMUX_SOCKET_PATH").filter(|v| !v.is_empty()).map(PathBuf::from)
        })
        .unwrap_or_else(|| PathBuf::from("/tmp/cmux.sock"));
    let (method, params, view, tui) = match plan {
        Plan::Request { method, params, view } => (method, params, view, false),
        Plan::Tui { vm } => (
            Operation::RemoteInfo,
            json!({"id":vm,"client_capabilities":crate::remote_cli::PROBE_CAPABILITIES}),
            View::Json,
            true,
        ),
    };
    // Match the app's bounded Cloud provisioning deadline. Inventory and
    // terminal operations use the shorter ordinary request deadline.
    let timeout = Duration::from_secs(if tui { 16 * 60 } else { 180 });
    let result = internal::request(&socket, method, params, timeout)?;
    if tui {
        let args = connect_args(&result)?;
        return Ok(crate::remote_cli::run(
            &args,
            &crate::usage(),
            crate::config::StartupConfigSnapshot::load,
        ));
    }
    if global.output == OutputMode::Quiet {
        return Ok(0);
    }
    let mut out = std::io::stdout().lock();
    if global.output != OutputMode::Human || matches!(view, View::Json) {
        serde_json::to_writer(&mut out, &result)?;
        writeln!(out)?;
    } else {
        match view {
            View::List => {
                let vms = result["vms"]
                    .as_array()
                    .ok_or_else(|| anyhow::anyhow!(catalog().cloud_vm.invalid_response))?;
                if vms.is_empty() {
                    writeln!(out, "{}", catalog().cloud_vm.empty)?;
                }
                for vm in vms {
                    let cell = |key| vm.get(key).and_then(Value::as_str).unwrap_or("");
                    writeln!(out, "{}\t{}\t{}", cell("id"), cell("status"), cell("displayName"))?;
                }
            }
            View::Text => {
                let text = result["text"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!(catalog().cloud_vm.invalid_response))?;
                out.write_all(text.as_bytes())?;
            }
            View::Json => unreachable!(),
        }
    }
    out.flush()?;
    Ok(0)
}

#[cfg(unix)]
fn connect_args(info: &Value) -> anyhow::Result<Vec<String>> {
    use anyhow::{anyhow, ensure};
    let messages = &catalog().cloud_vm;
    ensure!(info["trusted_carrier"].as_bool() == Some(true), messages.trust_required);
    let hub = info["wireguard_hub_socket"]
        .as_str()
        .filter(|p| std::path::Path::new(p).is_absolute())
        .ok_or_else(|| anyhow!(messages.hub_required))?;
    let route = info["route"].as_str().ok_or_else(|| anyhow!(messages.invalid_response))?;
    let url = url::Url::parse(route).map_err(|_| anyhow!(messages.invalid_response))?;
    ensure!(
        matches!(url.scheme(), "ws" | "wss")
            && url.host().is_some()
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none(),
        messages.invalid_response
    );
    if let Some(protocol) = info["daemon_build"]["remote_protocol"].as_u64() {
        ensure!(
            protocol == u64::from(cmux_remote_protocol::REMOTE_PROTOCOL_VERSION),
            messages.protocol_mismatch
        );
    }
    Ok(vec![
        "connect".into(),
        route.into(),
        "--carrier".into(),
        "--wireguard-hub".into(),
        hub.into(),
    ])
}
