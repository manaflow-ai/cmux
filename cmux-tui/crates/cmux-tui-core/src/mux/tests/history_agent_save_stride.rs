//! When the agent history's fold is saved.
//!
//! The saved fold is a cache of what the journal holds. Until a process has
//! folded to the journal's head one time, it saves after each journal page
//! with an agent record, so a long first fold keeps its progress. After that
//! it saves when the journal is 512 sequences past the saved cursor, and a
//! stop saves nothing: the next start folds the records after the saved
//! cursor again. Each row counts the saves by a trigger on the saved row;
//! no row has a clock.

use super::history_agent_fold::{journal_kinds_after, saved_agent_fold, seal_whole_journal};
use super::*;

const TERMINAL: &str = "00000000000040008000000000000072";
const INCARNATION: &str = "10000000000040008000000000000072";
const FIRST: &str = "history-save-first";
const LATE: &str = "history-save-late";
const STRIDE: u64 = 512;
/// The most records in one journal page of the fold.
const PAGE_ROWS: usize = 512;

/// Notes each write of the saved fold's row (its first insert and each
/// update) on the registry's connection, which is the one that saves it.
const NOTE_EACH_SAVE: &str = "
    CREATE TEMP TABLE history_saves(made INTEGER);
    CREATE TEMP TRIGGER note_history_insert AFTER INSERT ON meta
        WHEN new.key = 'journal_reducer.history.agent_sessions'
        BEGIN INSERT INTO history_saves VALUES (1); END;
    CREATE TEMP TRIGGER note_history_update AFTER UPDATE ON meta
        WHEN new.key = 'journal_reducer.history.agent_sessions'
        BEGIN INSERT INTO history_saves VALUES (1); END;";
const SAVES: &str = "SELECT cast(count(*) AS TEXT) FROM history_saves";

/// A daemon on a registry file, with one running terminal.
struct Daemon {
    session: &'static str,
    root: std::path::PathBuf,
    mux: Arc<Mux>,
    terminal: TerminalPublicId,
}

impl Daemon {
    fn open(session: &'static str, root: &std::path::Path) -> Arc<Mux> {
        let mux = open_persistent_test_mux(session, root);
        // The maintenance worker checkpoints and seals on its own clock.
        mux.stop_journal_maintenance();
        // A list folds until the journal's head, with no budget that ends first.
        crate::history_ops::set_list_fold_budget_for_test(&mux, Some(Duration::from_secs(600)));
        mux.workspace_registry.lock().unwrap().execute_sql_for_test(NOTE_EACH_SAVE).unwrap();
        mux
    }

    fn start(session: &'static str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-{session}-{}", crate::workspace_registry::new_uuid_v4()));
        let mux = Self::open(session, &root);
        let workspace = mux.create_empty_workspace(None, None, None).unwrap().key;
        mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace).unwrap();
        let terminal =
            mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
        Self { session, root, mux, terminal }
    }

    /// Stops the daemon and starts a new one on the same registry file.
    fn restart(self) -> Self {
        let Self { session, root, mux, terminal } = self;
        mux.shutdown();
        drop(mux);
        let mux = Self::open(session, &root);
        Self { session, root, mux, terminal }
    }

    fn close(self) {
        self.mux.shutdown();
        drop(self.mux);
        let _ = std::fs::remove_dir_all(&self.root);
    }

    /// One hook of the agent session `agent`, through the journal ingress
    /// path, as its hook helper sends it.
    fn hook(&self, agent: &str, event: &str, mut native: Value) {
        native["session_id"] = serde_json::json!(agent);
        native["cwd"] = serde_json::json!("/srv/project");
        let ingress = crate::agent_hooks::agent_hook_journal_ingress(
            "claude",
            event,
            Some(self.terminal.as_str()),
            native,
        )
        .unwrap();
        let key = format!("history-save-{}", crate::workspace_registry::new_uuid_v4());
        self.mux.append_journal_ingress(&ingress, "test", &key).unwrap();
    }

    /// `count` turns of the session `FIRST`: a prompt and the turn's end.
    fn turns(&self, count: usize) {
        for turn in 0..count {
            let prompt = serde_json::json!({ "prompt": format!("turn {turn}") });
            self.hook(FIRST, "UserPromptSubmit", prompt);
            self.hook(FIRST, "Stop", serde_json::json!({}));
        }
    }

    /// The agent entries of a history list (which answers when the fold is
    /// at the journal's head), by id. Without each entry's time and its
    /// `running` mark: a stop journals the agents' last report times and a
    /// start can end a session whose terminal has no process, and a restart
    /// folds those rows too.
    fn entries(&self) -> Vec<Value> {
        let mut fields = Map::new();
        fields.insert("kinds".into(), serde_json::json!(["agent"]));
        let listed = crate::history_ops::list_for_test(&self.mux, &fields).expect("a list answers");
        let mut entries = listed["entries"].as_array().expect("entries").clone();
        for entry in &mut entries {
            let entry = entry.as_object_mut().expect("an entry is an object");
            entry.remove("at_ms");
            entry.remove("running");
        }
        entries.sort_by_key(|entry| entry["id"].as_str().map(str::to_owned));
        entries
    }

    /// The saves of the fold's row that this daemon made.
    fn saves(&self) -> String {
        self.mux.workspace_registry.lock().unwrap().query_text_for_test(SAVES).unwrap()
    }
}

