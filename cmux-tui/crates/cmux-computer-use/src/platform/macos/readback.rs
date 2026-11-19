//! Read-backs the engine does once an action settled
//! ([`crate::desktop::ActionOutcome::expect`]): posted keys and scroll
//! events land a little after they are posted, and an effect read back at
//! once can still be undone by the app a moment later (a field that
//! reformats or rejects a value, a list that reselects), so every confirmed
//! result is read again after the settle too.
//!
//! Two rules hold for every check, by construction:
//! - A check is built only from a baseline read before the action that
//!   succeeded ([`Check`]'s constructors return `None` otherwise): a failed
//!   read is never taken for "empty", "false" or "not there".
//! - A check states the intended change ([`Check::change`]: before ->
//!   wanted). One whose wanted state already held before the action says so
//!   (`before == wanted`), and the engine never confirms it.
//!
//! Every attribute read here is strict (`Ax::try_*`, which tell a failed
//! read from no value); a guard test refuses the lossy readers in this file.

use std::collections::VecDeque;

use super::ax::Ax;
use super::sys::{AXError, CFRange};
use crate::desktop::Expect;

/// Read-backs kept at most (the engine reads each one after its action, a
/// batch's after the batch: up to its 20 steps; older ones are dropped).
const KEPT: usize = 24;

/// How far up from the element under a scroll the scroll area is looked for.
const SCROLL_AREA_DEPTH: usize = 12;

/// Rows read at most from one list (a pre-read on a larger list is skipped).
pub(super) const ROWS_MAX: usize = 500;

/// How deep and how many elements a window walk for sheets, popovers and
/// texts reads.
const WALK_DEPTH: usize = 12;
const WALK_MAX: usize = 400;

/// A string attribute read: `Ok(value)` (None: no value), `Err` when the
/// read failed.
pub(super) type Read = Result<Option<String>, AXError>;

/// Reads a string attribute, telling a failed read apart from no value.
pub(super) fn read_str(el: &Ax, name: &str) -> Read {
    el.try_string(name)
}

/// Every read succeeded: their values; any failed: `None`.
pub(super) fn all_known<T>(reads: impl IntoIterator<Item = Result<T, AXError>>) -> Option<Vec<T>> {
    reads.into_iter().collect::<Result<Vec<T>, AXError>>().ok()
}

/// A baseline read strictly before the action. Only this module can make
/// one (its field is private), from a strict read that succeeded, so a
/// constructor that takes it cannot be handed a guess.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Known<T>(T);

impl<T> Known<T> {
    /// From a strict read: `Some` only when it succeeded with a value.
    fn of(read: Result<Option<T>, AXError>) -> Option<Known<T>> {
        read.ok().flatten().map(Known)
    }
    pub(super) fn get(&self) -> &T {
        &self.0
    }
}

impl Known<String> {
    /// `el`'s value as text, read now. `None` when the read failed or the
    /// value is not text or a number (an element, a range: nothing a value
    /// read-back compares); no value at all reads as empty text.
    pub(super) fn value(el: &Ax) -> Option<Known<String>> {
        match el.attr("AXValue") {
            Ok(None) => Some(Known(String::new())),
            Ok(Some(v)) => super::ax::value_as_text(&v).map(Known),
            Err(_) => None,
        }
    }
}

impl Known<f64> {
    /// A number attribute of `el`, read now.
    pub(super) fn number(el: &Ax, name: &str) -> Option<Known<f64>> {
        Known::of(el.try_number(name))
    }
}

impl Known<Option<CFRange>> {
    /// `el`'s selected range, read now (none: `Known(None)`).
    pub(super) fn range(el: &Ax) -> Option<Known<Option<CFRange>>> {
        el.try_selected_range().ok().map(Known)
    }
}

/// What the action asked for, never a value read after it
/// ([`Wanted::from_request`]): the value requested, a direction, or only a
/// change (a toggle).
#[derive(Clone, Debug, PartialEq)]
pub(super) enum Wanted {
    /// The value the request names (the asked value, typed text joined in).
    Value(String),
    /// A number moving up (+1) or down (-1) from its value before.
    Direction(f64),
    /// Any other value than before (a toggle pressed).
    Other,
}

impl Wanted {
    /// The value a request asked for.
    pub(super) fn from_request(value: impl Into<String>) -> Wanted {
        Wanted::Value(value.into())
    }
}

/// How a read value is compared with a wanted one: as numbers within a
/// tolerance, only when the element's value is itself a number; otherwise
/// the text exactly (a ZIP field reading "00501" is not 501).
pub(super) type Tolerance = Option<f64>;

/// Whether `after` is what was wanted from `before` (`tolerance`: how far a
/// number may be from an asked one, e.g. one step of a stepper).
pub(super) fn wanted_reached(
    before: &str,
    after: &str,
    wanted: &Wanted,
    tolerance: Tolerance,
) -> bool {
    match wanted {
        Wanted::Value(v) => value_matches(after, v, tolerance),
        Wanted::Direction(sign) => {
            match (before.trim().parse::<f64>(), after.trim().parse::<f64>()) {
                (Ok(b), Ok(a)) => moved_toward(b, a, *sign),
                _ => false,
            }
        }
        Wanted::Other => after != before,
    }
}

/// One scroll bar of a scrolled view: its value before and the way it must
/// move (+1 toward the end: down or right; -1 toward the start).
pub(super) struct Bar {
    pub(super) el: Ax,
    pub(super) before: f64,
    pub(super) sign: f64,
}

