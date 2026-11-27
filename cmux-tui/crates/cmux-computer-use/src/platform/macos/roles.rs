//! Accessibility roles and actions as plain names (`AXButton` -> `button`,
//! `AXShowMenu` -> `show_menu`) and back, plus the small geometry helpers the
//! desktop needs. Pure, so it is unit tested.

use crate::desktop::{Point, Rect};

/// `AXFooBarBaz` -> `foo_bar_baz`. Text without the `AX` prefix (custom
/// action names) is lowercased the same way.
pub fn snake(ax: &str) -> String {
    let name = ax.strip_prefix("AX").unwrap_or(ax);
    let mut out = String::with_capacity(name.len() + 4);
    let chars: Vec<char> = name.chars().collect();
    for (i, c) in chars.iter().enumerate() {
        if c.is_ascii_uppercase() {
            let prev_lower =
                i > 0 && (chars[i - 1].is_ascii_lowercase() || chars[i - 1].is_ascii_digit());
            let next_lower = chars.get(i + 1).is_some_and(char::is_ascii_lowercase);
            let prev_upper = i > 0 && chars[i - 1].is_ascii_uppercase();
            if i > 0 && (prev_lower || (prev_upper && next_lower)) && !out.ends_with('_') {
                out.push('_');
            }
            out.push(c.to_ascii_lowercase());
        } else if c.is_alphanumeric() {
            out.push(*c);
        } else if !out.is_empty() && !out.ends_with('_') {
            out.push('_');
        }
    }
    while out.ends_with('_') {
        out.pop();
    }
    out
}

/// `foo_bar` -> `AXFooBar`.
pub fn pascal_ax(plain: &str) -> String {
    let mut out = String::from("AX");
    for part in plain.split('_').filter(|p| !p.is_empty()) {
        let mut chars = part.chars();
        if let Some(first) = chars.next() {
            out.push(first.to_ascii_uppercase());
            out.extend(chars);
        }
    }
    out
}

/// Subroles that say more than their role (a secure field is still an
/// `AXTextField`).
const MEANINGFUL_SUBROLES: &[&str] = &[
    "AXSecureTextField",
    "AXSearchField",
    "AXCloseButton",
    "AXMinimizeButton",
    "AXZoomButton",
    "AXFullScreenButton",
    "AXToolbarButton",
    "AXTabButton",
    "AXSwitch",
    "AXToggle",
    "AXDialog",
    "AXSystemDialog",
    "AXFloatingWindow",
    "AXOutlineRow",
    "AXTableRow",
    "AXSortButton",
    "AXIncrementArrow",
    "AXDecrementArrow",
    "AXTextAttachment",
    "AXTextLink",
];

/// The plain role of an element.
pub fn role_name(role: &str, subrole: Option<&str>) -> String {
    if let Some(sub) = subrole.filter(|s| MEANINGFUL_SUBROLES.contains(s)) {
        return snake(sub);
    }
    match role {
        "" => "unknown".into(),
        "AXIncrementor" => "stepper".into(),
        "AXProgressIndicator" | "AXBusyIndicator" => "progress".into(),
        "AXStaticText" => "text".into(),
        "AXPopUpButton" => "popup_button".into(),
        "AXCheckBox" => "checkbox".into(),
        "AXRadioButton" => "radio".into(),
        other => snake(other),
    }
}

/// Roles whose value is text the person edits.
pub fn is_text_input(role: &str) -> bool {
    matches!(role, "AXTextField" | "AXTextArea" | "AXComboBox" | "AXSearchField")
}

/// Whether a press (`AXPress`, `AXIncrement`, `AXDecrement`) on an element
/// of `role` must show in its value: a checkbox, radio button, switch,
/// disclosure triangle, stepper or slider. A plain button, `AXConfirm`,
/// `AXCancel`, `AXShowMenu` or a custom action may act where nothing shows.
pub fn press_shows_value(role: &str, subrole: Option<&str>, action: &str) -> bool {
    let value_role = matches!(
        role,
        "AXCheckBox" | "AXRadioButton" | "AXDisclosureTriangle" | "AXIncrementor" | "AXSlider"
    ) || subrole == Some("AXSwitch");
    value_role && matches!(action, "AXPress" | "AXIncrement" | "AXDecrement")
}

/// The digit `title` is, when it is exactly one ASCII digit.
pub fn single_digit(title: &str) -> Option<char> {
    let mut chars = title.trim().chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) if c.is_ascii_digit() => Some(c),
        _ => None,
    }
}

/// Whether a press finds its effect already done: a radio button already on
/// (value 1) stays on.
pub fn press_already_done(role: &str, action: &str, before: &str) -> bool {
    role == "AXRadioButton" && action == "AXPress" && before.trim() == "1"
}

/// Whether a plain click in a text element may place the caret through
/// accessibility: not when the element is denied (`blocked`), not in a
/// table or list row (a click there selects the row, an editable cell does
/// not start editing), and not in the app the person is using (it would
/// move their caret).
pub fn caret_click_allowed(blocked: bool, in_row: bool, persons_app: bool) -> bool {
    !blocked && !in_row && !persons_app
}

/// A slider about as tall as it is wide: a circular one (its value follows
/// the angle, not a track).
pub fn looks_circular(frame: &Rect) -> bool {
    let ratio = frame.width / frame.height;
    (0.8..=1.25).contains(&ratio)
}

/// How near a slider's read value must be to the wanted one: 2% of its range
/// (a slider with tick marks snaps to the nearest one).
pub fn slider_tolerance(min: f64, max: f64) -> f64 {
    ((max - min) * 0.02).max(f64::EPSILON)
}

/// How typed text reaches a text element in the background.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertRoute {
    /// Insert through accessibility (AXSelectedText), never followed by keys.
    Ax,
    /// Posted keys, gated as always, read back at the caret: web content and
    /// browser fields accept an AX write and ignore it.
    Keys,
}

/// [`InsertRoute`] for an element inside web content (an AXWebArea
/// ancestor) or in a browser app.
pub fn insert_route(in_web_content: bool, browser_app: bool) -> InsertRoute {
    if in_web_content || browser_app { InsertRoute::Keys } else { InsertRoute::Ax }
}

/// Browser engines by bundle id prefix (any case): their text fields
/// accept AX writes without applying them.
pub const BROWSERS: &[&str] = &[
    "com.apple.Safari",
    "com.google.Chrome",
    "org.chromium.Chromium",
    "company.thebrowser.",
    "org.mozilla.",
    "com.microsoft.edgemac",
    "com.brave.Browser",
    "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi",
    "com.kagi.kagimacOS",
    "app.zen-browser.",
    "com.duckduckgo.macos.browser",
];

/// Whether the app with `bundle_id` is a browser ([`BROWSERS`]).
pub fn is_browser(bundle_id: Option<&str>) -> bool {
    bundle_id.is_some_and(|id| {
        let id = id.to_ascii_lowercase();
        BROWSERS.iter().any(|p| id.starts_with(&p.to_ascii_lowercase()))
    })
}

/// Which engine draws an app's web content, for how a web field is given
/// its page's focus in the background ([`web_focus_write`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WebEngine {
    /// Chromium (Chrome, Edge, Brave, Arc, Opera, Vivaldi, Chromium).
    Chromium,
    /// WebKit (Safari, apps with a web view) or not known.
    Other,
}

/// Chromium browsers by bundle id prefix (any case).
pub const CHROMIUM_BROWSERS: &[&str] = &[
    "com.google.Chrome",
    "org.chromium.Chromium",
    "com.microsoft.edgemac",
    "com.brave.Browser",
    "company.thebrowser.",
    "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi",
];

/// [`WebEngine`] from the app's bundle id; an unknown app is `Other`.
pub fn web_engine(bundle_id: Option<&str>) -> WebEngine {
    let chromium = bundle_id.is_some_and(|id| {
        let id = id.to_ascii_lowercase();
        CHROMIUM_BROWSERS.iter().any(|p| id.starts_with(&p.to_ascii_lowercase()))
    });
    if chromium { WebEngine::Chromium } else { WebEngine::Other }
}

/// Apps that draw Chromium pages inside their own windows and build those
/// pages' accessibility trees only while a client asks, by bundle id: an
/// exact id, or a prefix ending in `.` (any case). cmux draws its agent
/// chats in Chromium (CEF): until `AXManualAccessibility` or
/// `AXEnhancedUserInterface` is set on its application element
/// (`CmuxApplication`, `CEFAccessibility` in the app), a chat page shows
/// nothing to accessibility, so get_ui_tree saw no message or composer.
pub const CHROMIUM_EMBEDDERS: &[&str] = &["com.cmuxterm.app", "com.cmuxterm.app."];

/// Whether the app with `bundle_id` embeds Chromium pages ([`CHROMIUM_EMBEDDERS`]).
pub fn embeds_chromium(bundle_id: Option<&str>) -> bool {
    bundle_id.is_some_and(|id| {
        let id = id.to_ascii_lowercase();
        CHROMIUM_EMBEDDERS.iter().any(|p| {
            let p = p.to_ascii_lowercase();
            if p.ends_with('.') { id.starts_with(&p) } else { id == p }
        })
    })
}

/// The app attribute that makes an app show its web content to
/// accessibility, if it needs one. A Chromium browser builds its pages'
/// accessibility trees only for an assistive client that sets
/// `AXEnhancedUserInterface` (Chrome 157 on macOS 26.6 and 27.0.1: no page
/// elements without it, the page within 2 s with it; it refuses
/// `AXManualAccessibility`). An app that embeds Chromium
/// ([`embeds_chromium`]: cmux) takes `AXManualAccessibility`, the automation
/// driver's attribute, which leaves the app's own behavior for screen readers
/// alone. WebKit shows its pages to any client.
pub fn web_accessibility_attribute(bundle_id: Option<&str>) -> Option<&'static str> {
    if embeds_chromium(bundle_id) {
        return Some("AXManualAccessibility");
    }
    match web_engine(bundle_id) {
        WebEngine::Chromium => Some("AXEnhancedUserInterface"),
        WebEngine::Other => None,
    }
}

/// How a web field is given its page's focus in a background app.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WebFocusWrite {
    /// `AXFocused`: Chromium moves the page's focus and never activates
    /// itself for it (macOS 26.6 and 27.0.1, Chrome after the person used it
    /// and with its address bar focused: the person's app stayed in front).
    Focused,
    /// A caret at the end of the field's text (`AXSelectedTextRange`), which
    /// moves the page's focus with it. WebKit answers an `AXFocused` write
    /// by focusing its page, and Safari then activates itself whenever it may
    /// (it was the active app before: the person lost their focus, live on
    /// 27.0.1), so it is never written there.
    Caret,
}

