//! Preview URLs use the machine's root agent identity inside Cloud, and the
//! app's account session when a Mac explicitly names a machine.

use std::io::Write;
use std::path::Path;

use cmux_host::cloud::preview::{
    PreviewAsk, PreviewOperation, ShareAudience, ask_agent, plain_inventory, preview_row,
};
use cmux_host::cloud::wire::AGENT_SOCKET;
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

fn messages() -> &'static crate::localization::AppControlMessages {
    &crate::localization::catalog().app_control
}

struct Command {
    ask: PreviewAsk,
    target: Option<String>,
}

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let [cloud, preview, rest @ ..] = words.as_slice() else { return None };
    if cloud != "cloud" || preview != "preview" {
        return None;
    }
    if rest.is_empty()
        || matches!(rest, [flag] if matches!(flag.as_str(), "help" | "--help" | "-h"))
        || matches!(rest, [verb, flag] if matches!(verb.as_str(), "ls" | "list" | "url" | "share") && matches!(flag.as_str(), "--help" | "-h"))
    {
        println!("{}", messages().cloud_preview_help);
        return Some(0);
    }
    let command = match parse(rest) {
        Ok(command) => command,
        Err(error) => {
            return Some(super::app::failure("usage.invalid", &error.0, global.output, 2));
        }
    };
    Some(match run(&global, &command) {
        Ok(value) => match output_text(&command.ask.operation, &value, global.output) {
            Ok(text) => match std::io::stdout().lock().write_all(text.as_bytes()) {
                Ok(()) => 0,
                Err(error) => {
                    super::app::failure("output.failed", &error.to_string(), global.output, 1)
                }
            },
            Err(message) => super::app::failure("preview.bad_answer", &message, global.output, 1),
        },
        Err(error) => super::wire::print_local_error(&error, global.output, 1),
    })
}

fn parse(args: &[String]) -> Result<Command, UsageError> {
    let usage = || UsageError::new(messages().cloud_preview_help);
    let (verb, rest) = args.split_first().ok_or_else(usage)?;
    let operation = match verb.as_str() {
        "ls" | "list" => PreviewOperation::List,
        "url" => PreviewOperation::Url,
        "share" => PreviewOperation::Share,
        _ => return Err(usage()),
    };
    let mut port = None;
    let mut target = None;
    let mut audience = None;
    let mut bootstrap = false;
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        let (flag, inline) =
            word.split_once('=').map_or((word.as_str(), None), |(k, v)| (k, Some(v)));
        if matches!(flag, "--bootstrap" | "--open") {
            if inline.is_some() || bootstrap || operation != PreviewOperation::Url {
                return Err(usage());
            }
            bootstrap = true;
            continue;
        }
        if matches!(flag, "--link" | "--team") {
            if inline.is_some() || audience.is_some() {
                return Err(UsageError::new(messages().cloud_preview_audience));
            }
            audience =
                Some(if flag == "--link" { ShareAudience::Link } else { ShareAudience::Team });
            continue;
        }
        let value = inline.or_else(|| words.next().map(String::as_str)).ok_or_else(usage)?;
        match flag {
            "--port" if port.is_none() => {
                port = Some(
                    value
                        .parse::<u16>()
                        .ok()
                        .filter(|port| *port > 0)
                        .ok_or_else(|| UsageError::new(messages().cloud_preview_port))?,
                );
            }
            "--target" if target.is_none() => {
                let id = value
                    .strip_prefix("machine:")
                    .filter(|id| valid_id(id))
                    .ok_or_else(|| UsageError::new(messages().cloud_preview_target))?;
                target = Some(format!("machine:{id}"));
            }
            "--user" if audience.is_none() && valid_id(value) => {
                audience = Some(ShareAudience::User(value.to_owned()));
            }
            _ => return Err(usage()),
        }
    }
    match operation {
        PreviewOperation::List if port.is_some() || audience.is_some() => return Err(usage()),
        PreviewOperation::Url if port.is_none() || audience.is_some() => return Err(usage()),
        PreviewOperation::Share if port.is_none() || audience.is_none() => return Err(usage()),
        _ => {}
    }
    Ok(Command { ask: PreviewAsk { operation, port, audience, bootstrap }, target })
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 256
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte))
}

