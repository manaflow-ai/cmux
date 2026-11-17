//! The change between two outlines of a window, as the model reads it:
//!
//! ```text
//! + [40] sheet "Do you want to save?" (in [1])
//! +   [41] button "Save"
//! ~ [4] text field "To" = "ada@example.com" focused (was: = "", not focused)
//! - [9] button "Undo" (and 3 inside it)
//! ```
//!
//! The menu bar is left out (its items change with every selection and the
//! state after an action does not read it). Frames count only when shown.
//! An element scrolled out of view is neither removed nor changed (its
//! container's `out of view` count says it moved); one scrolled into view is
//! added, since the last look did not show it.

use std::collections::{HashMap, HashSet};

use super::outline::{self, Line, Options, clip, line_text, quote};

/// How many removed elements are named; the rest are counted.
const REMOVED_NAMED: usize = 12;
/// Characters of context around a change in a long value.
const CONTEXT: usize = 40;
/// The most characters of the changed part of a long value shown.
const CHANGE_MAX: usize = 240;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Changes {
    /// Lines of the new outline that are new.
    pub added: Vec<usize>,
    /// (new line, old line) of the same element that changed.
    pub changed: Vec<(usize, usize)>,
    /// Lines of the old outline whose element is gone.
    pub removed: Vec<usize>,
    /// Lines of the new outline whose element the last look folded away.
    pub unfolded: Vec<usize>,
    /// Lines of the old outline whose element is still there, folded now.
    pub folded: Vec<usize>,
    /// (new line, old line): an element that reads the same, in the same
    /// place, under a new id (an app that makes its elements anew for every
    /// read; ids move only on evidence, so it got a new one).
    pub renumbered: Vec<(usize, usize)>,
    /// The focus moved (new focused id, old one).
    pub focus: Option<(Option<u32>, Option<u32>)>,
}

impl Changes {
    pub fn is_empty(&self) -> bool {
        self.added.is_empty()
            && self.changed.is_empty()
            && self.removed.is_empty()
            && self.unfolded.is_empty()
            && self.folded.is_empty()
            && self.renumbered.is_empty()
    }
}

fn compared(l: &Line) -> bool {
    !l.menu_bar && l.id != 0
}

fn same(a: &Line, b: &Line, opts: &Options) -> bool {
    a.role == b.role
        && a.label == b.label
        && a.value == b.value
        && a.identifier == b.identifier
        && a.shortcut == b.shortcut
        && a.focused == b.focused
        && a.disabled == b.disabled
        && a.checked == b.checked
        && a.selected == b.selected
        && a.actions == b.actions
        && a.tree_parent == b.tree_parent
        && a.out_of_view == b.out_of_view
        && (!opts.frames || a.frame == b.frame)
}

pub fn compute(old: &outline::Outline, new: &outline::Outline, opts: &Options) -> Changes {
    let old_at: HashMap<u32, usize> =
        old.lines.iter().enumerate().filter(|(_, l)| compared(l)).map(|(i, l)| (l.id, i)).collect();
    let new_ids: HashSet<u32> = new.lines.iter().filter(|l| compared(l)).map(|l| l.id).collect();
    let mut c = Changes::default();
    for (i, l) in new.lines.iter().enumerate().filter(|(_, l)| compared(l)) {
        match old_at.get(&l.id) {
            // Folded in the last look (a bare group that now has focus): shown.
            None if old.present.contains(&l.id) => c.unfolded.push(i),
            None => c.added.push(i),
            Some(&j) if !same(&old.lines[j], l, opts) => c.changed.push((i, j)),
            Some(_) => {}
        }
    }
    for (j, l) in old.lines.iter().enumerate().filter(|(_, l)| compared(l)) {
        if new_ids.contains(&l.id) {
            continue;
        }
        if new.present.contains(&l.id) {
            c.folded.push(j);
        } else if !new.clipped.contains(&l.id) {
            c.removed.push(j);
        }
    }
    // An added and a removed line that read the same at the same depth are
    // one element read anew: say so, with its new id.
    let mut removed = Vec::new();
    for j in std::mem::take(&mut c.removed) {
        let o = &old.lines[j];
        let twin = c.added.iter().position(|&i| {
            let n = &new.lines[i];
            n.role == o.role
                && n.label == o.label
                && n.value == o.value
                && n.identifier == o.identifier
                && n.depth == o.depth
                && n.parent == o.parent
        });
        match twin {
            Some(k) => c.renumbered.push((c.added.remove(k), j)),
            None => removed.push(j),
        }
    }
    c.removed = removed;
    let focus_id = |o: &outline::Outline| o.focused.and_then(|i| o.lines.get(i)).map(|l| l.id);
    let (was, now) = (focus_id(old), focus_id(new));
    if was != now {
        c.focus = Some((now, was));
    }
    c
}

