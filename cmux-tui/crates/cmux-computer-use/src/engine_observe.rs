//! The engine's side of [`crate::observe`]: every tree walk gives the
//! window's elements their stable ids, every look is shown as an outline
//! (the changes after the agent's first look), an action's element id is
//! mapped back to the desktop's, and the guards run before acting.

use super::*;
use crate::desktop::UiTree;
use crate::observe::{Look, diff, guards, ids, outline};

/// Windows whose last look is kept per session (least recently looked
/// dropped first), and the most outline lines kept per session.
const SEEN_WINDOWS: usize = 24;
const SEEN_LINES: usize = 60_000;
/// The most fingerprints kept per session and window (two full deep walks).
const SHOWN_PER_WINDOW: usize = 12_000;

/// What an agent last saw of each window: (session, window) -> (when, outline).
type Seen = HashMap<(String, String), (u64, outline::Outline)>;

/// What an agent was shown of each window's elements: (session, window) ->
/// (when, id -> fingerprint).
type Shown = HashMap<(String, String), (u64, HashMap<u32, ids::Fingerprint>)>;

/// What the engine keeps for observation.
pub(super) struct Observe {
    pub(super) ids: Mutex<ids::Registry>,
    /// One walk of a window at a time (each window its own lock), so the ids
    /// recorded are those of the desktop's latest tree of that window.
    pub(super) walking: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    /// (session, window) -> the outline the agent last saw of it, and when.
    pub(super) seen: Mutex<Seen>,
    seen_tick: std::sync::atomic::AtomicU64,
    /// (session, window) -> what each element was when its id was last shown
    /// to the agent, checked when it acts on the id.
    pub(super) shown: Mutex<Shown>,
    /// (session, window) -> the fingerprints of the walk a look for that
    /// session just made, taken with its ids ([`Engine::walk_tree_for`]).
    walked: Mutex<HashMap<(String, String), HashMap<u32, ids::Fingerprint>>>,
    /// window -> the most elements a walk of it was asked for, when more than
    /// the default: later default walks read as far, so ids past the default
    /// limit stay current instead of being carried (and healed every action).
    reach: Mutex<HashMap<String, usize>>,
}

impl Pixels {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Pixels::Changed => "changed",
            Pixels::Same => "same",
            Pixels::Unknown => "unknown",
            Pixels::NotRead => "not_read",
        }
    }
}

impl Default for Observe {
    fn default() -> Self {
        Self::new(None)
    }
}

impl Observe {
    /// With the engine's state directory, element ids are never given out
    /// twice, across restarts too ([`ids::Registry::new`]).
    pub(super) fn new(state_dir: Option<&std::path::Path>) -> Self {
        Self {
            // Tests read exact ids from 1; a running worker reserves them.
            ids: Mutex::new(if cfg!(test) {
                ids::Registry::default()
            } else {
                ids::Registry::new(state_dir)
            }),
            walking: Mutex::new(HashMap::new()),
            seen: Mutex::new(HashMap::new()),
            seen_tick: std::sync::atomic::AtomicU64::new(0),
            shown: Mutex::new(HashMap::new()),
            walked: Mutex::new(HashMap::new()),
            reach: Mutex::new(HashMap::new()),
        }
    }
}

/// An action's target after the guards: the desktop's element id, or the
/// call's whole result when it needs no input (a menu bar menu's items).
#[derive(Default)]
pub(super) struct Guarded {
    pub element: Option<String>,
    pub done: Option<ToolOutput>,
}

/// What a look can say about the window's pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Pixels {
    /// The settle wait's capture differs from the agent's last screenshot.
    Changed,
    /// It matches the agent's last screenshot.
    Same,
    /// No earlier screenshot to compare, or a mode that does not compare.
    Unknown,
    /// A look with no screenshot (get_ui_tree).
    NotRead,
}

/// The state key of an action whose result needs no window state (it read a
/// menu bar menu without opening it).
pub(super) const MENU_BAR_LISTING: &str = "menu_bar";

fn stale(message: String) -> ToolOutput {
    ToolOutput::error("stale_element", message)
}

fn refusal(r: guards::Refusal) -> ToolOutput {
    ToolOutput::error(
        r.code,
        format!("{} If you are sure it will work, pass force: true to skip this check.", r.message),
    )
}

