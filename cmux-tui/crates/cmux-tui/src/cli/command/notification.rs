//! The `notification` noun and the `notify` command: notification list,
//! create and clear, and an agent hook's notify that targets the caller's terminal.

use super::*;

/// `--terminal <term_id>` or `--workspace <ws_id>` of `notification create|clear`.
fn notification_scope(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
) -> Result<(), UsageError> {
    let terminal = flags.take("terminal");
    let workspace = flags.take("workspace");
    if terminal.is_some() && workspace.is_some() {
        return Err(UsageError::new("give --terminal or --workspace, not both"));
    }
    if let Some(terminal) = terminal {
        validate_prefixed_id("terminal", "term", &terminal)?;
        params.insert("terminal_id".into(), Value::String(terminal));
    }
    if let Some(workspace) = workspace {
        validate_prefixed_id("workspace", "ws", &workspace)?;
        params.insert("workspace_id".into(), Value::String(workspace));
    }
    Ok(())
}

pub(super) fn parse_notification(
    words: &[String],
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let selectors = Selectors::default();
    match strs(words).as_slice() {
        ["list"] => {
            let mut params = Map::new();
            if let Some(limit) = flags.take("limit") {
                insert_bounded_u32(&mut params, "limit", "--limit", limit, 1, 256)?;
            }
            request(ResourceOperation::NotificationList, &selectors, flags, params)
        }
        ["create"] => {
            let mut params = Map::new();
            let title = flags.required("title")?;
            if title.is_empty() {
                return Err(UsageError::new("--title cannot be empty"));
            }
            params.insert("title".into(), Value::String(title));
            if let Some(subtitle) = flags.take("subtitle") {
                params.insert("subtitle".into(), Value::String(subtitle));
            }
            params.insert("body".into(), Value::String(flags.required("body")?));
            if let Some(level) = flags.take("level") {
                validate_one_of("--level", &level, &["info", "warning", "error"])?;
                params.insert("level".into(), Value::String(level));
            }
            notification_scope(&mut params, flags)?;
            request(ResourceOperation::NotificationCreate, &selectors, flags, params)
        }
        ["clear"] => {
            let mut params = Map::new();
            // One row by its id (the notifications panel's Clear on a row);
            // the daemon takes one of notification, terminal or workspace.
            if let Some(notification) = flags.take("notification") {
                if flags.values.contains_key("terminal") || flags.values.contains_key("workspace") {
                    return Err(UsageError::new(
                        "give one of --notification, --terminal or --workspace",
                    ));
                }
                validate_prefixed_id("notification", "notification", &notification)?;
                params.insert("notification_id".into(), Value::String(notification));
            }
            notification_scope(&mut params, flags)?;
            request(ResourceOperation::NotificationClear, &selectors, flags, params)
        }
        ["ack", ids @ ..] => {
            let mut params = Map::new();
            let client_id = flags.required("client")?;
            if client_id.is_empty()
                || client_id.len() > 128
                || !client_id.bytes().all(|byte| byte.is_ascii_graphic())
            {
                return Err(UsageError::new(
                    "--client must be 1 to 128 printable ASCII bytes without spaces",
                ));
            }
            params.insert("client_id".into(), Value::String(client_id));
            if ids.is_empty() {
                return Err(UsageError::new("notification ack needs at least one notification ID"));
            }
            if ids.len() > 256 {
                return Err(UsageError::new(
                    "notification ack accepts at most 256 notification IDs",
                ));
            }
            for id in ids {
                validate_prefixed_id("notification", "notification", id)?;
            }
            params.insert(
                "notifications".into(),
                Value::Array(ids.iter().map(|id| Value::String((*id).to_string())).collect()),
            );
            request(ResourceOperation::NotificationAck, &selectors, flags, params)
        }
        _ => usage("notification action"),
    }
}

