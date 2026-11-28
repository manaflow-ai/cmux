//! A turn frame's structure (RFD 0151, cmuxterm-hq `docs/rfd/0151-deterministic-capture.md`: "a
//! structural diff beside the pixel hash"): with each page frame the same REPL cell reads an outline
//! of what the page's viewport shows, one line per element that says something (its role or tag and
//! its own text: `h1 Welcome`, `button Save`, `input:email Your email`), and acpmux hashes it here.
//! A frame whose picture is within `SAME` bits of the turn's last kept frame but whose outline
//! changed (the text changed, the layout did not) is kept, with a one-line [`change`] summary.
//!
//! Bounded: the page reads at most [`MAX_LINES`] lines of at most [`LINE_CHARS`] characters,
//! inside [`READ_MS`] and the capture's own bound. No outline (no page, the read ran out of time,
//! the simulator or the app's window was shot): the frame is pixel-only, as before. Never a typed
//! value: an input says its type and placeholder only.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex, PoisonError};

/// Lines of one outline.
pub(crate) const MAX_LINES: usize = 400;
/// Characters of one line.
pub(crate) const LINE_CHARS: usize = 120;
/// The page's read of its outline, in the REPL cell after the picture.
pub(crate) const READ_MS: u64 = 1500;
/// The longest [`change`] summary.
pub(crate) const SUMMARY_CHARS: usize = 160;
const MARKER: &str = "TURN_SHAPE ";

/// A page's outline and its hash.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Shape {
    pub hash: u64,
    pub lines: Vec<String>,
}

/// The in-page outline: elements in the viewport, visible, with a role, a meaningful tag or text of
/// their own. Runs in the page (`page.evaluate`), so plain DOM only.
const OUTLINE: &str = r#"() => {
  const W = innerWidth, H = innerHeight, out = [];
  const skip = new Set(["script", "style", "noscript", "template", "svg", "math", "head"]);
  const keep = new Set(["a", "button", "input", "select", "textarea", "img", "h1", "h2", "h3", "h4", "h5", "h6", "nav", "main", "header", "footer", "dialog", "form", "table", "label", "summary", "video", "canvas", "iframe"]);
  const own = (el) => { let s = ""; for (const n of el.childNodes) if (n.nodeType === 3) s += n.data; return s; };
  const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT, { acceptNode: (n) => (skip.has(n.localName) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT) });
  let visited = 0, size = 0;
  for (let el = walker.currentNode; el && visited < 20000 && out.length < MAX_LINES && size < 12000; el = walker.nextNode()) {
    visited++;
    const tag = el.localName, role = el.getAttribute("role");
    let text = tag === "img" ? el.getAttribute("alt") || "" : tag === "input" ? el.getAttribute("placeholder") || "" : tag === "textarea" || tag === "select" ? "" : own(el);
    text = text.replace(/\s+/g, " ").trim().slice(0, LINE_CHARS);
    if (!text && !role && !keep.has(tag)) continue;
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0 || r.bottom <= 0 || r.right <= 0 || r.top >= H || r.left >= W) continue;
    if (el.checkVisibility && !el.checkVisibility({ visibilityProperty: true, opacityProperty: true })) continue;
    const line = (role ? role + "/" : "") + (tag === "input" ? "input:" + (el.type || "text") : tag) + (text ? " " + text : "");
    out.push(line);
    size += line.length;
  }
  return out;
}"#;

/// The REPL cell's tail that prints `TURN_SHAPE [lines]` for the `tab` the picture was of, once the
/// picture is written. A read past [`READ_MS`] prints nothing.
pub(crate) fn cell() -> String {
    let outline = OUTLINE
        .replace("MAX_LINES", &MAX_LINES.to_string())
        .replace("LINE_CHARS", &LINE_CHARS.to_string());
    format!(
        r#"
if (tab) {{ try {{ const shaped = await Promise.race([(await tabs.get(tab.id)).evaluate({outline}), sleep({READ_MS}).then(() => null)]); if (Array.isArray(shaped)) console.log("{MARKER}" + JSON.stringify(shaped)); }} catch (_) {{}} }}"#
    )
}

/// The outline a cell printed, if it printed one whole.
pub(crate) fn parse(output: &str) -> Option<Shape> {
    let raw = output.lines().find_map(|l| l.strip_prefix(MARKER))?;
    let lines: Vec<String> = serde_json::from_str(raw).ok()?;
    Some(of_lines(lines))
}

/// `lines` bounded and normalized (whitespace collapsed), and their hash.
pub(crate) fn of_lines(lines: Vec<String>) -> Shape {
    let lines: Vec<String> = lines
        .into_iter()
        .take(MAX_LINES)
        .map(|line| {
            let mut tidy = String::with_capacity(line.len().min(LINE_CHARS * 4));
            for word in line.split_whitespace() {
                if !tidy.is_empty() {
                    tidy.push(' ');
                }
                tidy.push_str(word);
            }
            match tidy.char_indices().nth(LINE_CHARS) {
                Some((cut, _)) => {
                    tidy.truncate(cut);
                    tidy
                }
                None => tidy,
            }
        })
        .filter(|line| !line.is_empty())
        .collect();
    Shape { hash: fnv(&lines), lines }
}