/// The new and old values around where they differ, each cut to the change
/// with [`CONTEXT`] characters on either side.
pub fn around_change(old: &str, new: &str) -> (String, String) {
    let a: Vec<char> = old.chars().collect();
    let b: Vec<char> = new.chars().collect();
    let mut p = 0;
    while p < a.len() && p < b.len() && a[p] == b[p] {
        p += 1;
    }
    let mut q = 0;
    while q < a.len() - p && q < b.len() - p && a[a.len() - 1 - q] == b[b.len() - 1 - q] {
        q += 1;
    }
    // Where each value's changed part ends.
    let (mut end_a, mut end_b) = (a.len() - q, b.len() - q);
    // Two long values the platform cut at its limit end differently: find the
    // text after the change again (the old in the new: an insertion; the new
    // in the old: a deletion), so the change is what was typed or removed.
    let find = |from: &[char], to: &[char]| -> Option<usize> {
        let probe: Vec<char> = from[p..].iter().take(24).copied().collect();
        if probe.len() < 8 || to.len() < probe.len() {
            return None;
        }
        (p..=to.len() - probe.len()).take(4000).find(|&i| to[i..i + probe.len()] == probe[..])
    };
    if end_a - p > CHANGE_MAX || end_b - p > CHANGE_MAX {
        if let Some(i) = find(&a, &b) {
            (end_a, end_b) = (p, i);
        } else if let Some(i) = find(&b, &a) {
            (end_a, end_b) = (i, p);
        }
    }
    let cut = |v: &[char], end: usize| -> String {
        let start = p.saturating_sub(CONTEXT);
        let tail = (end + CONTEXT).min(v.len());
        let mut s = String::new();
        if start > 0 {
            s.push('\u{2026}');
        }
        s.extend(&v[start..p]);
        let mid: String = v[p..end].iter().collect();
        s.push_str(&clip(&mid, CHANGE_MAX));
        s.extend(&v[end..tail]);
        if tail < v.len() {
            s.push('\u{2026}');
        }
        s
    };
    (cut(&a, end_a), cut(&b, end_b))
}

/// A changed line: its new text, the value cut around the change when long,
/// then what was different before.
fn changed_line(new: &Line, old: &Line, opts: &Options) -> String {
    let long =
        new.value.chars().count() > opts.value_max || old.value.chars().count() > opts.value_max;
    let (old_value, mut text) = if long && new.value != old.value {
        let (o, n) = around_change(&old.value, &new.value);
        let shown = format!("{} ({} chars)", quote(&n), new.value.chars().count());
        (Some(quote(&o)), outline::line_text_with(new, opts, Some(shown)))
    } else {
        (None, line_text(new, opts))
    };
    let mut was: Vec<String> = Vec::new();
    if old.role != new.role {
        was.push(format!("a {}", old.role.replace('_', " ")));
    }
    if old.label != new.label {
        was.push(if old.label.is_empty() {
            "no name".into()
        } else {
            quote(&clip(&old.label, outline::NAME_MAX))
        });
    }
    if old.value != new.value {
        was.push(match old_value {
            Some(v) => format!("= {v}"),
            None if old.value.is_empty() => "empty".into(),
            None => format!("= {}", outline::value_text(&old.role, &old.value, opts.value_max)),
        });
    }
    if old.focused != new.focused {
        was.push(if old.focused { "focused" } else { "not focused" }.into());
    }
    if old.disabled != new.disabled {
        was.push(if old.disabled { "disabled" } else { "enabled" }.into());
    }
    if old.checked != new.checked {
        was.push(if old.checked { "checked" } else { "unchecked" }.into());
    }
    if old.selected != new.selected {
        was.push(if old.selected { "selected" } else { "not selected" }.into());
    }
    if old.shortcut != new.shortcut {
        was.push(if old.shortcut.is_empty() { "no shortcut".into() } else { old.shortcut.clone() });
    }
    if old.actions != new.actions {
        was.push(if old.actions.is_empty() {
            "no actions".into()
        } else {
            format!("actions: {}", old.actions.join(", "))
        });
    }
    if old.out_of_view != new.out_of_view {
        was.push(
            outline::out_of_view_text(&old.out_of_view).unwrap_or_else(|| "all in view".into()),
        );
    }
    // Moves name the parents the outlines show.
    if old.parent != new.parent {
        was.push(match old.parent {
            Some(p) => format!("in [{p}]"),
            None => "at the top".into(),
        });
    }
    if opts.frames
        && old.frame != new.frame
        && let Some(f) = old.frame
    {
        was.push(format!(
            "@{},{} {}x{}",
            f.x.round(),
            f.y.round(),
            f.width.round(),
            f.height.round()
        ));
    }
    let moved = new.parent.filter(|_| old.parent != new.parent).map(|p| format!(" (now in [{p}])"));
    if !was.is_empty() {
        text.push_str(&format!("{} (was: {})", moved.unwrap_or_default(), was.join(", ")));
    }
    format!("~ [{}] {text}", new.id)
}

