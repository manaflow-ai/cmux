//! MCP Apps (`io.modelcontextprotocol/ui`, ext-apps specification
//! 2026-01-26): a tool's `_meta.ui`, a `ui://` resource's contents, the CSP
//! for its frame, and the classification of every JSON-RPC message the view
//! sends (design, "MCP Apps bridge").

use crate::{Refusal, caps, text};
use serde_json::Value;

pub const EXTENSION_ID: &str = "io.modelcontextprotocol/ui";
pub const HTML_MIME: &str = "text/html;profile=mcp-app";

/// What the host advertises in `initialize.capabilities.extensions`.
pub fn client_extension() -> Value {
    serde_json::json!({ EXTENSION_ID: { "mimeTypes": [HTML_MIME, crate::a2ui::MIME] } })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolUi {
    pub resource_uri: String,
    /// `model`, `app`; both when the server omits it.
    pub visibility: Vec<String>,
}

impl ToolUi {
    pub fn app_visible(&self) -> bool {
        self.visibility.iter().any(|v| v == "app")
    }
}

/// A tool definition's `_meta.ui` (or the deprecated flat
/// `_meta["ui/resourceUri"]`). Only `ui://` and `a2ui://` URIs count.
pub fn tool_ui(tool: &Value) -> Option<ToolUi> {
    let meta = tool.get("_meta")?;
    let ui = meta.get("ui");
    let uri = ui
        .and_then(|u| u.get("resourceUri"))
        .or_else(|| meta.get("ui/resourceUri"))
        .and_then(Value::as_str)?;
    if !(uri.starts_with("ui://") || uri.starts_with("a2ui://")) || uri.len() > 2048 {
        return None;
    }
    let visibility = ui
        .and_then(|u| u.get("visibility"))
        .and_then(Value::as_array)
        .map(|v| v.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_else(|| vec!["model".to_string(), "app".to_string()]);
    Some(ToolUi { resource_uri: uri.to_string(), visibility })
}

/// One entry of the server's `tools/list`, as the bridge needs it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolInfo {
    pub name: String,
    pub ui: Option<ToolUi>,
}

pub fn tools_from_list(result: &Value) -> Vec<ToolInfo> {
    result
        .get("tools")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|t| {
            Some(ToolInfo { name: t.get("name")?.as_str()?.to_string(), ui: tool_ui(t) })
        })
        .collect()
}

/// What a `resources/read` result holds.
#[derive(Clone, Debug, PartialEq)]
pub enum ResourceView {
    Html {
        html: String,
        csp: String,
    },
    /// A2UI messages (a JSON array, a single message or JSONL text).
    A2ui(Value),
}

/// Read the first content of a `resources/read` result. Content `_meta.ui`
/// wins over the listing's (`listing_meta`).
pub fn resource_view(
    result: &Value,
    listing_meta: Option<&Value>,
) -> Result<ResourceView, Refusal> {
    let content = result
        .get("contents")
        .and_then(Value::as_array)
        .and_then(|c| c.first())
        .ok_or_else(|| Refusal::new("the resource has no contents"))?;
    let mime = content.get("mimeType").and_then(Value::as_str).unwrap_or("");
    let body = match (
        content.get("text").and_then(Value::as_str),
        content.get("blob").and_then(Value::as_str),
    ) {
        (Some(t), _) => t.to_string(),
        (None, Some(b)) => {
            decode_base64(b).ok_or_else(|| Refusal::new("the resource blob is not base64 UTF-8"))?
        }
        _ => return Err(Refusal::new("the resource has neither text nor blob")),
    };
    if body.len() > caps::SURFACE_BYTES * 4 {
        return Err(Refusal::new("the resource is over 1 MB"));
    }
    let mime_base = mime.split(';').next().unwrap_or("").trim();
    if mime == HTML_MIME || (mime_base == "text/html" && mime.contains("profile=mcp-app")) {
        let meta = content.get("_meta").and_then(|m| m.get("ui")).or(listing_meta);
        return Ok(ResourceView::Html { html: body, csp: csp(meta.and_then(|m| m.get("csp"))) });
    }
    if mime_base == crate::a2ui::MIME {
        let v = serde_json::from_str::<Value>(&body).unwrap_or(Value::String(body));
        return Ok(ResourceView::A2ui(v));
    }
    Err(Refusal::new(format!("unsupported resource type {:?}", text::clean(mime))))
}

