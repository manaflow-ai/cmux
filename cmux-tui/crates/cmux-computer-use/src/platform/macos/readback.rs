//! Read-backs the engine does once an action settled
//! ([`crate::desktop::ActionOutcome::expect`]): posted keys and scroll
//! events land a little after they are posted, and an effect read back at
//! once can still be undone by the app a moment later (a field that
//! reformats or rejects a value, a list that reselects), so every confirmed
//! result is read again after the settle too.

use std::collections::VecDeque;

use super::ax::Ax;
use super::sys::CFRange;
use crate::desktop::Expect;

/// Read-backs kept at most (the engine reads each one once, right after the
/// action; older ones are dropped).
const KEPT: usize = 8;

/// How far up from the element under a scroll the scroll area is looked for.
const SCROLL_AREA_DEPTH: usize = 12;

/// One scroll bar of a scrolled view: its value before and the way it must
/// move (+1 toward the end: down or right; -1 toward the start).
pub(super) struct Bar {
    pub(super) el: Ax,
    pub(super) before: Option<f64>,
    pub(super) sign: f64,
}

pub(super) enum Check {
    /// `text` was typed into `el` whose value was `before` with the caret
    /// or selection at `at` (UTF-16): the text is now at that spot and the
    /// value grew by it, less what was selected. Without a caret: more of
    /// the text in the value than before.
    Text { el: Ax, before: String, text: String, at: Option<CFRange> },
    /// The scrolled view's bars moved the way the scroll asked.
    Scroll { bars: Vec<Bar> },
    /// All of `el`'s text is selected.
    SelectAll { el: Ax },
    /// All of the list or table `el`'s rows are selected.
    AllRows { el: Ax },
    /// `el`'s value reads `wanted` (text, or a number within `tolerance`).
    Value { el: Ax, wanted: String, tolerance: f64 },
    /// `el`'s selected text range is `range`.
    Range { el: Ax, range: CFRange },
    /// `row` is selected, and the only one.
    Selected { row: Ax },
    /// A secure field holds `count` characters.
    Length { el: Ax, count: f64 },
    /// `el`'s value reads `title` (a pop-up's shown item; any case).
    Title { el: Ax, title: String },
    /// `el`'s boolean attribute `attr` is `value`.
    Bool { el: Ax, attr: String, value: bool },
    /// The menu `el` is still shown (left open for the next call).
    Shown { el: Ax },
    /// A pressed menu item: its title or check mark changed (a toggle).
    /// Unchanged says nothing (most items do not toggle).
    MenuItem { el: Ax, title: Option<String>, mark: Option<String> },
    /// A sheet or popover opened in window `win` (more of them than `before`).
    Opened { win: Ax, before: usize },
    /// The sheet `sheet` is gone (its button closed it).
    Gone { sheet: Ax },
    /// Exactly one text of window `win` changed, and it now ends with `ch`
    /// (a calculator's display after a digit).
    EndsWith { texts: Vec<(Ax, Option<String>)>, ch: char },
    /// Any of these holds.
    Any(Vec<Check>),
    /// The document file `path` was written after `before` (its mtime).
    Saved { path: String, before: Option<f64> },
    /// The list `el` has one new row selected (not among `names`).
    NewRow { el: Ax, names: Vec<String> },
    /// Type-to-select in the list `el` picked a row starting with `typed`.
    TypeSelect { el: Ax, typed: String },
    /// Some of these lists has more rows than its count before.
    RowsGrew { lists: Vec<(Ax, usize)> },
}

/// A file's modification time (seconds), when it can be read.
pub(super) fn mtime(path: &str) -> Option<f64> {
    let t = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(t.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64())
}