/// What a restart below the stride left and did.
struct Restarted {
    /// The saved fold after the first history read of the first daemon.
    first: Option<(u64, String)>,
    /// The first daemon's saves after that read, to its stop.
    saves_before_the_stop: String,
    entries_before_the_stop: Vec<Value>,
    /// The saved fold at the second daemon's start, before a history read.
    at_start: Option<(u64, String)>,
    entries_after: Vec<Value>,
    /// The second daemon's saves in its first list.
    saves_of_the_first_list: String,
    after: Option<(u64, String)>,
    sealed_segments: usize,
}

/// A daemon folds to the journal's head, then gets turn ends and a new agent
/// session below the stride, and stops (`seal`: with that stretch of the
/// journal sealed first). A new daemon on the same file answers a list.
fn restart_below_the_stride(session: &'static str, seal: bool) -> Restarted {
    let daemon = Daemon::start(session);
    daemon.hook(FIRST, "SessionStart", serde_json::json!({}));
    // The first history read folds to the head, saves, and starts the feed.
    let _ = daemon.entries();
    let first = saved_agent_fold(&daemon.mux);
    let saves_of_the_first_read = daemon.saves();
    daemon.turns(8);
    daemon.hook(LATE, "SessionStart", serde_json::json!({}));
    let entries_before_the_stop = daemon.entries();
    let saves_before_the_stop = daemon.saves();
    let head = daemon.mux.session_journal_head().unwrap();
    let first_cursor = first.as_ref().map_or(0, |(cursor, _)| *cursor);
    assert!(
        head > first_cursor && head - first_cursor < STRIDE,
        "setup: the journal is past the saved cursor by less than the stride ({first_cursor} to \
         {head})"
    );
    let sealed_segments =
        if seal { seal_whole_journal(&daemon.mux, "history_save_stride").len() } else { 0 };

    let daemon = daemon.restart();
    let at_start = saved_agent_fold(&daemon.mux);
    let entries_after = daemon.entries();
    let saves_of_the_first_list = daemon.saves();
    let after = saved_agent_fold(&daemon.mux);
    daemon.close();
    Restarted {
        first,
        saves_before_the_stop: format!("{saves_of_the_first_read} then {saves_before_the_stop}"),
        entries_before_the_stop,
        at_start,
        entries_after,
        saves_of_the_first_list,
        after,
        sealed_segments,
    }
}

fn assert_the_restart_folded_the_journal(run: &Restarted) {
    let (first_cursor, first_fold) = run.first.clone().expect("the first history read saved");
    assert!(!first_fold.contains(LATE), "setup: the saved fold is older than the late session");
    assert_eq!(
        run.saves_before_the_stop, "1 then 1",
        "the first history read saves the fold one time; the turn ends and the new session \
         below the stride save nothing"
    );
    assert_eq!(run.entries_before_the_stop.len(), 2, "setup: a list has both sessions");
    assert_eq!(
        run.at_start, run.first,
        "the stop saved nothing: the new daemon starts from the first read's saved fold"
    );
    assert_eq!(
        run.entries_after, run.entries_before_the_stop,
        "the new daemon's list has the entries of the old one: it folded the journal after the \
         saved cursor ({first_cursor}) again"
    );
    assert_eq!(
        run.saves_of_the_first_list, "1",
        "the first list of the new daemon saves the fold one time"
    );
    let (cursor, fold) = run.after.clone().expect("the new daemon saved the fold");
    assert!(cursor > first_cursor && fold.contains(LATE), "the save is the fold at the head");
}

#[test]
fn a_stop_below_the_stride_saves_nothing_and_the_restart_folds_the_journal_again() {
    let run = restart_below_the_stride("history-save-stride-restart", false);
    assert_the_restart_folded_the_journal(&run);
}

#[test]
fn a_restart_folds_a_sealed_stretch_after_the_saved_cursor_again() {
    let run = restart_below_the_stride("history-save-stride-sealed", true);
    assert!(run.sealed_segments > 0, "setup: the stretch after the saved cursor is sealed");
    assert_the_restart_folded_the_journal(&run);
}

/// A fold that has not reached the journal's head yet (the first one of a
/// process over a long journal) keeps today's rule: each page with an agent
/// record is saved, also when it is less than the stride past the last save.
#[test]
fn a_first_fold_of_more_than_one_page_saves_each_page_until_the_journal_head() {
    let daemon = Daemon::start("history-save-stride-first-fold");
    daemon.hook(FIRST, "SessionStart", serde_json::json!({}));
    daemon.turns(120);
    let head = daemon.mux.session_journal_head().unwrap();
    let rows: usize = journal_kinds_after(&daemon.mux, 0)
        .iter()
        .filter(|(kind, _)| kind.as_str() != "terminal.output" && !kind.starts_with("personal."))
        .map(|(_, count)| *count)
        .sum();
    let listed = daemon.entries().len();
    let saves = daemon.saves().parse::<u64>().unwrap();
    let saved = saved_agent_fold(&daemon.mux).map_or(0, |(cursor, _)| cursor);
    daemon.close();

    assert!(
        rows > PAGE_ROWS && head < 2 * STRIDE,
        "setup: the journal is more than one page of the fold and less than 2 strides ({rows} \
         rows that the fold reads, head {head})"
    );
    assert_eq!(listed, 1, "setup: the list has the session");
    assert!(
        saves >= 2 && saved > STRIDE,
        "the first fold made {saves} saves and the saved cursor is {saved} (the journal's head \
         is {head}): the page after the first one, less than a stride long, is saved too"
    );
}
