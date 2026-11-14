//! `cmux apps place <app>#<section>` places a sidebar contribution through
//! the daemon, including on a headless host. It uses the common private
//! command transport for socket ownership checks and response reporting.

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::raw::RawCommandPlan;

fn usage() -> &'static str {
    crate::localization::catalog().app_control.apps_place_usage
}

fn parse(args: &[String]) -> Result<Value, &'static str> {
    let (contribution, options) = args.split_first().ok_or_else(usage)?;
    let (app, section) = contribution.split_once('#').ok_or_else(usage)?;
    let (publisher, name) = app.split_once('/').ok_or_else(usage)?;
    if publisher.is_empty()
        || name.is_empty()
        || name.contains('/')
        || section.is_empty()
        || section.contains('#')
        || contribution.starts_with('-')
        || contribution.chars().any(char::is_whitespace)
    {
        return Err(usage());
    }
    let mut request =
        json!({"id": "apps-place-1", "cmd": "apps-place", "contribution": contribution});
    match options {
        [] => {}
        [flag, region]
            if flag == "--region" && matches!(region.as_str(), "top" | "middle" | "bottom") =>
        {
            request.set("region", json!(region));
        }
        _ => return Err(usage()),
    }
    Ok(request)
}

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let rest = words.strip_prefix(&["apps".to_string(), "place".to_string()][..])?;
    if matches!(rest, [flag] if matches!(flag.as_str(), "-h" | "--help" | "help")) {
        println!("{}", usage());
        return Some(0);
    }
    let request = match parse(rest) {
        Ok(request) => request,
        Err(usage) => {
            eprintln!("{usage}");
            return Some(2);
        }
    };
    Some(super::raw::run(global, RawCommandPlan { request, stream: false }))
}

#[cfg(test)]
mod tests;
