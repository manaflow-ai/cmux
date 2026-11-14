//! `cmux ext new NAME --kind K`, then `cmux ext dev`, for every kind: the new
//! folder loads as written, and a save to its `src/main.ts` is rebuilt and
//! reloaded, its view redrawn by the real QuickJS app host, within a second
//! of the save. The loop is `run_watch`'s: the folder watch, the debounce
//! (`dev::settle`), the fingerprint check and one `Session::reload`.

use std::path::Path;
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

use super::daemon::{Daemon, Wake};
use super::dev::{self, Phase};
use super::tests::{FakeDaemon, global, words};
use super::{Request, parse, scaffold};

/// The longest a save may take to be on screen.
const BUDGET: Duration = Duration::from_secs(1);

/// The kinds that make a folder; `view` when the kind draws one.
const KINDS: [(&str, bool); 3] = [("sidebar", true), ("pane", true), ("command", false)];

/// One kind's run: save to reloaded, and that reload's build and copy-to-frame times.
struct Measured {
    save_to_reload: Duration,
    build_ms: Option<u128>,
    reload_ms: Option<u128>,
}

/// The words a view's first scene shows, from its outline.
fn shown(outcome: &dev::Outcome) -> String {
    outcome.scene.join("\n")
}

fn new_edit_reload(root: &Path, kind: &str, view: bool, bun: &Path) -> Result<Measured, String> {
    let name = format!("hi-{kind}");
    let dir = root.join(&name);
    let new = format!("new {name} --kind {kind} --dir {}", dir.display());
    let Request::New { name, kind: made, dir: Some(target) } = parse(&words(&new))? else {
        return Err(format!("ext {new} is not a new request"));
    };
    scaffold::scaffold(&target, &name, &made)?;

    let fake = FakeDaemon::start_hosting(&root.join("state/apps/local"), &format!("local/{name}"));
    let Ok(Request::Dev(mut options)) = parse(&words(&format!("dev {}", dir.display()))) else {
        return Err("ext dev does not parse".into());
    };
    options.bun = Some(bun.to_path_buf());
    let (sender, wakes) = channel();
    let _watcher = dev::watch(&dir, sender.clone()).map_err(|e| format!("watch: {e}"))?;
    let daemon = Daemon::connect(&global(&fake.socket), sender, wakes)?;
    let mut session = dev::Session::new(dir.clone(), &options, daemon);

    // New: it loads as written.
    let first = session.reload(true);
    if first.phase != Phase::Done {
        return Err(format!("the new folder does not load: {:?}", first.errors));
    }
    if view && !shown(&first).contains("Hello") {
        return Err(format!("the new view shows no Hello: {}", shown(&first)));
    }
    let print = session.built_print.unwrap_or_else(|| dev::fingerprint(&dir));

    // Edit: one save to the source.
    let source = dir.join("src/main.ts");
    let text = std::fs::read_to_string(&source).map_err(|e| e.to_string())?;
    let saved = Instant::now();
    std::fs::write(&source, text.replace("Hello", "Edited")).map_err(|e| e.to_string())?;

    // Reload: as `run_watch` does, a wake, the debounce, a changed fingerprint.
    let outcome = loop {
        let left = (saved + Duration::from_secs(10)).saturating_duration_since(Instant::now());
        match session.daemon.next_wake_within(left) {
            None => return Err("no reload within 10 s of the save".into()),
            Some(Wake::Files) => {
                if let Some((why, _)) = dev::settle(&mut session.daemon) {
                    return Err(why.into());
                }
                if dev::fingerprint(&dir) == print {
                    continue;
                }
                break session.reload(false);
            }
            Some(Wake::DaemonGone) => return Err("the daemon went away".into()),
            Some(_) => {}
        }
    };
    let save_to_reload = saved.elapsed();
    if outcome.phase != Phase::Done {
        return Err(format!("the edit does not reload: {:?}", outcome.errors));
    }
    if view && !shown(&outcome).contains("Edited") {
        return Err(format!("the reloaded view does not show the edit: {}", shown(&outcome)));
    }
    let loaded =
        std::fs::read_to_string(root.join("state/apps/local").join(&name).join("dist/main.js"))
            .map_err(|e| e.to_string())?;
    if !loaded.contains("Edited") {
        return Err("the copy cmux loads is not the edited build".into());
    }
    Ok(Measured { save_to_reload, build_ms: outcome.build_ms, reload_ms: outcome.reload_ms })
}

#[test]
fn every_kind_is_new_loads_then_shows_an_edit_within_a_second() {
    let Some(bun) = dev::find_bun() else {
        eprintln!("SKIPPED: bun is not on PATH; the edit is a source save, which bun builds");
        return;
    };
    let mut problems = Vec::new();
    for (kind, view) in KINDS {
        let root = tempfile::tempdir().unwrap();
        match new_edit_reload(root.path(), kind, view, &bun) {
            Ok(m) => {
                eprintln!(
                    "ext new --kind {kind}: save to reloaded {} ms (build {:?} ms, copy to frame {:?} ms)",
                    m.save_to_reload.as_millis(),
                    m.build_ms,
                    m.reload_ms
                );
                if m.save_to_reload >= BUDGET {
                    problems.push(format!(
                        "{kind}: {} ms from the save to the reload",
                        m.save_to_reload.as_millis()
                    ));
                }
            }
            Err(problem) => problems.push(format!("{kind}: {problem}")),
        }
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

/// A kind whose cmux interface has not landed is refused with the interface
/// it needs and what works meanwhile, never scaffolded on an invented API.
/// When the interface lands this fails: give the kind its template.
#[test]
fn a_kind_whose_interface_has_not_landed_names_what_it_needs() {
    for (kind, needs) in [("newtab", "cmux.newtab/1"), ("menu", "cmux.context_menu/1")] {
        assert!(
            !cmux_app_manifest::KNOWN_INTERFACES.contains(&needs),
            "{needs} landed: give --kind {kind} its template"
        );
        let error = parse(&words(&format!("new x --kind {kind}"))).unwrap_err();
        assert!(error.contains(needs) && error.contains("meanwhile"), "{kind}: {error}");
    }
}