/// A read-back. Build it with its constructors, before the action: each
/// reads its baseline strictly and returns `None` when it cannot.
pub(super) enum Check {
    /// `text` was typed into `el` whose value was `before` with the caret
    /// or selection at `at` (UTF-16): the text is now at that spot and the
    /// value grew by it, less what was selected. Without a caret: more of
    /// the text in the value than before.
    Text { el: Ax, before: String, text: String, at: Option<CFRange> },
    /// The scrolled view's bars moved the way the scroll asked (to `wanted`
    /// when the route planned it).
    Scroll { bars: Vec<Bar>, wanted: Option<Vec<f64>> },
    /// All of `el`'s `chars` characters selected; `before` was its range.
    SelectAll { el: Ax, before: CFRange, chars: usize },
    /// All of the list `el`'s rows selected; before, `selected` of `rows`.
    AllRows { el: Ax, selected: usize, rows: usize },
    /// `el`'s value went from `before` to what the request `wanted` (a
    /// number within `tolerance`).
    Value { el: Ax, before: String, wanted: Wanted, tolerance: Tolerance },
    /// `el`'s selected text range went from `before` to `range`.
    Range { el: Ax, before: Option<CFRange>, range: CFRange },
    /// `row` is selected, and the only one; `before`: it already was.
    Selected { row: Ax, list: Ax, before: bool },
    /// A secure field went from `before` to `count` characters.
    Length { el: Ax, before: f64, count: f64 },
    /// `el` shows `title` (a pop-up's item; any case); it showed `before`.
    Title { el: Ax, before: Option<String>, title: String },
    /// `el`'s boolean `attr` went from `before` to `value`.
    Bool { el: Ax, attr: String, before: Option<bool>, value: bool },
    /// The menu `el`, which this call opened, is still shown.
    Shown { el: Ax },
    /// A pressed menu item: its title or check mark changed from these (a
    /// toggle). Unchanged says nothing (most items do not toggle).
    MenuItem { el: Ax, title: Option<String>, mark: Option<String> },
    /// More sheets or popovers in window `win` than `before`.
    Opened { win: Ax, before: usize },
    /// The sheet `sheet` is gone from window `win` (its button closed it).
    Gone { sheet: Ax, win: Ax },
    /// The display of `texts` (values before) took the digit `ch`.
    EndsWith { texts: Vec<(Ax, Option<String>)>, ch: char },
    /// Any of these holds (only the ones that state a change count).
    Any(Vec<Check>),
    /// The document file `path` was written after `before` (its mtime) and,
    /// when the window reports it, its edited state is cleared.
    Saved { path: String, before: f64, win: Ax },
    /// The list `el` has one new row selected (not among `names`).
    NewRow { el: Ax, names: Vec<String> },
    /// Type-to-select in the list `el` picked a row starting with `typed`;
    /// `before`: the selected rows' names.
    TypeSelect { el: Ax, before: Vec<String>, typed: String },
    /// One of these lists (with its rows' names before) gained a row, and
    /// that new row is the one selected.
    RowsGrew { lists: Vec<(Ax, Vec<String>)> },
}

// ------------------------------------------------------------ strict reads

/// The window's elements, breadth first, bounded; `None` when a read of
/// the walk failed or it ran past its bound.
fn walk(win: &Ax) -> Option<Vec<(Ax, usize)>> {
    walk_with(win, |_| true)
}

/// Roles whose contents a list search does not enter: their rows are read
/// on their own ([`row_names`], counted with
/// `AXUIElementGetAttributeValueCount` and capped).
const LIST_ROLES: &[&str] = &["AXTable", "AXOutline", "AXList"];

/// Whether a list search walks into an element of `role` (not into a
/// list's rows and cells: a window's lists are found by their containers,
/// so a long list does not push the search past its bound).
pub(super) fn list_search_enters(role: Option<&str>) -> bool {
    !role.is_some_and(|r| LIST_ROLES.contains(&r))
}

/// [`walk`], entering an element's children only when `enter` says so of
/// its role (read strictly; a failed read ends the walk as unknown).
fn walk_with(win: &Ax, enter: impl Fn(Option<&str>) -> bool) -> Option<Vec<(Ax, usize)>> {
    let mut out = Vec::new();
    let mut queue = VecDeque::from([(win.clone(), 0usize)]);
    while let Some((el, depth)) = queue.pop_front() {
        // Past the bound the window is not all read: unknown, not "none".
        if out.len() >= WALK_MAX {
            return None;
        }
        let role = el.try_string("AXRole").ok()?;
        if depth < WALK_DEPTH && enter(role.as_deref()) {
            for c in el.try_elements("AXChildren").ok()? {
                queue.push_back((c, depth + 1));
            }
        }
        out.push((el, depth));
    }
    Some(out)
}

/// The elements of `win` with one of `roles`, with their role.
fn with_roles(win: &Ax, roles: &[&str]) -> Option<Vec<Ax>> {
    let nodes = walk(win)?;
    let roles_read = all_known(nodes.iter().map(|(el, _)| el.try_string("AXRole")))?;
    Some(
        nodes
            .into_iter()
            .zip(roles_read)
            .filter(|(_, r)| r.as_deref().is_some_and(|r| roles.contains(&r)))
            .map(|((el, _), _)| el)
            .collect(),
    )
}

/// Sheets and popovers open in `win` (its own and its descendants').
pub(super) fn overlays(win: &Ax) -> Option<usize> {
    Some(with_roles(win, &["AXSheet", "AXPopover"])?.len())
}

/// The lists, tables and outlines of a window, found without walking into
/// their rows (Notes' window has 708 elements, 45 outside its lists).
pub(super) fn lists_of(win: &Ax) -> Option<Vec<Ax>> {
    let nodes = walk_with(win, list_search_enters)?;
    let roles = all_known(nodes.iter().map(|(el, _)| el.try_string("AXRole")))?;
    Some(
        nodes
            .into_iter()
            .zip(roles)
            .filter(|(_, r)| r.as_deref().is_some_and(|r| LIST_ROLES.contains(&r)))
            .map(|((el, _), _)| el)
            .collect(),
    )
}

/// The static texts of `win` and their values.
fn texts(win: &Ax) -> Option<Vec<(Ax, Option<String>)>> {
    let els = with_roles(win, &["AXStaticText"])?;
    let values = all_known(els.iter().map(Ax::try_value_text))?;
    Some(els.into_iter().zip(values).collect())
}

/// A row's name: the first text or text field value (or title) in it.
/// `Some(None)`: the row has none; `None`: a read failed.
fn row_name(row: &Ax) -> Option<Option<String>> {
    for (el, _) in walk(row)? {
        let named = match el.try_string("AXRole").ok()?.as_deref() {
            Some("AXStaticText" | "AXTextField") => el.try_value_text().ok()?,
            Some("AXCell" | "AXRow") => None,
            _ => el.try_string("AXTitle").ok()?,
        };
        if let Some(name) = named.filter(|v| !v.is_empty()) {
            return Some(Some(name));
        }
    }
    Some(None)
}

/// The names of `list`'s rows (or of its selected rows): every row read,
/// or `None` (a failed read, or more than [`ROWS_MAX`] rows).
pub(super) fn row_names(list: &Ax, attr: &str) -> Option<Vec<String>> {
    if list.try_count(attr).ok()? > ROWS_MAX {
        return None;
    }
    let rows = list.try_elements(attr).ok()?;
    let names = all_known(rows.iter().map(|r| row_name(r).ok_or(super::sys::AX_CANNOT_COMPLETE)))?;
    // A row with no name counts, by an empty name.
    Some(names.into_iter().map(|n| n.unwrap_or_else(String::new)).collect())
}

/// Whether a window's document has unsaved edits: its close button's
/// `AXEdited` (AppKit sets it with the window's document-edited dot), else
/// the window's own. `Ok(None)`: not reported; `Err`: a read failed.
pub(super) fn edited(win: &Ax) -> Result<Option<bool>, AXError> {
    if let Some(close) = win.try_element("AXCloseButton")?
        && let Some(e) = close.try_bool("AXEdited")?
    {
        return Ok(Some(e));
    }
    win.try_bool("AXEdited")
}