impl Engine {
    /// Walks `window_id`'s tree and gives its elements their ids (the tree
    /// comes back with them, frames still in global points).
    pub(super) fn walk_tree(
        &self,
        window_id: &str,
        options: TreeOptions,
    ) -> Result<UiTree, DesktopError> {
        self.walk_tree_for(None, window_id, options)
    }

    /// [`Self::walk_tree`] for a look `session` will be shown: the walk's
    /// fingerprints are taken under the same lock as its ids and kept for
    /// that look, so a concurrent walk cannot swap what is recorded as shown.
    pub(super) fn walk_tree_for(
        &self,
        session: Option<&str>,
        window_id: &str,
        options: TreeOptions,
    ) -> Result<UiTree, DesktopError> {
        let window_lock =
            lock(&self.observe.walking).entry(window_id.to_string()).or_default().clone();
        let _walking = lock(&window_lock);
        let default = TreeOptions::default().max_nodes;
        let options = {
            let mut reach = lock(&self.observe.reach);
            if options.max_nodes > default {
                reach.insert(window_id.to_string(), options.max_nodes);
                options
            } else if options.max_nodes == default
                && let Some(&wide) = reach.get(window_id)
            {
                TreeOptions { max_nodes: wide, ..options }
            } else {
                options
            }
        };
        let mut tree = self.desktop.ui_tree(window_id, options)?;
        // An app builds some accessibility only when a client first asks for
        // it (WebKit's and Chromium's page content): the first walk of a
        // window can find a web view empty that the next fills. Walk a window
        // the engine has never walked once more, when the first walk found
        // little in it (a large window costs a second walk it does not need),
        // and keep the fuller tree, so a first look shows the page and the
        // next look does not report it all as added.
        if size_outside_menus(&tree.root) < REREAD_BELOW
            && lock(&self.observe.ids).window(window_id).is_none()
            && let Ok(again) = self.desktop.ui_tree(window_id, options)
            && size(&again.root) > size(&tree.root)
        {
            tree = again;
        }
        let pid = self.desktop.window(window_id).ok().flatten().map(|w| w.pid);
        let mut reg = lock(&self.observe.ids);
        reg.assign(window_id, &mut tree, options.menus, pid);
        if let Some(session) = session {
            let fps = reg.window(window_id).map(|w| w.fingerprints()).unwrap_or_default();
            drop(reg);
            lock(&self.observe.walked).insert((session.to_string(), window_id.to_string()), fps);
        }
        Ok(tree)
    }

    /// The agent's view of the window is unknown (a retried call's first
    /// reply may not have reached it): its next look is whole.
    pub(super) fn forget_seen(&self, session: &str, window_id: &str) {
        lock(&self.observe.seen).remove(&(session.to_string(), window_id.to_string()));
    }

    pub(super) fn forget_session_seen(&self, session: &str) {
        lock(&self.observe.seen).retain(|(s, _), _| s != session);
        lock(&self.observe.shown).retain(|(s, _), _| s != session);
        lock(&self.observe.walked).retain(|(s, _), _| s != session);
    }

    /// Records the fingerprints of the window's latest walk as shown to the
    /// agent (merged: a look cut short keeps what it did not reach), keeping
    /// at most [`SEEN_WINDOWS`] windows per session.
    pub(super) fn record_shown(&self, session: &str, window_id: &str, ids: &[u32]) {
        let key = (session.to_string(), window_id.to_string());
        // The fingerprints of the walk this look comes from, else (a look
        // with no walk of its own) the window's latest walk.
        let walked = lock(&self.observe.walked).remove(&key);
        let fps: Vec<(u32, ids::Fingerprint)> = match walked {
            Some(map) => {
                ids.iter().filter_map(|id| map.get(id).map(|f| (*id, f.clone()))).collect()
            }
            None => {
                let reg = lock(&self.observe.ids);
                let Some(w) = reg.window(window_id) else { return };
                ids.iter().filter_map(|id| w.fingerprint(*id).map(|f| (*id, f))).collect()
            }
        };
        // What is still worth checking: ids the registry still has (current,
        // or carried past a cut walk or for the menus); gone ids are refused
        // by the registry anyway.
        let live: std::collections::HashSet<u32> = {
            let reg = lock(&self.observe.ids);
            reg.window(window_id).map(|w| w.live_ids()).unwrap_or_default()
        };
        let tick = self.observe.seen_tick.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut shown = lock(&self.observe.shown);
        let entry = shown.entry(key).or_default();
        entry.0 = tick;
        entry.1.extend(fps);
        entry.1.retain(|id, _| live.contains(id));
        if entry.1.len() > SHOWN_PER_WINDOW {
            // Keep this look's ids; drop the others.
            let now: std::collections::HashSet<u32> = ids.iter().copied().collect();
            entry.1.retain(|id, _| now.contains(id));
        }
        loop {
            let mine: Vec<_> = shown.iter().filter(|((s, _), _)| s == session).collect();
            if mine.len() <= SEEN_WINDOWS {
                break;
            }
            let Some(oldest) = mine.iter().min_by_key(|(_, (t, _))| *t).map(|(k, _)| (*k).clone())
            else {
                break;
            };
            shown.remove(&oldest);
        }
    }

