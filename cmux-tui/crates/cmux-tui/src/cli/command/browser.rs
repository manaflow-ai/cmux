use serde_json::{Map, Value};

use cmux_tui_core::resource::ResourceOperation;

use super::{
    CommandPlan, Flags, Selectors, UsageError, add_optional_parent_selectors, add_pixel_size,
    add_stream_id, insert_float, insert_optional_enum_list, insert_optional_string, insert_u32,
    map_with, request, strs, usage, validate_decimal, validate_one_of,
};

pub(super) fn parse_browser(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    match strs(words).as_slice() {
        ["list"] => request(ResourceOperation::BrowserList, selectors, flags, Map::new()),
        // browser-devices-v1: Chrome's device toolbar list and custom devices.
        ["devices", "list"] => {
            request(ResourceOperation::BrowserDevicesList, selectors, flags, Map::new())
        }
        ["devices", "add"] => {
            let device = super::parse_json_flag(flags, "device-json")?;
            request(
                ResourceOperation::BrowserDevicesAddCustom,
                selectors,
                flags,
                map_with("device", device),
            )
        }
        ["devices", "remove"] => {
            let title = flags.required("title")?;
            request(
                ResourceOperation::BrowserDevicesRemoveCustom,
                selectors,
                flags,
                map_with("title", Value::String(title)),
            )
        }
        // browser.profile.* (cx-2kl68): the records, never their stores.
        ["profile", "list"] => {
            request(ResourceOperation::BrowserProfileList, selectors, flags, Map::new())
        }
        ["profile", "create"] => {
            let mut params = map_with("name", Value::String(flags.required("name")?));
            insert_optional_string(&mut params, flags, "color", "color");
            insert_optional_string(&mut params, flags, "icon", "icon");
            if let Some(index) = flags.take("index") {
                insert_u32(&mut params, "index", "--index", index)?;
            }
            request(ResourceOperation::BrowserProfileCreate, selectors, flags, params)
        }
        ["profile", "open", ..] => parse_browser_profile_open(words, selectors, flags),
        ["profile", action] => parse_browser_profile(action, flags),
        // browser-profile-agent-v1: move a tab to another browser profile in
        // place (the app re-makes the page in that profile's store).
        ["tab", selector, "set-profile"] => {
            selectors.insert("tab", "tab", selector)?;
            let params = map_with("profile", Value::String(flags.required("profile")?));
            request(ResourceOperation::BrowserTabSetProfile, selectors, flags, params)
        }
        ["open"] | ["open", _] => parse_browser_open(words, selectors, flags),
        [selector, "show"] => {
            selectors.insert("browser", "browser", selector)?;
            request(ResourceOperation::BrowserGet, selectors, flags, Map::new())
        }
        [selector, "navigate"] => {
            selectors.insert("browser", "browser", selector)?;
            let url = flags.required("url")?;
            if url.is_empty() {
                return Err(UsageError::new("--url cannot be empty"));
            }
            request(
                ResourceOperation::BrowserNavigate,
                selectors,
                flags,
                map_with("url", Value::String(url)),
            )
        }
        [selector, "back"] => {
            browser_no_args(ResourceOperation::BrowserBack, selector, selectors, flags)
        }
        [selector, "forward"] => {
            browser_no_args(ResourceOperation::BrowserForward, selector, selectors, flags)
        }
        [selector, "reload"] => {
            browser_no_args(ResourceOperation::BrowserReload, selector, selectors, flags)
        }
        [selector, "activate"] => {
            browser_no_args(ResourceOperation::BrowserActivate, selector, selectors, flags)
        }
        [selector, "key"] => {
            selectors.insert("browser", "browser", selector)?;
            let mut params = Map::new();
            let key = flags.required("key")?;
            if key.is_empty() {
                return Err(UsageError::new("--key cannot be empty"));
            }
            params.insert("key".into(), Value::String(key));
            if let Some(kind) = flags.take("kind") {
                validate_one_of("--kind", &kind, &["down", "up", "press"])?;
                params.insert("kind".into(), Value::String(kind));
            }
            insert_optional_enum_list(
                &mut params,
                flags,
                "modifiers",
                &["shift", "control", "alt", "meta"],
            )?;
            request(ResourceOperation::BrowserInputKey, selectors, flags, params)
        }
        [selector, "text"] => {
            selectors.insert("browser", "browser", selector)?;
            let text = flags.required("text")?;
            request(
                ResourceOperation::BrowserInputText,
                selectors,
                flags,
                map_with("text", Value::String(text)),
            )
        }
        [selector, "mouse"] => {
            selectors.insert("browser", "browser", selector)?;
            let mut params = Map::new();
            let kind = flags.required("kind")?;
            validate_one_of("--kind", &kind, &["down", "up", "move"])?;
            params.insert("kind".into(), Value::String(kind.clone()));
            insert_float(&mut params, "x_px", "--x-px", flags.required("x-px")?)?;
            insert_float(&mut params, "y_px", "--y-px", flags.required("y-px")?)?;
            let pointer_frame_seq = flags.required("pointer-frame-seq")?;
            validate_decimal("--pointer-frame-seq", &pointer_frame_seq)?;
            params.insert("pointer_frame_seq".into(), Value::String(pointer_frame_seq));
            match (kind.as_str(), flags.take("button"), flags.take("click-count")) {
                ("down" | "up", Some(button), click_count) => {
                    validate_one_of(
                        "--button",
                        &button,
                        &["left", "middle", "right", "back", "forward"],
                    )?;
                    params.insert("button".into(), Value::String(button));
                    if let Some(click_count) = click_count {
                        insert_u32(&mut params, "click_count", "--click-count", click_count)?;
                    }
                }
                ("down" | "up", None, _) => {
                    return Err(UsageError::new("--button is required for down and up"));
                }
                ("move", None, None) => {}
                ("move", Some(_), _) => {
                    return Err(UsageError::new("--button is forbidden for move"));
                }
                ("move", None, Some(_)) => {
                    return Err(UsageError::new("--click-count is forbidden for move"));
                }
                _ => unreachable!("kind validated above"),
            }
            request(ResourceOperation::BrowserInputMouse, selectors, flags, params)
        }
        [selector, "wheel"] => {
            selectors.insert("browser", "browser", selector)?;
            let mut params = Map::new();
            insert_float(&mut params, "delta_x", "--delta-x", flags.required("delta-x")?)?;
            insert_float(&mut params, "delta_y", "--delta-y", flags.required("delta-y")?)?;
            insert_float(&mut params, "x_px", "--x-px", flags.required("x-px")?)?;
            insert_float(&mut params, "y_px", "--y-px", flags.required("y-px")?)?;
            let pointer_frame_seq = flags.required("pointer-frame-seq")?;
            validate_decimal("--pointer-frame-seq", &pointer_frame_seq)?;
            params.insert("pointer_frame_seq".into(), Value::String(pointer_frame_seq));
            request(ResourceOperation::BrowserInputWheel, selectors, flags, params)
        }
        [selector, "attach"] => {
            selectors.insert("browser", "browser", selector)?;
            let mut params = Map::new();
            add_stream_id(&mut params, flags)?;
            add_pixel_size(&mut params, flags)?;
            request(ResourceOperation::BrowserAttach, selectors, flags, params)
        }
        [selector, "close"] => {
            selectors.insert("browser", "browser", selector)?;
            request(ResourceOperation::BrowserClose, selectors, flags, Map::new())
        }
        _ => usage("browser action"),
    }
}

