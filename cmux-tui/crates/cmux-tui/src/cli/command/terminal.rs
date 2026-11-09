//! The `terminal` noun: list, show and status, input, screen reads and waits,
//! resize, run, and the other per-terminal verbs.

use super::*;

pub(super) fn parse_terminal(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["list"] => {
            add_optional_parent_selectors(
                selectors,
                flags,
                &["workspace", "screen", "pane", "tab"],
            )?;
            let filter = list_filter::take(flags, false, true)?;
            request(ResourceOperation::TerminalList, selectors, flags, Map::new())
                .map(|plan| plan.filtered(filter))
        }
        [selector, verb @ ("show" | "status")] => {
            selectors.insert("terminal", "term", selector)?;
            let plan = request(ResourceOperation::TerminalGet, selectors, flags, Map::new());
            if *verb == "show" { plan } else { plan.map(CommandPlan::terminal_program_status) }
        }
        [selector, "write"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            match (flags.take("text"), flags.take("bytes-base64")) {
                (Some(text), None) => {
                    params.insert("text".into(), Value::String(text));
                }
                (None, Some(bytes)) => {
                    validate_base64("--bytes-base64", &bytes)?;
                    params.insert("bytes_base64".into(), Value::String(bytes));
                }
                (None, None) => {
                    let mut text = String::new();
                    io::stdin()
                        .read_to_string(&mut text)
                        .map_err(|error| UsageError::new(format!("cannot read stdin: {error}")))?;
                    params.insert("text".into(), Value::String(text));
                }
                (Some(_), Some(_)) => {
                    return Err(UsageError::new(
                        "--text and --bytes-base64 are mutually exclusive",
                    ));
                }
            }
            request(ResourceOperation::TerminalInputWrite, selectors, flags, params)
        }
        [selector, "keys", keys @ ..] if !keys.is_empty() => {
            selectors.insert("terminal", "term", selector)?;
            if keys.iter().any(|key| key.is_empty()) {
                return Err(UsageError::new("terminal key names cannot be empty"));
            }
            request(
                ResourceOperation::TerminalInputKeys,
                selectors,
                flags,
                map_with("keys", json!(keys)),
            )
        }
        [selector, "mouse", kind] => {
            selectors.insert("terminal", "term", selector)?;
            validate_one_of("--kind", kind, &["down", "up", "move", "wheel"])?;
            let mut params = Map::new();
            params.insert("kind".into(), Value::String((*kind).into()));
            insert_u16(&mut params, "row", "--row", flags.required("row")?)?;
            insert_u16(&mut params, "column", "--column", flags.required("column")?)?;
            let button = flags.take("button");
            let delta_rows = flags.take("delta-rows");
            match (*kind, button, delta_rows) {
                ("down" | "up", Some(button), None) => {
                    validate_one_of("--button", &button, &["left", "middle", "right"])?;
                    params.insert("button".into(), Value::String(button));
                }
                ("move", None, None) => {}
                ("wheel", None, Some(delta_rows)) => {
                    let delta_rows = delta_rows.parse::<i32>().map_err(|_| {
                        UsageError::new("--delta-rows must be a signed 32-bit integer")
                    })?;
                    if delta_rows == 0 {
                        return Err(UsageError::new("--delta-rows must be nonzero for wheel"));
                    }
                    params.insert("delta_rows".into(), json!(delta_rows));
                }
                ("down" | "up", None, _) => {
                    return Err(UsageError::new("--button is required for down and up"));
                }
                ("down" | "up", Some(_), Some(_)) => {
                    return Err(UsageError::new("--delta-rows is forbidden for down and up"));
                }
                ("move", Some(_), _) => {
                    return Err(UsageError::new("--button is forbidden for move"));
                }
                ("move", None, Some(_)) => {
                    return Err(UsageError::new("--delta-rows is forbidden for move"));
                }
                ("wheel", Some(_), _) => {
                    return Err(UsageError::new("--button is forbidden for wheel"));
                }
                ("wheel", None, None) => {
                    return Err(UsageError::new("--delta-rows is required for wheel"));
                }
                _ => unreachable!("kind validated above"),
            }
            insert_optional_enum_list(
                &mut params,
                flags,
                "modifiers",
                &["shift", "control", "alt", "meta"],
            )?;
            request(ResourceOperation::TerminalInputMouse, selectors, flags, params)
        }
        [selector, "focus", state] => {
            selectors.insert("terminal", "term", selector)?;
            if !matches!(*state, "in" | "out") {
                return Err(UsageError::new("terminal focus must be in or out"));
            }
            request(
                ResourceOperation::TerminalInputFocus,
                selectors,
                flags,
                map_with("focused", Value::Bool(*state == "in")),
            )
        }
        [selector, "read"] | [selector, "screen", "read"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            // `terminal-read-unwrap-v1`: soft wraps joined, and the last N
            // lines of scrollback and screen.
            if flags.boolean("unwrap") {
                params.insert("unwrap".into(), Value::Bool(true));
            }
            if let Some(lines) = flags.take("lines") {
                insert_bounded_u32(&mut params, "lines", "--lines", lines, 1, 10_000)?;
            }
            // Plain screen text unless --details asks for the record's fields (W3-H).
            let details = flags.boolean("details");
            request(ResourceOperation::TerminalScreenRead, selectors, flags, params)
                .map(|plan| if details { plan } else { plan.screen_text() })
        }
        [selector, "state", "read"] => {
            selectors.insert("terminal", "term", selector)?;
            request(ResourceOperation::TerminalStateRead, selectors, flags, Map::new())
        }
        [selector, "history", "read"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            if let Some(before) = flags.take("before") {
                validate_decimal("--before", &before)?;
                params.insert("before".into(), Value::String(before));
            }
            if let Some(limit) = flags.take("limit") {
                insert_bounded_u32(&mut params, "limit", "--limit", limit, 1, 10_000)?;
            }
            if flags.boolean("styled") {
                params.insert("styled".into(), Value::Bool(true));
            }
            request(ResourceOperation::TerminalHistoryRead, selectors, flags, params)
        }
        [selector, "history", "clear"] => {
            selectors.insert("terminal", "term", selector)?;
            request(ResourceOperation::TerminalHistoryClear, selectors, flags, Map::new())
        }
        [selector, "output", "read"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            if let Some(after) = flags.take("after") {
                validate_decimal("--after", &after)?;
                params.insert("after".into(), Value::String(after));
            }
            if let Some(max_bytes) = flags.take("max-bytes") {
                insert_bounded_u32(
                    &mut params,
                    "max_bytes",
                    "--max-bytes",
                    max_bytes,
                    1,
                    4_194_304,
                )?;
            }
            request(ResourceOperation::TerminalOutputRead, selectors, flags, params)
        }
        [selector, "screen", "wait"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            let pattern = flags.required("pattern")?;
            if pattern.is_empty() {
                return Err(UsageError::new("--pattern cannot be empty"));
            }
            params.insert("pattern".into(), Value::String(pattern));
            if let Some(timeout) = flags.take("timeout-ms") {
                insert_decimal(&mut params, "timeout_ms", "--timeout-ms", timeout)?;
            }
            // `terminal-wait-new-v1`: only output printed below the cursor's
            // line from now on can match, never a typed command's echo.
            if flags.boolean("new") {
                params.insert("new".into(), Value::Bool(true));
            }
            request(ResourceOperation::TerminalWait, selectors, flags, params)
        }
        [selector, "copy"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            if let Some(mode) = flags.take("mode") {
                validate_one_of("--mode", &mode, &["screen", "selection", "scrollback"])?;
                params.insert("mode".into(), Value::String(mode));
            }
            if flags.boolean("unwrap") {
                params.insert("unwrap".into(), Value::Bool(true));
            }
            request(ResourceOperation::TerminalCopy, selectors, flags, params)
        }
        [selector, "process", "show"] => {
            selectors.insert("terminal", "term", selector)?;
            request(ResourceOperation::TerminalProcessGet, selectors, flags, Map::new())
        }
        [selector, "process", "wait"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            if let Some(timeout) = flags.take("timeout-ms") {
                insert_decimal(&mut params, "timeout_ms", "--timeout-ms", timeout)?;
            }
            request(ResourceOperation::TerminalWaitExit, selectors, flags, params)
        }
        [selector, "viewport", "scroll"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            insert_i32(&mut params, "delta_rows", "--delta-rows", flags.required("delta-rows")?)?;
            request(ResourceOperation::TerminalViewportScroll, selectors, flags, params)
        }
        [selector, "move"] => {
            selectors.insert("terminal", "term", selector)?;
            let params = destination_params(flags)?;
            request(ResourceOperation::TerminalMove, selectors, flags, params)
        }
        [selector, "project"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = destination_params(flags)?;
            if let Some(name) = flags.take("name") {
                params.insert("name".into(), Value::String(name));
            }
            request(ResourceOperation::TerminalProject, selectors, flags, params)
        }
        [selector, "attach"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            add_stream_id(&mut params, flags)?;
            add_size(&mut params, flags)?;
            if flags.boolean("read-only") {
                params.insert("read_only".into(), Value::Bool(true));
            }
            request(ResourceOperation::TerminalAttach, selectors, flags, params)
        }
        [selector, "close"] => {
            selectors.insert("terminal", "term", selector)?;
            let mut params = Map::new();
            // Ends it only when nothing shows it (no tab, no keep mark, no attach stream).
            if flags.boolean("if-unplaced") {
                params.insert("if_unplaced".into(), Value::Bool(true));
            }
            request(ResourceOperation::TerminalClose, selectors, flags, params)
        }
        [selector, "keep", state] => {
            // `set-terminal-keep` resolves only exact terminal identities, so
            // the relative selectors other terminal verbs accept are refused.
            if !matches!(Selector::parse(selector), Ok(Selector::Id(_))) {
                return Err(UsageError::new("terminal keep needs a term_ terminal ID"));
            }
            validate_prefixed_id("terminal", "term", selector)?;
            let keep = match *state {
                "on" => true,
                "off" => false,
                _ => return Err(UsageError::new("terminal keep must be on or off")),
            };
            Ok(CommandPlan::RawCommand(super::super::raw::RawCommandPlan {
                request: json!({
                    "id": 1,
                    "cmd": "set-terminal-keep",
                    "terminal_id": selector,
                    "keep": keep,
                }),
                stream: false,
            }))
        }
        _ => usage("terminal action"),
    }
}