    /// The use-time check: the element `n` resolves to now is the element the
    /// agent was shown under `n` (same role, label, kind of value, place and
    /// ancestors). Anything else is refused as stale, so an id that moved to
    /// another element can never be acted on.
    pub(super) fn check_shown(
        &self,
        session: &str,
        window: &Window,
        n: u32,
    ) -> Result<(), ToolOutput> {
        let now = lock(&self.observe.ids).window(&window.id).and_then(|w| w.fingerprint(n));
        let then = lock(&self.observe.shown)
            .get(&(session.to_string(), window.id.clone()))
            .and_then(|(_, m)| m.get(&n).cloned());
        let look = format!("Call get_ui_tree on window {} and use the id it shows now.", window.id);
        match (then, now) {
            (Some(then), Some(now)) => match then.difference(&now) {
                None => Ok(()),
                Some(why) => Err(stale(format!(
                    "element [{n}] is not the element you were shown under that id ({why}), so nothing was done. {look}"
                ))),
            },
            (None, _) => Err(stale(format!(
                "element [{n}] was not shown to you in window {} by this Computer Use (it may be from before a restart), so nothing was done. {look}",
                window.id
            ))),
            (Some(_), None) => {
                Err(stale(format!("element [{n}] is not in window {} now. {look}", window.id)))
            }
        }
    }

    /// The outline the agent last saw of a window.
    pub(super) fn last_seen(&self, session: &str, window_id: &str) -> Option<outline::Outline> {
        lock(&self.observe.seen)
            .get(&(session.to_string(), window_id.to_string()))
            .map(|(_, o)| o.clone())
    }

    /// Records what the agent saw of a window, keeping at most
    /// [`SEEN_WINDOWS`] windows and [`SEEN_LINES`] lines per session (the
    /// least recently seen go first; their next look is whole).
    pub(super) fn record_seen(
        &self,
        session: &str,
        window_id: &str,
        new: outline::Outline,
    ) -> Option<outline::Outline> {
        let tick = self.observe.seen_tick.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut seen = lock(&self.observe.seen);
        let old =
            seen.insert((session.to_string(), window_id.to_string()), (tick, new)).map(|(_, o)| o);
        loop {
            let mine: Vec<_> = seen.iter().filter(|((s, _), _)| s == session).collect();
            let lines: usize = mine.iter().map(|(_, (_, o))| o.lines.len()).sum();
            if mine.len() <= SEEN_WINDOWS && (lines <= SEEN_LINES || mine.len() <= 1) {
                break;
            }
            let Some(oldest) = mine.iter().min_by_key(|(_, (t, _))| *t).map(|(k, _)| (*k).clone())
            else {
                break;
            };
            seen.remove(&oldest);
        }
        old
    }

    /// The windows over `window_id` that opened or closed since `before`
    /// (bg-fix's `window_ids_over`: sheets, panels and popovers, another
    /// process's Save panel too).
    pub(super) fn window_changes(&self, window_id: &str, before: &[String]) -> Vec<String> {
        let Some(after) = self.window_ids_over_target(window_id) else { return Vec::new() };
        let mut lines = Vec::new();
        for id in after.iter().filter(|id| !before.contains(id)) {
            let title = self.desktop.window(id).ok().flatten().map(|w| w.title).unwrap_or_default();
            let title = if title.is_empty() {
                String::new()
            } else {
                format!(" {}", outline::quote(&title))
            };
            lines.push(format!("+ window {id}{title} opened over it (window_id {id})"));
        }
        for id in before.iter().filter(|id| !after.contains(id)) {
            lines.push(format!("- window {id} closed"));
        }
        lines
    }