/// The path of a window's document (`AXDocument`, a file URL).
pub(super) fn document_path(win: &Ax) -> Option<String> {
    let url = win.string("AXDocument")?;
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

/// A row's name: the first text or text field value (or title) in it.
pub(super) fn row_name(row: &Ax) -> Option<String> {
    walk(row).into_iter().find_map(|(el, _)| match el.string("AXRole").as_deref() {
        Some("AXStaticText" | "AXTextField") => el.value_text().filter(|v| !v.is_empty()),
        Some("AXCell" | "AXRow") => None,
        _ => el.string("AXTitle").filter(|v| !v.is_empty()),
    })
}

/// The names of `list`'s rows (or of its selected rows).
pub(super) fn row_names(list: &Ax, attr: &str) -> Vec<String> {
    list.elements(attr).iter().filter_map(row_name).collect()
}

/// The lists, tables and outlines of a window.
pub(super) fn lists_of(win: &Ax) -> Vec<Ax> {
    walk(win)
        .into_iter()
        .filter(|(el, _)| {
            matches!(el.string("AXRole").as_deref(), Some("AXTable" | "AXOutline" | "AXList"))
        })
        .map(|(el, _)| el)
        .collect()
}

/// How deep and how many elements a window walk for sheets, popovers and
/// texts reads.
const WALK_DEPTH: usize = 12;
const WALK_MAX: usize = 400;

/// The window's elements, breadth first, bounded.
fn walk(win: &Ax) -> Vec<(Ax, usize)> {
    let mut out = Vec::new();
    let mut queue = VecDeque::from([(win.clone(), 0usize)]);
    while let Some((el, depth)) = queue.pop_front() {
        if out.len() >= WALK_MAX {
            break;
        }
        if depth < WALK_DEPTH {
            for c in el.elements("AXChildren") {
                queue.push_back((c, depth + 1));
            }
        }
        out.push((el, depth));
    }
    out
}

/// Sheets and popovers open in `win` (its own and its descendants').
pub(super) fn overlays(win: &Ax) -> usize {
    walk(win)
        .iter()
        .filter(|(el, _)| matches!(el.string("AXRole").as_deref(), Some("AXSheet" | "AXPopover")))
        .count()
}

/// The sheet `el` is in, when it is in one.
pub(super) fn sheet_of(el: &Ax) -> Option<Ax> {
    let mut cur = el.element("AXParent");
    for _ in 0..16 {
        let node = cur?;
        match node.string("AXRole").as_deref() {
            Some("AXSheet") => return Some(node),
            Some("AXWindow" | "AXApplication") | None => return None,
            _ => {}
        }
        cur = node.element("AXParent");
    }
    None
}

/// The static texts of `win` and their values.
pub(super) fn texts(win: &Ax) -> Vec<(Ax, Option<String>)> {
    walk(win)
        .into_iter()
        .filter(|(el, _)| el.string("AXRole").as_deref() == Some("AXStaticText"))
        .map(|(el, _)| {
            let v = el.value_text();
            (el, v)
        })
        .collect()
}

/// Whether, of `before` and `after` values of the same texts, exactly one
/// changed and it now ends with `ch` (spaces and group separators aside).
pub(super) fn one_changed_ending(pairs: &[(Option<String>, Option<String>)], ch: char) -> bool {
    let changed: Vec<&Option<String>> =
        pairs.iter().filter(|(b, a)| b != a).map(|(_, a)| a).collect();
    let [Some(after)] = changed.as_slice() else { return false };
    let clean: String = after
        .chars()
        .filter(|c| !c.is_whitespace() && !matches!(c, ',' | '\u{2009}' | '\u{202F}'))
        .collect();
    clean.ends_with(ch)
}

#[derive(Default)]
pub(super) struct Checks {
    next: u64,
    pending: VecDeque<(u64, Check)>,
}

impl Checks {
    /// Keeps `check`; `already`: the state matched before the action.
    pub(super) fn add(&mut self, check: Check, already: bool) -> Expect {
        self.next += 1;
        let what = match &check {
            Check::Text { .. } | Check::Length { .. } => "text",
            Check::Scroll { .. } => "scroll",
            Check::SelectAll { .. }
            | Check::AllRows { .. }
            | Check::Range { .. }
            | Check::Selected { .. } => "selection",
            Check::Value { .. } | Check::Title { .. } | Check::Bool { .. } => "value",
            Check::Shown { .. } | Check::MenuItem { .. } => "menu",
            Check::Opened { .. } | Check::Gone { .. } => "window",
            Check::EndsWith { .. } => "text",
            Check::Saved { .. } => "file",
            Check::NewRow { .. } | Check::TypeSelect { .. } | Check::RowsGrew { .. } => "rows",
            Check::Any(_) => "any",
        };
        self.pending.push_back((self.next, check));
        while self.pending.len() > KEPT {
            self.pending.pop_front();
        }
        Expect { token: self.next, what: what.into(), already }
    }

    pub(super) fn take(&mut self, token: u64) -> Option<Check> {
        let i = self.pending.iter().position(|(t, _)| *t == token)?;
        self.pending.remove(i).map(|(_, c)| c)
    }
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

/// How many characters a (secure) text field holds: its
/// `AXNumberOfCharacters`, else the length of a value it shows (bullets),
/// else where its caret ends (AppKit's secure field on macOS 27.0.1 reads
/// an empty value and no character count, but its selected range moves
/// with what is typed or set).
pub(super) fn secure_count(el: &Ax) -> Option<f64> {
    el.number("AXNumberOfCharacters")
        .or_else(|| {
            el.value_text().filter(|v| !v.is_empty()).map(|v| v.encode_utf16().count() as f64)
        })
        .or_else(|| el.selected_range().map(|r| (r.location + r.length) as f64))
}

/// Whether a save shows: the document file's modification time moved
/// forward (stub until implemented).
pub(super) fn saved(before: Option<f64>, after: Option<f64>) -> bool {
    matches!((before, after), (Some(b), Some(a)) if a > b)
}

/// Whether exactly one row is selected and its name was not among the
/// rows before (a new folder or note waiting for its name).
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
    let (b, a, t) = (units(before), units(after), units(text));
    let (loc, sel) = (at.location.max(0) as usize, at.length.max(0) as usize);
    if t.is_empty() || loc + sel > b.len() || a.len() + sel != b.len() + t.len() {
        return false;
    }
    a.get(loc..loc + t.len()) == Some(&t[..])
}

/// Whether a scroll bar moved the way it was asked to: by more than
/// rounding, with the sign of `sign`.
pub(super) fn moved_toward(before: f64, after: f64, sign: f64) -> bool {
    (after - before) * sign > 1e-6
}

/// Whether a read value matches the wanted one: the same text, or numbers
/// within `tolerance`.
pub(super) fn value_matches(read: &str, wanted: &str, tolerance: f64) -> bool {
    if read == wanted {
        return true;
    }
    match (read.trim().parse::<f64>(), wanted.trim().parse::<f64>()) {
        (Ok(a), Ok(b)) => (a - b).abs() <= tolerance,
        _ => false,
    }
}

impl Check {
    /// A check of text typed into `el` (not a secure field: its value
    /// cannot be read).
    pub(super) fn text(el: &Ax, text: &str) -> Option<Check> {
        let role = el.string("AXRole").unwrap_or_default();
        if !super::roles::is_text_input(&role)
            || super::roles::is_secure(&role, el.string("AXSubrole").as_deref())
            || text.trim().is_empty()
        {
            return None;
        }
        let before = el.value_text().unwrap_or_default();
        let at = el.selected_range();
        Some(Check::Text { el: el.clone(), before, text: text.to_string(), at })
    }

    /// A check of `text` inserted into `el` whose value was `before`.
    pub(super) fn text_from(
        el: &Ax,
        before: &str,
        text: &str,
        at: Option<CFRange>,
    ) -> Option<Check> {
        (!text.is_empty()).then(|| Check::Text {
            el: el.clone(),
            before: before.to_string(),
            text: text.to_string(),
            at,
        })
    }

    /// A check of a posted scroll at the global point (`x`, `y`) in `pid`'s
    /// app: the bars of the scroll area under it, moving as asked.
    pub(super) fn scroll(pid: i32, x: f64, y: f64, dx: f64, dy: f64) -> Option<Check> {
        let app = Ax::application(pid)?;
        app.set_timeout(0.25);
        let mut el = app.element_at(x, y)?;
        for _ in 0..SCROLL_AREA_DEPTH {
            if el.string("AXRole").as_deref() == Some("AXScrollArea") {
                let bars: Vec<Bar> = [("AXVerticalScrollBar", dy), ("AXHorizontalScrollBar", dx)]
                    .iter()
                    .filter(|(_, lines)| *lines != 0.0)
                    .filter_map(|(a, lines)| {
                        let bar = el.element(a)?;
                        let before = bar.number("AXValue");
                        Some(Bar { el: bar, before, sign: lines.signum() })
                    })
                    .collect();
                return (!bars.is_empty()).then_some(Check::Scroll { bars });
            }
            el = el.element("AXParent")?;
        }
        None
    }

    /// `Some(true)`: the effect shows; `Some(false)`: it does not; `None`:
    /// unreadable.
    pub(super) fn holds(&self) -> Option<bool> {
        match self {
            Check::Text { el, before, text, at } => {
                let after = el.value_text()?;
                Some(match at {
                    Some(at) => typed_at(before, &after, text, *at),
                    None => typed_shows(before, &after, text),
                })
            }
            Check::Scroll { bars } => {
                let mut read = false;
                for bar in bars {
                    let (Some(before), Some(after)) = (bar.before, bar.el.number("AXValue")) else {
                        continue;
                    };
                    read = true;
                    if moved_toward(before, after, bar.sign) {
                        return Some(true);
                    }
                }
                read.then_some(false)
            }
            Check::SelectAll { el } => {
                let n = el.number("AXNumberOfCharacters")?;
                let r = el.selected_range()?;
                Some(n > 0.0 && r.location == 0 && r.length as f64 == n)
            }
            Check::AllRows { el } => {
                let rows = el.elements("AXRows").len();
                let selected = el.elements("AXSelectedRows").len();
                Some(rows > 0 && selected == rows)
            }
            Check::Value { el, wanted, tolerance } => {
                Some(value_matches(&el.value_text()?, wanted, *tolerance))
            }
            Check::Range { el, range } => Some(el.selected_range()? == *range),
            Check::Selected { row } => {
                Some(row.bool("AXSelected") == Some(true) && super::actions::only_selected(row))
            }
            Check::Length { el, count } => Some(secure_count(el)? == *count),
            Check::Title { el, title } => Some(super::roles::same_title(&el.value_text()?, title)),
            Check::Bool { el, attr, value } => Some(el.bool(attr)? == *value),
            Check::Shown { el } => Some(el.string("AXRole").as_deref() == Some("AXMenu")),
            Check::MenuItem { el, title, mark } => {
                let changed = (title.is_some() && el.string("AXTitle") != *title)
                    || el.string("AXMenuItemMarkChar") != *mark;
                changed.then_some(true)
            }
            Check::Opened { win, before } => (overlays(win) > *before).then_some(true),
            Check::Gone { sheet } => sheet.string("AXRole").is_none().then_some(true),
            Check::EndsWith { texts, ch } => {
                let pairs: Vec<_> =
                    texts.iter().map(|(el, b)| (b.clone(), el.value_text())).collect();
                one_changed_ending(&pairs, *ch).then_some(true)
            }
            Check::Saved { path, before } => saved(*before, mtime(path)).then_some(true),
            Check::NewRow { el, names } => {
                new_row_selected(names, &row_names(el, "AXSelectedRows")).then_some(true)
            }
            Check::TypeSelect { el, typed } => {
                type_selected(&row_names(el, "AXSelectedRows"), typed)
            }
            Check::RowsGrew { lists } => {
                let counts: Vec<_> =
                    lists.iter().map(|(el, n)| (*n, el.elements("AXRows").len())).collect();
                rows_grew(&counts).then_some(true)
            }
            Check::Any(all) => {
                let reads: Vec<Option<bool>> = all.iter().map(Check::holds).collect();
                if reads.contains(&Some(true)) { Some(true) } else { None }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn typed_text_shows_only_when_more_of_it_is_there() {
        assert!(typed_shows("", "Zed", "Zed"));
        assert!(typed_shows("Zed", "ZedZed", "Zed"));
        assert!(!typed_shows("Zed", "Zed", "Zed"));
        assert!(!typed_shows("abc", "abd", "x"));
        assert!(!typed_shows("", "", ""));
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

    /// A calculator digit: exactly one text changed and it ends with the
    /// digit; two changed texts, none, or another ending say nothing.
    #[test]
    fn one_text_changed_ending_with_the_digit() {
        let p = |b: &str, a: &str| (Some(b.to_string()), Some(a.to_string()));
        assert!(one_changed_ending(&[p("0", "8"), p("C", "C")], '8'));
        assert!(one_changed_ending(&[p("1,23", "1,238")], '8'));
        assert!(!one_changed_ending(&[p("0", "8"), p("a", "b")], '8'), "two changed");
        assert!(!one_changed_ending(&[p("8", "8")], '8'), "none changed");
        assert!(!one_changed_ending(&[p("0", "9")], '8'), "another digit");
    }

    /// Batch 2: ⌘S confirms when the document file was written after the
    /// press; an unchanged or unreadable time says nothing.
    #[test]
    fn a_save_shows_as_a_newer_file() {
        assert!(saved(Some(100.0), Some(101.5)));
        assert!(!saved(Some(100.0), Some(100.0)));
        assert!(
            !saved(None, Some(100.0)),
            "no file before: a new document's first save is a dialog"
        );
        assert!(!saved(Some(100.0), None));
    }

    /// Batch 2: Finder ⌘⇧N and Notes New Note: one new row selected.
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

    #[test]
    fn values_match_as_text_or_within_the_tolerance() {
        assert!(value_matches("abc", "abc", 0.0));
        assert!(!value_matches("abc", "abd", 1.0));
        assert!(value_matches("60.4", "60", 1.0));
        assert!(!value_matches("62", "60", 1.0));
        assert!(value_matches("1", "1.0", 0.0));
    }

    #[test]
    fn checks_are_taken_once_and_bounded() {
        let mut checks = Checks::default();
        let first = checks.add(Check::Scroll { bars: vec![] }, false);
        assert_eq!(first.what, "scroll");
        for _ in 0..KEPT {
            checks.add(Check::Scroll { bars: vec![] }, false);
        }
        assert!(checks.take(first.token).is_none(), "the oldest is dropped");
        let last = checks.add(Check::Scroll { bars: vec![] }, true);
        assert!(last.already);
        assert!(checks.take(last.token).is_some());
        assert!(checks.take(last.token).is_none());
    }
}
