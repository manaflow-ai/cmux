//! What one `list-workspaces` request and one `session.snapshot` request do, as counts.
//!
//! In a session of 826 workspaces these two requests took 10 to 36 ms and 21 to 52 ms. Most of
//! that time was work that a reply does not need:
//!
//! - A connection that did not declare each tab capability got its reply from the text: the
//!   whole reply was written, parsed, changed and written a second time.
//! - The catalog check of a `session.snapshot` result built a path string for each value of the
//!   result, and used it only for a value that fails.
//! - Each walk of the tree read the git HEAD of each terminal's directory when its cached value
//!   was older than 2 seconds: one file-system walk for each directory. Each walk and each
//!   `list-workspaces` request, with or without `known`, now takes the cached value and leaves
//!   the read to one background refresh, which a watch of the HEAD files wakes
//!   (list_request_counts/git_head_watch.rs). A branch that the refresh finds changed goes to
//!   each client.
//! - `list-workspaces` built the nodes of its tree with the mux state lock held: each request
//!   that needs the state waited for the whole build.
//!
//! Each test here counts (texts, parses, allocations, git reads, holds of the state lock), so a
//! loaded host does not change its result. No test asserts a time.
//!
//! The session is the one a daemon has: a registry that is a file, with the journal writer
//! thread, and each terminal in a directory of its own below a test repository.

use super::list_workspaces_cost::allocations_of;
use super::*;
use crate::event_bus::MuxEventReceiver;
use crate::mux::{MuxEvent, TreeDeltaKind};
use crate::state::conversation_tabs_store::{
    AGENT_SESSION_TABS_CAPABILITY, CLOSED_CONVERSATION_TABS_CAPABILITY,
    CONVERSATION_TABS_CAPABILITY, PAGE_TABS_CAPABILITY,
};
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::time::Instant;

const TAB_CAPABILITIES: [&str; 4] = [
    CONVERSATION_TABS_CAPABILITY,
    AGENT_SESSION_TABS_CAPABILITY,
    PAGE_TABS_CAPABILITY,
    CLOSED_CONVERSATION_TABS_CAPABILITY,
];

fn workspace_key(index: usize) -> String {
    format!("018f6e21-7b70-7e70-8000-{index:012}")
}

/// A session of `workspaces` workspaces with one running terminal each, on a registry file below
/// a directory of its own, with the journal's public fold complete, as in a live session.
struct Session {
    root: PathBuf,
    mux: Arc<Mux>,
    surfaces: Vec<SurfaceId>,
}

impl Session {
    fn of(name: &str, workspaces: usize) -> Self {
        Self::with_git_head_watch(name, workspaces, false)
    }