    /// Puts `root` (small ids, screenshot pixels) into `body` as the look
    /// asks: `root` JSON, or `tree` text, whole the first time and the
    /// changes since the agent's last look after that. `menu_only`: show only
    /// the menu the action opened (root children with role `menu`).
    #[allow(clippy::too_many_arguments)] // each argument is one fact of the look
    pub(super) fn present(
        &self,
        session: &str,
        window_id: &str,
        root: &Element,
        truncated: bool,
        look: Look,
        body: &mut serde_json::Map<String, Value>,
        windows: Vec<String>,
        menu_only: Option<u32>,
        pixels: Pixels,
    ) {
        let opts = look.outline_options();
        let new = outline::build(root, truncated, &opts);
        let key = (session.to_string(), window_id.to_string());
        let menus = menu_only.map(|acted| open_menus(root, acted)).unwrap_or_default();
        // What the model reads becomes its last look: not a script's JSON,
        // and not a menu-only look, which showed only the menu.
        let old = if look.json || !menus.is_empty() {
            self.last_seen(&key.0, &key.1)
        } else {
            self.record_seen(&key.0, &key.1, new.clone())
        };
        // The JSON tree stays in the result for direct callers (the CLI, a
        // bench); the MCP result a model reads drops it when it has the
        // outline (ToolOutput::to_mcp).
        body.insert("root".into(), serde_json::to_value(root).unwrap_or(Value::Null));
        body.insert("frames_in".into(), json!("screenshot pixels"));
        body.insert("truncated".into(), json!(truncated));
        // What the agent is shown, for the use-time check: every element of
        // the tree the result carries (the JSON `root` goes back with every
        // look, and a direct caller reads menu items out of it), the menu bar's
        // items included, each with its own chain (menu bar, menu).
        let mut shown_ids = Vec::new();
        fn walk(e: &Element, out: &mut Vec<u32>) {
            if let Ok(n) = e.id.parse() {
                out.push(n);
            }
            e.children.iter().for_each(|c| walk(c, out));
        }
        walk(root, &mut shown_ids);
        self.record_shown(session, window_id, &shown_ids);
        if look.json {
            if !windows.is_empty() {
                body.insert("windows_changed".into(), json!(windows));
            }
            return;
        }
        // The evidence in a fixed shape beside the text, for an outcome
        // (confirmed / no_effect / uncertain) to be decided from: what changed
        // in the elements, the windows over the target, and the pixels.
        // get_ui_tree: no action, no screenshot, no windows to compare.
        let pure_look = pixels == Pixels::NotRead && windows.is_empty() && menus.is_empty();
        let opened = windows.iter().filter(|l| l.starts_with('+')).count();
        let closed = windows.iter().filter(|l| l.starts_with('-')).count();
        let first_look = (old.is_none() || look.full) && menus.is_empty();
        let mut evidence = json!({
            "windows_opened": opened,
            "windows_closed": closed,
            "pixels": pixels.as_str(),
            "elements_read": if truncated { "partial" } else { "all" },
        });
        let mut parts: Vec<String> = windows;
        if !menus.is_empty() {
            let mut text = String::from(
                "The menu is open; only it is shown. Click an item's id (or perform_action press) to choose it, or press_key Escape to close it.",
            );
            for menu in menus {
                let items = outline::build_items(menu, &opts);
                text.push('\n');
                text.push_str(&outline::render_lines(&items, &opts));
            }
            parts.push(text);
        } else {
            let full = outline::render(&new, &opts);
            match old.filter(|_| !look.full) {
                Some(old) => {
                    let changes = diff::compute(&old, &new, &opts);
                    set_key(&mut evidence, "added", json!(changes.added.len()));
                    set_key(
                        &mut evidence,
                        "changed",
                        json!(
                            changes.changed.len() + changes.unfolded.len() + changes.folded.len()
                        ),
                    );
                    set_key(&mut evidence, "removed", json!(changes.removed.len()));
                    set_key(&mut evidence, "renumbered", json!(changes.renumbered.len()));
                    set_key(&mut evidence, "focus_moved", json!(changes.focus.is_some()));
                    match diff::render(&old, &new, &changes, &opts) {
                        // A look of its own (get_ui_tree) needs no account of
                        // pixels or effects: one sentence, and no evidence
                        // (there is no action to judge).
                        None if pure_look => {
                            evidence = Value::Null;
                            parts.push(if truncated {
                                "No change in what this look read (it stopped at the element limit).".into()
                            } else {
                                "No change since your last look.".into()
                            });
                        }
                        // Effects outside the window are the outcome's
                        // (its reason names what was not read).
                        None => {
                            let elements = if truncated {
                                format!(
                                    "No change in the part of window {window_id} read (element limit; a larger max_nodes reads further)"
                                )
                            } else {
                                format!("No change in window {window_id}'s elements")
                            };
                            let pixels = match pixels {
                                Pixels::Changed => "; its pixels changed (see the screenshot): scrolled or drawn content the tree does not describe.",
                                Pixels::Same => "; its pixels look the same.",
                                Pixels::Unknown => "; whether its pixels changed is unknown (no earlier screenshot of it).",
                                Pixels::NotRead => " (full: true shows the whole tree).",
                            };
                            parts.push(format!("{elements}{pixels}"));
                        }
                        Some(d) if d.len() < full.len() => parts.push(format!(
                            "Changes in window {window_id} since your last look (+{} ~{} -{}):\n{d}",
                            changes.added.len(),
                            changes.changed.len() + changes.renumbered.len() + changes.unfolded.len() + changes.folded.len(),
                            changes.removed.len()
                        )),
                        Some(_) => parts.push(format!("Window {window_id} changed throughout; the whole tree:\n{full}")),
                    }
                }
                None => parts.push(full),
            }
        }
        // Only a look compared with an earlier one has element changes; a
        // first get_ui_tree has nothing to compare (the evidence is for
        // judging an action).
        if evidence.get("added").is_some() {
            body.insert("changes".into(), evidence);
        } else if first_look && !pure_look {
            set_key(&mut evidence, "first_look", json!(true));
            body.insert("changes".into(), evidence);
        }
        body.insert("tree".into(), json!(parts.join("\n")));
    }

