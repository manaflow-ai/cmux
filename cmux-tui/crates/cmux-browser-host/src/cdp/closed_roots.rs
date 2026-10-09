//! Closed shadow roots on Chromium (closed-shadow design, a9 conditions).
//!
//! WebKit's agent world sees closed shadow roots; a CDP isolated world does
//! not (`el.shadowRoot` is null). The browser knows every root, so the host
//! hands them to a world: `DOM.getDocument {pierce}` in the frame's CDP
//! session lists each closed root with its host element, `DOM.resolveNode`
//! makes both objects in the world, and the world records host -> root (the
//! page agent's `adoptClosedRoot`; a `WeakMap` in the host world, which the
//! capture mask reads). The page's own worlds never see this.
//!
//! The walk runs before a `frame.observe` (agent world) and before a
//! capture mask step (`closedRoots: true`, host world), and only when the
//! session's DOM changed: any `DOM.*` event marks it dirty (DOM events are
//! sent once `DOM.getDocument` enabled the domain). A world adopts a frame's
//! roots once per DOM state.
//!
//! The walk sends every node of the page (about 700 ms and 19 MB on a
//! 100k-node page), so a node count goes first: `DOM.performSearch` with an
//! empty query matches every element, text, comment and CDATA node outside
//! user agent shadow roots, closed roots included, in every document of the
//! session; the world counts the same nodes it can reach (open roots and
//! same-origin frame documents). Equal counts mean no closed root holds a
//! node, and the walk is skipped (about 30 ms on 200k nodes). Any other
//! result, or an error, walks.
//!
//! A skip cannot be cached: without `getDocument` no node events come, so
//! the next sync counts again. A walk can be cached until the next DOM
//! event. So a session counts while the counts it paid since its last walk
//! cost less than a walk is estimated to cost (`walk_is_cheaper`), and then
//! walks once: a static page stops paying per call, a changing page keeps
//! the count. Both paths read the same roots.

use super::driver::{Inner, Session};
use super::evaluate::{Context, handle_group};
use super::state::World;
use crate::protocol::DriverError;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::time::Instant;

/// A tab's closed-root cost (`tab.info closedRoots`): the bench and the
/// parity runs read it, so a regression in the walk shows.
#[derive(Debug, Clone, Copy, Default)]
pub struct WalkStats {
    pub walks: u64,
    pub walk_ms: f64,
    pub roots: u64,
    /// `DOM.*` events received while the domain is on.
    pub dom_events: u64,
    /// Syncs whose node count showed no closed root, so no walk ran.
    pub skips: u64,
    pub skip_ms: f64,
}

impl WalkStats {
    pub fn to_json(self) -> Value {
        json!({"walks": self.walks, "walkMs": self.walk_ms, "roots": self.roots, "domEvents": self.dom_events,
            "skips": self.skips, "skipMs": self.skip_ms})
    }
}

/// DOM events after a read that turn the domain off: about 2 s of a page
/// that changes 50 nodes every 16 ms (6,400 events/s on the Testbox).
pub const DOM_EVENT_BUDGET: u64 = 12_000;
/// The domain also turns off at the first event that comes this long after
/// the last read.
pub const DOM_IDLE_AFTER_READ: std::time::Duration = std::time::Duration::from_secs(30);

/// One CDP session's closed roots, from its last `DOM.getDocument`.
#[derive(Debug, Clone, Default)]
pub struct SessionRoots {
    /// False once a DOM event came after the last walk (or before any).
    fresh: bool,
    /// Frame id -> (host backend node id, root backend node id).
    by_frame: HashMap<String, Vec<(i64, i64)>>,
    /// (frame id, context id) that adopted this walk's roots.
    adopted: HashSet<(String, i64)>,
    /// Whether the DOM domain is on in this session (a walk turns it on).
    dom_on: bool,
    /// DOM events since the last walk, and when that walk ran.
    events_since_read: u64,
    last_read: Option<Instant>,
    /// Node counts since the last walk: their total ms, and the node count
    /// the last one found (the walk's cost estimate).
    counted_ms: f64,
    last_count: Option<u64>,
}

