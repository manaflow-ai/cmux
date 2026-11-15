//! The engine's side of [`crate::observe`]: every tree walk gives the
//! window's elements their stable ids, every look is shown as an outline
//! (the changes after the agent's first look), an action's element id is
//! mapped back to the desktop's, and the guards run before acting.

use super::*;
use crate::desktop::UiTree;
use crate::observe::{Look, diff, guards, ids, outline};

/// What the engine keeps for observation.
#[derive(Default)]
pub(super) struct Observe {
    ids: Mutex<ids::Registry>,
    /// One walk at a time, so the ids recorded are those of the desktop's
    /// latest tree of the window.
    walking: Mutex<()>,
    /// (session, window) -> the outline the agent last saw of it.
    seen: Mutex<HashMap<(String, String), outline::Outline>>,
    /// window -> the most elements a walk of it was asked for, when more than
    /// the default: later default walks read as far, so ids past the default
    /// limit stay current instead of being carried (and healed every action).
    reach: Mutex<HashMap<String, usize>>,
}

/// An action's target after the guards: the desktop's element id, or the
/// call's whole result when it needs no input (a menu bar menu's items).
#[derive(Default)]
pub(super) struct Guarded {
    pub element: Option<String>,
    pub done: Option<ToolOutput>,
}

/// The state key of an action whose result needs no window state (it read a
/// menu bar menu without opening it).
pub(super) const MENU_BAR_LISTING: &str = "menu_bar";

fn stale(message: String) -> ToolOutput {
    ToolOutput::error("stale_element", message)
}

fn refusal(r: guards::Refusal) -> ToolOutput {
    ToolOutput::error(r.code, r.message)
}

impl Engine {
    /// Walks `window_id`'s tree and gives its elements their ids (the tree
    /// comes back with them, frames still in global points).
    pub(super) fn walk_tree(
        &self,
        window_id: &str,
        options: TreeOptions,
    ) -> Result<UiTree, DesktopError> {
        let _walking = lock(&self.observe.walking);
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
        lock(&self.observe.ids).assign(window_id, &mut tree, options.menus);
        Ok(tree)
    }

    /// The agent's view of the window is unknown (a retried call's first
    /// reply may not have reached it): its next look is whole.
    pub(super) fn forget_seen(&self, session: &str, window_id: &str) {
        lock(&self.observe.seen).remove(&(session.to_string(), window_id.to_string()));
    }

    pub(super) fn forget_session_seen(&self, session: &str) {
        lock(&self.observe.seen).retain(|(s, _), _| s != session);
    }

    /// The windows over `window_id` that opened or closed since `before`
    /// (bg-fix's `window_ids_over`: sheets, panels and popovers, another
    /// process's Save panel too).
    fn window_changes(&self, window_id: &str, before: &[String]) -> Vec<String> {
        let Some(after) = self.window_ids_over_target(window_id) else { return Vec::new() };
        let mut lines = Vec::new();
        for id in after.iter().filter(|id| !before.contains(id)) {
            let title = self.desktop.window(id).ok().flatten().map(|w| w.title).unwrap_or_default();
            let title = if title.is_empty() { String::new() } else { format!(" {}", outline::quote(&title)) };
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
        pixels_changed: bool,
    ) {
        let opts = look.outline_options();
        let new = outline::build(root, truncated, &opts);
        let key = (session.to_string(), window_id.to_string());
        let menus = menu_only.map(|acted| open_menus(root, acted)).unwrap_or_default();
        // What the model reads becomes its last look: not a script's JSON,
        // and not a menu-only look, which showed only the menu.
        let old = if look.json || !menus.is_empty() {
            lock(&self.observe.seen).get(&key).cloned()
        } else {
            lock(&self.observe.seen).insert(key, new.clone())
        };
        if look.json {
            body.insert("root".into(), serde_json::to_value(root).unwrap_or(Value::Null));
            body.insert("frames_in".into(), json!("screenshot pixels"));
            if !windows.is_empty() {
                body.insert("windows_changed".into(), json!(windows));
            }
            return;
        }
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
                    match diff::render(&old, &new, &changes, &opts) {
                        None if pixels_changed => parts.push(format!(
                            "No change in window {window_id}'s elements since your last look, but its pixels changed (see the screenshot): something the tree does not describe moved, such as scrolled or drawn content."
                        )),
                        None => parts.push(format!(
                            "No change in window {window_id}'s elements since your last look (full: true shows the whole tree)."
                        )),
                        Some(d) if d.len() < full.len() => parts.push(format!(
                            "Changes in window {window_id} since your last look (+{} ~{} -{}):\n{d}",
                            changes.added.len(),
                            changes.changed.len(),
                            changes.removed.len()
                        )),
                        Some(_) => parts.push(format!("Window {window_id} changed throughout; the whole tree:\n{full}")),
                    }
                }
                None => parts.push(full),
            }
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
            let truncated = state.get("truncated").and_then(Value::as_bool).unwrap_or(false);
            for key in ["frames_in", "coordinates", "target", "captures"] {
                state.remove(key);
            }
            if !truncated {
                state.remove("truncated");
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
                let pixels_changed = state.get("unchanged") == Some(&json!(false));
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
                    pixels_changed,
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
        out.body["state"] = Value::Object(state);
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
    fn resolve_small(&self, window: &Window, n: u32) -> Result<String, ToolOutput> {
        let resolved = |e: &Self| {
            lock(&e.observe.ids)
                .window(&window.id)
                .map(|w| w.resolve(n))
                .unwrap_or(ids::Resolved::Unknown)
        };
        let mut r = resolved(self);
        if matches!(r, ids::Resolved::Carried(_)) {
            // Carried from a walk with the menus, or past a walk's limit.
            self.walk_tree(&window.id, TreeOptions { max_nodes: 5000, ..TreeOptions::default() })
                .map_err(|e| ToolOutput::desktop(&e))?;
            r = resolved(self);
        }
        match r {
            ids::Resolved::Current(e) => Ok(e.platform_id),
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
        let _ = ctx;
        let element = match args_str(args, "element_id") {
            None => None,
            Some(raw) => Some(match ids::parse(raw) {
                Some(n) => self.resolve_small(window, n)?,
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
            && let Some(listing) = self.menu_bar_listing(&window.id, n)
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
                    let wid = window.id.clone();
                    let frame = window.frame;
                    if let Some(r) = self.confirmed(&window.id, &|_, t, truncated| {
                        guards::pixel_click(&wid, &frame, t, truncated, p)
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
        if let Some(n) = small {
            out.element = Some(self.resolve_small(window, n)?);
        }
        Ok(out)
    }
    /// A menu bar menu's items, from the walk that read the menus (it stays
    /// closed: the menu bar is the frontmost app's).
    fn menu_bar_listing(&self, window_id: &str, n: u32) -> Option<ToolOutput> {
        let reg = lock(&self.observe.ids);
        let item = reg.window(window_id)?.element(n)?.clone();
        drop(reg);
        let opts = outline::Options { menus: true, ..outline::Options::default() };
        let items = outline::build_items(&item, &opts);
        if items.lines.is_empty() {
            return None;
        }
        let title = item.name;
        let mut out = ToolOutput::ok(json!({
            "menu": {
                "state": MENU_BAR_LISTING,
                "title": title,
                "next": "menu bar menus stay closed in the background; click an item's id to run it (or press_key its shortcut)",
            },
        }));
        out.body["tree"] = json!(format!(
            "Menu {} (not opened; its items):\n{}",
            outline::quote(&title),
            outline::render_lines(&items, &opts)
        ));
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