/// A2UI content embedded in a tool result (`content[]` entries of type
/// `resource` with mimeType `application/a2ui+json`).
pub fn a2ui_in_tool_result(result: &Value) -> Option<Value> {
    let items = result.get("content").and_then(Value::as_array).or_else(|| result.as_array())?;
    for item in items {
        let res = item.get("resource").unwrap_or(item);
        if res.get("mimeType").and_then(Value::as_str) == Some(crate::a2ui::MIME) {
            let raw = res.get("text").and_then(Value::as_str)?;
            return Some(serde_json::from_str(raw).unwrap_or(Value::String(raw.to_string())));
        }
    }
    None
}

fn decode_base64(s: &str) -> Option<String> {
    fn val(c: u8) -> Option<u32> {
        Some(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => return None,
        } as u32)
    }
    let clean: Vec<u8> = s.bytes().filter(|b| !b.is_ascii_whitespace() && *b != b'=').collect();
    let mut out = Vec::with_capacity(clean.len() * 3 / 4);
    for chunk in clean.chunks(4) {
        let mut acc = 0u32;
        for (i, b) in chunk.iter().enumerate() {
            acc |= val(*b)? << (18 - 6 * i);
        }
        let n = match chunk.len() {
            4 => 3,
            3 => 2,
            2 => 1,
            _ => return None,
        };
        for i in 0..n {
            out.push((acc >> (16 - 8 * i)) as u8);
        }
    }
    String::from_utf8(out).ok()
}

/// One CSP source from a server: `https://host[:port][/path]` or `wss://...`,
/// optionally `*.`-prefixed host. Anything else (quotes, `;`, keywords,
/// `http:`, `*`) is dropped so a server cannot loosen the policy.
fn source_ok(s: &str) -> bool {
    let Some(rest) = s.strip_prefix("https://").or_else(|| s.strip_prefix("wss://")) else {
        return false;
    };
    let host = rest.split('/').next().unwrap_or("");
    let host = host.strip_prefix("*.").unwrap_or(host);
    !host.is_empty()
        && s.len() <= 256
        && host.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | ':'))
        && rest.chars().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | ':' | '/' | '*' | '_' | '~')
        })
}

fn sources(csp_meta: Option<&Value>, key: &str) -> Vec<String> {
    csp_meta
        .and_then(|m| m.get(key))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .filter(|s| source_ok(s))
        .take(32)
        .map(str::to_string)
        .collect()
}

/// The frame's CSP from `_meta.ui.csp` (`connectDomains`, `resourceDomains`,
/// `frameDomains`, `baseUriDomains`). Omitted, it is the spec default with
/// `connect-src 'none'`.
pub fn csp(csp_meta: Option<&Value>) -> String {
    let join = |base: &str, extra: &[String]| {
        if extra.is_empty() { base.to_string() } else { format!("{base} {}", extra.join(" ")) }
    };
    let res = sources(csp_meta, "resourceDomains");
    let connect = sources(csp_meta, "connectDomains");
    let frame = sources(csp_meta, "frameDomains");
    let base = sources(csp_meta, "baseUriDomains");
    let mut parts = vec![
        "default-src 'none'".to_string(),
        format!("script-src {}", join("'self' 'unsafe-inline'", &res)),
        format!("style-src {}", join("'self' 'unsafe-inline'", &res)),
        format!("img-src {}", join("'self' data:", &res)),
        format!("media-src {}", join("'self' data:", &res)),
    ];
    if !res.is_empty() {
        parts.push(format!("font-src {}", join("'self'", &res)));
    }
    parts.push(format!(
        "connect-src {}",
        if connect.is_empty() { "'none'".into() } else { connect.join(" ") }
    ));
    parts.push(format!(
        "frame-src {}",
        if frame.is_empty() { "'none'".into() } else { frame.join(" ") }
    ));
    parts.push(format!(
        "base-uri {}",
        if base.is_empty() { "'self'".into() } else { base.join(" ") }
    ));
    parts.push("object-src 'none'".to_string());
    parts.push("form-action 'none'".to_string());
    parts.join("; ")
}

/// What the view may know about its tools and lifecycle.
#[derive(Clone, Copy, Debug)]
pub struct ViewContext<'a> {
    pub tools: &'a [ToolInfo],
    pub initialized: bool,
}

/// Allowed with no confirmation: the daemon (or page) answers it.
#[derive(Clone, Debug, PartialEq)]
pub enum Allowed {
    Initialize,
    Initialized,
    SizeChanged {
        height: u32,
    },
    /// Read another `ui://` resource of the same server.
    ResourceRead {
        uri: String,
    },
    /// `ui/message`: fills the composer; the person presses Send.
    Draft {
        text: String,
    },
}

