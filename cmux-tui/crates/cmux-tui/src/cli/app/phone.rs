//! `cmux browser tab_…@phone <verb>` (or `tab_…@<device>`): a page verb on
//! the tab the iPhone shows in its own web view, so an agent checks a page
//! as the phone renders it (RFD 0089). The verb parses as the Mac tab's does
//! ([`super::page::parse_page`]); only the verbs `cmux_phone_page::VERBS`
//! lists go to a phone. The call goes to this Mac's link host on its local
//! socket (`{"op":"phone-page",…}`), which routes it to the linked phone or
//! refuses (`phone_not_linked` when none holds the tab's channel open).

use serde_json::{Value, json};

use super::super::machine_link::{Conversation, link_socket};
use super::{AppCommand, GlobalArgs, UsageError, failure, page};

/// Parses `browser <tab_…@device> <verb…>`; `None` when `target` is not a
/// phone tab address.
pub(super) fn parse(target: &str, args: &[String]) -> Option<Result<AppCommand, UsageError>> {
    let address = cmux_phone_page::Address::parse(target)?;
    Some(page::parse_page(&address.tab, args).and_then(|command| {
        if let AppCommand::Screenshot { params, .. } = &command
            && (params.get("selector").is_some() || params.get("full_page").is_some())
        {
            let messages = &crate::localization::catalog().app_control;
            return Err(UsageError::new(messages.browser_page_usage));
        }
        let method = match &command {
            AppCommand::Call { method, .. } => *method,
            AppCommand::Screenshot { .. } => "browser.page.screenshot",
            _ => "",
        };
        if !cmux_phone_page::supports(method) {
            let messages = &crate::localization::catalog().app_control;
            return Err(UsageError::new(messages.browser_page_usage));
        }
        Ok(AppCommand::Phone { device: address.device, then: Box::new(command) })
    }))
}

/// The link host's request for `command` (a parsed phone call).
pub(super) fn request(device: Option<&str>, command: &AppCommand) -> Option<Value> {
    let (method, params) = match command {
        AppCommand::Call { method, params, .. } => (*method, params),
        AppCommand::Screenshot { params, .. } => ("browser.page.screenshot", params),
        _ => return None,
    };
    Some(json!({"op": "phone-page", "device": device, "method": method, "params": params}))
}

pub(super) fn run(global: &GlobalArgs, device: Option<&str>, command: &AppCommand) -> i32 {
    let output = global.output;
    let Some(request) = request(device, command) else {
        return failure("usage.invalid", "cmux: not a phone tab verb", output, 2);
    };
    let daemon = match super::super::wire::resolve_socket_or_report(global) {
        Ok((socket, _)) => socket,
        Err(code) => return code,
    };
    let answer = Conversation::start(&link_socket(&daemon), &request).and_then(|mut c| c.next());
    let answer = match answer {
        Ok(answer) => answer,
        Err((code, message)) => return failure(&code, &format!("cmux: {message}"), output, 3),
    };
    match answered(answer) {
        Ok(value) => match command {
            AppCommand::Screenshot { out, .. } => {
                page::save_screenshot(value, out.as_deref(), output)
            }
            _ => super::super::wire::print_local_success(&value, output),
        },
        Err((code, message)) => failure(&code, &format!("cmux: {message}"), output, 1),
    }
}

/// The link host's answer: the verb's value, or the refusal's code and
/// sentence (`phone.phone_not_linked`, …).
pub(super) fn answered(answer: Value) -> Result<Value, (String, String)> {
    if answer.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(answer.get("value").cloned().unwrap_or(Value::Null));
    }
    let code = answer.get("error").and_then(Value::as_str).unwrap_or("bad_reply");
    let message = answer.get("message").and_then(Value::as_str).unwrap_or_default();
    // An older link host does not know the op.
    if code == "bad_request" && message.starts_with("op is ") {
        return Err((
            "phone.unsupported_host".to_owned(),
            "this Mac's link host has no phone-page service (phone-page-v1)".to_owned(),
        ));
    }
    Err((format!("phone.{code}"), message.to_owned()))
}

#[cfg(test)]
#[path = "phone_tests.rs"]
mod tests;