fn action_params(command: &Command) -> Value {
    let mut arguments = json!({"operation": match command.ask.operation {
        PreviewOperation::List => "list",
        PreviewOperation::Url => "url",
        PreviewOperation::Share => "share",
    }});
    if let Some(port) = command.ask.port {
        arguments["port"] = json!(port);
    }
    if let Some(audience) = &command.ask.audience {
        arguments["audience"] = json!(match audience {
            ShareAudience::Link => "link",
            ShareAudience::Team => "team",
            ShareAudience::User(_) => "user",
        });
        if let ShareAudience::User(user) = audience {
            arguments["user_id"] = json!(user);
        }
    }
    let mut params = Value::Object(super::app::action_run_params(
        "cloudPreview",
        super::app::ActionName::Any,
        super::app::action_origin(),
    ));
    params["target"] = json!(command.target);
    params["args"] = arguments;
    params
}

fn local_error(message: impl Into<String>) -> Value {
    json!({"code":"preview.failed", "message":message.into(), "retryable":false})
}

fn run(global: &GlobalArgs, command: &Command) -> Result<Value, Value> {
    if global.machine.is_some() {
        return Err(local_error(messages().cloud_preview_machine_option));
    }
    let value = if command.target.is_none() {
        let socket = Path::new(AGENT_SOCKET);
        if !socket.exists() {
            return Err(local_error(messages().cloud_preview_agent_unavailable));
        }
        ask_agent(socket, &command.ask).map_err(local_error)?
    } else {
        let mut params = action_params(command);
        super::app::insert_run_key(&mut params, global.idempotency_key.as_deref())
            .map_err(local_error)?;
        let mut stream = super::app::connect_command(global)?;
        let reply = super::app::wait::request(
            global,
            &mut stream,
            "action.run",
            &params,
            Some(super::app::waiting_run_timeout("cloudPreview")),
        )??;
        if reply.get("ran") != Some(&Value::Bool(true)) {
            return Err(local_error(messages().cloud_preview_unfinished));
        }
        reply
            .get("result")
            .cloned()
            .ok_or_else(|| local_error(messages().cloud_preview_missing_result))?
    };
    if value.get("ok") == Some(&Value::Bool(false)) {
        return Err(value
            .get("error")
            .cloned()
            .unwrap_or_else(|| local_error(messages().cloud_preview_failed)));
    }
    preview_result(command, value).map_err(local_error)
}

/// The app forwards the fresh inventory; selecting the requested listener
/// belongs in Rust, shared with the guest command's output contract.
fn preview_result(command: &Command, value: Value) -> Result<Value, String> {
    if command.ask.operation == PreviewOperation::Share {
        return Ok(value);
    }
    if command.ask.operation == PreviewOperation::List {
        if let Some(target) = &command.target
            && value.get("machine").and_then(Value::as_str) != target.strip_prefix("machine:")
        {
            return Err(messages().cloud_preview_wrong_machine.to_owned());
        }
        return plain_inventory(&value);
    }
    if value.get("previews").is_none() && value.get("machine").is_none() {
        return preview_row(&value, command.ask.bootstrap);
    }
    if let Some(target) = &command.target
        && value.get("machine").and_then(Value::as_str) != target.strip_prefix("machine:")
    {
        return Err(messages().cloud_preview_wrong_machine.to_owned());
    }
    let rows = value
        .get("previews")
        .and_then(Value::as_array)
        .ok_or_else(|| messages().cloud_preview_bad_inventory.to_owned())?;
    let row = rows
        .iter()
        .find(|row| row.get("port").and_then(Value::as_u64) == command.ask.port.map(u64::from))
        .ok_or_else(|| messages().cloud_preview_start_server.to_owned())?;
    preview_row(row, command.ask.bootstrap)
}