pub fn web_focus_write(engine: WebEngine) -> WebFocusWrite {
    match engine {
        WebEngine::Chromium => WebFocusWrite::Focused,
        WebEngine::Other => WebFocusWrite::Caret,
    }
}

/// Whether the caret of a web field is written again after keys typed into
/// it ([`WebEngine::Other`]: WebKit keeps an autocorrection pending on the
/// last word and applies it at a later caret write into another field).
pub fn settles_caret_after_keys(engine: WebEngine) -> bool {
    engine == WebEngine::Other
}

/// The caret writes made after keys typed into a WebKit page's field, in
/// order, as UTF-16 (location, length) pairs: `at` is the field's selection
/// read once the typed text shows, `typed` the text's UTF-16 length. The
/// caret goes to where the typing began, then back to `at`, so the typing
/// context of the last word ends and WebKit offers no autocorrection for it
/// (it would otherwise accept that correction at the next focus move into
/// another field, after this call said confirmed).
pub fn settle_caret_writes(at: (isize, isize), typed: isize) -> Vec<(isize, isize)> {
    if typed <= 0 {
        return Vec::new();
    }
    let began = (at.0 - typed).max(0);
    vec![(began, 0), at]
}

/// Whether WebKit may offer to autocorrect text typed with keys: its last
/// word must end the text (live, Safari on macOS 26.6: text ending in a
/// space or punctuation was never corrected later).
pub fn may_be_autocorrected(text: &str) -> bool {
    text.chars().last().is_some_and(char::is_alphabetic)
}

/// Whether a window of the app is WebKit's autocorrection bubble for the
/// field at `field` (global points): untitled, small, on screen, layer 0,
/// new since the keys (`new`), and near the field. Live, Safari on macOS
/// 26.6: two untitled windows, about 97x49 and 81x22 points, appeared at
/// the field 0.3 s after the call while a correction was pending, and went
/// away when it was accepted or dismissed.
pub fn is_correction_bubble(
    title: &str,
    layer: i64,
    on_screen: bool,
    new: bool,
    frame: &Rect,
    field: &Rect,
) -> bool {
    // Within this many points of the field (the bubble sits on the word).
    const NEAR: f64 = 80.0;
    let near = Rect {
        x: field.x - NEAR,
        y: field.y - NEAR,
        width: field.width + 2.0 * NEAR,
        height: field.height + 2.0 * NEAR,
    };
    title.is_empty()
        && layer == 0
        && on_screen
        && new
        && frame.width >= 2.0
        && frame.height >= 2.0
        && frame.width <= BUBBLE_MAX.0
        && frame.height <= BUBBLE_MAX.1
        && frame.intersects(&near)
}

/// The largest a correction bubble window is (width, height in points): the
/// bubble grows with the suggested word, and a long suggestion is still far
/// smaller than this.
pub const BUBBLE_MAX: (f64, f64) = (400.0, 80.0);

/// What the settle found about WebKit's autocorrection of the typed text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Autocorrection {
    /// No correction was offered while it was watched (or none can be).
    NoneOffered,
    /// One was offered and dismissed: the text stays as typed.
    Dismissed,
    /// One is still offered: the text may change at the next focus move.
    StillOffered,
}

/// [`Autocorrection`] from whether a bubble was seen and whether it was
/// still there after the dismissal.
pub fn autocorrection(seen: bool, still_there: bool) -> Autocorrection {
    match (seen, still_there) {
        (false, _) => Autocorrection::NoneOffered,
        (true, false) => Autocorrection::Dismissed,
        (true, true) => Autocorrection::StillOffered,
    }
}

/// The note when WebKit still offers to correct the typed text.
pub const AUTOCORRECTION_PENDING: &str = "the browser is offering to autocorrect the last word typed and the offer could not be dismissed; the text reads back as typed now, but the browser may replace that word when focus moves to another field";

/// Where a background app's focused element (`AXFocusedUIElement`) is,
/// relative to the field keys are meant for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppFocus {
    /// The app names no focused element (a background WebKit app whose
    /// keyboard focus is its web view).
    Nothing,
    /// The field itself.
    Target,
    /// An element of the field's own web content (its web area).
    InPage,
    /// An element outside the field's web content: the address bar, a find
    /// bar, a sidebar, another web view. Keys posted to the app go there.
    Outside,
}

/// What the web keys guard reads after the field was given focus
/// ([`web_keys_guard`]). Every read is strict: `None` is unread.
#[derive(Clone, Debug, PartialEq)]
pub struct WebKeyFacts {
    /// The field's own AXFocused.
    pub own: Option<bool>,
    /// Where the app's focused element is.
    pub app_focus: Option<AppFocus>,
    /// Web areas between the field and its window (more than one: an iframe).
    pub web_areas: usize,
    /// Whether the window holds a web area other than the field's own and
    /// those inside it (a docked web inspector, another web view).
    pub other_web_views: Option<bool>,
    /// The app reports no focused window, and then whether it has a sheet or
    /// another window keys could reach.
    pub no_focused_window: bool,
    pub other_targets: bool,
}

/// Whether keys posted to a background app reach this web field (live,
/// Safari and Chrome on macOS 26.6 and 27.0.1: with the field holding its
/// page's focus, keys posted to the app's process type into it, with the
/// page's own keydown, beforeinput and input events, and the person's front
/// app, key window and input source unchanged). Keys go wherever the app's
/// window has its keyboard focus: they are posted only when that is this
/// page (the app names the field, an element of its page, or nothing, as a
/// background WebKit app does for its web view), the field holds the page's
/// focus, the field is not in an iframe, the window has no other web view
/// (a docked inspector names nothing either) and no sheet or second window
/// could take them. The reason otherwise.
pub fn web_keys_guard(f: &WebKeyFacts) -> Result<(), &'static str> {
    if f.own != Some(true) {
        return Err("the field did not take its page's focus");
    }
    if f.web_areas > 1 {
        return Err("the field is in a frame inside the page, whose focus cannot be checked");
    }
    match f.other_web_views {
        Some(false) => {}
        Some(true) => {
            return Err(
                "the window shows another web view (a web inspector or a second page), which may hold the keyboard",
            );
        }
        None => return Err("the window's web views could not be read"),
    }
    match f.app_focus {
        Some(AppFocus::Nothing | AppFocus::Target | AppFocus::InPage) => {}
        Some(AppFocus::Outside) => {
            return Err(
                "the window's keyboard focus is outside the page (its address bar, a find bar or another field), so keys would go there",
            );
        }
        None => return Err("the app's focused element could not be read"),
    }
    if f.no_focused_window && f.other_targets {
        return Err("the app has a sheet or another window that keys could reach");
    }
    Ok(())
}

/// The UTF-16 caret at the end of a field's text (where the caret write
/// puts it): its length.
pub fn caret_at_end(value: &str) -> isize {
    value.encode_utf16().count() as isize
}

/// The value a set_value request writes, as `value_for` maps it: on an
/// element whose value is a number, "true"/"on" is 1 and "false"/"off" is
/// 0, and a number is that number (written out as AX reads it back);
/// `None` when the request is no number there (the write is refused).
pub fn requested_value(current_is_number: bool, value: &str) -> Option<String> {
    if !current_is_number {
        return Some(value.to_string());
    }
    let n: f64 = match value.trim() {
        "true" | "on" => 1.0,
        "false" | "off" => 0.0,
        s => s.parse().ok()?,
    };
    Some(if n.fract() == 0.0 && n.abs() < 1e15 { format!("{}", n as i64) } else { format!("{n}") })
}

/// Whether an element is in web content, from the roles from it up to its
/// window (`None`: a read failed or the walk ran past its bound). Callers
/// choose the safe side for `Unknown` themselves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Web {
    In,
    Out,
    Unknown,
}

/// [`Web`] from the roles walked.
pub fn web_content(roles: Option<Vec<String>>) -> Web {
    match roles {
        None => Web::Unknown,
        Some(r) if r.iter().any(|r| r == "AXWebArea") => Web::In,
        // Not web only for a walk that reached the window or the app.
        Some(r) if r.last().is_some_and(|l| matches!(l.as_str(), "AXWindow" | "AXApplication")) => {
            Web::Out
        }
        Some(_) => Web::Unknown,
    }
}

/// Whether the native AX routes (caret, text drag, slider, scroll, the AX
/// insert) may run: only outside web content, known; unknown takes the
/// events or the keys.
pub fn native_route(web: Web) -> bool {
    web == Web::Out
}

/// Whether the menu gate treats an element as web content (which narrows
/// the roles that open a menu to a pop-up with one). Unknown is not web:
/// the full gate applies, so nothing that could open a menu passes
/// ungated.
pub fn menu_gate_web(web: Web) -> bool {
    web == Web::In
}

/// The tolerance a stepper's read-back allows around its target: half a
/// step (so stopping one step short does not reach it, and one step moved
/// from one step away is not "already"), and a hair more for rounding.
pub fn step_tolerance(step: f64) -> f64 {
    step.abs() / 2.0 + 1e-9
}

/// The refusal when an element that may open a menu cannot be read.
pub const MENU_UNREAD_REFUSAL: &str = "this element could not be read well enough to tell whether it opens a menu, so nothing was done; try again, or take a screenshot and use another element";

/// What the focus guard reads after an AX focus write ([`focus_guard`]).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FocusFacts {
    /// The app's focused element: `Some(true)` the target, `Some(false)`
    /// another, `None` none reported.
    pub app_names_target: Option<bool>,
    /// The target's own AXFocused before and after the write.
    pub own_before: Option<bool>,
    pub own_after: Option<bool>,
    /// The target is in web content, through this many web areas.
    pub in_web: bool,
    pub web_areas: usize,
    /// The web area's host view (the element just outside it) AXFocused.
    pub host_focused: Option<bool>,
    /// The app reports no focused window, and then whether it has a sheet
    /// or more than one window keys could reach.
    pub no_focused_window: bool,
    pub other_targets: bool,
}