/// A file's modification time (seconds), when it can be read.
pub(super) fn mtime(path: &str) -> Option<f64> {
    let t = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(t.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64())
}

/// The path of a window's document (`AXDocument`, a file URL).
fn document_path(win: &Ax) -> Option<String> {
    let url = win.try_string("AXDocument").ok()??;
    let path = url.strip_prefix("file://")?;
    Some(percent_decode(path))
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%'
            && i + 2 < b.len()
            && let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16)
        {
            out.push(v);
            i += 3;
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// How many characters a (secure) text field holds: its
/// `AXNumberOfCharacters`, else the length of a value it shows (bullets),
/// else where its caret ends (AppKit's secure field on macOS 27.0.1 reads
/// an empty value and no character count, but its selected range moves
/// with what is typed or set). `None`: a read failed or nothing tells.
pub(super) fn secure_count(el: &Ax) -> Option<f64> {
    if let Some(n) = el.try_number("AXNumberOfCharacters").ok()? {
        return Some(n);
    }
    if let Some(v) = el.try_value_text().ok()?.filter(|v| !v.is_empty()) {
        return Some(v.encode_utf16().count() as f64);
    }
    el.try_selected_range().ok()?.map(|r| (r.location + r.length) as f64)
}

/// The only selected row of its list, read strictly.
fn only_selected(row: &Ax, list: &Ax) -> Option<bool> {
    let selected = row.try_bool("AXSelected").ok()? == Some(true);
    let all = list.try_elements("AXSelectedRows").ok()?;
    Some(selected && all.len() == 1 && all[0].same(row))
}

// --------------------------------------------------------- pure decisions

/// Whether a menu item changed between two reads: only reads that both
/// succeeded are compared (a failed read is never a change).
pub(super) fn item_changed(before: &Read, after: &Read) -> bool {
    matches!((before, after), (Ok(b), Ok(a)) if a != b)
}

/// Whether a sheet is gone: its role read says the element no longer
/// exists, or it is no longer among its window's children. Any other
/// failed read says nothing.
pub(super) fn sheet_gone(role: &Read, among_children: Option<bool>) -> Option<bool> {
    match role {
        Err(e) if *e == super::sys::AX_INVALID_ELEMENT => Some(true),
        Err(_) => None,
        Ok(_) => (among_children == Some(false)).then_some(true),
    }
}

/// Whether, of `before` and `after` values of the same texts, exactly one
/// changed and it is a display that took the digit `ch`: digits only, the
/// old value a strict prefix with the digit after it, or a cleared display
/// (empty or zeros) replaced by the digit. Not a lone label.
pub(super) fn one_changed_ending(pairs: &[(Option<String>, Option<String>)], ch: char) -> bool {
    let changed: Vec<(&Option<String>, &Option<String>)> =
        pairs.iter().filter(|(b, a)| b != a).map(|(b, a)| (b, a)).collect();
    let [(before, Some(after))] = changed.as_slice() else { return false };
    let clean = |v: &str| -> String {
        v.chars()
            .filter(|c| !c.is_whitespace() && !matches!(c, ',' | '.' | '\u{2009}' | '\u{202F}'))
            .collect()
    };
    let (b, a) = (clean(before.as_deref().unwrap_or("")), clean(after));
    let digits = |v: &str| !v.is_empty() && v.chars().all(|c| c.is_ascii_digit() || c == '-');
    digits(&a)
        && (digits(&b) || b.is_empty())
        && (a == format!("{b}{ch}")
            || (b.trim_start_matches('0').is_empty() && a == ch.to_string()))
}

/// Times `needle` appears in `hay` (not overlapping).
fn occurrences(hay: &str, needle: &str) -> usize {
    if needle.is_empty() { 0 } else { hay.matches(needle).count() }
}

/// Whether typing `text` shows: the value now holds it more times than
/// before (a value that already held it, or a value the app rewrote without
/// it, does not count).
pub(super) fn typed_shows(before: &str, after: &str, text: &str) -> bool {
    occurrences(after, text) > occurrences(before, text)
}

/// Whether a save shows: the document file's modification time moved
/// forward.
pub(super) fn saved(before: Option<f64>, after: Option<f64>) -> bool {
    matches!((before, after), (Some(b), Some(a)) if a > b)
}

/// Whether exactly one row is selected and its name was not among the
/// rows before (a new folder or note waiting for its name). Rows compare
/// by name: an element's identity does not survive a list reloading.
pub(super) fn new_row_selected(before: &[String], selected: &[String]) -> bool {
    matches!(selected, [one] if !before.contains(one))
}

/// What type-to-select picked: `Some(true)` the one selected row's name
/// starts with the typed text (any case), `Some(false)` it does not,
/// `None` no single row selected.
pub(super) fn type_selected(selected: &[String], typed: &str) -> Option<bool> {
    let [one] = selected else { return None };
    Some(one.to_lowercase().starts_with(&typed.to_lowercase()))
}

/// Whether some list grew: a pair of row counts before and after.
pub(super) fn rows_grew(counts: &[(usize, usize)]) -> bool {
    counts.iter().any(|(before, after)| after > before)
}

/// UTF-16 code units of `s`.
fn units(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

/// Whether typing `text` at `at` (the caret, or a selection it replaced)
/// shows in `after`: the text sits at the caret and the value grew by its
/// length less the selection's (UTF-16, as AX ranges count).
pub(super) fn typed_at(before: &str, after: &str, text: &str, at: CFRange) -> bool {
    if typed_at_exactly(before, after, text, at) {
        return true;
    }
    // A rich editor's empty paragraph reads as a line break that typing
    // replaces (ProseMirror: "\n" then "Zed"; Lexical adds paragraph
    // breaks after the text): line breaks at the ends of the value are not
    // the text's. Text that has its own line breaks is held to the exact
    // rule.
    if text.contains(['\n', '\r']) {
        return false;
    }
    let trim = |s: &str| s.trim_end_matches(['\n', '\r']).to_string();
    let (b, a) = (trim(before), trim(after));
    if b == before && a == after {
        return false;
    }
    let len = units(&b).len() as isize;
    let loc = at.location.clamp(0, len);
    let sel = at.length.clamp(0, len - loc);
    typed_at_exactly(&b, &a, text, CFRange { location: loc, length: sel })
}

/// [`typed_at`] without the line-break rule.
fn typed_at_exactly(before: &str, after: &str, text: &str, at: CFRange) -> bool {
    let (b, a, t) = (units(before), units(after), units(text));
    let (loc, sel) = (at.location.max(0) as usize, at.length.max(0) as usize);
    if t.is_empty() || loc + sel > b.len() || a.len() + sel != b.len() + t.len() {
        return false;
    }
    a.get(loc..loc + t.len()) == Some(&t[..])
}

/// The value typing `text` at `at` would leave in `before`.
fn typed_value(before: &str, text: &str, at: Option<CFRange>) -> String {
    let b = units(before);
    let Some(at) = at else { return format!("{before}{text}") };
    let loc = (at.location.max(0) as usize).min(b.len());
    let end = (loc + at.length.max(0) as usize).min(b.len());
    let mut out = b[..loc].to_vec();
    out.extend(units(text));
    out.extend(&b[end..]);
    String::from_utf16_lossy(&out)
}

/// Whether a scroll bar moved the way it was asked to: by more than
/// rounding, with the sign of `sign`.
pub(super) fn moved_toward(before: f64, after: f64, sign: f64) -> bool {
    (after - before) * sign > 1e-6
}

/// Whether a read value matches the wanted one: the same text, or numbers
/// within `tolerance` when the value is a number (`Some`).
pub(super) fn value_matches(read: &str, wanted: &str, tolerance: Tolerance) -> bool {
    if read == wanted {
        return true;
    }
    let Some(tolerance) = tolerance else { return false };
    match (read.trim().parse::<f64>(), wanted.trim().parse::<f64>()) {
        (Ok(a), Ok(b)) => (a - b).abs() <= tolerance,
        _ => false,
    }
}

/// The tolerance for comparing `el`'s value: `tolerance` when its value is
/// a number, read strictly now; exact text otherwise (a failed read
/// included: exact is the stricter comparison).
pub(super) fn tolerance_for(el: &Ax, tolerance: f64) -> Tolerance {
    matches!(el.try_number("AXValue"), Ok(Some(_))).then_some(tolerance)
}

/// Of sub-checks given as (states a change, holds), whether any of the
/// ones that state a change holds: one whose wanted state already held
/// before the action never makes the whole hold.
pub(super) fn any_holds(subs: &[(bool, Option<bool>)]) -> Option<bool> {
    let reads: Vec<Option<bool>> = subs.iter().filter(|(c, _)| *c).map(|(_, h)| *h).collect();
    if reads.contains(&Some(true)) { Some(true) } else { None }
}

fn range_text(r: Option<CFRange>) -> String {
    match r {
        Some(r) => format!("{}+{}", r.location, r.length),
        None => "none".into(),
    }
}

// ------------------------------------------------------------ constructors

impl Check {
    /// Text typed into the text element `el` (not a secure field: its
    /// value cannot be read): the value and caret before.
    pub(super) fn text(el: &Ax, text: &str) -> Option<Check> {
        let role = el.try_string("AXRole").ok()??;
        let subrole = el.try_string("AXSubrole").ok()?;
        if !super::roles::is_text_input(&role)
            || super::roles::is_secure(&role, subrole.as_deref())
            || text.trim().is_empty()
        {
            return None;
        }
        let before = el.try_value_text().ok()?.unwrap_or_else(String::new);
        let at = el.try_selected_range().ok()?;
        Some(Check::Text { el: el.clone(), before, text: text.to_string(), at })
    }

    /// `text` inserted into `el` whose value `before` and caret `at` the
    /// caller read (strictly) before the insert.
    pub(super) fn text_from(
        el: &Ax,
        before: &Known<String>,
        text: &str,
        at: &Known<Option<CFRange>>,
    ) -> Option<Check> {
        (!text.is_empty()).then(|| Check::Text {
            el: el.clone(),
            before: before.0.clone(),
            text: text.to_string(),
            at: at.0,
        })
    }

    /// A posted scroll at the global point (`x`, `y`) in `pid`'s app: the
    /// bars of the scroll area under it, moving as asked.
    pub(super) fn scroll(pid: i32, x: f64, y: f64, dx: f64, dy: f64) -> Option<Check> {
        let app = Ax::application(pid)?;
        app.set_timeout(0.25);
        let mut el = app.element_at(x, y)?;
        for _ in 0..SCROLL_AREA_DEPTH {
            if el.try_string("AXRole").ok()?.as_deref() == Some("AXScrollArea") {
                let mut bars = Vec::new();
                for (attr, lines) in [("AXVerticalScrollBar", dy), ("AXHorizontalScrollBar", dx)] {
                    if lines == 0.0 {
                        continue;
                    }
                    let Some(bar) = el.try_element(attr).ok()? else { continue };
                    let before = bar.try_number("AXValue").ok()??;
                    bars.push(Bar { el: bar, before, sign: lines.signum() });
                }
                return (!bars.is_empty()).then_some(Check::Scroll { bars, wanted: None });
            }
            el = el.try_element("AXParent").ok()??;
        }
        None
    }

    /// Scroll bars a route moves itself: their values before (read by the
    /// route, strictly) and the values it sets.
    pub(super) fn scroll_planned(plan: Vec<(Ax, Known<f64>, f64, f64)>) -> Check {
        let wanted = plan.iter().map(|(_, _, w, _)| *w).collect();
        let bars = plan
            .into_iter()
            .map(|(el, before, _, sign)| Bar { el, before: before.0, sign })
            .collect();
        Check::Scroll { bars, wanted: Some(wanted) }
    }

    /// All of the text element `el` selected.
    pub(super) fn select_all(el: &Ax) -> Option<Check> {
        let chars = el.try_number("AXNumberOfCharacters").ok()?? as usize;
        let before = el.try_selected_range().ok()??;
        Some(Check::SelectAll { el: el.clone(), before, chars })
    }

    /// All of the list `el`'s rows selected.
    pub(super) fn all_rows(el: &Ax) -> Option<Check> {
        let rows = el.try_count("AXRows").ok()?;
        let selected = el.try_count("AXSelectedRows").ok()?;
        Some(Check::AllRows { el: el.clone(), selected, rows })
    }

    /// `el`'s value from `before` (read by the caller before the action) to
    /// `wanted`.
    pub(super) fn value_from(
        el: &Ax,
        before: &Known<String>,
        wanted: Wanted,
        tolerance: f64,
    ) -> Check {
        let tolerance = tolerance_for(el, tolerance);
        Check::Value { el: el.clone(), before: before.0.clone(), wanted, tolerance }
    }

    /// `el`'s value to what the request `wanted`, its value now read as
    /// the before.
    pub(super) fn value(el: &Ax, wanted: Wanted, tolerance: f64) -> Option<Check> {
        Some(Check::value_from(el, &Known::value(el)?, wanted, tolerance))
    }

    /// `el`'s selected text range to `range`.
    pub(super) fn range(el: &Ax, range: CFRange) -> Option<Check> {
        let before = el.try_selected_range().ok()?;
        Some(Check::Range { el: el.clone(), before, range })
    }

    /// `row` of `list` selected, and the only one.
    pub(super) fn selected(row: &Ax, list: &Ax) -> Option<Check> {
        let before = only_selected(row, list)?;
        Some(Check::Selected { row: row.clone(), list: list.clone(), before })
    }

    /// A secure field to `count` characters.
    pub(super) fn length(el: &Ax, count: f64) -> Option<Check> {
        Some(Check::Length { el: el.clone(), before: secure_count(el)?, count })
    }

    /// A pop-up showing `title`.
    pub(super) fn title(el: &Ax, title: &str) -> Option<Check> {
        let before = el.try_value_text().ok()?;
        Some(Check::Title { el: el.clone(), before, title: title.to_string() })
    }

    /// `el`'s boolean `attr` to `value`.
    pub(super) fn flag(el: &Ax, attr: &str, value: bool) -> Option<Check> {
        let before = el.try_bool(attr).ok()?;
        Some(Check::Bool { el: el.clone(), attr: attr.to_string(), before, value })
    }

    /// The menu `el` this call opened stays shown.
    pub(super) fn shown(el: &Ax) -> Check {
        Check::Shown { el: el.clone() }
    }

    /// A menu item's title and check mark, to see a toggle.
    pub(super) fn menu_item(el: &Ax) -> Option<Check> {
        let title = el.try_string("AXTitle").ok()?;
        let mark = el.try_string("AXMenuItemMarkChar").ok()?;
        Some(Check::MenuItem { el: el.clone(), title, mark })
    }

    /// A sheet or popover opening in `win`.
    pub(super) fn opened(win: &Ax) -> Option<Check> {
        Some(Check::Opened { win: win.clone(), before: overlays(win)? })
    }

    /// The sheet that `el` sits in closing; `None` when `el` is in no
    /// sheet or a read on the way failed.
    pub(super) fn gone_of(el: &Ax) -> Option<Check> {
        let mut cur = el.try_element("AXParent").ok()?;
        for _ in 0..16 {
            let node = cur?;
            match node.try_string("AXRole").ok()?.as_deref() {
                Some("AXSheet") => {
                    let win = node.try_element("AXParent").ok()??;
                    return Some(Check::Gone { sheet: node, win });
                }
                Some("AXWindow" | "AXApplication") | None => return None,
                _ => {}
            }
            cur = node.try_element("AXParent").ok()?;
        }
        None
    }

    /// A digit `ch` reaching the display of `win`.
    pub(super) fn digit(win: &Ax, ch: char) -> Option<Check> {
        Some(Check::EndsWith { texts: texts(win)?, ch })
    }

    /// Saving the document of `win`: its file's time before.
    pub(super) fn saved_doc(win: &Ax) -> Option<Check> {
        let path = document_path(win)?;
        let before = mtime(&path)?;
        Some(Check::Saved { path, before, win: win.clone() })
    }

    /// A new row selected in the list `el`: its rows' names before.
    pub(super) fn new_row(el: &Ax) -> Option<Check> {
        Some(Check::NewRow { el: el.clone(), names: row_names(el, "AXRows")? })
    }

    /// Type-to-select of `typed` in the list `el`.
    pub(super) fn type_select(el: &Ax, typed: &str) -> Option<Check> {
        let before = row_names(el, "AXSelectedRows")?;
        Some(Check::TypeSelect { el: el.clone(), before, typed: typed.to_string() })
    }

    /// A row added to one of `win`'s lists and selected.
    pub(super) fn rows_grew_in(win: &Ax) -> Option<Check> {
        let lists = lists_of(win)?;
        let named = all_known(
            lists.iter().map(|l| row_names(l, "AXRows").ok_or(super::sys::AX_CANNOT_COMPLETE)),
        )?;
        let lists: Vec<(Ax, Vec<String>)> = lists.into_iter().zip(named).collect();
        (!lists.is_empty()).then_some(Check::RowsGrew { lists })
    }

    /// Any of `checks`; `None` when there are none.
    pub(super) fn any(checks: Vec<Check>) -> Option<Check> {
        match checks.len() {
            0 => None,
            1 => checks.into_iter().next(),
            _ => Some(Check::Any(checks)),
        }
    }
}

// ---------------------------------------------------------- change, holds

impl Check {
    /// The intended change, before -> wanted, as text. Equal: the wanted
    /// state already held before the action, so nothing reads back that it
    /// did anything.
    pub(super) fn change(&self) -> (String, String) {
        let s = |v: &Option<String>| v.clone().unwrap_or_else(|| "none".into());
        match self {
            Check::Text { before, text, at, .. } => {
                (before.clone(), typed_value(before, text, *at))
            }
            Check::Scroll { bars, wanted } => {
                let b: Vec<String> = bars.iter().map(|b| format!("{:.4}", b.before)).collect();
                let w: Vec<String> = match wanted {
                    Some(w) => w.iter().map(|v| format!("{v:.4}")).collect(),
                    None => {
                        bars.iter().map(|b| format!("{:.4} moved {:+}", b.before, b.sign)).collect()
                    }
                };
                (b.join(","), w.join(","))
            }
            Check::SelectAll { before, chars, .. } => (
                range_text(Some(*before)),
                range_text(Some(CFRange { location: 0, length: *chars as isize })),
            ),
            Check::AllRows { selected, rows, .. } => {
                (format!("{selected} of {rows}"), format!("{rows} of {rows}"))
            }
            Check::Value { before, wanted, tolerance, .. } => match wanted {
                Wanted::Value(v) if value_matches(before, v, *tolerance) => {
                    (before.clone(), before.clone())
                }
                Wanted::Value(v) => (before.clone(), v.clone()),
                Wanted::Direction(sign) => (before.clone(), format!("{before} moved {sign:+}")),
                Wanted::Other => (before.clone(), format!("other than {before:?}")),
            },
            Check::Range { before, range, .. } => (range_text(*before), range_text(Some(*range))),
            Check::Selected { before, .. } => {
                let b = if *before { "only selected" } else { "not only selected" };
                (b.into(), "only selected".into())
            }
            Check::Length { before, count, .. } => (before.to_string(), count.to_string()),
            Check::Title { before, title, .. } => {
                let b = s(before);
                if super::roles::same_title(&b, title) {
                    (b.clone(), b)
                } else {
                    (b, title.clone())
                }
            }
            Check::Bool { before, value, .. } => {
                (format!("{before:?}"), format!("{:?}", Some(*value)))
            }
            Check::Shown { .. } => ("closed".into(), "open".into()),
            Check::MenuItem { title, mark, .. } => {
                (format!("{}|{}", s(title), s(mark)), "toggled".into())
            }
            Check::Opened { before, .. } => (before.to_string(), format!("more than {before}")),
            Check::Gone { .. } => ("shown".into(), "gone".into()),
            Check::EndsWith { texts, ch } => {
                let b: Vec<String> = texts.iter().map(|(_, v)| s(v)).collect();
                (b.join("|"), format!("display then {ch}"))
            }
            Check::Saved { before, .. } => (format!("{before}"), "written later".into()),
            Check::NewRow { names, .. } => (names.join("|"), "a new row selected".into()),
            Check::TypeSelect { before, typed, .. } => {
                let b = before.join("|");
                if type_selected(before, typed) == Some(true) {
                    (b.clone(), b)
                } else {
                    (b, format!("a row starting with {typed:?}"))
                }
            }
            Check::RowsGrew { lists } => {
                let b: Vec<String> = lists.iter().map(|(_, n)| n.join("|")).collect();
                (b.join(";"), "a new row selected".into())
            }
            Check::Any(all) => {
                let changes: Vec<(String, String)> =
                    all.iter().map(Check::change).filter(|(b, w)| b != w).collect();
                let before: Vec<String> = all.iter().map(|c| c.change().0).collect();
                let before = before.join(" / ");
                if changes.is_empty() {
                    (before.clone(), before)
                } else {
                    let wanted: Vec<String> = changes.into_iter().map(|(_, w)| w).collect();
                    (before, wanted.join(" / "))
                }
            }
        }
    }

    /// Whether the check states a change (its wanted state did not already
    /// hold before the action).
    pub(super) fn states_change(&self) -> bool {
        let (b, w) = self.change();
        b != w
    }

    /// `Some(true)`: the intended change shows; `Some(false)`: it does
    /// not; `None`: unreadable, or nothing tells.
    pub(super) fn holds(&self) -> Option<bool> {
        match self {
            Check::Text { el, before, text, at } => {
                let after = el.try_value_text().ok()??;
                Some(match at {
                    Some(at) => typed_at(before, &after, text, *at),
                    None => typed_shows(before, &after, text),
                })
            }
            Check::Scroll { bars, .. } => {
                let mut read = false;
                for bar in bars {
                    let Some(after) = bar.el.try_number("AXValue").ok()? else { continue };
                    read = true;
                    if moved_toward(bar.before, after, bar.sign) {
                        return Some(true);
                    }
                }
                read.then_some(false)
            }
            Check::SelectAll { el, .. } => {
                let n = el.try_number("AXNumberOfCharacters").ok()??;
                let r = el.try_selected_range().ok()??;
                Some(n > 0.0 && r.location == 0 && r.length as f64 == n)
            }
            Check::AllRows { el, .. } => {
                let rows = el.try_count("AXRows").ok()?;
                let selected = el.try_count("AXSelectedRows").ok()?;
                Some(rows > 0 && selected == rows)
            }
            Check::Value { el, before, wanted, tolerance } => {
                Some(wanted_reached(before, &el.try_value_text().ok()??, wanted, *tolerance))
            }
            Check::Range { el, range, .. } => Some(el.try_selected_range().ok()? == Some(*range)),
            Check::Selected { row, list, .. } => only_selected(row, list),
            Check::Length { el, count, .. } => Some(secure_count(el)? == *count),
            Check::Title { el, title, .. } => {
                Some(super::roles::same_title(&el.try_value_text().ok()??, title))
            }
            Check::Bool { el, attr, value, .. } => Some(el.try_bool(attr).ok()?? == *value),
            Check::Shown { el } => Some(el.try_string("AXRole").ok()?.as_deref() == Some("AXMenu")),
            Check::MenuItem { el, title, mark } => {
                let changed = item_changed(&Ok(title.clone()), &read_str(el, "AXTitle"))
                    || item_changed(&Ok(mark.clone()), &read_str(el, "AXMenuItemMarkChar"));
                changed.then_some(true)
            }
            Check::Opened { win, before } => (overlays(win)? > *before).then_some(true),
            Check::Gone { sheet, win } => {
                let among =
                    win.try_elements("AXChildren").ok().map(|c| c.iter().any(|c| c.same(sheet)));
                sheet_gone(&read_str(sheet, "AXRole"), among)
            }
            Check::EndsWith { texts, ch } => {
                let after = all_known(texts.iter().map(|(el, _)| el.try_value_text()))?;
                let pairs: Vec<_> =
                    texts.iter().zip(after).map(|((_, b), a)| (b.clone(), a)).collect();
                one_changed_ending(&pairs, *ch).then_some(true)
            }
            Check::Saved { path, before, win } => {
                let written = saved(Some(*before), mtime(path));
                // An edited state that cannot be read says nothing.
                let clean = edited(win).ok()? != Some(true);
                (written && clean).then_some(true)
            }
            Check::NewRow { el, names } => {
                new_row_selected(names, &row_names(el, "AXSelectedRows")?).then_some(true)
            }
            Check::TypeSelect { el, typed, .. } => {
                type_selected(&row_names(el, "AXSelectedRows")?, typed)
            }
            Check::RowsGrew { lists } => {
                for (el, before) in lists {
                    let now = el.try_count("AXRows").ok()?;
                    let selected = row_names(el, "AXSelectedRows")?;
                    if rows_grew(&[(before.len(), now)]) && new_row_selected(before, &selected) {
                        return Some(true);
                    }
                }
                None
            }
            Check::Any(all) => {
                let subs: Vec<(bool, Option<bool>)> =
                    all.iter().map(|c| (c.states_change(), c.holds())).collect();
                any_holds(&subs)
            }
        }
    }

    fn what(&self) -> &'static str {
        match self {
            Check::Text { .. } | Check::Length { .. } | Check::EndsWith { .. } => "text",
            Check::Scroll { .. } => "scroll",
            Check::SelectAll { .. }
            | Check::AllRows { .. }
            | Check::Range { .. }
            | Check::Selected { .. } => "selection",
            Check::Value { .. } | Check::Title { .. } | Check::Bool { .. } => "value",
            Check::Shown { .. } | Check::MenuItem { .. } => "menu",
            Check::Opened { .. } | Check::Gone { .. } => "window",
            Check::Saved { .. } => "file",
            Check::NewRow { .. } | Check::TypeSelect { .. } | Check::RowsGrew { .. } => "rows",
            Check::Any(_) => "any",
        }
    }
}

#[derive(Default)]
pub(super) struct Checks {
    next: u64,
    pending: VecDeque<(u64, Check)>,
}

impl Checks {
    /// Keeps `check` for the engine's read-back; the [`Expect`] carries the
    /// intended change (before -> wanted) the engine checks.
    pub(super) fn add(&mut self, check: Check) -> Expect {
        self.next += 1;
        let (before, wanted) = check.change();
        let what = check.what();
        self.pending.push_back((self.next, check));
        while self.pending.len() > KEPT {
            self.pending.pop_front();
        }
        Expect { token: self.next, what: what.into(), already: before == wanted, before, wanted }
    }

    pub(super) fn take(&mut self, token: u64) -> Option<Check> {
        let i = self.pending.iter().position(|(t, _)| *t == token)?;
        self.pending.remove(i).map(|(_, c)| c)
    }

    /// The check for `token`, left in place (read again later).
    pub(super) fn get(&self, token: u64) -> Option<&Check> {
        self.pending.iter().find(|(t, _)| *t == token).map(|(_, c)| c)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Review of e840a32 (root B): read-back code never uses the lossy AX
    /// readers, which take a failed read for "empty", "false" or "none".
    #[test]
    fn read_back_code_uses_only_strict_reads() {
        let source = include_str!("readback.rs");
        let code = &source[..source.find("#[cfg(test)]").expect("tests at the end")];
        for lossy in [
            ".elements(",
            ".element(",
            ".string(",
            ".bool(",
            ".number(",
            ".value_text()",
            ".selected_range()",
            ".frame()",
            "unwrap_or_default",
        ] {
            assert!(!code.contains(lossy), "read-back code calls the lossy {lossy}");
        }
    }

    /// Root B: one failed read makes the whole baseline unknown.
    #[test]
    fn a_failed_read_makes_the_baseline_unknown() {
        let err = super::super::sys::AX_CANNOT_COMPLETE;
        assert_eq!(all_known(vec![Ok(1), Ok(2)]), Some(vec![1, 2]));
        assert_eq!(all_known(vec![Ok(1), Err(err)]), None);
        assert_eq!(all_known(Vec::<Result<u8, AXError>>::new()), Some(vec![]));
    }

    /// Root A: in an Any, a sub-check whose wanted state already held
    /// (states no change) never makes the whole hold, even when it holds.
    #[test]
    fn an_unchanged_sub_check_never_makes_any_hold() {
        assert_eq!(any_holds(&[(false, Some(true))]), None, "already held");
        assert_eq!(any_holds(&[(false, Some(true)), (true, Some(true))]), Some(true));
        assert_eq!(any_holds(&[(true, None), (true, Some(false))]), None);
        assert_eq!(any_holds(&[]), None);
    }

    #[test]
    fn typed_text_shows_only_when_more_of_it_is_there() {
        assert!(typed_shows("", "Zed", "Zed"));
        assert!(typed_shows("Zed", "ZedZed", "Zed"));
        assert!(!typed_shows("Zed", "Zed", "Zed"));
        assert!(!typed_shows("abc", "abd", "x"));
        assert!(!typed_shows("", "", ""));
    }

    #[test]
    fn the_typed_value_inserts_at_the_caret() {
        let at = |location, length| Some(CFRange { location, length });
        assert_eq!(typed_value("ab", "Z", at(1, 0)), "aZb");
        assert_eq!(typed_value("aXXb", "Z", at(1, 2)), "aZb");
        assert_eq!(typed_value("ab", "Z", None), "abZ");
    }

    /// Review 9 (7): a scroll down that moved the view up, or not at all,
    /// is not the scroll asked for.
    #[test]
    fn a_scroll_confirms_only_moving_the_way_asked() {
        assert!(moved_toward(0.2, 0.3, 1.0));
        assert!(!moved_toward(0.3, 0.2, 1.0));
        assert!(!moved_toward(0.3, 0.3, 1.0));
        assert!(moved_toward(0.3, 0.2, -1.0));
        assert!(!moved_toward(0.0, 0.0, -1.0));
    }

    /// Review of e75f474 (8): typing shows at the caret, with the value
    /// grown by the text; the same text elsewhere does not count.
    #[test]
    fn typed_text_shows_at_the_caret() {
        let at = |location, length| CFRange { location, length };
        assert!(typed_at("ab", "aZedb", "Zed", at(1, 0)));
        assert!(typed_at("aXXb", "aZb", "Z", at(1, 2)), "replacing a selection");
        assert!(typed_at("Zed", "ZedZed", "Zed", at(3, 0)), "typed at the end");
        assert!(!typed_at("ab!", "ab!Zed", "Zed", at(0, 0)), "landed elsewhere");
        assert!(!typed_at("ab", "ab", "Z", at(1, 0)), "nothing typed");
        assert!(!typed_at("ab", "aZZb", "Z", at(1, 0)), "typed twice");
        assert!(typed_at("é", "éZ", "Z", at(1, 0)), "UTF-16 offsets");
    }

    /// Live, Safari and Chrome: an empty ProseMirror or Lexical editor reads
    /// "\n" (its empty paragraph) before typing and "Zq9 x" (or "Zq9 x\n\n")
    /// after: the text landed; the break was the placeholder's.
    #[test]
    fn typed_text_shows_in_a_rich_editor_whose_empty_paragraph_was_a_break() {
        let at = |location, length| CFRange { location, length };
        assert!(typed_at("\n", "Zq9 x", "Zq9 x", at(0, 0)), "ProseMirror");
        assert!(typed_at("\n", "Zq9 x", "Zq9 x", at(1, 0)), "caret after the break");
        assert!(typed_at("\n", "Zq9 x\n\n", "Zq9 x", at(0, 0)), "Lexical");
        assert!(typed_at("ab\n", "abZ\n", "Z", at(2, 0)));
        assert!(!typed_at("\n", "Zq9 xZq9 x", "Zq9 x", at(0, 0)), "typed twice");
        assert!(!typed_at("\n", "\n", "Zq9 x", at(0, 0)), "nothing typed");
        assert!(!typed_at("ab\n", "Zab\n", "Z", at(2, 0)), "landed elsewhere");
        assert!(
            !typed_at("\n", "a\nb", "a\nb\n", at(0, 0)),
            "text with its own breaks stays exact"
        );
    }

    /// A calculator digit: exactly one text changed, a display that took
    /// the digit; two changed texts, none, or another digit say nothing.
    #[test]
    fn one_text_changed_ending_with_the_digit() {
        let p = |b: &str, a: &str| (Some(b.to_string()), Some(a.to_string()));
        assert!(one_changed_ending(&[p("0", "8"), p("C", "C")], '8'));
        assert!(one_changed_ending(&[p("1,23", "1,238")], '8'));
        assert!(!one_changed_ending(&[p("0", "8"), p("a", "b")], '8'), "two changed");
        assert!(!one_changed_ending(&[p("8", "8")], '8'), "none changed");
        assert!(!one_changed_ending(&[p("0", "9")], '8'), "another digit");
    }

    /// Review of 13dca61 (8), e840a32: a display, the old value a strict
    /// prefix or cleared; not a lone label that ends with the digit.
    #[test]
    fn the_digit_check_reads_a_display() {
        let p = |b: &str, a: &str| (Some(b.to_string()), Some(a.to_string()));
        assert!(one_changed_ending(&[p("12", "128")], '8'));
        assert!(one_changed_ending(&[p("0", "8")], '8'));
        assert!(one_changed_ending(&[p("", "8")], '8'), "a blank display");
        assert!(!one_changed_ending(&[p("Items: 3", "Items: 8")], '8'), "a label");
        assert!(!one_changed_ending(&[p("5", "8")], '8'), "not appended");
        assert!(!one_changed_ending(&[p("12", "8")], '8'), "replaced, not appended");
    }

    /// Batch 2: ⌘S confirms when the document file was written after the
    /// press; an unchanged or unreadable time says nothing.
    #[test]
    fn a_save_shows_as_a_newer_file() {
        assert!(saved(Some(100.0), Some(101.5)));
        assert!(!saved(Some(100.0), Some(100.0)));
        assert!(!saved(None, Some(100.0)), "no file before");
        assert!(!saved(Some(100.0), None));
    }

    /// Batch 2: Finder ⌘⇧N and Notes New Note: one new row selected, by
    /// name (review of e840a32: not by element identity).
    #[test]
    fn a_new_row_is_one_selected_row_not_seen_before() {
        let names = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(new_row_selected(&names(&["a", "b"]), &names(&["untitled folder"])));
        assert!(!new_row_selected(&names(&["a", "b"]), &names(&["a"])), "an old row");
        assert!(!new_row_selected(&names(&["a"]), &names(&["x", "y"])), "two selected");
        assert!(!new_row_selected(&names(&["a"]), &[]), "none selected");
    }

    /// Batch 2: type-to-select picked the row whose name starts with the
    /// typed text; a row that does not is a wrong pick, said as such.
    #[test]
    fn type_select_reads_the_picked_row() {
        let one = |s: &str| vec![s.to_string()];
        assert_eq!(type_selected(&one("file-07.txt"), "file-07"), Some(true));
        assert_eq!(type_selected(&one("File-07.txt"), "file-07"), Some(true), "any case");
        assert_eq!(type_selected(&one("file-08.txt"), "file-07"), Some(false));
        assert_eq!(type_selected(&[], "file"), None);
        assert_eq!(type_selected(&[one("a"), one("b")].concat(), "a"), None, "two selected");
    }

    #[test]
    fn rows_grew_when_any_list_has_more_rows() {
        assert!(rows_grew(&[(3, 3), (5, 6)]));
        assert!(!rows_grew(&[(3, 3), (6, 5)]));
        assert!(!rows_grew(&[]));
    }

    /// Review of 13dca61 (1): a failed read after the press is not a change.
    #[test]
    fn a_failed_menu_item_read_is_never_a_change() {
        let ok = |v: Option<&str>| -> Read { Ok(v.map(String::from)) };
        let err: Read = Err(super::super::sys::AX_CANNOT_COMPLETE);
        assert!(item_changed(&ok(Some("Hide Ruler")), &ok(Some("Show Ruler"))));
        assert!(item_changed(&ok(None), &ok(Some("\u{2713}"))), "a check mark appeared");
        assert!(!item_changed(&ok(Some("Hide Ruler")), &ok(Some("Hide Ruler"))));
        assert!(!item_changed(&ok(Some("Hide Ruler")), &err), "after-read failed");
        assert!(!item_changed(&err, &ok(Some("Show Ruler"))), "before-read failed");
    }

    /// Review of 13dca61 (2): a sheet is gone only when its element is
    /// invalid or it left its window; a timeout says nothing.
    #[test]
    fn a_sheet_is_gone_only_when_invalid_or_detached() {
        let invalid: Read = Err(super::super::sys::AX_INVALID_ELEMENT);
        let timeout: Read = Err(super::super::sys::AX_CANNOT_COMPLETE);
        let alive: Read = Ok(Some("AXSheet".into()));
        assert_eq!(sheet_gone(&invalid, None), Some(true));
        assert_eq!(sheet_gone(&timeout, None), None, "a timeout is not gone");
        assert_eq!(sheet_gone(&timeout, Some(true)), None);
        assert_eq!(sheet_gone(&alive, Some(true)), None, "still a child of its window");
        assert_eq!(sheet_gone(&alive, Some(false)), Some(true), "left its window");
        assert_eq!(sheet_gone(&alive, None), None, "its window unreadable");
    }

    #[test]
    fn checks_are_taken_once_and_bounded() {
        let mut checks = Checks::default();
        let scroll = || Check::Scroll { bars: vec![], wanted: None };
        let first = checks.add(scroll());
        assert_eq!(first.what, "scroll");
        for _ in 0..KEPT {
            checks.add(scroll());
        }
        assert!(checks.take(first.token).is_none(), "the oldest is dropped");
        let last = checks.add(scroll());
        assert!(checks.take(last.token).is_some());
        assert!(checks.take(last.token).is_none());
    }

    /// Review of 02ca109 (1): a stepper asked for 10 that stopped at 7 has
    /// not reached what was wanted (one step of tolerance); a direction is
    /// reached only by moving that way; a toggle only by a different value.
    #[test]
    fn the_wanted_value_comes_from_the_request() {
        let to = |v: &str| Wanted::from_request(v);
        assert!(!wanted_reached("5", "7", &to("10"), Some(1.0)), "stopped short");
        assert!(wanted_reached("5", "9.5", &to("10"), Some(1.0)), "within one step");
        assert!(wanted_reached("5", "6", &Wanted::Direction(1.0), None));
        assert!(!wanted_reached("5", "4", &Wanted::Direction(1.0), None), "the other way");
        assert!(!wanted_reached("5", "5", &Wanted::Direction(-1.0), None));
        assert!(wanted_reached("0", "1", &Wanted::Other, None));
        assert!(!wanted_reached("1", "1", &Wanted::Other, None));
    }

    /// Notes on macOS 27.0.1: its window walk ran past its bound (708
    /// elements, 83 rows in its notes list), so no "New Note" read-back
    /// was attached. A list search finds lists by their containers and does
    /// not walk into their rows; everything else is walked as before.
    #[test]
    fn a_list_search_does_not_walk_into_rows() {
        for role in ["AXTable", "AXOutline", "AXList"] {
            assert!(!list_search_enters(Some(role)), "{role}");
        }
        for role in ["AXWindow", "AXSplitGroup", "AXScrollArea", "AXGroup", "AXToolbar"] {
            assert!(list_search_enters(Some(role)), "{role}");
        }
        assert!(list_search_enters(None));
    }

    #[test]
    fn values_match_as_text_or_within_the_tolerance() {
        assert!(value_matches("abc", "abc", Some(0.0)));
        assert!(!value_matches("abc", "abd", Some(1.0)));
        assert!(value_matches("60.4", "60", Some(1.0)));
        assert!(!value_matches("62", "60", Some(1.0)));
        assert!(value_matches("1", "1.0", Some(0.0)));
    }

    /// Review of e28e981 (2): numbers only when the value is a number; a
    /// text value compares exactly (a ZIP code "00501" is not 501).
    #[test]
    fn a_text_value_compares_exactly() {
        assert!(!value_matches("501", "00501", None), "text: exact");
        assert!(value_matches("00501", "00501", None));
        assert!(value_matches("501", "00501", Some(0.0)), "a number value: 501");
    }
}