/// `4-9, 12, 15-16`.
pub fn ranges(ids: &mut [u32]) -> String {
    ids.sort_unstable();
    let mut parts: Vec<String> = Vec::new();
    let mut i = 0;
    while i < ids.len() {
        let mut j = i;
        while j + 1 < ids.len() && ids[j + 1] == ids[j] + 1 {
            j += 1;
        }
        parts.push(if i == j { ids[i].to_string() } else { format!("{}-{}", ids[i], ids[j]) });
        i = j + 1;
    }
    parts.join(", ")
}

/// The changes as lines, or None when there are none.
pub fn render(
    old: &outline::Outline,
    new: &outline::Outline,
    c: &Changes,
    opts: &Options,
) -> Option<String> {
    if c.is_empty() && c.focus.is_none() {
        return None;
    }
    let mut out: Vec<String> = Vec::new();
    let added_ids: HashSet<u32> = c.added.iter().map(|&i| new.lines[i].id).collect();
    let mut top_depth = 0usize;
    for &i in &c.added {
        let l = &new.lines[i];
        let inner = l.parent.is_some_and(|p| added_ids.contains(&p));
        if inner {
            let pad = "  ".repeat(l.depth.saturating_sub(top_depth));
            out.push(format!("+ {pad}{}", outline::line(l, opts)));
        } else {
            top_depth = l.depth;
            let place = l.parent.map(|p| format!(" (in [{p}])")).unwrap_or_default();
            out.push(format!("+ {}{place}", outline::line(l, opts)));
        }
    }
    for &(i, j) in &c.changed {
        out.push(changed_line(&new.lines[i], &old.lines[j], opts));
    }
    for &(i, j) in &c.renumbered {
        let l = &new.lines[i];
        out.push(format!(
            "~ [{}] {} (new id; was [{}])",
            l.id,
            line_text(l, opts),
            old.lines[j].id
        ));
    }
    // A container shown or folded only because its own state changed.
    for &i in &c.unfolded {
        let l = &new.lines[i];
        let was = if l.focused {
            "not focused"
        } else if l.selected {
            "not selected"
        } else {
            "a plain container"
        };
        out.push(format!("~ [{}] {} (was: {was})", l.id, line_text(l, opts)));
    }
    for &j in &c.folded {
        let l = &old.lines[j];
        let was = if l.focused {
            "focused"
        } else if l.selected {
            "selected"
        } else {
            "named"
        };
        out.push(format!("~ [{}] {} (was: {was})", l.id, outline::short(l)));
    }
    if !c.removed.is_empty() {
        let removed_ids: HashSet<u32> = c.removed.iter().map(|&j| old.lines[j].id).collect();
        let tops: Vec<usize> = c
            .removed
            .iter()
            .copied()
            .filter(|&j| !old.lines[j].parent.is_some_and(|p| removed_ids.contains(&p)))
            .collect();
        // How many removed lines sit under each removed top.
        let mut inside: HashMap<u32, usize> = HashMap::new();
        let parents: HashMap<u32, Option<u32>> =
            old.lines.iter().map(|l| (l.id, l.parent)).collect();
        for &j in &c.removed {
            let mut cur = old.lines[j].parent;
            let mut top = None;
            while let Some(p) = cur {
                if !removed_ids.contains(&p) {
                    break;
                }
                top = Some(p);
                cur = parents.get(&p).copied().flatten();
            }
            if let Some(t) = top {
                *inside.entry(t).or_default() += 1;
            }
        }
        for &j in tops.iter().take(REMOVED_NAMED) {
            let l = &old.lines[j];
            let more = match inside.get(&l.id) {
                Some(n) => format!(" (and {n} inside it)"),
                None => String::new(),
            };
            out.push(format!("- [{}] {}{more}", l.id, outline::short(l)));
        }
        if tops.len() > REMOVED_NAMED {
            let mut rest: Vec<u32> =
                tops[REMOVED_NAMED..].iter().map(|&j| old.lines[j].id).collect();
            out.push(format!("- also removed: {}", ranges(&mut rest)));
        }
        if new.truncated {
            out.push(
                "(This look was cut at the element limit, so some of what shows as removed may only be past it; get_ui_tree with a larger max_nodes tells.)"
                    .into(),
            );
        }
    }
    if let Some((now, _)) = c.focus {
        let line = now.and_then(|id| new.lines.iter().find(|l| l.id == id));
        out.push(match line {
            Some(l) => format!("Focus now: [{}] {}", l.id, outline::short(l)),
            None => "Focus now: no element of this window".into(),
        });
    }
    Some(out.join("\n"))
}
