//! Toasts: CmuxNextDesign/Toast (styles, the stack, timing, placement, dedupe, plain copy).
//!
//! Ops: `toast.NAME` (see [`call`]). Every rule here is the Swift one moved as is: the same
//! numbers, strings and order, pinned by `tests/toast.rs`.

pub mod center;
pub mod copy;
pub mod model;
pub mod stores;

pub use center::*;
pub use copy::*;
pub use model::*;
pub use stores::*;

use crate::ops::{OpError, OpResult, parse, reply};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StyleRequest {
    style: ToastStyle,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ToneRequest {
    tone: ToastTone,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ToastRequest {
    toast: Toast,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShownDurationRequest {
    #[serde(default)]
    tuning: ToastTuning,
    toast: Toast,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StackPushRequest {
    stack: ToastStack,
    serial: i64,
    id: String,
    undo: bool,
    #[serde(default)]
    keeps_slot: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StackRemoveRequest {
    stack: ToastStack,
    serial: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DetailRequest {
    detail: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CodeRequest {
    code: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ErrorRequest {
    error: ErrorChain,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ErrorKindRequest {
    kind: Option<PlainErrorKind>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AnchorRequest {
    height: f64,
    bounds: Rect,
    floor: Option<f64>,
    #[serde(default)]
    below: Vec<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AnchorsRequest {
    sizes: Vec<Size>,
    #[serde(default)]
    placements: Vec<ToastPlacement>,
    bounds: Rect,
    /// The floor each toast's width gives, one per size (the app measures what it avoids).
    floors: Vec<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DetailCapRequest {
    window_height: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PaddingRequest {
    padding: f64,
    compact: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ButtonRowRequest {
    row: ToastButtonRow,
    has_secondary: bool,
    has_action: bool,
    has_never_show: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExitRequest {
    entrance: ToastEntrance,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FocusRequest {
    focus: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ZoomRequest {
    percent: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NeverShowRequest {
    store: NeverShowStore,
    #[serde(default)]
    kind: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StyleStoreRequest {
    store: StyleStore,
    #[serde(default)]
    style: Option<ToastStyle>,
    #[serde(default)]
    stored: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CenterRequest {
    #[serde(default)]
    center: ToastCenter,
    event: CenterEvent,
}

/// Runs `toast.NAME`.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "styles" => reply(&ToastStyle::ALL.iter().map(|s| s.info()).collect::<Vec<_>>()),
        "style" => reply(&parse::<StyleRequest>(request)?.style.info()),
        "tone" => {
            let tone = parse::<ToneRequest>(request)?.tone;
            reply(&json!({"symbolName": tone.symbol_name(), "color": tone.color()}))
        }
        "glasses" => reply(&ToastGlass::ALL.iter().map(|g| g.info()).collect::<Vec<_>>()),
        "buttonRows" => reply(&ToastButtonRow::ALL.iter().map(|r| r.info()).collect::<Vec<_>>()),
        "buttonRowSpacing" => {
            let r = parse::<ButtonRowRequest>(request)?;
            reply(&r.row.spacing(r.has_secondary, r.has_action, r.has_never_show))
        }
        "normalize" => reply(&parse::<ToastRequest>(request)?.toast.normalized()),
        "offersNeverShow" => reply(&parse::<ToastRequest>(request)?.toast.offers_never_show()),
        "shownDuration" => {
            let r = parse::<ShownDurationRequest>(request)?;
            reply(&r.tuning.shown_duration(&r.toast))
        }
        "tuning" => reply(&ToastTuning::default()),
        "tunables" => reply(&json!({"section": tunable_section(), "tunables": tunables()})),
        "stackPush" => {
            let mut r = parse::<StackPushRequest>(request)?;
            let removed = r.stack.push(r.serial, &r.id, r.undo, r.keeps_slot);
            reply(
                &json!({"stack": r.stack, "removed": removed, "newestUndo": r.stack.newest_undo()}),
            )
        }
        "stackRemove" => {
            let mut r = parse::<StackRemoveRequest>(request)?;
            r.stack.remove(r.serial);
            reply(&json!({"stack": r.stack, "newestUndo": r.stack.newest_undo()}))
        }
        "detailCopy" => reply(&DetailCopy::plain(&parse::<DetailRequest>(request)?.detail)),
        "detailWords" => reply(&DetailCopy::words(&parse::<CodeRequest>(request)?.code)),
        "detailCodeLine" => reply(&DetailCopy::code_line(&parse::<CodeRequest>(request)?.code)),
        "errorKind" => reply(&PlainErrorText::kind(&parse::<ErrorRequest>(request)?.error)),
        "errorText" => reply(&PlainErrorText::text(&parse::<ErrorRequest>(request)?.error)),
        "errorPersonal" => reply(&PlainErrorText::personal(&parse::<ErrorRequest>(request)?.error)),
        "errorWords" => reply(&PlainErrorText::words(parse::<ErrorKindRequest>(request)?.kind)),
        "strings" => reply(&strings()),
        "anchor" => {
            let r = parse::<AnchorRequest>(request)?;
            reply(&overlay_anchor(r.height, r.bounds, r.floor, &r.below))
        }
        "anchors" => {
            let r = parse::<AnchorsRequest>(request)?;
            if r.floors.len() != r.sizes.len() {
                return Err(OpError::Invalid("one floor per size".into()));
            }
            reply(&overlay_anchors(&r.sizes, &r.placements, r.bounds, |i, _| r.floors[i]))
        }
        "detailCap" => reply(&detail_cap(parse::<DetailCapRequest>(request)?.window_height)),
        "padding" => {
            let r = parse::<PaddingRequest>(request)?;
            reply(&look_padding(r.padding, r.compact))
        }
        "metrics" => reply(&metrics()),
        "exit" => reply(&exit_motion(parse::<ExitRequest>(request)?.entrance)),
        "focus" => {
            let raw = parse::<FocusRequest>(request)?.focus;
            let focus = PlaygroundFocus::from_raw(&raw);
            reply(&focus.map(
                |f| json!({"rawValue": f.raw_value(), "title": f.title(), "styles": f.styles()}),
            ))
        }
        "focuses" => {
            reply(&PlaygroundFocus::all_cases().iter().map(|f| f.raw_value()).collect::<Vec<_>>())
        }
        "samples" => reply(&json!({
            "kinds": playground_kinds(),
            "sidebarRefusals": playground_sidebar_refusals(),
            "sheet": playground_sheet(),
            "fired": playground_fired(),
        })),
        "surfaceZoom" => reply(&surface_zoom_toast(parse::<ZoomRequest>(request)?.percent)),
        "notice" => reply(&notice_toast(request)?),
        "neverShowHide" => {
            let mut r = parse::<NeverShowRequest>(request)?;
            let changed = r.store.hide(&r.kind);
            reply(&json!({"store": r.store, "persist": changed.then(|| r.store.persisted())}))
        }
        "neverShowAll" => {
            let mut r = parse::<NeverShowRequest>(request)?;
            let changed = r.store.show_all();
            reply(&json!({"store": r.store, "persist": changed.then(|| r.store.persisted())}))
        }
        "neverShowIsHidden" => {
            let r = parse::<NeverShowRequest>(request)?;
            reply(&r.store.is_hidden(&r.kind))
        }
        "styleLoad" => {
            let r = parse::<StyleStoreRequest>(request)?;
            reply(&StyleStore::load(r.stored.as_deref(), r.store.configured))
        }
        "stylePick" => {
            let mut r = parse::<StyleStoreRequest>(request)?;
            let style = r.style.ok_or_else(|| OpError::Invalid("style".into()))?;
            let change = r.store.pick(style);
            reply(&json!({"store": r.store, "style": r.store.style(), "change": change}))
        }
        "styleConfigure" => {
            let mut r = parse::<StyleStoreRequest>(request)?;
            let style = r.style.ok_or_else(|| OpError::Invalid("style".into()))?;
            let notifies = r.store.configure(style);
            reply(&json!({"store": r.store, "style": r.store.style(), "notifies": notifies}))
        }
        "center" => {
            let mut r = parse::<CenterRequest>(request)?;
            let effects = r.center.handle(r.event);
            reply(&json!({"center": r.center, "effects": effects}))
        }
        _ => Err(OpError::Unknown),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NoticeRequest {
    id: String,
    message: String,
    #[serde(default)]
    detail: Option<String>,
    #[serde(default)]
    tone: Option<ToastTone>,
}

fn notice_toast(request: &Value) -> Result<Toast, OpError> {
    let r = parse::<NoticeRequest>(request)?;
    let mut toast = Toast::new(&r.id, &r.message);
    toast.detail = r.detail;
    toast.tone = r.tone;
    toast.duration = Some(NOTICE_SECONDS);
    Ok(toast.normalized())
}
