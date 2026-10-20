//! The classic CLI's discovery verbs, which this app answers too.

/// The classic CLI's top-level discovery verbs: `cmux identify`, `cmux ping`
/// and `cmux capabilities`, with the classic `--id-format <refs|uuids|both>`
/// before or after the verb (ignored: these answers carry no refs). Skills,
/// prompts and agent habits written for both apps still run them (cx-4w47
/// D1); they are this app's `app identify|ping|capabilities`, the same
/// `system.*` methods the classic CLI sends.
pub(super) fn classic_system_method(args: &[String]) -> Option<&'static str> {
    let words = args.iter().map(String::as_str).collect::<Vec<_>>();
    let verb = match words.as_slice() {
        [verb] => *verb,
        ["--id-format", format, verb] | [verb, "--id-format", format]
            if matches!(*format, "refs" | "uuids" | "both") =>
        {
            *verb
        }
        _ => return None,
    };
    match verb {
        "identify" => Some("system.identify"),
        "ping" => Some("system.ping"),
        "capabilities" => Some("system.capabilities"),
        _ => None,
    }
}