/// Whether keys may follow an AX focus write. The app naming the target
/// posts keys; naming another element posts none. Naming none (a background
/// app; Safari's background web field on macOS 27.0.1), the target's own
/// focus must have turned false to true across the write (document-level
/// focus alone could be another web view's, an inspector's), in web content
/// its host view must be focused and the walk must pass one web area only
/// (an iframe is refused), and with no focused window the app must have no
/// sheet and only one window keys could reach.
pub fn focus_guard(f: &FocusFacts) -> bool {
    match f.app_names_target {
        Some(same) => same && f.web_areas <= 1,
        None => {
            f.own_before == Some(false)
                && f.own_after == Some(true)
                && f.web_areas <= 1
                && (!f.in_web || f.host_focused == Some(true))
                && !(f.no_focused_window && f.other_targets)
        }
    }
}

/// `before` with `text` inserted at the UTF-16 range (`location`, `length`)
/// it replaces; `None` when the range lies outside `before`.
pub fn insert_at(before: &str, text: &str, location: isize, length: isize) -> Option<String> {
    let b: Vec<u16> = before.encode_utf16().collect();
    let (start, len) = (usize::try_from(location).ok()?, usize::try_from(length).ok()?);
    let end = start.checked_add(len)?;
    if end > b.len() {
        return None;
    }
    let mut out: Vec<u16> = b[..start].to_vec();
    out.extend(text.encode_utf16());
    out.extend(&b[end..]);
    String::from_utf16(&out).ok()
}

/// What the web value route reads of a field ([`web_value_gate`]).
#[derive(Clone, Debug, PartialEq)]
pub struct WebField {
    pub kind: WebKind,
    pub secure: bool,
    pub width: f64,
    pub height: f64,
    /// Its frame overlaps its window.
    pub on_screen: bool,
    pub hidden: bool,
    /// It exposes a length limit (AXMaxLength), which a value write does
    /// not apply.
    pub limited: bool,
    pub center: Point,
}

/// What a web text element is, for its value to be its content.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WebKind {
    /// A text field or search field with no children: an `<input>`.
    Plain,
    /// A text field with children: rich content (`role="textbox"`).
    Rich,
    /// A text area: a native `<textarea>` or a contenteditable, which
    /// Safari shows alike.
    Area,
    /// Anything else (a combobox, a group).
    Other,
}

/// From the element's role and how many children it has. Live in Safari
/// (macOS 27.0.1): an `<input>` has none; a native `<textarea>` and a
/// one-paragraph contenteditable (an empty ProseMirror `<p><br></p>`, a
/// one-paragraph Quill, a one-line CodeMirror 6) are both an AXTextArea with
/// one AXGroup child, with the same attributes, settable attributes,
/// parameterized attributes and actions, so no text area counts as plain.
pub fn web_kind(role: &str, kids: usize) -> WebKind {
    match role {
        "AXTextField" | "AXSearchField" if kids == 0 => WebKind::Plain,
        "AXTextField" | "AXSearchField" => WebKind::Rich,
        "AXTextArea" => WebKind::Area,
        _ => WebKind::Other,
    }
}

/// Whether the gate lets a password field through: typing into one by its
/// value would replace it with what it shows; set_value replaces it by
/// design (read back by its length).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SecureField {
    Refuse,
    Allow,
}

/// The refusal when a web field's facts cannot be read.
pub const WEB_FIELD_UNREAD: &str = "this web field could not be read well enough to write its value safely, so nothing was written; try again";

/// The smallest a field may be, wide and high, for its value to be its
/// content: input helpers of terminals and code editors are styled 1 pt or
/// hidden (WebKit pads a 1x1 textarea to 12x6 pt), and a text field one can
/// read is taller than 10 pt.
pub const WEB_FIELD_MIN: f64 = 10.0;

/// Whether a value write may be made into a web field: a plain text input
/// (see [`web_kind`]), not tiny, off screen or hidden (an input helper, whose
/// value is not the content), and not a password field unless `secure`
/// allows it.
pub fn web_value_gate(f: Option<&WebField>, secure: SecureField) -> Result<(), &'static str> {
    let Some(f) = f else { return Err(WEB_FIELD_UNREAD) };
    if f.secure && secure == SecureField::Refuse {
        return Err(
            "this is a password field; its value is never written this way, because what it shows is not its text. Use delivery foreground",
        );
    }
    match f.kind {
        WebKind::Plain => {}
        WebKind::Rich => {
            return Err(
                "this web text field holds rich content (a rich editor), so its value is not written through accessibility; use delivery foreground",
            );
        }
        WebKind::Area => {
            return Err(
                "this is a web text area; a browser shows a native text area and a rich editor alike to accessibility, so its value is not written through accessibility, and the field could not be focused for keys in the background; use delivery foreground",
            );
        }
        WebKind::Other => {
            return Err(
                "this web element is not a plain text field (a combobox or another control), so its value is not written through accessibility; use delivery foreground",
            );
        }
    }
    if f.width < WEB_FIELD_MIN || f.height < WEB_FIELD_MIN || !f.on_screen || f.hidden {
        return Err(
            "this web field is tiny, off screen or hidden (an editor's input helper, whose value is not its content), so its value is not written this way; use delivery foreground",
        );
    }
    Ok(())
}

/// Whether a web field the gate refuses only for being out of its window
/// is first scrolled into view (a field the page is scrolled past): every
/// other rule of the gate holds first ([`web_value_gate_but_view`]), so a
/// tiny, hidden, rich or password field is refused without scrolling; an
/// input placed off the page cannot be scrolled into view.
pub fn scroll_into_view_first(f: &WebField, secure: SecureField) -> bool {
    !f.on_screen && web_value_gate_but_view(f, secure).is_ok()
}

/// Whether a web field may take a value write: only while it holds its
/// page's focus (read strictly, `None` unread). Live in Safari (macOS
/// 27.0.1): an AXValue write on an `<input>` lands in whichever field holds
/// the page's focus, whichever one was addressed, and returns success.
pub fn holds_page_focus(focused: Option<bool>) -> bool {
    focused == Some(true)
}

/// Whether a failed value write certainly wrote nothing: the app refused
/// the argument or the attribute. Any other error (no answer in time, an
/// element gone, a generic failure) may have come after the write applied.
pub fn write_not_applied(e: super::sys::AXError) -> bool {
    matches!(
        e,
        super::sys::AX_ILLEGAL_ARGUMENT
            | super::sys::AX_ATTRIBUTE_UNSUPPORTED
            | super::sys::AX_ACTION_UNSUPPORTED
    )
}

/// The note of a web value write at UTF-16 position `at` that replaced
/// `replaced` selected characters.
pub fn web_value_note(at: isize, replaced: isize, limited: bool, scrolled: bool) -> String {
    let what = match replaced {
        0 => String::new(),
        1 => ", replacing the 1 selected character,".into(),
        n => format!(", replacing the {n} selected characters,"),
    };
    // macOS 27.0.1, Safari: the value write fires the page's input event
    // (not change, which comes when the field loses focus).
    let mut note = format!(
        "web content: the text was written into the field's value at position {at} (its selection then){what} through accessibility, with no keystrokes, so the page's key handlers did not run (its input event did)"
    );
    if limited {
        note.push_str("; the field has a length limit, which was not applied");
    }
    if scrolled {
        note.push_str("; the page was scrolled to bring the field into view first");
    }
    note
}

/// The gate's rules except being in view, which scrolling can fix: every
/// other rule refuses before anything is scrolled.
pub fn web_value_gate_but_view(f: &WebField, secure: SecureField) -> Result<(), &'static str> {
    web_value_gate(Some(&WebField { on_screen: true, ..f.clone() }), secure)
}

/// Where background typing into web content goes once the focus write was
/// tried: keys when the guard proved focus; else the value route when the
/// field is eligible for it; else the reason it is not (no keys, nothing
/// written).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WebTyping {
    Keys,
    Value,
    Refuse(&'static str),
}

pub fn web_typing(focused: bool, eligible: Result<(), &'static str>) -> WebTyping {
    match (focused, eligible) {
        (true, _) => WebTyping::Keys,
        (false, Ok(())) => WebTyping::Value,
        (false, Err(why)) => WebTyping::Refuse(why),
    }
}

/// Where the person's caret is relative to a field a targeted write goes
/// into, in the app the person is using (#13742: targeted writes into a
/// field that is not where the person's caret is stay allowed).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Caret {
    /// The app's focused element is another element, unrelated to the field.
    Elsewhere,
    /// The focused element is the field, contains it, or lies inside it.
    OnTarget,
    /// The app's focused element could not be read.
    Unread,
}

/// One step of the walk up to the menu bar: `Some(true)` at the menu bar,
/// `Some(false)` at the window or the application (the element is not in
/// the menu bar), `None` to keep walking. Any other role keeps walking: a
/// subview inside a menu item's custom view (a search field, a slider, a
/// button) has a role of its own and is still in the menu bar.
pub fn menu_bar_walk_step(role: &str) -> Option<bool> {
    match role {
        "AXMenuBar" => Some(true),
        "AXWindow" | "AXApplication" => Some(false),
        _ => None,
    }
}

/// How many levels the walk follows before it gives up: deep enough for
/// any window's content (Electron and web pages run past 20 levels; the
/// old cap of 16 refused them).
pub const MENU_WALK_MAX: usize = 128;

/// Whether an element is in the menu bar, from `role_at(n)`, the role of
/// its `n`-th ancestor (0: the element itself; `None`: unreadable). `None`
/// when a role could not be read, or the walk passed [`MENU_WALK_MAX`]
/// levels without reaching the menu bar, a window or the application.
pub fn menu_bar_walk(mut role_at: impl FnMut(usize) -> Option<String>) -> Option<bool> {
    for depth in 0..MENU_WALK_MAX {
        let role = role_at(depth)?;
        if let Some(answer) = menu_bar_walk_step(&role) {
            return Some(answer);
        }
    }
    None
}

/// The refusal when an element's place (in the menu bar or not) cannot be
/// read, before a press that the menu bar's checks would gate.
pub const MENU_PLACE_UNREAD: &str = "Computer Use could not read whether this element is in the menu bar, so it does not act on it (the menu checks could not be applied); try again";

/// Whether a focused element that contains the field may hold the
/// person's caret on it: a web area, a group or a scroll area may (the caret
/// sits in a field inside it); a window or the application itself is focused
/// when no element in it has the caret (live: a fixture window on macOS
/// 27.0.1 reports its window as the focused element).
pub fn container_holds_caret(role: &str) -> bool {
    !matches!(role, "AXWindow" | "AXApplication")
}

/// Whether a targeted value write may go into a field of the person's app:
/// only when their caret is elsewhere (an unreadable one fails closed).
pub fn caret_allows_write(caret: Caret) -> bool {
    caret == Caret::Elsewhere
}