    /// Turns an acting call's `state` (its tree as JSON) into the look the
    /// call asked for, with the app's windows that opened or closed.
    pub(super) fn present_state(
        &self,
        ctx: &CallContext,
        args: &Value,
        out: &mut ToolOutput,
        before: Option<&[String]>,
        acted: Option<u32>,
        had_screenshot: bool,
    ) {
        let Some(window_id) = args_str(args, "window_id") else { return };
        let menu_open = out.body.pointer("/menu/state") == Some(&json!("open"));
        let Some(Value::Object(mut state)) = out.body.get_mut("state").map(Value::take) else {
            return;
        };
        let windows = before.map(|b| self.window_changes(window_id, b)).unwrap_or_default();
        let look = Look::from_args(args);
        let root = state.remove("root").and_then(|r| serde_json::from_value::<Element>(r).ok());
        if !look.json {
            for key in ["frames_in", "coordinates", "target", "captures"] {
                state.remove(key);
            }
            for key in ["redacted_windows", "left_out_apps"] {
                if state.get(key) == Some(&json!(0)) {
                    state.remove(key);
                }
            }
        }
        match root {
            Some(root) => {
                let truncated = state.get("truncated").and_then(Value::as_bool).unwrap_or(false);
                // Only an adaptive settle compares with a screenshot the agent
                // had; the other modes capture once, forced.
                let pixels = match (
                    had_screenshot,
                    state.get("settle").and_then(Value::as_str),
                    state.get("unchanged"),
                ) {
                    (true, Some("adaptive"), Some(Value::Bool(true))) => Pixels::Same,
                    (true, Some("adaptive"), Some(Value::Bool(false))) => Pixels::Changed,
                    _ => Pixels::Unknown,
                };
                // Named before the action, else by the desktop id the state walk gave it.
                let acted = acted.or_else(|| self.acted_id(args));
                let shown_menu = menu_open && !open_menus(&root, acted.unwrap_or(0)).is_empty();
                self.present(
                    &ctx.session,
                    window_id,
                    &root,
                    truncated,
                    look,
                    &mut state,
                    windows,
                    shown_menu.then_some(acted.unwrap_or(0)),
                    pixels,
                );
                // The outline lists the open menu's items with their ids.
                if shown_menu
                    && !look.json
                    && let Some(menu) = out.body.get_mut("menu").and_then(Value::as_object_mut)
                {
                    menu.remove("items");
                }
            }
            None if !windows.is_empty() => {
                state.insert("tree".into(), json!(windows.join("\n")));
            }
            None => {}
        }
        set_key(&mut out.body, "state", Value::Object(state));
    }