/// FNV-1a over the lines, each ended by a newline: the same outline hashes the same in every run.
fn fnv(lines: &[String]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in lines.iter().flat_map(|l| l.bytes().chain(std::iter::once(b'\n'))) {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

/// What changed from `old` to `new`, in one line of at most [`SUMMARY_CHARS`] characters (`+` a
/// line that came, `-` one that went, the counts first), or none when they are the same.
pub(crate) fn change(old: &Shape, new: &Shape) -> Option<String> {
    if old.hash == new.hash && old.lines == new.lines {
        return None;
    }
    let mut count: HashMap<&str, i64> = HashMap::with_capacity(old.lines.len());
    for line in &old.lines {
        *count.entry(line).or_default() += 1;
    }
    for line in &new.lines {
        *count.entry(line).or_default() -= 1;
    }
    // A line left over in `old` counts above 0, one new in `new` below: one map serves both.
    let removed: Vec<&str> = old
        .lines
        .iter()
        .map(String::as_str)
        .filter(|l| {
            let Some(left) = count.get_mut(l) else { return false };
            let went = *left > 0;
            *left -= i64::from(went);
            went
        })
        .collect();
    let added: Vec<&str> = new
        .lines
        .iter()
        .map(String::as_str)
        .filter(|l| {
            let Some(left) = count.get_mut(l) else { return false };
            let came = *left < 0;
            *left += i64::from(came);
            came
        })
        .collect();
    if added.is_empty() && removed.is_empty() {
        return Some("reordered".to_owned());
    }
    let mut summary = format!("+{} -{}", added.len(), removed.len());
    let mut items = Vec::with_capacity(added.len() + removed.len());
    for at in 0..added.len().max(removed.len()) {
        items.extend(added.get(at).map(|l| ('+', *l)));
        items.extend(removed.get(at).map(|l| ('-', *l)));
    }
    for (sign, line) in items {
        let item = format!(" {sign}{line}");
        let used = summary.chars().count();
        if used + item.chars().count() > SUMMARY_CHARS {
            let room = SUMMARY_CHARS.saturating_sub(used + 1);
            if room > 8 {
                summary.extend(item.chars().take(room));
                summary.push('…');
            }
            break;
        }
        summary.push_str(&item);
    }
    Some(summary)
}

// ---- the capture's outline, handed to the frame ----------------------------------------------

/// Captures in flight (the page's picture path) whose outline the frame has not taken yet.
static TAKEN: LazyLock<Mutex<HashMap<PathBuf, Shape>>> = LazyLock::new(Default::default);
/// The outline of each chat's last kept frame, by session: its turn and outline.
static LAST: LazyLock<Mutex<HashMap<String, (String, Shape)>>> = LazyLock::new(Default::default);
/// At most this many of either (a chat's capture that never reached its frame, a chat long gone).
const MAX_HELD: usize = 64;

fn bounded<K: Clone + Eq + std::hash::Hash, V>(map: &mut HashMap<K, V>) {
    if map.len() >= MAX_HELD
        && let Some(key) = map.keys().next().cloned()
    {
        map.remove(&key);
    }
}

/// The capture into `out` read `shape` (none: it read none).
pub(crate) fn stash(out: &Path, shape: Option<Shape>) {
    let mut taken = TAKEN.lock().unwrap_or_else(PoisonError::into_inner);
    match shape {
        Some(shape) => {
            bounded(&mut taken);
            taken.insert(out.to_owned(), shape);
        }
        None => {
            taken.remove(out);
        }
    }
}

/// The outline the capture into `out` read, once.
pub(crate) fn take(out: &Path) -> Option<Shape> {
    TAKEN.lock().unwrap_or_else(PoisonError::into_inner).remove(out)
}

/// What `shape` changed from the outline of `session`'s last kept frame in `turn`: none when either
/// has no outline or they match.
pub(crate) fn since_last(session: &str, turn: &str, shape: Option<&Shape>) -> Option<String> {
    let last = LAST.lock().unwrap_or_else(PoisonError::into_inner);
    let (_, last) = last.get(session).filter(|(t, _)| t == turn)?;
    change(last, shape?)
}

/// `session`'s frame in `turn` was kept with `shape`.
pub(crate) fn kept(session: &str, turn: &str, shape: Option<Shape>) {
    let mut last = LAST.lock().unwrap_or_else(PoisonError::into_inner);
    match shape {
        Some(shape) => {
            if !last.contains_key(session) {
                bounded(&mut last);
            }
            last.insert(session.to_owned(), (turn.to_owned(), shape));
        }
        None => {
            last.remove(session);
        }
    }
}

/// The chat was deleted.
pub(crate) fn forget(session: &str) {
    LAST.lock().unwrap_or_else(PoisonError::into_inner).remove(session);
}

#[cfg(test)]
#[path = "turn_frames_shape_tests.rs"]
mod tests;