/// Estimated cost of `DOM.getDocument {pierce}` per node: about 700 ms for
/// 200k nodes on the Testbox and on an M5 Pro.
const WALK_MS_PER_NODE: f64 = 0.0035;

/// True when the counts paid since the last walk reach the estimated cost
/// of a walk of `nodes` nodes, so walking (cached until a DOM event) is now
/// the cheaper choice. Without a count yet, counting is.
pub fn walk_is_cheaper(counted_ms: f64, nodes: Option<u64>) -> bool {
    nodes.is_some_and(|nodes| counted_ms >= nodes as f64 * WALK_MS_PER_NODE)
}

impl SessionRoots {
    /// A `DOM.*` event: the next sync walks again. True when the domain
    /// must turn off now (DOM-EVENTS (c): the churn budget is spent, or the
    /// event came long after the last read); the check runs only here, on
    /// an event, never on a timer.
    pub fn dom_changed(&mut self, now: Instant) -> bool {
        self.fresh = false;
        if !self.dom_on {
            return false;
        }
        self.events_since_read += 1;
        let idle = self
            .last_read
            .is_none_or(|read| now.saturating_duration_since(read) > DOM_IDLE_AFTER_READ);
        if self.events_since_read >= DOM_EVENT_BUDGET || idle {
            self.dom_on = false;
            return true;
        }
        false
    }
}

/// Closed roots per frame in a `DOM.getDocument` tree. `frame` is the
/// frame of `node`'s document; a frame owner's content document starts its
/// own frame.
pub fn collect(node: &Value, frame: &str, out: &mut HashMap<String, Vec<(i64, i64)>>) {
    let host = node.get("backendNodeId").and_then(Value::as_i64);
    for root in node.get("shadowRoots").and_then(Value::as_array).into_iter().flatten() {
        if root.get("shadowRootType").and_then(Value::as_str) == Some("closed")
            && let (Some(host), Some(id)) =
                (host, root.get("backendNodeId").and_then(Value::as_i64))
        {
            out.entry(frame.to_owned()).or_default().push((host, id));
        }
        collect(root, frame, out);
    }
    for child in node.get("children").and_then(Value::as_array).into_iter().flatten() {
        collect(child, frame, out);
    }
    if let Some(document) = node.get("contentDocument") {
        let inner = node.get("frameId").and_then(Value::as_str).unwrap_or(frame);
        collect(document, inner, out);
    }
}

/// `frame.observe` methods that walk the DOM (and so must see closed
/// roots); the others read handles or the agent's own tables.
pub const WALKING_OBSERVE_METHODS: &[&str] = &[
    "snapshot",
    "elementAt",
    "splitFrames",
    "queryAll",
    "strictError",
    "iframeHandles",
    "retarget",
];

/// Agent world: the page agent records the pairs. Host world: a WeakMap the
/// capture mask reads (`__cmuxClosedRoots`).
const ADOPT_AGENT: &str = "function (...pairs) { const a = globalThis[Symbol.for('cmux.browserRepl.agent')]; \
    if (!a || !a.adoptClosedRoot) return 0; for (let i = 0; i + 1 < pairs.length; i += 2) a.adoptClosedRoot(pairs[i], pairs[i + 1]); \
    return pairs.length / 2; }";
/// The nodes `DOM.performSearch {query: ""}` matches that a world can
/// reach: elements, text, comments and CDATA from each document element,
/// through open shadow roots and same-origin frame documents.
const COUNT_REACHABLE: &str = "(() => { let n = 0; const show = NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT | NodeFilter.SHOW_COMMENT | NodeFilter.SHOW_CDATA_SECTION; \
    const visit = (root) => { const w = document.createTreeWalker(root, show); \
    for (let x = w.currentNode; x; x = w.nextNode()) { if (x === root && x.nodeType !== 1) continue; n++; if (x.nodeType !== 1) continue; \
    if (x.shadowRoot) visit(x.shadowRoot); let d = null; try { d = x.contentDocument; } catch (e) {} if (d && d.documentElement) visit(d.documentElement); } }; \
    if (document.documentElement) visit(document.documentElement); return n; })()";