fn private_browser_command(command: &str, mut params: Map<String, Value>) -> CommandPlan {
    params.insert("id".into(), Value::from(1));
    params.insert("cmd".into(), Value::String(command.to_owned()));
    CommandPlan::RawCommand(super::super::raw::RawCommandPlan {
        request: Value::Object(params),
        stream: false,
    })
}

fn parse_browser_profile(action: &str, flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    match action {
        "move" => {
            let mut params = Map::new();
            params.insert("browser_profile".into(), Value::String(flags.required("profile")?));
            insert_u32(&mut params, "index", "--index", flags.required("index")?)?;
            Ok(private_browser_command("move-browser-profile", params))
        }
        // Only a person deletes a browser profile, in the app (the daemon refuses every other caller).
        "delete" => Err(UsageError::new(
            "browser profile delete: only a person deletes a browser profile, in the cmux app (Settings, the palette or the menu)",
        )),
        _ => usage("browser profile action"),
    }
}

fn parse_browser_profile_open(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    if words.len() > 3 {
        return Err(UsageError::new("browser profile open accepts one positional URL"));
    }
    let positional_url = words.get(2).cloned();
    let flagged_url = flags.take("url");
    let url = match (positional_url, flagged_url) {
        (Some(_), Some(_)) => {
            return Err(UsageError::new(
                "browser profile open accepts either a URL or --url, not both",
            ));
        }
        (Some(url), None) | (None, Some(url)) if !url.is_empty() => url,
        _ => return Err(UsageError::new("browser profile open needs a URL or --url")),
    };
    let mut params = map_with("url", Value::String(url));
    params.insert("profile".into(), Value::String(flags.required("profile")?));
    insert_engine(&mut params, flags)?;
    insert_optional_string(&mut params, flags, "title", "title");
    if let Some(background) = flags.take("background") {
        validate_one_of("--background", &background, &["true", "false"])?;
        if background == "true" {
            params.insert("activate".into(), Value::Bool(false));
        }
    }
    add_optional_parent_selectors(selectors, flags, &["workspace", "screen", "pane"])?;
    request(ResourceOperation::BrowserProfileOpen, selectors, flags, params)
}