    /// The small id of the element an acting call names, taken before it acts
    /// (the state walk after it gives the desktop's ids anew).
    pub(super) fn acted_id(&self, args: &Value) -> Option<u32> {
        let raw = args_str(args, "element_id")?;
        ids::parse(raw)
            .or_else(|| lock(&self.observe.ids).window(args_str(args, "window_id")?)?.id_of(raw))
    }

    /// The desktop's id for an agent's `[n]`, walking the window again when
    /// the id is a menu bar element of an earlier walk.
    fn resolve_small(&self, session: &str, window: &Window, n: u32) -> Result<String, ToolOutput> {
        let resolved = |e: &Self| {
            lock(&e.observe.ids)
                .window(&window.id)
                .map(|w| w.resolve(n))
                .unwrap_or(ids::Resolved::Unknown)
        };
        let mut r = resolved(self);
        if let ids::Resolved::Carried(e) = &r {
            // A menu bar element waits for a walk with the menus (the default
            // depth, so it is not remembered as the window's reach); one past
            // a cut walk's limit for a deeper walk, which is remembered.
            let options = if e.menu_bar {
                TreeOptions::default()
            } else {
                TreeOptions { max_nodes: 5000, ..TreeOptions::default() }
            };
            self.walk_tree(&window.id, options).map_err(|e| ToolOutput::desktop(&e))?;
            r = resolved(self);
        }
        match r {
            ids::Resolved::Current(e) => {
                self.check_shown(session, window, n)?;
                Ok(e.platform_id)
            }
            ids::Resolved::Gone(what) => Err(stale(format!(
                "element [{n}] ({what}) is no longer in window {}: it closed or was replaced after the state you read it from. Use an id from the latest state of this window, or call get_ui_tree.",
                window.id
            ))),
            ids::Resolved::Carried(_) | ids::Resolved::Unknown => {
                let owner = lock(&self.observe.ids).owner(n).map(str::to_string);
                Err(stale(match owner {
                    Some(other) if other != window.id => format!(
                        "element [{n}] belongs to window {other}, not window {}: pass window_id {other}, or call get_ui_tree on window {} for its own ids.",
                        window.id, window.id
                    ),
                    _ => format!(
                        "element [{n}] is not in window {}: ids come from its get_ui_tree or an action's state. Call get_ui_tree on window {} for its ids.",
                        window.id, window.id
                    ),
                }))
            }
        }
    }

    /// The element behind a desktop id in the window's latest walk (small
    /// ids, global frames).
    fn small_id(&self, window_id: &str, platform_id: &str) -> Option<u32> {
        lock(&self.observe.ids).window(window_id)?.id_of(platform_id)
    }

    /// Element `n` of the window's latest walk, without its children.
    fn known_element(&self, window_id: &str, n: u32) -> Option<Element> {
        let reg = lock(&self.observe.ids);
        let mut e = reg.window(window_id)?.element(n)?.clone();
        e.children.clear();
        Some(e)
    }

    fn in_menu_bar(&self, window_id: &str, n: u32) -> bool {
        let reg = lock(&self.observe.ids);
        reg.window(window_id).and_then(|w| w.entry(n)).is_some_and(|e| e.menu_bar)
    }

    /// The window frame, then its scroll areas around `platform_id`, outermost
    /// first, with their small ids (0 for the window).
    fn clips(&self, window: &Window, n: u32) -> Vec<(u32, Rect)> {
        let reg = lock(&self.observe.ids);
        let Some(w) = reg.window(&window.id) else { return Vec::new() };
        let mut clips = vec![(0, window.frame)];
        let mut areas: Vec<(u32, Rect)> = w
            .ancestors(n)
            .into_iter()
            .filter_map(|a| w.entry(a).map(|e| (a, e)))
            .filter(|(_, e)| e.role == "scroll_area")
            .filter_map(|(a, e)| e.frame.map(|f| (a, f)))
            .collect();
        areas.reverse();
        clips.extend(areas);
        clips
    }

    /// The window's latest tree (global frames), walking it when there is
    /// none or `fresh`.
    fn tree_for_guard(&self, window_id: &str, fresh: bool) -> Option<(Element, bool)> {
        if !fresh
            && let Some((t, truncated)) = lock(&self.observe.ids)
                .window(window_id)
                .and_then(|w| w.tree())
                .map(|(t, x)| (t.clone(), x))
        {
            return Some((t, truncated));
        }
        let tree = self
            .walk_tree(window_id, TreeOptions { menus: false, ..TreeOptions::default() })
            .ok()?;
        Some((tree.root, tree.truncated))
    }