const ADOPT_HOST: &str = "function (...pairs) { const m = globalThis.__cmuxClosedRoots || (globalThis.__cmuxClosedRoots = new WeakMap()); \
    for (let i = 0; i + 1 < pairs.length; i += 2) m.set(pairs[i], pairs[i + 1]); return pairs.length / 2; }";

impl Inner {
    /// `sync_closed_roots` for a call's tab and frame (`frameId`, else the
    /// main frame).
    pub(super) fn sync_closed_roots_for(
        &self,
        params: &Value,
        world: World,
    ) -> Result<(), DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + crate::protocol::timeout_of(params);
        let frame_id = self.frame_or_main(&session, params)?;
        self.sync_closed_roots(&session, &frame_id, world, deadline)
    }

    /// Makes `world` of the frame see the frame's closed shadow roots.
    pub(super) fn sync_closed_roots(
        &self,
        session: &Session,
        frame_id: &str,
        world: World,
        deadline: Instant,
    ) -> Result<(), DriverError> {
        let context = self.context(session, frame_id, world, deadline)?;
        let cdp = context.session.clone();
        let fresh = self
            .lock()
            .tabs
            .get(&session.target_id)
            .and_then(|tab| tab.closed_roots.get(&cdp))
            .is_some_and(|roots| roots.fresh);
        if !fresh {
            self.walk(session, &cdp, world, deadline)?;
        }
        let pairs = {
            let mut state = self.lock();
            let Some(roots) = state
                .tabs
                .get_mut(&session.target_id)
                .and_then(|tab| tab.closed_roots.get_mut(&cdp))
            else {
                return Ok(());
            };
            if !roots.adopted.insert((frame_id.to_owned(), context.id)) {
                return Ok(());
            }
            roots.by_frame.get(frame_id).cloned().unwrap_or_default()
        };
        if pairs.is_empty() {
            return Ok(());
        }
        self.adopt(&context, &pairs, world, deadline)
    }

    /// One `DOM.getDocument {pierce}` of a CDP session.
    fn walk(
        &self,
        session: &Session,
        cdp: &str,
        world: World,
        deadline: Instant,
    ) -> Result<(), DriverError> {
        let (root_frame, dom_was_on, counted_ms, last_count) = {
            let mut state = self.lock();
            let Some(tab) = state.tabs.get_mut(&session.target_id) else {
                return Ok(());
            };
            let entry = tab.closed_roots.entry(cdp.to_owned()).or_default();
            let dom_was_on = entry.dom_on;
            let (counted_ms, last_count) = (entry.counted_ms, entry.last_count);
            // Fresh from now on: a DOM event during the walk marks it stale
            // again. The walk's getDocument turns the DOM domain on.
            *entry = SessionRoots {
                fresh: true,
                dom_on: true,
                last_read: Some(Instant::now()),
                counted_ms,
                last_count,
                ..SessionRoots::default()
            };
            let root_frame = if cdp == tab.session_id {
                tab.main_frame.clone()
            } else {
                tab.frame_sessions.iter().find(|(_, s)| s.as_str() == cdp).map(|(f, _)| f.clone())
            };
            (root_frame, dom_was_on, counted_ms, last_count)
        };
        let Some(root_frame) = root_frame else {
            return Ok(());
        };
        let started = Instant::now();
        if !walk_is_cheaper(counted_ms, last_count) {
            let count = self.closed_root_count(session, cdp, &root_frame, world, dom_was_on, deadline);
            let ms = started.elapsed().as_secs_f64() * 1000.0;
            let mut state = self.lock();
            if let Some(tab) = state.tabs.get_mut(&session.target_id) {
                if let Some(entry) = tab.closed_roots.get_mut(cdp) {
                    entry.counted_ms += ms;
                    entry.last_count = count.map(|(nodes, _)| nodes).or(entry.last_count);
                }
                if count.is_some_and(|(_, none)| none) {
                    tab.closed_root_stats.skips += 1;
                    tab.closed_root_stats.skip_ms += ms;
                    // Not fresh: without getDocument no node events come,
                    // so the next sync counts again.
                    if let Some(entry) = tab.closed_roots.get_mut(cdp) {
                        entry.fresh = false;
                        entry.by_frame.clear();
                    }
                    return Ok(());
                }
            }
        }
        let started = Instant::now();
        let document =
            self.send_on(cdp, "DOM.getDocument", json!({"depth": -1, "pierce": true}), deadline)?;
        let mut by_frame = HashMap::new();
        collect(&document["root"], &root_frame, &mut by_frame);
        let roots: usize = by_frame.values().map(Vec::len).sum();
        let mut state = self.lock();
        if let Some(tab) = state.tabs.get_mut(&session.target_id) {
            let stats = &mut tab.closed_root_stats;
            stats.walks += 1;
            stats.walk_ms += started.elapsed().as_secs_f64() * 1000.0;
            stats.roots += roots as u64;
            if let Some(entry) = tab.closed_roots.get_mut(cdp) {
                entry.by_frame = by_frame;
                entry.counted_ms = 0.0;
            }
        }
        Ok(())
    }

    /// The session's node count (`DOM.performSearch`) and whether it shows
    /// that no closed shadow root holds a node. None on any error (the
    /// caller walks).
    fn closed_root_count(
        &self,
        session: &Session,
        cdp: &str,
        root_frame: &str,
        world: World,
        dom_on: bool,
        deadline: Instant,
    ) -> Option<(u64, bool)> {
        let context = self.context(session, root_frame, world, deadline).ok()?;
        if context.session != cdp {
            return None;
        }
        let reachable = self
            .send_on(
                cdp,
                "Runtime.evaluate",
                json!({"expression": COUNT_REACHABLE, "contextId": context.id, "returnByValue": true}),
                deadline,
            )
            .ok()
            .and_then(|reply| reply["result"]["value"].as_u64());
        let reachable = reachable?;
        // performSearch needs the DOM domain (a walk turns it on too).
        if !dom_on {
            self.send_on(cdp, "DOM.enable", json!({}), deadline).ok()?;
        }
        let search = self
            .send_on(
                cdp,
                "DOM.performSearch",
                json!({"query": "", "includeUserAgentShadowDOM": false}),
                deadline,
            )
            .ok()?;
        if let Some(id) = search["searchId"].as_str() {
            let _ = self.send_on(cdp, "DOM.discardSearchResults", json!({"searchId": id}), deadline);
        }
        let nodes = search["resultCount"].as_u64()?;
        Some((nodes, nodes == reachable))
    }

    fn adopt(
        &self,
        context: &Context,
        pairs: &[(i64, i64)],
        world: World,
        deadline: Instant,
    ) -> Result<(), DriverError> {
        let group = handle_group();
        let mut arguments = Vec::with_capacity(pairs.len() * 2);
        let mut resolved = Ok(());
        'pairs: for &(host, root) in pairs {
            let mut objects = Vec::with_capacity(2);
            for node in [host, root] {
                match self.send_on(
                    &context.session,
                    "DOM.resolveNode",
                    json!({"backendNodeId": node, "executionContextId": context.id, "objectGroup": group}),
                    deadline,
                ) {
                    Ok(reply) => match reply["object"]["objectId"].as_str() {
                        Some(id) => objects.push(json!({"objectId": id})),
                        None => continue 'pairs,
                    },
                    // A node that went away since the walk: skip it.
                    Err(_) => continue 'pairs,
                }
            }
            arguments.extend(objects);
        }
        if !arguments.is_empty() {
            let source = if world == World::Host { ADOPT_HOST } else { ADOPT_AGENT };
            resolved = self
                .send_on(
                    &context.session,
                    "Runtime.callFunctionOn",
                    json!({"functionDeclaration": source, "executionContextId": context.id,
                        "arguments": arguments, "returnByValue": true}),
                    deadline,
                )
                .map(|_| ());
        }
        self.release_handles(&context.session, &group);
        resolved
    }
}