/// The refusal when the person's caret is on (or cannot be told apart
/// from) the field.
pub const CARET_ON_TARGET: &str = "this field is where the person's caret is in the app they are using (or their focus could not be read), so its value is not written; use delivery foreground";

/// Whether a web field still held the page's focus after a value write:
/// its own AXFocused read true, and the web area's focused element, where
/// it could be read, is the field. Otherwise the write may have gone into
/// another field.
pub fn kept_focus(own: Option<bool>, area_names_target: Option<bool>) -> bool {
    own == Some(true) && area_names_target != Some(false)
}

/// How a posted press is aimed, from the two readings of the front app
/// taken right before the post.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Aiming {
    /// The target is the front app by both readings: name its window.
    Addressed,
    /// Another app is front by both readings: a background press, not
    /// addressed (an addressed one would raise the target's window).
    Unaddressed,
    /// The readings disagree about the target, or one cannot be read: an
    /// unaddressed press could land as if in the target's menu bar (the
    /// Apple menu), an addressed one could raise it. Nothing is posted.
    Refuse,
}

/// [`Aiming`] from the active app's and the keyboard's pids.
pub fn press_aiming(active: Option<i32>, keyboard: Option<i32>, target: i32) -> Aiming {
    match (active, keyboard) {
        (Some(a), Some(k)) if a == target && k == target => Aiming::Addressed,
        (Some(a), Some(k)) if a != target && k != target => Aiming::Unaddressed,
        _ => Aiming::Refuse,
    }
}

/// The two readings agreed on, for "the person's front app" where one pid
/// is needed (`None`: they disagree or one cannot be read; callers fail
/// closed on it).
pub fn agreed_front(active: Option<i32>, keyboard: Option<i32>) -> Option<i32> {
    match (active, keyboard) {
        (Some(a), Some(k)) if a == k => Some(a),
        _ => None,
    }
}

/// The refusal when the front app cannot be read consistently.
pub const FRONT_UNSURE: &str = "which app is in front could not be read consistently (a panel such as Spotlight may hold the keyboard), so the click was not posted; try again, or use an element_id";

/// Command-A alone: Select All.
pub fn is_select_all(combo: &crate::keys::KeyCombo) -> bool {
    combo.modifiers == [crate::keys::Modifier::Meta]
        && matches!(combo.key, crate::keys::Key::Char('a' | 'A'))
}

pub fn is_secure(role: &str, subrole: Option<&str>) -> bool {
    subrole == Some("AXSecureTextField") || role == "AXSecureTextField"
}

/// AX actions never offered to agents in the background: `AXRaise` brings a
/// window in front of the person's work. (`AXShowMenu` opens a context menu,
/// which `computerUse.menus` decides; see [`crate::menus`].)
pub fn is_foreground_action(ax: &str) -> bool {
    ax == "AXRaise"
}

/// Menu bar items and menu extras: their menus are the frontmost app's menu
/// bar, never opened in the background in any `computerUse.menus` mode.
pub fn is_menu_bar(role: &str) -> bool {
    matches!(role, "AXMenuBarItem" | "AXMenuExtra")
}

/// The AX action that opens an element's menu: its press, else its
/// show-menu action.
pub fn open_action(available: &[String]) -> Option<&'static str> {
    ["AXPress", "AXShowMenu"].into_iter().find(|a| available.iter().any(|x| x == a))
}

/// Whether pressing, clicking or keyboard-activating an element of `role`
/// opens a menu or list pop-up that takes the person's pointer and keyboard
/// while it is open. Inside web content (`in_web`) only a pop-up button with
/// a menu of its own (an HTML `<select>`, drawn as a native menu) does; an
/// ARIA menu button opens DOM content in the page.
pub fn opens_menu(role: &str, in_web: bool, has_menu: bool) -> bool {
    if in_web {
        return role == "AXPopUpButton" && has_menu;
    }
    matches!(
        role,
        "AXPopUpButton" | "AXMenuButton" | "AXComboBox" | "AXMenuBarItem" | "AXMenuExtra"
    )
}

/// Keys that open a focused pop-up or menu button (an editable combo box
/// only types them).
pub fn key_opens_menu(key: &crate::keys::Key) -> bool {
    use crate::keys::Key;
    matches!(key, Key::Space | Key::Return | Key::Up | Key::Down) || *key == Key::Char(' ')
}

/// Text whose typing opens a focused pop-up (a space or a newline).
pub fn text_opens_menu(text: &str) -> bool {
    text.contains([' ', '\n', '\r'])
}

/// Why a menu-opening element is refused in the background, and what to
/// use instead.
pub fn menu_refusal(role: &str) -> String {
    let name = role_name(role, None);
    let instead = match role {
        "AXPopUpButton" | "AXMenuButton" => {
            "use set_value with the title of the item to choose (a pop-up that lists its items while closed is set without opening the menu)"
        }
        "AXComboBox" => "use set_value or type_text with element_id to change its text",
        _ => "use perform_action on the item you want if the tree shows it",
    };
    format!(
        "this {name} opens a menu, and Computer Use is set not to open menus in the background (Settings > Computer Use > Menus, computerUse.menus is \"refuse\"); {instead}, or click it with delivery foreground"
    )
}

/// Why a context menu (right click, control-click) is refused in the background.
pub const CONTEXT_MENU_REFUSAL: &str = "a right click, control-click or show_menu opens a context menu, and Computer Use is set not to open menus in the background (computerUse.menus is \"refuse\"); use perform_action with the element's own actions (get_ui_tree lists them), or click with delivery foreground";

/// Whether the case-insensitive, trimmed titles match (a menu item for a
/// `set_value` on a pop-up).
pub fn same_title(a: &str, b: &str) -> bool {
    a.trim().eq_ignore_ascii_case(b.trim())
}

/// An AX action name as the plain name agents see. Custom actions
/// (`Name:Reply\nTarget:...`) keep their name part.
pub fn action_name(ax: &str) -> String {
    if let Some(rest) = ax.strip_prefix("Name:") {
        let name = rest.split('\n').next().unwrap_or(rest);
        return name.to_string();
    }
    snake(ax)
}

/// Actions that are attribute writes rather than AX actions: the plain
/// name, the attribute and the value written.
pub fn attribute_action(plain: &str) -> Option<(&'static str, bool)> {
    Some(match plain {
        "expand" => ("AXExpanded", true),
        "collapse" => ("AXExpanded", false),
        "select" => ("AXSelected", true),
        "focus" => ("AXFocused", true),
        _ => return None,
    })
}

/// The AX action an agent's name refers to among the element's actions:
/// exact AX name, the plain name, or a custom action's name.
pub fn resolve_action<'a>(requested: &str, available: &'a [String]) -> Option<&'a String> {
    let wanted = requested.trim();
    available.iter().find(|ax| {
        ax.as_str() == wanted
            || action_name(ax) == wanted
            || action_name(ax).eq_ignore_ascii_case(wanted)
            || pascal_ax(wanted) == ax.as_str()
    })
}

pub fn center(r: &Rect) -> Point {
    Point { x: r.x + r.width / 2.0, y: r.y + r.height / 2.0 }
}

/// Whether a global point lies in a rect (edges included, half a point of
/// slack for rounding of screenshot pixels).
pub fn contains(r: &Rect, p: Point) -> bool {
    const SLACK: f64 = 0.5;
    p.x >= r.x - SLACK
        && p.y >= r.y - SLACK
        && p.x <= r.x + r.width + SLACK
        && p.y <= r.y + r.height + SLACK
}

/// Clamps a point into a rect (after `contains` passed with slack).
pub fn clamp_into(r: &Rect, p: Point) -> Point {
    Point {
        x: p.x.clamp(r.x, r.x + (r.width - 1.0).max(0.0)),
        y: p.y.clamp(r.y, r.y + (r.height - 1.0).max(0.0)),
    }
}

/// Roles a plain click presses: what AXPress does is what the click does.
/// Pop-ups, menu buttons and combo boxes open menus (handled before), text
/// inputs take a caret, and containers hold what was meant.
const PRESS_ROLES: &[&str] = &[
    "AXButton",
    "AXCheckBox",
    "AXRadioButton",
    "AXLink",
    "AXDisclosureTriangle",
    "AXSwitch",
    "AXToggle",
    "AXMenuItem",
    "AXTab",
];

pub fn is_press_role(role: &str) -> bool {
    PRESS_ROLES.contains(&role)
}

/// A label or picture inside a control: the click is the control's.
pub fn is_label_role(role: &str) -> bool {
    matches!(role, "AXStaticText" | "AXImage")
}

/// How a plain background click on the element the point hits is done.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HitClick {
    /// Refused: the element is a menu item the deny list blocks.
    Refuse,
    /// AXPress on it.
    Press,
    /// Select its row (a list, table or outline row with no press).
    Select,
    /// Post the mouse events (text, canvas, web content, anything else).
    Events,
}

/// A text field in a row that is not selected counts as the row: a click in
/// a row selects it first (Finder's file name is a text field; AppKit tables
/// edit a cell only on a click in a row already selected, which gets the
/// events).
pub fn hit_click(role: &str, has_press: bool, in_unselected_row: bool, blocked: bool) -> HitClick {
    if blocked {
        HitClick::Refuse
    } else if has_press && is_press_role(role) {
        HitClick::Press
    } else if !has_press && in_unselected_row {
        HitClick::Select
    } else {
        HitClick::Events
    }
}

/// Whether the element a point hits may be acted on through accessibility:
/// the window is on screen (an off-screen window keeps refusing point
/// clicks) and the element is inside the target window (the app's hit test
/// can return a sibling window's element at an overlapping point).
pub fn hit_usable(on_screen: bool, in_target_window: bool) -> bool {
    on_screen && in_target_window
}

/// After a hit-test AXPress that returned `code`: fall back to the mouse
/// events only when the element did not take the press at all (unsupported
/// action or attribute, illegal argument). A timeout or "cannot complete"
/// may come back after the press ran (a modal loop, a menu that popped), so
/// posting a click too could act twice: that is reported as delivered.
pub fn press_error_falls_back(code: i32) -> bool {
    matches!(code, -25201 | -25205 | -25206)
}