    /// Runs a check on the window's latest tree, and when it refuses on a
    /// tree an earlier call walked, again on a fresh walk: a refusal always
    /// rests on the window as it is now.
    fn confirmed(
        &self,
        window_id: &str,
        check: &dyn Fn(&Self, &Element, bool) -> Option<guards::Refusal>,
    ) -> Option<guards::Refusal> {
        let cached = lock(&self.observe.ids).window(window_id).and_then(|w| w.tree()).is_some();
        let (tree, truncated) = self.tree_for_guard(window_id, false)?;
        // A cached tree cut short (often by the menu bar's share of a
        // get_ui_tree) tells nothing: read the window alone, fresh.
        if cached && truncated {
            let (tree, truncated) = self.tree_for_guard(window_id, true)?;
            return check(self, &tree, truncated);
        }
        let first = check(self, &tree, truncated)?;
        if !cached {
            return Some(first);
        }
        let (tree, truncated) = self.tree_for_guard(window_id, true)?;
        check(self, &tree, truncated)
    }

    /// Maps the call's element id to the desktop's and runs the guards
    /// ([`guards`]) for `tool` on `window`, after policy allowed the call.
    /// `point`: a pixel click's global point.
    pub(super) fn guard(
        &self,
        ctx: &CallContext,
        tool: &str,
        window: &Window,
        args: &Value,
        point: Option<Point>,
    ) -> Result<Guarded, ToolOutput> {
        let element = match args_str(args, "element_id") {
            None => None,
            Some(raw) => Some(match ids::parse(raw) {
                Some(n) => {
                    // Read the window as it is now (the menus too for a menu
                    // item), so the use-time check compares the element the
                    // action would reach, not the one an earlier walk saw.
                    let menu = lock(&self.observe.ids)
                        .window(&window.id)
                        .and_then(|w| w.entry(n))
                        .is_some_and(|e| e.menu_bar);
                    self.walk_tree(
                        &window.id,
                        TreeOptions { menus: menu, ..TreeOptions::default() },
                    )
                    .map_err(|e| ToolOutput::desktop(&e))?;
                    self.resolve_small(&ctx.session, window, n)?
                }
                None => raw.to_string(),
            }),
        };
        let mut out = Guarded { element: element.clone(), done: None };
        let force = args.get("force").and_then(Value::as_bool) == Some(true);
        let foreground = args_str(args, "delivery") == Some("foreground");
        let small = element.as_deref().and_then(|p| self.small_id(&window.id, p));
        let known = small.and_then(|n| self.known_element(&window.id, n));
        let action = args_str(args, "action").unwrap_or_default();

        // A menu bar menu: its items, read while it stays closed.
        if let (Some(el), Some(n)) = (&known, small)
            && el.role == "menu_bar_item"
            && !foreground
            && match tool {
                "click" => {
                    args_str(args, "menu_item").is_none()
                        && args_str(args, "button").is_none_or(|b| b == "left")
                }
                "perform_action" => matches!(action, "press" | "show_menu" | "pick" | "AXPress"),
                _ => false,
            }
            && let Some(listing) = self.menu_bar_listing(&ctx.session, &window.id, n)
        {
            out.done = Some(listing);
            return Ok(out);
        }
        if force {
            return Ok(out);
        }
        let menu_bar = small.is_some_and(|n| self.in_menu_bar(&window.id, n));

        // Disabled: refused on a fresh read (AppKit validates menu items only
        // when their menu opens, so menu bar items are let through).
        let acts_on_element = match tool {
            "click" | "set_value" | "type_text" => true,
            "perform_action" => {
                matches!(action, "press" | "confirm" | "pick" | "increment" | "decrement")
            }
            _ => false,
        };
        if acts_on_element
            && !menu_bar
            && let Some(n) = small
            && known.as_ref().is_some_and(|e| e.disabled)
            && self
                .walk_tree(&window.id, TreeOptions { menus: false, ..TreeOptions::default() })
                .is_ok()
            && let Some(r) = self.known_element(&window.id, n).as_ref().and_then(guards::disabled)
        {
            return Err(refusal(r));
        }

        match tool {
            "type_text" => match &known {
                Some(el) => {
                    if let Some(r) = guards::typing_into(el) {
                        return Err(refusal(r));
                    }
                }
                None if element.is_none() => {
                    let wid = window.id.clone();
                    if let Some(r) = self.confirmed(&window.id, &|_, t, truncated| {
                        guards::typing_without_target(&wid, t, truncated)
                    }) {
                        return Err(refusal(r));
                    }
                }
                None => {}
            },
            "click" if !foreground => {
                if let Some(p) = point
                    && element.is_none()
                {
                    let quartz = self.desktop.draws_title_bars();
                    let wid = window.id.clone();
                    let frame = window.frame;
                    if let Some(r) = self.confirmed(&window.id, &|_, t, truncated| {
                        guards::pixel_click(&wid, &frame, t, truncated, p, quartz)
                    }) {
                        return Err(refusal(r));
                    }
                }
                if let (Some(el), Some(n)) = (&known, small)
                    && !menu_bar
                {
                    let scroll_to_visible = el.actions.iter().any(|a| a == "scroll_to_visible");
                    let check = |e: &Self, _: &Element, _: bool| -> Option<guards::Refusal> {
                        let now = e.known_element(&window.id, n)?;
                        guards::offscreen(&now, &e.clips(window, n), scroll_to_visible)
                    };
                    if guards::offscreen(el, &self.clips(window, n), scroll_to_visible).is_some()
                        && let Some(r) = self.confirmed(&window.id, &check)
                    {
                        return Err(refusal(r));
                    }
                }
            }
            _ => {}
        }
        // A fresh walk above gave the element a new desktop id (and one that
        // carried it walks again: never act on a replaced desktop id).
        // An agent's small id is checked against what it was shown; a desktop
        // id the agent passed itself (the old form) only follows the walk.
        let passed_small = args_str(args, "element_id").and_then(ids::parse).is_some();
        if let Some(n) = small {
            if passed_small {
                out.element = Some(self.resolve_small(&ctx.session, window, n)?);
            } else if let Some(ids::Resolved::Current(e)) =
                lock(&self.observe.ids).window(&window.id).map(|w| w.resolve(n))
            {
                out.element = Some(e.platform_id);
            }
        }
        Ok(out)
    }
    /// A menu bar menu's items, from the walk that read the menus (it stays
    /// closed: the menu bar is the frontmost app's).
    fn menu_bar_listing(&self, session: &str, window_id: &str, n: u32) -> Option<ToolOutput> {
        // Menus change with the app's state (Open Recent, enabled items):
        // list them as they are now.
        self.walk_tree_for(Some(session), window_id, TreeOptions::default()).ok()?;
        let reg = lock(&self.observe.ids);
        let item = reg.window(window_id)?.element(n)?.clone();
        drop(reg);
        let opts = outline::Options { menus: true, ..outline::Options::default() };
        let items = outline::build_items(&item, &opts);
        if items.lines.is_empty() {
            return None;
        }
        let listed: Vec<u32> = items.lines.iter().map(|l| l.id).collect();
        self.record_shown(session, window_id, &listed);
        let title = item.name;
        let mut out = ToolOutput::ok(json!({
            "menu": {
                "state": MENU_BAR_LISTING,
                "title": title,
                "next": "menu bar menus stay closed in the background; click an item's id to run it (or press_key its shortcut)",
            },
        }));
        let tree = json!(format!(
            "Menu {} (not opened; its items):\n{}",
            outline::quote(&title),
            outline::render_lines(&items, &opts)
        ));
        set_key(&mut out.body, "tree", tree);
        Some(out)
    }
}

/// The menus an action left open: menus the desktop walked as the window's
/// own children (a context menu), else the menus under the element it acted
/// on (`acted`, a small id; an open pop-up's menu).
fn open_menus(root: &Element, acted: u32) -> Vec<&Element> {
    let top: Vec<&Element> = root.children.iter().filter(|c| c.role == "menu").collect();
    if !top.is_empty() {
        return top;
    }
    ids::find(root, &acted.to_string())
        .map(|e| e.children.iter().filter(|c| c.role == "menu").collect())
        .unwrap_or_default()
}

/// A window's first walk found fewer elements than this outside its menu
/// bar: it is read once more ([`Engine::walk_tree_for`]).
const REREAD_BELOW: usize = 300;

/// How many elements a tree holds.
fn size(e: &Element) -> usize {
    1 + e.children.iter().map(size).sum::<usize>()
}

/// How many elements a tree holds outside the app's menu bar.
fn size_outside_menus(e: &Element) -> usize {
    1 + e.children.iter().filter(|c| c.role != ids::MENU_BAR).map(size).sum::<usize>()
}