#[cfg(test)]
mod tests {
    use super::super::state::State;
    use super::*;
    use crate::cdp::CdpEvent;
    use std::time::Duration;

    /// A tab whose session `S` was read `ago` before now (domain on).
    fn read_state(ago: Duration) -> State {
        let mut state = State::default();
        let mut tab =
            super::super::state::TabState::new("S".into(), "u".into(), String::new(), None);
        tab.closed_roots.insert(
            "S".into(),
            SessionRoots {
                fresh: true,
                dom_on: true,
                last_read: Instant::now().checked_sub(ago),
                ..SessionRoots::default()
            },
        );
        state.tabs.insert("T".into(), tab);
        state.sessions.insert("S".into(), "T".into());
        state
    }

    fn dom_event(state: &mut State) -> String {
        let applied = state.apply(&CdpEvent {
            session_id: Some("S".into()),
            method: "DOM.characterDataModified".into(),
            params: json!({"nodeId": 7, "characterData": "x"}),
        });
        format!("{:?}", applied.follow_ups)
    }

    fn roots(state: &State) -> &SessionRoots {
        &state.tabs["T"].closed_roots["S"]
    }

    #[test]
    fn a_session_counts_until_the_counts_cost_a_walk() {
        // No count yet: count.
        assert!(!walk_is_cheaper(0.0, None));
        assert!(!walk_is_cheaper(1e9, None));
        // 200k nodes: a walk is about 700 ms.
        assert!(!walk_is_cheaper(0.0, Some(200_000)));
        assert!(!walk_is_cheaper(699.0, Some(200_000)));
        assert!(walk_is_cheaper(700.0, Some(200_000)));
        // A small page walks soon: its walk is cheap too.
        assert!(walk_is_cheaper(1.0, Some(100)));
    }