/// Why a disabled background menu item must not be made available, if it
/// must not (pure, for tests): its place is in a launch list (Services,
/// Open With, Share, Recent Items, Quick Actions, in AppKit's languages) or
/// could not be read; a menu above it is an open command (Open Recent's
/// documents); its title is an open or reveal command (`open_titles`,
/// English and AppKit's languages); its key equivalent is AppKit's Open
/// (Command-O) or Finder's Open (Command-Down), which holds in any language;
/// or its title or key equivalent could not be read (fail closed). The
/// title list is best effort: an app's own open command under another name
/// is caught only by its place or its Command-O key equivalent.
pub fn prime_block(
    title: Option<&str>,
    ancestors: Option<&[String]>,
    opens_by_key: Option<bool>,
    launch_titles: &[String],
    open_titles: &[String],
) -> Option<&'static str> {
    const LAUNCH: &str = "this menu item is in a launch list (Services, Open With, Share, Recent Items or Quick Actions) or an open command's submenu; it is disabled while its app is in the background and is never made available there, so nothing was pressed. Use delivery foreground if it is allowed";
    const OPENS: &str = "this menu item opens or reveals documents or apps, which can start another app (a denied one too), or its title or key could not be read; it is disabled while its app is in the background and is never made available there, so nothing was pressed. Use delivery foreground if it is allowed";
    let is_open = |t: &str| {
        let key = submenu_title_key(t);
        open_titles.iter().any(|o| key == *o || key.starts_with(&format!("{o} ")))
    };
    const PLACE: &str = "this menu item's place in the menus could not be read (a submenu deeper than the walk, or a menu that did not answer), so it is not known whether it is a launch or open command; it is disabled while its app is in the background and is never made available there, so nothing was pressed. Use delivery foreground if it is allowed";
    let Some(ancestors) = ancestors else { return Some(PLACE) };
    if ancestors.iter().any(|t| launch_titles.contains(&submenu_title_key(t)) || is_open(t)) {
        return Some(LAUNCH);
    }
    let (Some(title), Some(opens_by_key)) = (title, opens_by_key) else { return Some(OPENS) };
    if opens_by_key || is_open(title) {
        return Some(OPENS);
    }
    None
}

/// One parent of a menu item, as read (for [`menu_place`]).
pub struct MenuNode {
    /// None: the role could not be read.
    pub role: Option<String>,
    /// Err: the title could not be read.
    pub title: Result<Option<String>, ()>,
}

/// How far up a menu item's place is walked.
pub const MENU_PLACE_DEPTH: usize = 10;

/// A menu item's place (pure, for tests): the titles of the menu items and
/// menu bar items above it, from its parents read one at a time, or None
/// when the walk does not reach the menu bar: a role or title that cannot be
/// read, the walk ending elsewhere (the application), deeper than
/// [`MENU_PLACE_DEPTH`], or `live` turning false (the scope ended).
pub fn menu_place(
    parents: impl Iterator<Item = MenuNode>,
    live: &dyn Fn() -> bool,
) -> Option<Vec<String>> {
    let mut titles = Vec::new();
    for node in parents.take(MENU_PLACE_DEPTH) {
        if !live() {
            return None;
        }
        match node.role.as_deref()? {
            "AXMenuItem" | "AXMenuBarItem" => titles.push(node.title.ok()?.unwrap_or_default()),
            "AXMenuBar" => return Some(titles),
            "AXApplication" => return None,
            _ => {}
        }
    }
    None
}

/// Whether a menu item's key equivalent is AppKit's Open (Command-O) or
/// Finder's Open (Command-Down): Command alone (no Shift, Option, Control).
pub fn is_open_key_equivalent(key: &super::keymap::MenuItemKey, menu_mods: i64) -> bool {
    use super::keymap::{MENU_CONTROL, MENU_NO_COMMAND, MENU_OPTION, MENU_SHIFT};
    if menu_mods & (MENU_SHIFT | MENU_OPTION | MENU_CONTROL | MENU_NO_COMMAND) != 0 {
        return false;
    }
    key.printable.is_some_and(|c| c.eq_ignore_ascii_case(&'o')) || key.codes.contains(&125)
}

/// Whether a menu item is still the one checked before the scope opened
/// (pure, for tests): its title, read again inside the scope, is the same.
/// Validation can retitle an item (Undo X, Show/Hide); a changed or
/// unreadable title is not pressed.
pub fn same_item(before: Option<&str>, now: Option<&str>) -> Result<(), &'static str> {
    match (before, now) {
        (Some(b), Some(n)) if b == n => Ok(()),
        _ => Err(
            "the menu item changed while it was being made available (its title is not the one checked), so nothing was pressed; read the menu again",
        ),
    }
}

/// What a click may do inside a key-in-app scope (pure, for tests): only
/// the item's own press. Without a press action read (it may have timed
/// out) nothing happens: no row select, no click at its center.
pub fn primed_click(scope_open: bool, has_press: bool) -> Result<(), &'static str> {
    if scope_open && !has_press {
        return Err(
            "the menu item's press action could not be read while it was being made available, so nothing was pressed",
        );
    }
    Ok(())
}

/// Whether an item may be pressed inside a key-in-app scope (pure, for
/// tests): the scope is still live (not stopped, within its bound, the
/// person did not switch to the app), the app still reports the target as
/// its focused window, and the item is not one that is never made available
/// ([`prime_block`]: launch lists, Services, open and reveal commands).
pub fn primed_press(
    live: bool,
    focus_on_target: bool,
    never_primed: bool,
) -> Result<(), &'static str> {
    if !live {
        return Err(
            "the target app came to the front, the call was stopped or the app did not answer in time while its menu item was being made available, so nothing was pressed",
        );
    }
    if !focus_on_target {
        return Err(
            "the target window stopped being its app's key window before the menu item was pressed (another window of the app took it), so nothing was pressed",
        );
    }
    if never_primed {
        return Err(
            "the menu item is a launch-list or open command (Services, Open With, Open...), which is never run from a background app's menu: nothing was pressed",
        );
    }
    Ok(())
}

/// Text split into chunks of about `n` characters, never inside a
/// user-perceived character (pure, for tests): a chunk does not end before a
/// combining mark, variation selector, zero-width joiner, emoji modifier or
/// tag character, nor right after a joiner, nor between the two regional
/// indicators of a flag. (A conservative rule instead of full UAX #29.)
pub fn text_chunks(text: &str, n: usize) -> Vec<String> {
    let extends = |c: char| {
        matches!(c as u32,
            0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF
            | 0xFE00..=0xFE0F | 0xFE20..=0xFE2F | 0x200D | 0x1F3FB..=0x1F3FF
            | 0xE0020..=0xE007F | 0xE0100..=0xE01EF)
            || unicode_category_mark(c)
    };
    let regional = |c: char| (0x1F1E6..=0x1F1FF).contains(&(c as u32));
    let chars: Vec<char> = text.chars().collect();
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut count = 0usize;
    let mut ri_run = 0usize;
    for (i, &c) in chars.iter().enumerate() {
        let prev = i.checked_sub(1).map(|j| chars[j]);
        let joins = extends(c) || prev == Some('\u{200D}') || (regional(c) && ri_run % 2 == 1);
        if count >= n.max(1) && !joins {
            out.push(std::mem::take(&mut cur));
            count = 0;
        }
        ri_run = if regional(c) { ri_run + 1 } else { 0 };
        cur.push(c);
        count += 1;
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Combining marks outside the ranges above that scripts commonly use
/// (Devanagari and other Indic vowel signs, Hangul jamo medials and finals,
/// Thai and Arabic marks): kept with their base.
fn unicode_category_mark(c: char) -> bool {
    matches!(c as u32,
        0x0483..=0x0489 | 0x0591..=0x05BD | 0x0610..=0x061A | 0x064B..=0x065F | 0x0670
        | 0x06D6..=0x06DC | 0x0900..=0x0903 | 0x093A..=0x094F | 0x0951..=0x0957
        | 0x0962..=0x0963 | 0x0981..=0x0983 | 0x09BC..=0x09D7 | 0x0E31 | 0x0E34..=0x0E3A
        | 0x0E47..=0x0E4E | 0x1160..=0x11FF | 0x302A..=0x302F | 0x3099..=0x309A)
}

/// The refusal when typing stopped part way because the app became primed.
pub fn partial_typing_refusal(sent: usize, total: usize, why: &str) -> String {
    if sent == 0 {
        why.to_string()
    } else {
        format!("{why} (the first {sent} of {total} characters were typed before it)")
    }
}

/// What a pid-routed mouse event carries to reach its window: the window
/// number (field 51) and the point inside the window (top-left origin),
/// when the window's origin is known. AppKit drops a posted mouse event
/// without both.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PidMouseStamp {
    pub window_number: i64,
    pub local: Option<Point>,
}

pub fn pid_mouse_stamp(window: u32, at: Point, origin: Option<Point>) -> PidMouseStamp {
    PidMouseStamp {
        window_number: i64::from(window),
        local: origin.map(|o| Point { x: at.x - o.x, y: at.y - o.y }),
    }
}

/// Points along a drag, excluding `from` and including `to`: one per ~8
/// points of distance, at least 4 and at most 60.
pub fn drag_path(from: Point, to: Point) -> Vec<Point> {
    let distance = ((to.x - from.x).powi(2) + (to.y - from.y).powi(2)).sqrt();
    let steps = ((distance / 8.0).ceil() as usize).clamp(4, 60);
    (1..=steps)
        .map(|i| {
            let t = i as f64 / steps as f64;
            Point { x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t }
        })
        .collect()
}

/// Pixels per point of a captured image of a `points`-wide area.
pub fn scale_of(pixels: usize, points: f64) -> f64 {
    if points <= 0.0 { 1.0 } else { pixels as f64 / points }
}

/// Lines to scroll-wheel deltas: CG's positive wheel moves content toward
/// the top (scrolls up), so `dy > 0` (down) is a negative wheel. A nonzero
/// fraction rounds away from zero to at least one line.
pub fn wheel_deltas(dx: f64, dy: f64) -> (i32, i32) {
    let lines = |v: f64| -> i32 {
        if v == 0.0 || !v.is_finite() {
            0
        } else {
            let r = v.abs().ceil().min(10_000.0) as i32;
            if v > 0.0 { r } else { -r }
        }
    };
    (-lines(dy), -lines(dx))
}

/// Element ids: `<generation>.<index>`.
pub fn element_id(generation: u64, index: usize) -> String {
    format!("{generation}.{index}")
}

pub fn parse_element_id(id: &str) -> Option<(u64, usize)> {
    let (g, i) = id.trim().split_once('.')?;
    Some((g.parse().ok()?, i.parse().ok()?))
}

/// The number `value` asks a stepping element for: its own unit ("0.25",
/// "12") or a percentage of its range ("25%"). None for anything else.
pub fn step_target(value: &str, min: f64, max: f64) -> Option<f64> {
    let text = value.trim();
    let target = if let Some(percent) = text.strip_suffix('%') {
        let p: f64 = percent.trim().parse().ok()?;
        min + (max - min) * p / 100.0
    } else {
        text.parse().ok()?
    };
    target.is_finite().then(|| target.clamp(min.min(max), max.max(min)))
}

/// Whether a stepped value is as close to the target as one step allows:
/// within 2% of the range.
pub fn step_reached(read: f64, target: f64, min: f64, max: f64) -> bool {
    (read - target).abs() <= ((max - min).abs() * 0.02).max(f64::EPSILON)
}

/// Where a menu item sits in an app's menu bar, for the deny list. Built from
/// structure, never from titles, so it holds in every language.
#[derive(Clone, Debug, Default)]
pub struct MenuItemContext<'a> {
    /// The item's title.
    pub title: &'a str,
    /// Index of the menu bar item it is under (0: the Apple menu, 1: the
    /// app's own menu, which holds Services).
    pub top_index: Option<usize>,
    /// How many menus it is inside: 1 for an item of a menu bar menu, 2 or
    /// more inside a submenu.
    pub depth: usize,
    /// The titles of the items in the same menu (the item's own included).
    pub siblings: &'a [String],
    /// Whether its menu is a launch list by its items, when the caller
    /// worked that out once for the whole menu (else from `siblings`).
    pub launch: Option<bool>,
}