    /// [`Self::of`], with the watch of the HEAD files that a daemon has when `watch_git_heads`.
    fn with_git_head_watch(name: &str, workspaces: usize, watch_git_heads: bool) -> Self {
        let root = std::env::temp_dir().join(format!(
            "cmux-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let registry = crate::workspace_registry::WorkspaceRegistry::open(&root, name).unwrap();
        let mux = Mux::from_workspace_registry(
            name.to_string(),
            SurfaceOptions::default(),
            registry,
            crate::mux::ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        // Only the test writes: a commit of the maintenance worker between two requests would
        // change what the second one does.
        mux.stop_journal_maintenance();
        // A test here writes a HEAD file and counts the reads that follow: with no watch, only a
        // value past its lifetime is read again. The watch has its own tests (git_head_watch.rs).
        if !watch_git_heads {
            mux.stop_git_head_watch_for_test();
        }
        let mut terminals = Vec::with_capacity(workspaces);
        for index in 0..workspaces {
            mux.create_empty_workspace(
                Some(format!("ws {index}")),
                Some(workspace_key(index)),
                None,
            )
            .unwrap();
            let number = index + 1;
            terminals.push((
                format!("00000000000040008000{number:012x}"),
                format!("10000000000040008000{number:012x}"),
                workspace_key(index),
            ));
        }
        let surfaces = mux.seed_running_terminals_for_test(&terminals).unwrap();
        let (key, operation) = ("seed-public-fold", "test.seed_public_fold");
        let fingerprint = json!({"operation": operation, "fixture": key});
        let expected_revision = mux.with_state(|state| state.resource_revision);
        mux.prepare_resource_effect(
            &WorkspaceMutation::daemon(key, "test").unwrap(),
            operation,
            &fingerprint,
            &json!({}),
            None,
            Some(expected_revision),
        )
        .unwrap();
        mux.mark_resource_effect_executing(key, operation, &fingerprint).unwrap();
        mux.commit_full_resource_effect_projection(key, operation, &fingerprint, json!({}))
            .unwrap();
        Self { root, mux, surfaces }
    }

    /// A repository below the session's directory whose HEAD is the branch `branch`.
    fn repository(&self, name: &str, branch: &str) -> PathBuf {
        let repository = self.root.join(name);
        std::fs::create_dir_all(repository.join(".git")).unwrap();
        set_branch(&repository, branch);
        repository
    }

    /// Gives each terminal a directory of its own: terminal `n` is below
    /// `repositories[n % repositories.len()]`.
    fn give_directories(&self, repositories: &[PathBuf]) {
        for (index, surface) in self.surfaces.iter().enumerate() {
            let repository = &repositories[index % repositories.len()];
            let directory = repository.join(format!("project-{index}")).join("src");
            std::fs::create_dir_all(&directory).unwrap();
            let runtime = self.mux.surface(*surface).unwrap();
            runtime.commit_published_directory(Some(directory.to_string_lossy().into_owned()));
        }
    }

    /// One conversation tab in the pane of the first terminal: the tab kind that a connection
    /// without the capabilities reads as another kind.
    fn add_conversation_tab(&self) {
        let pane = self.mux.with_state(|state| state.pane_of(self.surfaces[0])).unwrap();
        run_json_command(
            &self.mux,
            json!({"cmd": "new-conversation-tab", "pane": pane,
                   "agent_session": {"host": "install:mac-test"}}),
        )
        .unwrap();
    }

    fn end(self) {
        wait_until("each git HEAD refresh ended", || Mux::git_head_refreshes_running() == 0);
        self.mux.shutdown();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn set_branch(repository: &Path, branch: &str) {
    std::fs::write(repository.join(".git").join("HEAD"), format!("ref: refs/heads/{branch}\n"))
        .unwrap();
}

fn wait_until(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting until {what}");
        std::thread::yield_now();
    }
}

/// A local (Unix socket) connection of the daemon.
struct Connection {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Connection {
    /// A connection whose writer uses `render`, with `capabilities` declared when there are any.
    fn open(mux: &Arc<Mux>, render: &Arc<RenderService>, capabilities: &[&str]) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new_with_render_service(
            QueuedSink { outbound: outbound.clone(), control: None },
            render.clone(),
        );
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let connection = Self { client, writer, outbound, scheduler };
        if !capabilities.is_empty() {
            let info = connection.command(
                mux,
                json!({"id": "info", "cmd": "set-client-info", "name": "test",
                       "capabilities": capabilities}),
            );
            assert!(info.contains("\"ok\":true"), "{info}");
        }
        connection
    }

    /// The reply line to the legacy command `request`, which runs on this thread.
    fn command(&self, mux: &Arc<Mux>, request: Value) -> String {
        let request: Request = serde_json::from_value(request).unwrap();
        assert!(handle_request(mux, self.client, request, &self.writer));
        self.reply()
    }

    /// The reply line to `list-workspaces`.
    fn list(&self, mux: &Arc<Mux>) -> String {
        let reply = self.command(mux, json!({"id": 1, "cmd": "list-workspaces"}));
        assert!(reply.contains("\"ok\":true"), "{}", start_of(&reply));
        reply
    }

    /// The data of the reply to `list-workspaces` with `known`.
    fn list_since(&self, mux: &Arc<Mux>, known: &Value) -> Value {
        let reply = self.command(mux, json!({"id": 1, "cmd": "list-workspaces", "known": known}));
        let mut reply: Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(reply["ok"], json!(true), "{reply}");
        reply["data"].take()
    }

    /// The reply line to a v2 `session.snapshot`, which runs on this thread.
    fn snapshot(&self, mux: &Arc<Mux>) -> String {
        let line = resource_request(
            "snapshot",
            "session.snapshot",
            json!({"machine": "current", "session": "current"}),
            None,
        );
        assert!(handle_connection_message(mux, self.client, &line, &self.writer, &self.scheduler));
        let reply = self.reply();
        assert!(reply.contains("\"ok\":true"), "{}", start_of(&reply));
        reply
    }

    fn reply(&self) -> String {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Some(line) = self.outbound.try_pop() {
                return line;
            }
            assert!(Instant::now() < deadline, "no reply");
            std::thread::yield_now();
        }
    }
}

fn start_of(reply: &str) -> String {
    reply.chars().take(600).collect()
}

/// The texts that `render` wrote and the messages that the projection parsed on this thread
/// while `request` ran, with its reply.
fn texts_and_parses(
    render: &RenderService,
    request: impl FnOnce() -> String,
) -> (usize, u64, String) {
    let texts = render.control_serializations.load(Ordering::SeqCst);
    let parses = conversation_tabs_wire::message_parses_on_this_thread();
    let reply = request();
    (
        render.control_serializations.load(Ordering::SeqCst) - texts,
        conversation_tabs_wire::message_parses_on_this_thread() - parses,
        reply,
    )
}

#[test]
fn a_list_workspaces_reply_without_the_tab_capabilities_is_written_one_time() {
    let session = Session::of("list-counts-tree-text", 6);
    session.add_conversation_tab();
    let mux = &session.mux;
    let render = Arc::new(RenderService::new());
    let plain = Connection::open(mux, &render, &[]);
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    plain.list(mux);

    let (app_texts, app_parses, app_reply) = texts_and_parses(&render, || app.list(mux));
    assert!(app_reply.contains("\"kind\":\"conversation\""), "{}", start_of(&app_reply));
    assert_eq!((app_texts, app_parses), (1, 0), "a connection with each tab capability");

    let (texts, parses, reply) = texts_and_parses(&render, || plain.list(mux));
    assert!(
        !reply.contains("\"kind\":\"conversation\""),
        "a connection without the capabilities reads the conversation tab as another kind"
    );
    assert_eq!(
        (texts, parses),
        (1, 0),
        "a list-workspaces reply for a connection without the tab capabilities was written \
         {texts} times and parsed from its text {parses} times"
    );
    session.end();
}

/// The projection of a tree changes the tree where it is. It reads the tree through a reply
/// envelope, and that envelope is one map: `json!` of an expression serializes the expression,
/// which is a copy of the whole tree.
#[test]
fn the_tab_projection_of_a_tree_makes_no_copy_of_it() {
    let session = Session::of("list-counts-projection-copy", 6);
    session.add_conversation_tab();
    let mux = &session.mux;
    let render = Arc::new(RenderService::new());
    let plain = Connection::open(mux, &render, &[]);
    let projection = plain.writer.tab_projection();
    assert!(!projection.is_canonical(), "a connection with no capability has a projection");
    let mut tree = list_workspaces_tree(mux).unwrap();
    assert!(tree.to_string().contains("\"kind\":\"conversation\""), "the tree has the tab");
    let (copy, copy_allocations) = allocations_of(|| tree.clone());
    drop(copy);
    let (changed, allocations) = allocations_of(|| projection.project_data(&mut tree));
    assert!(changed, "the conversation tab reads as another kind");
    assert!(!tree.to_string().contains("\"kind\":\"conversation\""), "the tab is projected");
    assert!(
        allocations <= 16,
        "the tab projection of a tree made {allocations} allocations; one deep copy of that \
         tree makes {copy_allocations}"
    );
    session.end();
}

#[test]
fn a_session_snapshot_reply_without_the_tab_capabilities_is_written_one_time() {
    let session = Session::of("list-counts-snapshot-text", 6);
    session.add_conversation_tab();
    let mux = &session.mux;
    let render = Arc::new(RenderService::new());
    let plain = Connection::open(mux, &render, &[]);
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    plain.snapshot(mux);

    let (app_texts, app_parses, app_reply) = texts_and_parses(&render, || app.snapshot(mux));
    assert_eq!((app_texts, app_parses), (1, 0), "a connection with each tab capability");

    let (texts, parses, reply) = texts_and_parses(&render, || plain.snapshot(mux));
    assert_ne!(
        reply, app_reply,
        "a connection without the capabilities reads the conversation tab as another kind"
    );
    assert_eq!(
        (texts, parses),
        (1, 0),
        "a session.snapshot reply for a connection without the tab capabilities was written \
         {texts} times and parsed from its text {parses} times"
    );
    session.end();
}

/// The allocations of the catalog check of the `session.snapshot` result of a session of
/// `workspaces` workspaces, and the number of values in that result.
fn snapshot_check_allocations(name: &str, workspaces: usize) -> (u64, usize) {
    fn values(value: &Value) -> usize {
        match value {
            Value::Array(items) => 1 + items.iter().map(values).sum::<usize>(),
            Value::Object(fields) => 1 + fields.values().map(values).sum::<usize>(),
            _ => 1,
        }
    }
    let session = Session::of(name, workspaces);
    let mux = &session.mux;
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    let mut reply: Value = serde_json::from_str(&app.snapshot(mux)).unwrap();
    let result = reply["result"].take();
    assert!(result.is_object(), "the reply has no result");
    let count = values(&result);
    // The first check of a process reads the catalog.
    let check = |result: Value| {
        crate::resource_router::validate_operation_outcome(
            ResourceOperation::SessionSnapshot,
            Ok(result),
        )
    };
    let result = check(result).unwrap();
    let (checked, allocations) = allocations_of(|| check(result));
    assert!(checked.is_ok(), "the snapshot of a session fails its catalog type");
    session.end();
    (allocations, count)
}

#[test]
fn the_catalog_check_of_a_snapshot_that_passes_builds_no_path() {
    let (small, small_values) = snapshot_check_allocations("list-counts-check-small", 3);
    let (large, large_values) = snapshot_check_allocations("list-counts-check-large", 12);
    assert!(large_values > small_values + 100, "{small_values} and {large_values} values");
    assert!(
        large <= 16 && small <= 16,
        "the catalog check of a snapshot that passes made {small} allocations for {small_values} \
         values and {large} allocations for {large_values} values: it builds a string for each \
         value"
    );
}

/// A request with `known` that gets the whole tree (here a client that holds no tree yet and
/// sends an empty `known`) reads a directory only when the cache has no value for it.
#[test]
fn a_known_reply_with_the_whole_tree_reads_no_git_head_of_a_cached_directory() {
    let session = Session::of("list-counts-git-reads", 6);
    let mux = &session.mux;
    session.give_directories(&[session.repository("repository", "main")]);
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);

    // No cached value: the reply reads each directory, so the first reply of a client has its
    // branches.
    let before = Mux::git_head_reads_on_this_thread();
    let first = app.list_since(mux, &json!({})).to_string();
    assert_eq!(first.matches("\"git_branch\":\"main\"").count(), 6, "{}", start_of(&first));
    assert_eq!(Mux::git_head_reads_on_this_thread() - before, 6, "one read for each directory");

    assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
    let before = Mux::git_head_reads_on_this_thread();
    let stale = app.list_since(mux, &json!({})).to_string();
    let reads = Mux::git_head_reads_on_this_thread() - before;
    assert_eq!(stale.matches("\"git_branch\":\"main\"").count(), 6, "{}", start_of(&stale));
    assert_eq!(
        reads, 0,
        "a list-workspaces reply to a request with `known` made {reads} git HEAD reads for 6 \
         directories that each have a cached value"
    );
    session.end();
}

#[test]
fn list_requests_inside_one_git_head_refresh_start_no_second_one() {
    let session = Session::of("list-counts-one-refresh", 2);
    let mux = &session.mux;
    session.give_directories(&[session.repository("repository", "main")]);
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    app.list(mux);

    // Each read below the session's directory waits from now.
    Mux::watch_git_head_reads_below(&session.root, true);
    assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
    let before = Mux::git_head_reads_on_this_thread();
    for _ in 0..3 {
        let reply = app.list_since(mux, &json!({})).to_string();
        assert_eq!(reply.matches("\"git_branch\":\"main\"").count(), 2, "{}", start_of(&reply));
    }
    let in_replies = Mux::git_head_reads_on_this_thread() - before;
    wait_until("the refresh reads its first directory", || {
        Mux::watched_git_head_reads(&session.root) >= 1
    });
    let held = Mux::watched_git_head_reads(&session.root);
    Mux::watch_git_head_reads_below(&session.root, false);
    wait_until("the refresh ended", || Mux::git_head_refreshes_running() == 0);
    let all = Mux::watched_git_head_reads(&session.root);
    assert_eq!(
        (in_replies, held, all),
        (0, 1, 2),
        "3 list-workspaces requests with `known` and 2 stale directories: {in_replies} git HEAD \
         reads in the replies, {held} reads started while the first one was held, {all} reads in \
         all (one refresh reads each directory one time)"
    );
    session.end();
}

/// What a client keeps of a whole tree and sends back as `known`.
fn known_of(tree: &Value) -> Value {
    json!({
        "registry_id": tree["registry_id"],
        "generation": tree["generation"],
        "workspace_revision": tree["workspace_revision"],
        "pane_revision": tree["pane_revision"],
        "terminal_revision": tree["terminal_revision"],
        "tree_revision": tree["tree_revision"],
    })
}

/// The surfaces of the `tab-changed` deltas that `events` holds now, each with whether its
/// tab has `branch` in the event.
fn changed_tabs_on_branch(events: &MuxEventReceiver, branch: &str) -> Vec<(SurfaceId, bool)> {
    let field = format!("\"git_branch\":\"{branch}\"");
    std::iter::from_fn(|| events.try_recv().ok())
        .filter_map(|event| match event {
            MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::TabChanged => {
                Some((delta.surface?, delta.entity.to_string().contains(&field)))
            }
            _ => None,
        })
        .collect()
}

/// The surfaces of the `tab-changed` deltas that `events` holds now.
fn changed_tabs(events: &MuxEventReceiver) -> Vec<SurfaceId> {
    std::iter::from_fn(|| events.try_recv().ok())
        .filter_map(|event| match event {
            MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::TabChanged => delta.surface,
            _ => None,
        })
        .collect()
}

#[test]
fn a_git_head_refresh_sends_tab_changed_only_for_a_branch_that_changed() {
    let session = Session::of("list-counts-tab-changed", 2);
    let mux = &session.mux;
    let (moving, still) =
        (session.repository("moving", "main"), session.repository("still", "main"));
    session.give_directories(&[moving.clone(), still]);
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    app.list(mux);
    let events = mux.subscribe();

    // The walk that each mutation makes for its delta (`tree_decorations`) sends each stale
    // directory to the refresh. A refresh that finds each branch as it was sends nothing.
    assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
    let before = Mux::git_head_reads_on_this_thread();
    drop(mux.tree_decorations());
    wait_until("the refresh ended", || Mux::git_head_refreshes_running() == 0);
    assert_eq!(changed_tabs(&events), Vec::<SurfaceId>::new(), "no branch changed");

    // The branch of the first terminal's repository changes with no change of its directory.
    set_branch(&moving, "next");
    assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
    drop(mux.tree_decorations());
    assert_eq!(
        Mux::git_head_reads_on_this_thread() - before,
        0,
        "the walks of 2 mutations read no git HEAD of a cached directory on their thread"
    );
    let mut changed = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while changed.is_empty() && Instant::now() < deadline {
        changed.extend(changed_tabs(&events));
        std::thread::yield_now();
    }
    wait_until("the refresh ended", || Mux::git_head_refreshes_running() == 0);
    changed.extend(changed_tabs(&events));
    assert_eq!(
        changed,
        vec![session.surfaces[0]],
        "a client that takes events gets one tab-changed for the tab whose branch changed"
    );
    let reply = app.list(mux);
    assert_eq!(reply.matches("\"git_branch\":\"next\"").count(), 1, "{}", start_of(&reply));
    assert_eq!(reply.matches("\"git_branch\":\"main\"").count(), 1, "{}", start_of(&reply));
    session.end();
}

/// A client that holds a tree asks with `known` and gets `unchanged` while nothing that the
/// tree shows changed. A branch that changes with no change of directory has no event of its
/// own: the refresh that reads it counts in the tree revision, so the next `known` request gets
/// the whole tree with the new branch. A refresh that reads each branch as it was leaves the
/// revision as it is, so it sends no client back to the whole tree.
#[test]
fn a_git_head_refresh_moves_the_tree_revision_only_for_a_branch_that_changed() {
    let session = Session::of("list-counts-tree-revision", 2);
    let mux = &session.mux;
    let (moving, still) =
        (session.repository("moving", "main"), session.repository("still", "main"));
    session.give_directories(&[moving.clone(), still]);
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    let since = |known: &Value| app.list_since(mux, known);
    let first = since(&json!({}));
    assert_eq!(first["workspaces"].as_array().map(Vec::len), Some(2), "the whole tree");
    let known = known_of(&first);
    assert!(known["tree_revision"].is_string(), "{known}");
    assert_eq!(since(&known)["unchanged"], json!(true), "nothing changed");

    // A refresh that finds each branch as it was. A request with an empty `known` gets the whole
    // tree from the cache and sends each stale directory to the refresh.
    assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
    since(&json!({}));
    wait_until("the refresh ended", || Mux::git_head_refreshes_running() == 0);
    assert_eq!(since(&known)["unchanged"], json!(true), "a refresh with no change of a branch");

    // The branch of the first terminal's repository changes with no change of its directory.
    set_branch(&moving, "next");
    assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
    since(&json!({}));
    wait_until("the refresh ended", || Mux::git_head_refreshes_running() == 0);
    let next = since(&known);
    assert!(next.get("unchanged").is_none(), "the tree changed: {next}");
    assert_ne!(next["tree_revision"], known["tree_revision"]);
    let text = next.to_string();
    assert_eq!(text.matches("\"git_branch\":\"next\"").count(), 1, "{}", start_of(&text));
    assert_eq!(text.matches("\"git_branch\":\"main\"").count(), 1, "{}", start_of(&text));
    session.end();
}

/// A request with `known` can answer `unchanged` and read no tree, so a branch switched with no
/// event would never reach its client (cmux#42895). The request sends each stale directory of the
/// cache to the refresh and reads no git HEAD itself; the request after the refresh gets the
/// whole tree with the new branch.
#[test]
fn a_known_request_reads_no_git_head_and_sends_each_stale_directory_to_the_refresh() {
    let session = Session::of("list-counts-known-refresh", 2);
    let mux = &session.mux;
    let repository = session.repository("repository", "main");
    session.give_directories(std::slice::from_ref(&repository));
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    let known = known_of(&app.list_since(mux, &json!({})));
    assert_eq!(app.list_since(mux, &known)["unchanged"], json!(true), "nothing changed");

    // The branch changes with no event, each cached value is past its lifetime, and each read
    // below the session's directory waits from now.
    set_branch(&repository, "next");
    Mux::watch_git_head_reads_below(&session.root, true);
    assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
    let before = Mux::git_head_reads_on_this_thread();
    let asked = app.list_since(mux, &known);
    let in_reply = Mux::git_head_reads_on_this_thread() - before;
    assert_eq!(asked["unchanged"], json!(true), "the refresh has read no directory yet: {asked}");
    wait_until("the refresh reads its first directory", || {
        Mux::watched_git_head_reads(&session.root) >= 1
    });
    Mux::watch_git_head_reads_below(&session.root, false);
    wait_until("the refresh ended", || Mux::git_head_refreshes_running() == 0);
    let all = Mux::watched_git_head_reads(&session.root);
    assert_eq!(
        (in_reply, all),
        (0, 2),
        "a list-workspaces request with `known` and 2 stale directories: {in_reply} git HEAD \
         reads in the reply, {all} reads in all (one refresh reads each directory one time)"
    );

    let next = app.list_since(mux, &known);
    assert!(next.get("unchanged").is_none(), "the branch changed: {next}");
    assert_ne!(next["tree_revision"], known["tree_revision"]);
    let text = next.to_string();
    assert_eq!(text.matches("\"git_branch\":\"next\"").count(), 2, "{}", start_of(&text));
    let known = known_of(&next);
    assert_eq!(app.list_since(mux, &known)["unchanged"], json!(true), "nothing changed again");
    session.end();
}

/// A request with no `known` comes from a client that holds no tree: a command that prints the
/// tree one time. It once read each stale directory that a tab shows on its own thread before it
/// replied. Every form of it now draws each cached value at once, stale or not, and reads none:
/// the refresh behind it reads them, and the next reply has the new branch. (In a daemon the
/// watch of the HEAD file brings a switch before any request: git_head_watch.rs.)
#[test]
fn a_request_with_no_known_tree_reads_no_cached_git_head_in_its_reply() {
    let session = Session::of("list-counts-no-known-stale", 3);
    let mux = &session.mux;
    let (moving, still) =
        (session.repository("moving", "main"), session.repository("still", "main"));
    // Terminals 0 and 2 are below `moving`, terminal 1 is below `still`.
    session.give_directories(&[moving.clone(), still]);
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    let first = app.list(mux);
    assert_eq!(first.matches("\"git_branch\":\"main\"").count(), 3, "{}", start_of(&first));

    // Terminal 2 moves to another directory of `moving`, which the next reply reads (it has no
    // cached value) and caches.
    let elsewhere = moving.join("elsewhere");
    std::fs::create_dir_all(&elsewhere).unwrap();
    let runtime = mux.surface(session.surfaces[2]).unwrap();
    runtime.commit_published_directory(Some(elsewhere.to_string_lossy().into_owned()));
    app.list(mux);
    wait_until("each git HEAD refresh ended", || Mux::git_head_refreshes_running() == 0);

    // Each form of the request with no `known`: the shared tree text of a local connection, the
    // reply with `limit`, and the reply value that a remote client gets.
    let forms: [(&str, &dyn Fn() -> String); 3] = [
        ("the tree text", &|| app.list(mux)),
        ("with limit", &|| {
            app.command(mux, json!({"id": 1, "cmd": "list-workspaces", "limit": 3}))
        }),
        ("the reply value", &|| {
            cmd_workspaces::list_workspaces(mux, app.client, None, None, None, None)
                .unwrap()
                .to_string()
        }),
    ];
    let mut seen = Vec::new();
    for (round, (form, request)) in forms.iter().enumerate() {
        // The branch of `moving` changes with no change of a directory and no event.
        let branch = format!("next-{round}");
        let field = format!("\"git_branch\":\"{branch}\"");
        set_branch(&moving, &branch);
        assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
        let before = Mux::git_head_reads_on_this_thread();
        let reply = request();
        let reads = Mux::git_head_reads_on_this_thread() - before;
        let new = reply.matches(&field).count();
        wait_until("each git HEAD refresh ended", || Mux::git_head_refreshes_running() == 0);
        let next = app.list(mux).matches(&field).count();
        seen.push((*form, reads, new, next));
    }
    assert_eq!(
        seen,
        vec![("the tree text", 0, 0, 2), ("with limit", 0, 0, 2), ("the reply value", 0, 0, 2)],
        "for each form of a list-workspaces request with no `known`, after a branch switch in \
         the repository of 2 of the 3 terminals and with each cached value older than 2 seconds: \
         the git HEAD reads on the thread of the request, its tabs with the new branch, and the \
         tabs with the new branch in the reply after the refresh"
    );
    session.end();
}

/// A request with no `known` that draws a stale branch sends its directory to the refresh,
/// which tells each client: one `tab-changed` for each tab of the directory whose branch
/// changed (a client that takes events), with the new branch in it, and a move of the tree
/// revision (a client that asks again with `known`). A second request finds each value fresh and
/// reads no HEAD, and a refresh after it sends no second event for the same switch.
#[test]
fn a_branch_that_the_refresh_behind_a_request_with_no_known_tree_found_reaches_each_client() {
    let session = Session::of("list-counts-no-known-tells", 3);
    let mux = &session.mux;
    let (moving, still) =
        (session.repository("moving", "main"), session.repository("still", "main"));
    // Terminals 0 and 2 are below `moving`, terminal 1 is below `still`.
    session.give_directories(&[moving.clone(), still]);
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    let known = known_of(&app.list_since(mux, &json!({})));
    wait_until("each git HEAD refresh ended", || Mux::git_head_refreshes_running() == 0);
    let events = mux.subscribe();

    // The branch of `moving` changes with no change of a directory and no event, and a request
    // with no `known` is the first to ask.
    set_branch(&moving, "next");
    assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
    let reply = app.list(mux);
    let drawn_stale = reply.matches("\"git_branch\":\"main\"").count();
    wait_until("each git HEAD refresh ended", || Mux::git_head_refreshes_running() == 0);
    let mut told: Vec<(Option<usize>, bool)> = changed_tabs_on_branch(&events, "next")
        .iter()
        .map(|(surface, next)| (session.surfaces.iter().position(|tab| tab == surface), *next))
        .collect();
    told.sort_unstable();

    let before = Mux::git_head_reads_on_this_thread();
    let again = app.list(mux);
    let reads_again = Mux::git_head_reads_on_this_thread() - before;
    assert_eq!(again.matches("\"git_branch\":\"next\"").count(), 2, "{}", start_of(&again));

    let since = app.list_since(mux, &known);
    let whole_tree = since.get("unchanged").is_none();
    let with_new_branch = since.to_string().matches("\"git_branch\":\"next\"").count();
    wait_until("each git HEAD refresh ended", || Mux::git_head_refreshes_running() == 0);

    // The walk of a mutation sends each directory to the refresh: it finds the branch that the
    // refresh stored and has nothing to tell.
    assert!(mux.age_git_heads_for_test(), "this host has no instant that is 3 seconds old");
    drop(mux.tree_decorations());
    wait_until("each git HEAD refresh ended", || Mux::git_head_refreshes_running() == 0);
    let told_by_the_refresh = changed_tabs(&events).len();

    assert_eq!(
        (drawn_stale, told, reads_again, whole_tree, with_new_branch, told_by_the_refresh),
        (3, vec![(Some(0), true), (Some(2), true)], 0, true, 2, 0),
        "after a branch switch in the repository of terminals 0 and 2 and a request with no \
         `known`: the tabs that request drew with the old branch, the terminals with a \
         `tab-changed` from the refresh behind it (and whether the event has the new branch), the \
         git HEAD reads of a second request with no `known`, whether a request with the `known` \
         from before the switch gets the whole tree, the tabs with the new branch in it, and the \
         `tab-changed` events of a later refresh"
    );
    session.end();
}

/// A v2 reply was made from its text: the message was written, parsed, changed and written a
/// second time (`send_control`). It is now changed as a value and written one time
/// (`send_control_value`). Each connection gets the same bytes from the two.
#[test]
fn a_v2_reply_has_the_bytes_of_the_reply_made_from_its_text() {
    let session = Session::of("list-counts-equal-reply", 6);
    session.add_conversation_tab();
    let mux = &session.mux;
    let render = Arc::new(RenderService::new());
    let app = Connection::open(mux, &render, &TAB_CAPABILITIES);
    // The message with each tab kind as it is: the reply of a connection with each capability.
    let message: Value = serde_json::from_str(&app.snapshot(mux)).unwrap();

    let declared: [&[&str]; 4] =
        [&[], &TAB_CAPABILITIES[..1], &TAB_CAPABILITIES[..3], &TAB_CAPABILITIES];
    let mut lines = Vec::new();
    for capabilities in declared {
        let connection = Connection::open(mux, &render, capabilities);
        connection.writer.send_control(&message).unwrap();
        let from_text = connection.reply();
        connection.writer.send_control_value(message.clone()).unwrap();
        let from_value = connection.reply();
        assert_eq!(from_value, from_text, "capabilities {capabilities:?}");
        lines.push(from_value);
    }
    assert_ne!(
        lines[0], lines[3],
        "a connection without the capabilities reads the conversation tab as another kind"
    );
    session.end();
}

#[test]
fn a_list_workspaces_tree_is_built_with_no_state_lock_held() {
    let session = Session::of("list-counts-nodes-lock", 6);
    let mux = &session.mux;
    let locks = crate::mux::state_locks_taken_on_this_thread();
    let held = tree_reply_nodes::trees_built_under_state_lock_on_this_thread();
    let tree = list_workspaces_tree(mux).unwrap();
    let locks = crate::mux::state_locks_taken_on_this_thread() - locks;
    let held = tree_reply_nodes::trees_built_under_state_lock_on_this_thread() - held;
    assert_eq!(tree["workspaces"].as_array().map(Vec::len), Some(6), "the tree of the session");
    assert_eq!(
        (locks, held),
        (1, 0),
        "the tree of a list-workspaces reply took the state lock {locks} times and built its \
         nodes {held} times with the lock held"
    );
    session.end();
}

/// The tree of a `list-workspaces` reply was built in two holds of the state lock: the walks of
/// its decorations, then its nodes. It is now built from one copy of the state, with no lock
/// held. Each connection gets the same bytes from the two.
#[test]
fn a_list_workspaces_reply_has_the_bytes_of_the_tree_built_under_the_state_lock() {
    let session = Session::of("list-counts-equal-tree", 6);
    session.add_conversation_tab();
    session.give_directories(&[session.repository("repository", "main")]);
    let mux = &session.mux;
    let render = Arc::new(RenderService::new());
    let declared: [&[&str]; 2] = [&[], &TAB_CAPABILITIES];
    for capabilities in declared {
        let connection = Connection::open(mux, &render, capabilities);
        let reply = connection.list(mux);
        assert_eq!(reply.matches("\"git_branch\":\"main\"").count(), 6, "{}", start_of(&reply));
        assert_eq!(
            reply.contains("\"kind\":\"conversation\""),
            !capabilities.is_empty(),
            "capabilities {capabilities:?}"
        );

        // A connection with the same history, so the same lines written before its read.
        let reference = Connection::open(mux, &render, capabilities);
        let lines_written = reference.writer.lines_written();
        let decorations = mux.tree_decorations();
        let mut tree = mux.with_state(|state| workspaces_json(state, &decorations));
        let (registry_id, generation) = mux.registry_identity();
        tree["registry_id"] = json!(registry_id);
        tree["generation"] = json!(generation);
        tree["terminal_revision"] = json!(mux.terminal_registry_revision().unwrap());
        if let Some(lines) = lines_written {
            tree["lines_written_before_read"] = json!(lines);
        }
        let response = Response {
            id: Some(json!(1)),
            ok: true,
            data: Some(tree),
            error: None,
            error_code: None,
            error_delivery: None,
        };
        assert!(responses::send_response_with_details(
            &reference.writer,
            response,
            None,
            None,
            None
        ));
        assert_eq!(reply, reference.reply(), "capabilities {capabilities:?}");
    }
    session.end();
}

mod git_head_watch;