    #[test]
    fn a_churning_page_turns_dom_events_off_after_the_event_budget() {
        let mut state = read_state(Duration::from_secs(1));
        for _ in 1..DOM_EVENT_BUDGET {
            assert!(!dom_event(&mut state).contains("DisableDom"));
        }
        assert!(roots(&state).dom_on);
        assert!(
            dom_event(&mut state).contains("DisableDom"),
            "the budget's last event turns it off"
        );
        assert!(!roots(&state).dom_on);
        assert!(!roots(&state).fresh, "roots are stale once the domain is off");
        assert!(!dom_event(&mut state).contains("DisableDom"), "turned off once");
    }

    #[test]
    fn the_first_event_long_after_a_read_turns_dom_events_off() {
        let mut state = read_state(DOM_IDLE_AFTER_READ + Duration::from_secs(1));
        assert!(dom_event(&mut state).contains("DisableDom"));
        assert!(!roots(&state).dom_on && !roots(&state).fresh);
        let mut recent = read_state(Duration::from_secs(1));
        assert!(!dom_event(&mut recent).contains("DisableDom"));
        assert!(roots(&recent).dom_on && !roots(&recent).fresh);
    }

    #[test]
    fn closed_roots_are_grouped_by_their_frame() {
        let tree = json!({"backendNodeId": 1, "children": [
            {"backendNodeId": 2, "shadowRoots": [{"backendNodeId": 3, "shadowRootType": "closed", "children": [
                {"backendNodeId": 4, "shadowRoots": [{"backendNodeId": 5, "shadowRootType": "closed"}]}]}]},
            {"backendNodeId": 6, "shadowRoots": [{"backendNodeId": 7, "shadowRootType": "open"}]},
            {"backendNodeId": 8, "frameId": "F2", "contentDocument": {"backendNodeId": 9, "children": [
                {"backendNodeId": 10, "shadowRoots": [{"backendNodeId": 11, "shadowRootType": "closed"}]}]}},
        ]});
        let mut out = HashMap::new();
        collect(&tree, "F1", &mut out);
        assert_eq!(out["F1"], vec![(2, 3), (4, 5)]);
        assert_eq!(out["F2"], vec![(10, 11)]);
        assert_eq!(out.len(), 2);
    }
}