/// An item title as an app name: without a trailing "…" or "...", and
/// without a trailing " (…)" ("TextEdit (default)"). The second value says
/// whether that suffix was a version ("Xcode (16.4)"), which names one of
/// several installed copies.
pub fn menu_app_name(title: &str) -> (&str, bool) {
    let mut t = title.trim();
    t = t.strip_suffix('\u{2026}').or_else(|| t.strip_suffix("...")).unwrap_or(t).trim_end();
    if t.ends_with(')')
        && let Some(i) = t.rfind(" (")
    {
        let inner = &t[i + 2..t.len() - 1];
        let version = !inner.is_empty() && inner.chars().all(|c| c.is_ascii_digit() || c == '.');
        return (t[..i].trim_end(), version);
    }
    (t, false)
}

/// The app names a menu item title could start with: the whole title, and
/// the title cut at each "…", "...", ", ", " (" and " – " (one to four
/// candidates, longest first, each trimmed).
pub fn menu_name_candidates(title: &str) -> Vec<&str> {
    let t = title.trim();
    let mut out = vec![menu_app_name(t).0];
    for sep in ["\u{2026}", "...", ", ", " (", " \u{2013} ", " - "] {
        if let Some(i) = t.find(sep) {
            let head = menu_app_name(&t[..i]).0;
            if !head.is_empty() && !out.contains(&head) {
                out.push(head);
            }
        }
    }
    out
}

/// What a key does while a menu this desktop left open shows in its app.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpenMenuKey {
    /// Escape: close the menu (through accessibility).
    Close,
    /// A bare arrow: it only moves the highlight.
    Post,
    /// Anything else could run or type-select an item, a hidden one too.
    Refuse,
}

pub fn key_with_open_menu(combo: &crate::keys::KeyCombo) -> OpenMenuKey {
    use crate::keys::Key;
    if !combo.modifiers.is_empty() {
        return OpenMenuKey::Refuse;
    }
    match combo.key {
        Key::Escape => OpenMenuKey::Close,
        Key::Up | Key::Down | Key::Left | Key::Right => OpenMenuKey::Post,
        _ => OpenMenuKey::Refuse,
    }
}

/// A submenu title as [`super::workspace::launch_submenu_titles`] keeps it:
/// trimmed, lower case, no trailing ellipsis, no-break spaces as spaces.
pub fn submenu_title_key(title: &str) -> String {
    let t = title.replace('\u{a0}', " ");
    let t = t.trim();
    let t = t.strip_suffix('\u{2026}').or_else(|| t.strip_suffix("...")).unwrap_or(t);
    t.trim().to_lowercase()
}

/// Whether an item of a menu the desktop opened (a context menu, a pop-up)
/// sits in a launch list: some item above it is titled as one of AppKit's
/// launch submenus (Services, Quick Actions, Share, Open With, Recent
/// Items, in any language). `path` is None when a title above it could not
/// be read: that counts as a launch list (fail closed).
pub fn in_opened_launch_list(path: Option<&[String]>, launch_titles: &[String]) -> bool {
    match path {
        None => true,
        Some(path) => path.iter().any(|p| launch_titles.contains(&submenu_title_key(p))),
    }
}

/// Whether a submenu is a launch list: under the Apple menu (Recent Items:
/// apps, documents, servers) or the app menu (Services), or one where most
/// items name installed apps (Open With in any app and any language).
pub fn is_launch_list(
    ctx: &MenuItemContext,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> bool {
    if ctx.depth < 2 {
        return false;
    }
    if matches!(ctx.top_index, Some(0 | 1)) {
        return true;
    }
    if let Some(launch) = ctx.launch {
        return launch;
    }
    siblings_name_apps(ctx.siblings, resolve)
}

/// Whether a menu counts as a launch list by its items: by what its titles
/// name, or, when a title could not be read (unknown siblings), whenever
/// something is denied (fail closed: the rule then wants an item to name an
/// allowed app). Pure, for tests.
pub fn launch_by_items(
    titles: Option<&[String]>,
    denies_any: bool,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> bool {
    match titles {
        Some(t) => siblings_name_apps(t, resolve),
        None => denies_any,
    }
}

/// Whether most of a menu's items name installed apps (Open With in any
/// app and any language): once per menu.
pub fn siblings_name_apps(
    siblings: &[String],
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> bool {
    let named: Vec<&String> = siblings.iter().filter(|t| !t.trim().is_empty()).collect();
    let apps = named
        .iter()
        .filter(|t| resolve(menu_app_name(t).0).is_some_and(|ids| !ids.is_empty()))
        .count();
    named.len() >= 2 && apps * 2 >= named.len()
}

/// Whether the deny list hides and refuses a menu item. `resolve` gives the
/// bundle ids of every installed app with a display name (in any language),
/// several for a shared name, none for an unknown one.
/// - In any menu, an item whose title names an app is blocked when any app
///   of that name is denied or protected ("System Settings…", "Terminal",
///   "Benutzte Objekte > Terminal").
/// - In a launch list (Recent Items, Services, Open With), while any app is
///   denied, an item that names no app, names it only by version, or is a
///   document or service is blocked too: it could reach a denied app.
pub fn menu_item_blocked(
    guard: &dyn crate::desktop::MenuGuard,
    ctx: &MenuItemContext,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> bool {
    menu_item_check(guard, ctx, resolve) != ItemCheck::Allowed
}

/// What [`menu_item_blocked`] decided, and why.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ItemCheck {
    Allowed,
    /// It reaches a denied or protected app.
    Blocked,
    /// A name it shows could not be resolved yet (the app names are still
    /// loading): blocked, and a refusal says the names are loading.
    Unknown,
    /// Its place in the menus could not be read while something is denied:
    /// blocked, and a refusal says an item above it cannot be read.
    Unplaced,
}

/// [`menu_item_blocked`], telling a real block from a name not resolved yet.
pub fn menu_item_check(
    guard: &dyn crate::desktop::MenuGuard,
    ctx: &MenuItemContext,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> ItemCheck {
    let (name, version) = menu_app_name(ctx.title);
    if name.is_empty() {
        return ItemCheck::Allowed;
    }
    // Menus add text after an app's name ("System Settings…, 1 update"):
    // every leading part of the title is checked, so none hides an app.
    for candidate in menu_name_candidates(ctx.title) {
        if guard.app_blocked("", candidate) {
            return ItemCheck::Blocked;
        }
        match resolve(candidate) {
            // The name cannot be resolved yet: fail closed (the protected
            // apps always apply, whatever the deny list).
            None => return ItemCheck::Unknown,
            Some(ids) if ids.iter().any(|id| guard.app_blocked(id, candidate)) => {
                return ItemCheck::Blocked;
            }
            Some(_) => {}
        }
    }
    let ids = resolve(name).unwrap_or_default();
    if guard.denies_any()
        && is_launch_list(ctx, resolve)
        && (ids.is_empty() || version || ids.len() > 1)
    {
        ItemCheck::Blocked
    } else {
        ItemCheck::Allowed
    }
}

/// The refusal a chord gets: when the menu item that blocks it is blocked
/// only because a name it shows could not be resolved yet, it says the
/// names are loading, not "the deny list"; a real block keeps its refusal.
/// Pure, for tests.
pub fn loading_instead(why: &str, blocked_unknown: bool) -> Option<&'static str> {
    (why == REFUSE_BLOCKED && blocked_unknown).then_some(crate::menus::APP_NAMES_LOADING)
}

/// Why pressing a menu-bar element is refused, if it is: one that opens a
/// submenu would open a menu over the person's screen.
pub fn submenu_refusal(role: &str, has_submenu: bool) -> Option<&'static str> {
    (role == "AXMenuItem" && has_submenu).then_some(
        "this menu item opens a submenu; press one of the submenu's items (they are in the tree under it)",
    )
}

/// A key-equivalent match found while searching the menus in AppKit's order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShortcutMatch {
    pub title: String,
    pub enabled: bool,
    pub blocked: bool,
    /// Its title was read and held to the deny list and the protected apps.
    /// An unchecked match (its title could not be read) is blocked while
    /// something is denied; with nothing denied it is never pressed and the
    /// key is posted, as Codex does (a posted chord does not leave a menu
    /// under the person's keys).
    pub checked: bool,
    /// It is blocked only because a name it shows could not be resolved yet
    /// (the app names are still loading).
    pub unknown: bool,
    /// It is blocked because an item above it could not be read.
    pub unplaced: bool,
}

/// What a shortcut does, given its matches in menu order (depth-first).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ShortcutPick {
    /// Press the match at this index.
    Press(usize),
    /// The first enabled match is blocked: AppKit would run it, so nothing runs.
    Blocked(String),
    /// Only disabled matches.
    Disabled(String),
    /// No match.
    None,
}

/// AppKit runs the first enabled item with the key equivalent; disabled
/// ones are passed over. A blocked first enabled match refuses the shortcut
/// (a later item must not run in its place).
pub fn pick_shortcut(matches: &[ShortcutMatch]) -> ShortcutPick {
    if let Some((i, m)) = matches.iter().enumerate().find(|(_, m)| m.enabled) {
        return if m.blocked {
            ShortcutPick::Blocked(m.title.clone())
        } else {
            ShortcutPick::Press(i)
        };
    }
    match matches.first() {
        Some(m) => ShortcutPick::Disabled(m.title.clone()),
        None => ShortcutPick::None,
    }
}