/// `cmux notify`, with the flags of the macOS `cmux notify`, so a script or an
/// agent hook written for a local terminal works unchanged inside a machine.
/// The target is the caller's own terminal (`CMUX_TUI_TERMINAL_ID`, injected
/// into every daemon PTY) unless `--surface` names another terminal of this
/// session or `--workspace` names a workspace (`current`: a session-level
/// row); a machine cannot
/// address anything outside its own session. `--reply` asks the app for a
/// banner that takes a typed reply for the target terminal (only it).
/// `--window` and `--id-format` are accepted for signature
/// parity. `--desktop false` asks the app for no banner; like the local flag
/// it is not validated with `--clear`.
pub(super) fn parse_notify(words: &[String], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    if !words.is_empty() {
        return usage("notify takes flags only");
    }
    let selectors = Selectors::default();
    let reply = flags.boolean("reply");
    let _ = flags.take("window");
    let _ = flags.take("id-format");
    let desktop = flags.take("desktop");
    let workspace = flags.take("workspace");
    if let Some(workspace) = &workspace
        && workspace != "current"
    {
        validate_prefixed_id("workspace", "ws", workspace)?;
    }
    let caller_terminal = std::env::var("CMUX_TUI_TERMINAL_ID").ok().filter(|id| !id.is_empty());
    let surface = match flags.take_dashed("--surface") {
        Some(value) if value == "current" => match caller_terminal {
            Some(terminal) => Some(terminal),
            None => {
                return Err(UsageError::new(
                    "--surface current needs a caller terminal (CMUX_TUI_TERMINAL_ID is not set); pass --surface <term_id>",
                ));
            }
        },
        Some(value) => Some(value),
        // A workspace-scoped notify has no terminal, like the local form.
        None if workspace.is_some() => None,
        None => caller_terminal,
    };
    if let Some(surface) = &surface {
        validate_prefixed_id("terminal", "term", surface)?;
    }
    // `--workspace ws_…` scopes the row (and a clear) to that workspace;
    // `current` keeps its session-level meaning.
    let workspace_id = workspace.as_ref().filter(|workspace| *workspace != "current").cloned();
    if workspace_id.is_some() && surface.is_some() {
        return Err(UsageError::new(
            "--workspace <ws_id> and --surface are one scope or the other: a terminal's notification already belongs to its workspace",
        ));
    }
    let mut params = Map::new();
    if let Some(workspace_id) = workspace_id {
        params.insert("workspace_id".into(), Value::String(workspace_id));
    }
    if flags.boolean("clear") {
        if flags.take("title").is_some()
            || flags.take("subtitle").is_some()
            || flags.take("body").is_some()
        {
            return Err(UsageError::new("--clear does not take --title, --subtitle, or --body"));
        }
        // A clear must name its scope. Outside a daemon terminal there is no
        // caller terminal to default to, and silently clearing the whole
        // session would be the wrong surprise.
        if surface.is_none() && workspace.is_none() {
            return Err(UsageError::new(
                "--clear needs a scope: run it from a machine terminal, or pass --surface <term_id> or --workspace current",
            ));
        }
        if let Some(surface) = surface {
            params.insert("terminal_id".into(), Value::String(surface));
        }
        return request(ResourceOperation::NotificationClear, &selectors, flags, params);
    }
    // Like the local flag, `--desktop` has no effect with `--clear` and is validated only here.
    if let Some(desktop) = desktop
        && !parse_bool("--desktop", &desktop)
            .map_err(|_| UsageError::new("--desktop must be true|false"))?
    {
        params.insert("desktop".into(), Value::Bool(false));
    }
    if reply {
        params.insert("reply".into(), Value::Bool(true));
    }
    let title = flags.take("title").unwrap_or_else(|| "Notification".into());
    if title.is_empty() {
        return Err(UsageError::new("--title cannot be empty"));
    }
    if title.chars().count() > 512 {
        return Err(UsageError::new("--title is limited to 512 characters"));
    }
    params.insert("title".into(), Value::String(title));
    if let Some(subtitle) = flags.take("subtitle") {
        if subtitle.chars().count() > 512 {
            return Err(UsageError::new("--subtitle is limited to 512 characters"));
        }
        params.insert("subtitle".into(), Value::String(subtitle));
    }
    let body = flags.take("body").unwrap_or_default();
    if body.chars().count() > 4096 {
        return Err(UsageError::new("--body is limited to 4096 characters"));
    }
    params.insert("body".into(), Value::String(body));
    if let Some(surface) = surface {
        params.insert("terminal_id".into(), Value::String(surface));
    }
    request(ResourceOperation::NotificationCreate, &selectors, flags, params)
}