fn parse_browser_open(
    words: &[String],
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let positional_url = words.get(1).cloned();
    let flagged_url = flags.take("url");
    let url = match (positional_url, flagged_url) {
        (Some(_), Some(_)) => {
            return Err(UsageError::new("browser open accepts either a URL or --url, not both"));
        }
        (Some(url), None) => url,
        (None, Some(url)) => url,
        (None, None) => {
            return Err(UsageError::new("browser open needs a URL or --url"));
        }
    };
    if url.is_empty() {
        return Err(UsageError::new("browser open URL cannot be empty"));
    }

    let mut params = Map::new();
    params.insert("url".into(), Value::String(url));
    insert_optional_string(&mut params, flags, "name", "name");
    insert_engine(&mut params, flags)?;
    add_optional_parent_selectors(selectors, flags, &["workspace", "screen", "pane"])?;
    add_pixel_size(&mut params, flags)?;
    request(ResourceOperation::TabCreateBrowser, selectors, flags, params)
}

/// `--engine chromium|webkit` (also `chrome`, `cef`, `safari`) as the
/// wire's `engine` field (`cef` or `webkit`). Absent leaves the field out:
/// the person's `browser.defaultEngine` (Chromium unless set to WebKit)
/// decides, in the app and in the daemon.
pub(super) fn insert_engine(
    params: &mut Map<String, Value>,
    flags: &mut Flags,
) -> Result<(), UsageError> {
    let Some(engine) = flags.take("engine") else { return Ok(()) };
    let tag = match engine.to_ascii_lowercase().as_str() {
        "chromium" | "chrome" | "cef" => "cef",
        "webkit" | "safari" => "webkit",
        _ => return Err(UsageError::new("--engine must be chromium or webkit")),
    };
    params.insert("engine".into(), Value::String(tag.into()));
    Ok(())
}

fn browser_no_args(
    operation: ResourceOperation,
    selector: &str,
    selectors: &mut Selectors,
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    selectors.insert("browser", "browser", selector)?;
    request(operation, selectors, flags, Map::new())
}