/// Every value of each NSKeyEquivalent dictionary in `pbs -dump` output
/// (default and localized ones), keeping those that are a key equivalent:
/// modifier marks ($ ^ ~ @) and one key, which may be a function-key
/// character such as \Uf704 (written that way in the dump).
pub fn service_equivalents(dump: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = dump;
    while let Some(i) = rest.find("NSKeyEquivalent") {
        rest = &rest[i + "NSKeyEquivalent".len()..];
        let after = rest.trim_start();
        let Some(after) = after.strip_prefix('=') else { continue };
        let after = after.trim_start();
        // Only a dictionary value: "{ ... }".
        let Some(body_start) = after.strip_prefix('{') else { continue };
        let (values, consumed) = dump_dict_values(body_start);
        for value in values {
            if is_key_equivalent(&value) && !out.contains(&value) {
                out.push(value);
            }
        }
        rest = &body_start[consumed..];
    }
    out
}

/// The values of one old-style plist dictionary body (after its "{"), with
/// quoted strings read whole (";", "}" and escapes inside them), and how
/// many bytes it took up to and including the closing "}".
fn dump_dict_values(body: &str) -> (Vec<String>, usize) {
    let mut values = Vec::new();
    let mut in_value = false;
    // An unquoted value's text, trimmed when stored.
    let mut bare = String::new();
    // A quoted value, verbatim (spaces, \t and \r are keys).
    let mut quoted: Option<String> = None;
    let mut chars = body.char_indices();
    let take = |bare: &mut String, quoted: &mut Option<String>, values: &mut Vec<String>| {
        match quoted.take() {
            Some(q) => values.push(q),
            None if !bare.trim().is_empty() => values.push(bare.trim().to_string()),
            None => {}
        }
        bare.clear();
    };
    while let Some((i, c)) = chars.next() {
        match c {
            '"' => {
                let mut q = String::new();
                while let Some((_, ch)) = chars.next() {
                    match ch {
                        '\\' => match chars.next().map(|(_, e)| e) {
                            Some('"') => q.push('"'),
                            Some('\\') => q.push('\\'),
                            Some('n') => q.push('\n'),
                            Some('t') => q.push('\t'),
                            Some('a') => q.push('\u{7}'),
                            Some('b') => q.push('\u{8}'),
                            Some('f') => q.push('\u{c}'),
                            Some('r') => q.push('\r'),
                            Some('v') => q.push('\u{b}'),
                            Some('U') => {
                                let hex: String = chars.clone().take(4).map(|(_, h)| h).collect();
                                match u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32) {
                                    Some(x) if hex.len() == 4 => {
                                        q.push(x);
                                        for _ in 0..4 {
                                            chars.next();
                                        }
                                    }
                                    _ => q.push('U'),
                                }
                            }
                            Some(d @ '0'..='7') => {
                                let mut n = d.to_digit(8).unwrap_or(0);
                                for _ in 0..2 {
                                    match chars.clone().next() {
                                        Some((_, o @ '0'..='7')) => {
                                            n = n * 8 + o.to_digit(8).unwrap_or(0);
                                            chars.next();
                                        }
                                        _ => break,
                                    }
                                }
                                if let Some(x) = char::from_u32(n) {
                                    q.push(x);
                                }
                            }
                            Some(other) => q.push(other),
                            None => {}
                        },
                        '"' => break,
                        other => q.push(other),
                    }
                }
                if in_value {
                    quoted = Some(q);
                }
            }
            '=' => {
                in_value = true;
                bare.clear();
                quoted = None;
            }
            ';' => {
                if in_value {
                    take(&mut bare, &mut quoted, &mut values);
                }
                in_value = false;
                bare.clear();
            }
            '}' => {
                // A last entry may have no trailing ";".
                if in_value {
                    take(&mut bare, &mut quoted, &mut values);
                }
                return (values, i + 1);
            }
            other => {
                if quoted.is_none() {
                    bare.push(other);
                }
            }
        }
    }
    (values, body.len())
}

/// Modifier marks and exactly one key. When every character is a mark
/// ("@$"), the last one is the key ("$" with Command).
pub fn is_key_equivalent(value: &str) -> bool {
    let keys = value.chars().filter(|c| !matches!(c, '$' | '^' | '~' | '@')).count();
    // One key; or marks only, the last being the key (a single "@" is the
    // "@" key, Command implied).
    keys == 1 || (keys == 0 && !value.is_empty())
}

/// Whether background keys may go to the target window: it is the key
/// window, or the app's only standard window while no other unminimized
/// window (a dialog, a panel) is the key window.
pub fn keys_reach_target(
    is_key: bool,
    standard_windows: usize,
    target_is_standard: bool,
    other_key_window: bool,
) -> bool {
    is_key || (standard_windows <= 1 && target_is_standard && !other_key_window)
}

/// The app's focused text element when it sits in no window of its own: an
/// inline editor (Finder's rename field, a table cell being edited) that
/// AppKit draws as a small window of its own over its window. Measured with
/// Finder on macOS 27.0: while the rename field is open the app reports no
/// focused window, its main window is the Finder window, its windows list
/// the text field itself (role AXTextField, parent the app, a CG window of
/// its own), and keys posted to the app go into the field.
#[derive(Clone, Debug, PartialEq)]
pub struct OverlayEditor {
    /// The focused element's role.
    pub role: String,
    /// Whether its AXWindow names a window other than the target.
    pub in_other_window: bool,
    /// Its frame (global points), if it could be read.
    pub frame: Option<Rect>,
}

/// Whether background keys meant for `target` go to an inline editor lying
/// over it, which is where the person's keys would go: the app has no
/// focused window (the editor took it), its main window is the target, and
/// the focused element is a text input in no other window whose frame lies
/// inside the target's. A sheet, an alert or another document's window as
/// focused window never passes (those are the cases the key-window rule
/// guards).
pub fn keys_reach_overlay_editor(
    focused_window_present: bool,
    main_is_target: bool,
    editor: Option<&OverlayEditor>,
    target: &Rect,
) -> bool {
    let Some(editor) = editor else { return false };
    !focused_window_present
        && main_is_target
        && is_text_input(&editor.role)
        && !editor.in_other_window
        && editor.frame.as_ref().is_some_and(|f| rect_within(f, target))
}

/// Whether `inner` lies inside `outer` (one point of slack for rounding),
/// and is smaller than it (an editor, not a second window over it).
pub fn rect_within(inner: &Rect, outer: &Rect) -> bool {
    const SLACK: f64 = 1.0;
    inner.width > 0.0
        && inner.height > 0.0
        && inner.x >= outer.x - SLACK
        && inner.y >= outer.y - SLACK
        && inner.x + inner.width <= outer.x + outer.width + SLACK
        && inner.y + inner.height <= outer.y + outer.height + SLACK
        && inner.width * inner.height < outer.width * outer.height
}

/// The answer for a window id that names an inline editor (see
/// [`OverlayEditor`]) instead of a window: where keys for it go.
pub fn overlay_editor_window_hint(id: u32, role: &str, over: Option<u32>) -> String {
    // "AXTextField" -> "text field".
    let mut what = String::new();
    for c in role.strip_prefix("AX").unwrap_or(role).chars() {
        if c.is_uppercase() && !what.is_empty() {
            what.push(' ');
        }
        what.extend(c.to_lowercase());
    }
    match over {
        Some(over) => format!(
            "window {id} is an inline editor (a {what} the app draws over window {over}), not a window of its own; it has the app's keyboard focus, so type_text or press_key with window_id {over} type into it (Return applies it, Escape cancels it)"
        ),
        None => format!(
            "window {id} is an inline editor (a {what} the app draws over one of its windows), not a window of its own; type_text or press_key on the window it lies over type into it"
        ),
    }
}

/// Whether set_value gives a native text field the focus before writing
/// it. An AppKit field that is not being edited takes an AXValue write as
/// its text, but the app's end-of-editing handler never runs, so a value
/// the app applies when editing ends (Finder's Get Info name) is never
/// applied, and even AXConfirm afterwards does nothing; measured on macOS
/// 27.0. Focused first, the write lands in the field's editor, and
/// AXConfirm, Return or Tab then applies it. Never in web content (its own
/// focus rule), never in the person's app (it would move their caret), only
/// for a field that is not focused and offers AXConfirm.
pub fn focus_before_value_write(
    role: &str,
    web: bool,
    persons_app: bool,
    focused: Option<bool>,
    has_confirm: bool,
) -> bool {
    !web && !persons_app && role == "AXTextField" && focused == Some(false) && has_confirm
}

/// The note when set_value focused the field first.
pub const FOCUSED_FOR_EDIT: &str = "the field was given focus first, so it is being edited with the value; an app that applies a field only when editing ends (a name in a Get Info window, a setting) applies it on perform_action confirm on the field, or press_key Tab";

/// One step of stepping a value toward `target`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Step {
    /// Keep stepping from `next`.
    Continue,
    /// The value did not move: the end of the range.
    AtEnd,
    /// The step passed the target; `back` says whether to step back (the
    /// previous value was nearer).
    Passed { back: bool },
    /// The step moved away from the target.
    Away,
}

pub fn step_outcome(current: f64, next: f64, target: f64, going_up: bool) -> Step {
    if (next - current).abs() < f64::EPSILON {
        return Step::AtEnd;
    }
    if (next > current) != going_up {
        return Step::Away;
    }
    let passed = if going_up { next > target } else { next < target };
    if passed {
        return Step::Passed { back: (next - target).abs() > (current - target).abs() };
    }
    Step::Continue
}

/// Whether a stepped value is reported confirmed: the stepping ended on its
/// own (not at the step cap) within one step of the target.
pub fn step_confirmed(capped: bool, read: f64, target: f64, min: f64, max: f64) -> bool {
    !capped && step_reached(read, target, min, max)
}

/// One node kept by [`breadth_first`] and its parent's slot.
pub struct BfsSlot<N> {
    pub node: N,
    pub parent: Option<usize>,
}