/// Needs the person's Confirm before anything is sent.
#[derive(Clone, Debug, PartialEq)]
pub enum Proposal {
    ToolCall { tool: String, arguments: Value },
    OpenLink { url: String },
}

/// Why `ui/update-model-context` is refused: the view's error message.
pub const MODEL_CONTEXT_REFUSED: &str = "cmux does not take model context from an app: the agent \
    reads only what the person sends. Use ui/message to draft a message for the person to send";

#[derive(Clone, Debug, PartialEq)]
pub enum ViewDecision {
    Allowed(Allowed),
    NeedsConfirm(Proposal),
    Refused(String),
}

/// A link that may be opened: `https` only, no credentials, no whitespace.
pub fn https_url(url: &str) -> Option<String> {
    let rest = url.strip_prefix("https://")?;
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    if host.is_empty()
        || host.contains('@')
        || url.len() > 2048
        || url.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return None;
    }
    Some(url.to_string())
}

/// Classify one JSON-RPC message from an MCP App view (design table).
pub fn classify_view_message(ctx: ViewContext<'_>, msg: &Value) -> ViewDecision {
    if msg.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
        return ViewDecision::Refused("not a JSON-RPC 2.0 message".into());
    }
    let Some(method) = msg.get("method").and_then(Value::as_str) else {
        return ViewDecision::Refused("a view message needs a method".into());
    };
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    let not_ready =
        || ViewDecision::Refused(format!("{method} before ui/notifications/initialized"));
    match method {
        "ui/initialize" => ViewDecision::Allowed(Allowed::Initialize),
        "ui/notifications/initialized" => ViewDecision::Allowed(Allowed::Initialized),
        "ui/notifications/size-changed" => {
            let h = params.get("height").and_then(Value::as_f64).unwrap_or(0.0);
            let height = (h.max(0.0) as u32).clamp(caps::FRAME_MIN_HEIGHT, caps::FRAME_MAX_HEIGHT);
            ViewDecision::Allowed(Allowed::SizeChanged { height })
        }
        "tools/call" => {
            if !ctx.initialized {
                return not_ready();
            }
            let Some(name) = params.get("name").and_then(Value::as_str) else {
                return ViewDecision::Refused("tools/call needs a tool name".into());
            };
            let visible = ctx
                .tools
                .iter()
                .any(|t| t.name == name && t.ui.as_ref().is_none_or(ToolUi::app_visible));
            if !visible {
                return ViewDecision::Refused(format!(
                    "tool {:?} is not visible to apps",
                    text::clean(name)
                ));
            }
            ViewDecision::NeedsConfirm(Proposal::ToolCall {
                tool: name.to_string(),
                arguments: params
                    .get("arguments")
                    .cloned()
                    .unwrap_or(Value::Object(Default::default())),
            })
        }
        "ui/message" => {
            if !ctx.initialized {
                return not_ready();
            }
            let content = params.get("content");
            let text = match content {
                Some(Value::Array(items)) => items
                    .iter()
                    .filter_map(|i| i.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n"),
                Some(c) => c.get("text").and_then(Value::as_str).unwrap_or("").to_string(),
                None => String::new(),
            };
            ViewDecision::Allowed(Allowed::Draft { text: text::clean(&text) })
        }
        "ui/open-link" => match params.get("url").and_then(Value::as_str).and_then(https_url) {
            Some(url) if ctx.initialized => ViewDecision::NeedsConfirm(Proposal::OpenLink { url }),
            Some(_) => not_ready(),
            None => ViewDecision::Refused("only https links open".into()),
        },
        // Refused, not held for a Confirm: ACP has no way to add context to an agent's next turn
        // without starting one, and a confirmed send that the agent never reads would tell the
        // person it was given. A view that wants the agent to know something asks with
        // `ui/message`, which drafts it into the composer for the person to send.
        "ui/update-model-context" => ViewDecision::Refused(MODEL_CONTEXT_REFUSED.into()),
        "resources/read" => match params.get("uri").and_then(Value::as_str) {
            Some(uri) if uri.starts_with("ui://") => {
                ViewDecision::Allowed(Allowed::ResourceRead { uri: uri.to_string() })
            }
            _ => ViewDecision::Refused(
                "resources/read is limited to the server's ui:// resources".into(),
            ),
        },
        other => ViewDecision::Refused(format!("{} is blocked", text::clean(other))),
    }
}