fn output_text(
    operation: &PreviewOperation,
    value: &Value,
    output: OutputMode,
) -> Result<String, String> {
    let url = match operation {
        PreviewOperation::List => None,
        _ => Some(
            value
                .get("url")
                .or_else(|| value.pointer("/preview/url"))
                .or_else(|| value.pointer("/share/url"))
                .and_then(Value::as_str)
                .filter(|url| valid_url(url))
                .ok_or(messages().cloud_preview_invalid_url)?,
        ),
    };
    match output {
        OutputMode::Quiet => Ok(String::new()),
        OutputMode::Json | OutputMode::JsonLines => Ok(format!("{value}\n")),
        OutputMode::Human => match url {
            Some(url) => Ok(format!("{url}\n")),
            None => {
                Ok(format!("{}\n", serde_json::to_string_pretty(value).map_err(|e| e.to_string())?))
            }
        },
    }
}

fn valid_url(url: &str) -> bool {
    !url.chars().any(|character| character.is_control() || character.is_whitespace())
        && url::Url::parse(url).is_ok_and(|url| {
            url.scheme() == "https"
                && url.host_str().is_some()
                && url.username().is_empty()
                && url.password().is_none()
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn preview_commands_keep_guest_identity_implicit_and_mac_target_explicit() {
        let guest = parse(&words("url --port 3000")).unwrap();
        assert!(guest.target.is_none());
        assert_eq!(guest.ask.port, Some(3000));
        let mac =
            parse(&words("share --port=8080 --user user_abc --target machine:vm_abc")).unwrap();
        assert_eq!(mac.target.as_deref(), Some("machine:vm_abc"));
        assert_eq!(
            action_params(&mac)["args"],
            json!({
                "operation":"share", "port":8080, "audience":"user", "user_id":"user_abc"
            })
        );
        assert!(parse(&words("ls")).is_ok());
        assert!(parse(&words("share --port 65535 --team")).is_ok());
        assert!(parse(&words("share --link --port 1")).is_ok());
        let (global, words) =
            super::super::parse_globals(&words("cloud preview share --port 3000 --team --json"))
                .unwrap();
        assert_eq!(global.output, OutputMode::Json);
        assert!(parse(&words[2..]).is_ok());
    }

    #[test]
    fn preview_boolean_switches_do_not_consume_global_output_flags() {
        for command in [
            "share --port 3000 --link",
            "share --port 3000 --team",
            "url --port 3000 --bootstrap",
            "url --port 3000 --open",
        ] {
            for (flag, output) in [
                ("--json", OutputMode::Json),
                ("--jsonl", OutputMode::JsonLines),
                ("--quiet", OutputMode::Quiet),
            ] {
                let args = words(&format!("cloud preview {command} {flag}"));
                let (global, rest) = super::super::parse_globals(&args).unwrap();
                assert_eq!(global.output, output, "{command} {flag}");
                assert!(parse(&rest[2..]).is_ok(), "{command} {flag}");
            }
        }
    }

    #[test]
    fn preview_rejects_ambiguous_sharing_bad_ports_and_unknown_flags() {
        for invalid in [
            "url",
            "url --port 0",
            "url --port 65536",
            "url --port -1",
            "url --port 80 --link",
            "ls --port 80",
            "ls --bootstrap",
            "share --port 80 --link --bootstrap",
            "url --port 80 --bootstrap=true",
            "url --port 80 --bootstrap --open",
            "share --port 80",
            "share --port 80 --link --team",
            "share --port 80 --user x --link",
            "share --port 80 --link=true",
            "share --port 80 --user ../x",
            "url --port 80 --port 81",
            "url --port 80 --target vm_abc",
            "url --port 80 --target machine:../x",
            "url --port 80 --cloud-api https://other.test",
        ] {
            assert!(parse(&words(invalid)).is_err(), "{invalid}");
        }
    }

    #[test]
    fn preview_url_output_is_a_single_line_and_json_retains_metadata() {
        let value = json!({"url":"https://example.preview.cmux.dev/", "expires_at":"later"});
        assert_eq!(
            output_text(&PreviewOperation::Url, &value, OutputMode::Human).unwrap(),
            "https://example.preview.cmux.dev/\n"
        );
        let structured: Value = serde_json::from_str(
            &output_text(&PreviewOperation::Share, &value, OutputMode::Json).unwrap(),
        )
        .unwrap();
        assert_eq!(structured, value);
        assert_eq!(output_text(&PreviewOperation::Url, &value, OutputMode::Quiet).unwrap(), "");
        for invalid in [
            json!({}),
            json!({"url":"http://example.test"}),
            json!({"url":"https://user:pass@example.test"}),
            json!({"url":"https://example.test/\nsecond-line"}),
        ] {
            assert!(output_text(&PreviewOperation::Url, &invalid, OutputMode::Human).is_err());
        }
    }

    #[test]
    fn preview_mac_url_selects_only_the_fresh_port_on_the_target_machine() {
        let command = parse(&words("url --port 3000 --target machine:vm_selected")).unwrap();
        let fresh = json!({"port":3000,"url":"https://fresh.preview.cmux.dev", "origin":"https://fresh.preview.cmux.dev"});
        let inventory = json!({"machine":"vm_selected", "previews":[
            {"port":8080,"url":"https://other.preview.cmux.dev/"}, fresh.clone()
        ]});
        assert_eq!(preview_result(&command, inventory).unwrap(), fresh);
        let wrong = json!({"machine":"vm_other", "previews":[fresh]});
        assert!(
            preview_result(&command, wrong)
                .unwrap_err()
                .contains(messages().cloud_preview_wrong_machine)
        );
        let stopped = json!({"machine":"vm_selected", "previews":[]});
        assert!(
            preview_result(&command, stopped)
                .unwrap_err()
                .contains(messages().cloud_preview_start_server)
        );
        let malformed = json!({"machine":"vm_selected", "previews":null});
        assert!(
            preview_result(&command, malformed)
                .unwrap_err()
                .contains(messages().cloud_preview_bad_inventory)
        );
    }
    #[test]
    fn preview_defaults_never_print_owner_tokens_in_human_or_json_output() {
        let fresh = json!({"port":3000, "origin":"https://fresh.preview.cmux.dev",
            "url":"https://fresh.preview.cmux.dev/__cmux_preview_auth?token=OWNER_SECRET"});
        let inventory = json!({"machine":"vm_selected", "previews":[fresh]});
        for args in
            ["url --port 3000 --target machine:vm_selected", "ls --target machine:vm_selected"]
        {
            let command = parse(&words(args)).unwrap();
            let plain = preview_result(&command, inventory.clone()).unwrap();
            for mode in [OutputMode::Human, OutputMode::Json, OutputMode::JsonLines] {
                let text = output_text(&command.ask.operation, &plain, mode).unwrap();
                assert!(!text.contains("OWNER_SECRET"));
                assert!(!text.contains("token="));
                assert!(text.contains("https://fresh.preview.cmux.dev"));
            }
        }
        for flag in ["--bootstrap", "--open"] {
            let command =
                parse(&words(&format!("url --port 3000 --target machine:vm_selected {flag}")))
                    .unwrap();
            assert!(command.ask.bootstrap);
            let value = preview_result(&command, inventory.clone()).unwrap();
            for mode in [OutputMode::Human, OutputMode::Json] {
                assert!(
                    output_text(&command.ask.operation, &value, mode)
                        .unwrap()
                        .contains("token=OWNER_SECRET")
                );
            }
        }
    }
}