/// Breadth-first from `root`, keeping at most `budget` nodes and not
/// expanding below `max_depth` levels. `visit` returns a node's children
/// (kept) or None (left out with everything under it). The bool says whether
/// the budget or the depth cut the walk short.
pub fn breadth_first<N>(
    root: N,
    budget: usize,
    max_depth: usize,
    mut visit: impl FnMut(&N, usize) -> Option<Vec<N>>,
) -> (Vec<BfsSlot<N>>, bool) {
    let mut slots: Vec<BfsSlot<N>> = Vec::new();
    let mut truncated = false;
    let mut queue = std::collections::VecDeque::new();
    queue.push_back((root, None::<usize>, 0usize));
    while let Some((node, parent, depth)) = queue.pop_front() {
        if slots.len() >= budget {
            truncated = true;
            break;
        }
        let Some(children) = visit(&node, depth) else { continue };
        let slot = slots.len();
        slots.push(BfsSlot { node, parent });
        if children.is_empty() {
            continue;
        }
        if depth + 1 >= max_depth {
            truncated = true;
            continue;
        }
        for child in children {
            queue.push_back((child, Some(slot), depth + 1));
        }
    }
    (slots, truncated)
}

/// How much of the ANSI key codes in keymap.rs a keyboard layout keeps.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layout {
    /// Every character key (U.S., ABC and their variants).
    Ansi,
    /// The letters and the unshifted digits; punctuation and the shifted
    /// digits differ (British: Shift-3 is £, # is Option-3).
    LettersDigits,
    /// Unknown, or letters elsewhere (German, French, Dvorak).
    Other,
}

/// The layout from its input source ID. With no current layout recorded,
/// only a default install (no enabled input sources recorded either) counts
/// as U.S.; anything else is unknown and fails closed.
pub fn layout_of(input_source_id: Option<&str>, enabled_sources_recorded: bool) -> Layout {
    match input_source_id {
        None if !enabled_sources_recorded => Layout::Ansi,
        None => Layout::Other,
        Some(
            "com.apple.keylayout.US"
            | "com.apple.keylayout.ABC"
            | "com.apple.keylayout.USExtended"
            | "com.apple.keylayout.USInternational-PC"
            | "com.apple.keylayout.Australian"
            | "com.apple.keylayout.Canadian",
        ) => Layout::Ansi,
        Some(
            "com.apple.keylayout.British"
            | "com.apple.keylayout.British-PC"
            | "com.apple.keylayout.Irish"
            | "com.apple.keylayout.IrishExtended",
        ) => Layout::LettersDigits,
        Some(_) => Layout::Other,
    }
}

/// One entry of HIToolbox's `AppleSelectedInputSources` or
/// `AppleEnabledInputSources`: its `InputSourceKind` and, for a keyboard
/// layout, its `KeyboardLayout Name`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct InputSourceEntry {
    pub kind: Option<String>,
    pub layout_name: Option<String>,
}

/// The current keyboard layout's input source ID when HIToolbox recorded no
/// `AppleCurrentKeyboardLayoutInputSourceID` (macOS writes that key only after
/// a layout switch, so a Mac that was never switched has none): the one
/// keyboard layout among the selected sources, else the one enabled layout
/// (the only one, so the current one). None, which fails closed, when either
/// list holds an input method (it can translate keys its own way) or the
/// chosen list holds more than one layout. Only the layout's name is known
/// here; a name that is not its ID's last part (`U.S.` is `US`) makes an ID
/// `layout_of` does not know, so it fails closed too.
pub fn layout_id_from_sources(
    selected: &[InputSourceEntry],
    enabled: &[InputSourceEntry],
) -> Option<String> {
    let layout = |e: &InputSourceEntry| e.kind.as_deref() == Some("Keyboard Layout");
    // Emoji & Symbols and other palettes do not type keys.
    let method =
        |e: &InputSourceEntry| !layout(e) && e.kind.as_deref() != Some("Non Keyboard Input Method");
    if selected.iter().chain(enabled).any(method) {
        return None;
    }
    let list = if selected.iter().any(layout) { selected } else { enabled };
    let mut layouts = list.iter().filter(|e| layout(e));
    let only = layouts.next()?;
    if layouts.next().is_some() {
        return None;
    }
    let name = only.layout_name.as_deref()?;
    let id = match name {
        "U.S." => "US",
        other => other,
    };
    Some(format!("com.apple.keylayout.{id}"))
}

/// Whether the Services check can place `key` on `layout`: arrows, function
/// keys, Return, Tab, Space, Escape, Delete and the navigation keys have the
/// same codes on every layout; letters and unshifted digits need their ANSI
/// positions; other characters need the whole ANSI layout.
pub fn layout_places(key: &crate::keys::Key, shift: bool, layout: Layout) -> bool {
    use crate::keys::Key;
    match key {
        Key::Char(c) if c.is_ascii_alphabetic() => layout != Layout::Other,
        Key::Char(c) if c.is_ascii_digit() => {
            layout == Layout::Ansi || (layout == Layout::LettersDigits && !shift)
        }
        Key::Char(_) => layout == Layout::Ansi,
        _ => true,
    }
}

/// What to do with a key chord (any with Command, Control or Option, or a
/// function key) after the menu search, for either delivery.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChordAction {
    /// Press the matched menu item (its index) through AX; no key is posted.
    PressItem(usize),
    /// Post the chord as key events.
    Post,
    /// Refuse, with why.
    Refuse(&'static str),
}

/// Facts the chord decision needs (the menu search, the deny list, the
/// keyboard layout and the Services shortcuts), so it is one tested place.
/// The layout and Services facts are read only when the rule gets to them
/// (`needs_key_checks`).
#[derive(Clone, Debug)]
pub struct ChordFacts<'a> {
    /// Matches in menu order: every one in the foreground, up to and
    /// including the first enabled one in the background.
    pub matches: &'a [ShortcutMatch],
    /// The menu search saw every item (no AX error, no branch cut).
    pub complete: bool,
    pub background: bool,
    pub denies_any: bool,
    /// The Services check can place this chord's key on the current layout
    /// (`layout_places`).
    pub layout_known: bool,
    /// Whether the chord is a registered Services shortcut.
    pub is_service: ServiceCheck,
}

pub const REFUSE_TOO_DEEP: &str = "this app's menus could not all be read to check this shortcut against the Computer Use deny list; use the app's menu items in the tree";
pub const REFUSE_LAYOUT: &str = "this shortcut cannot be checked against the Computer Use deny list on this keyboard layout; use the app's menu items in the tree";
pub const REFUSE_SERVICES_UNREAD: &str = "the Services shortcuts could not be read yet; try again in a moment, or use the app's menu items in the tree";
pub const REFUSE_SERVICE: &str = "this shortcut runs a Service, which can hand the selection to an app on the Computer Use deny list; use the app's menu items in the tree";
pub const REFUSE_BLOCKED: &str =
    "the menu item for this shortcut would reach an app on the Computer Use deny list";

/// AppKit's routing, held to the deny list. AppKit offers a key to the key
/// view's performKeyEquivalent first (web content, editors), then to the
/// menus (the first enabled item with the equivalent, revalidated at key
/// time), then to Services. A posted chord keeps its Shift on every route
/// (see press_keys).
/// - Foreground: post the key, as the person's key would go, when posting is
///   safe: no match is blocked and, while something is denied, the walk was
///   complete, the layout places the key and no Services shortcut has it.
///   Otherwise fall through to the rules below, which press the app's item
///   instead when one can be pressed (so a Service on the same chord cannot
///   run).
/// - The first enabled match is not blocked: press that item through AX
///   (disabled matches before it, blocked or not, do not run). No key is
///   posted, so no Service, other item or key-time revalidation can take it.
///   The background always does this: a background window's key view does
///   not handle key equivalents the way the key window's does.
/// - The first enabled match is blocked: refuse.
/// - No enabled match, but a disabled one is blocked: refuse (it may be
///   revalidated at key time). This holds with nothing denied too (protected
///   apps: sign-in, security prompts, cmux Remote).
/// - Otherwise the key is posted: as typed with nothing denied; while
///   something is denied only after a complete walk, when the layout places
///   the key, and when it is no Services shortcut (read).
///
/// With nothing denied an incomplete walk is posted: what it may miss is a
/// protected app's item (sign-in, security prompts, cmux Remote) deep in a
/// menu with a key equivalent of its own; none is known, and refusing would
/// refuse every unmatched chord in an app with deep menus.
pub fn decide_chord(f: &ChordFacts) -> ChordAction {
    let any_blocked = f.matches.iter().any(|m| m.blocked);
    let checks_pass = |f: &ChordFacts| {
        !f.denies_any || (f.complete && f.layout_known && f.is_service == ServiceCheck::NoMatch)
    };
    if !f.background && !any_blocked && checks_pass(f) {
        return ChordAction::Post;
    }
    match pick_shortcut(f.matches) {
        ShortcutPick::Press(i) if !f.matches[i].checked => return ChordAction::Post,
        ShortcutPick::Press(i) => return ChordAction::PressItem(i),
        ShortcutPick::Blocked(_) => return ChordAction::Refuse(REFUSE_BLOCKED),
        ShortcutPick::Disabled(_) | ShortcutPick::None => {}
    }
    if any_blocked {
        return ChordAction::Refuse(REFUSE_BLOCKED);
    }
    if !f.denies_any {
        return ChordAction::Post;
    }
    if !f.complete {
        return ChordAction::Refuse(REFUSE_TOO_DEEP);
    }
    if !f.layout_known {
        return ChordAction::Refuse(REFUSE_LAYOUT);
    }
    match f.is_service {
        ServiceCheck::Unread => ChordAction::Refuse(REFUSE_SERVICES_UNREAD),
        ServiceCheck::Match => ChordAction::Refuse(REFUSE_SERVICE),
        ServiceCheck::NoMatch => ChordAction::Post,
    }
}

/// Whether a background chord's menu matches need the app to validate its
/// menus first: there are matches, none is blocked and none is enabled (an
/// app with no key window disables every item that acts on one).
pub fn needs_menu_validation(matches: &[ShortcutMatch]) -> bool {
    !matches.is_empty() && !matches.iter().any(|m| m.blocked || m.enabled)
}

/// Whether the rule reads the layout and the Services shortcuts: while
/// something is denied and no match is blocked, for a foreground chord
/// (which is posted when they pass) and for a background one with no
/// enabled match (pressed otherwise).
pub fn needs_key_checks(matches: &[ShortcutMatch], denies_any: bool, background: bool) -> bool {
    denies_any
        && !matches.iter().any(|m| m.blocked)
        && (!background || !matches.iter().any(|m| m.enabled))
}

/// Whether a chord is a Services shortcut.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ServiceCheck {
    NoMatch,
    Match,
    /// The Services shortcuts have not been read.
    Unread,
}
