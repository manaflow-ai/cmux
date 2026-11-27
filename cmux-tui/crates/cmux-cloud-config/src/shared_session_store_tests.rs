//! The shared session store's rules, driven the way the app drives them: memory stores stand in for
//! this build's Keychain store, the in-memory imported store and the shared item, and `Sim` performs
//! each reply's effects exactly as `SharedSessionTokenStore` (CmuxNextCloud `CloudAuth.swift`) does.
use super::*;
use serde_json::json;

#[derive(Default)]
struct Sim {
    state: State,
    own: Pair,
    imported: Pair,
    shared: Pair,
    shared_reads: usize,
}

fn pair(access: &str, refresh: &str) -> Pair {
    Pair { access: Some(access.into()), refresh: Some(refresh.into()) }
}

fn clean(token: Option<&str>) -> Option<String> {
    token.filter(|t| !t.is_empty()).map(str::to_owned)
}

/// One token store call, as the app makes it on whichever store an [`Effect::Apply`] names.
#[derive(Clone, Copy)]
enum Call<'a> {
    Set(Option<&'a str>, Option<&'a str>),
    Cas(&'a str, Option<&'a str>, Option<&'a str>),
    Clear,
    ClearIfCurrent(&'a str),
}

impl Sim {
    fn with(own: Option<Pair>, shared: Option<Pair>) -> Self {
        Sim {
            own: own.unwrap_or_default(),
            shared: shared.unwrap_or_default(),
            ..Default::default()
        }
    }

    fn store(&mut self, store: Store) -> &mut Pair {
        match store {
            Store::Own => &mut self.own,
            Store::Imported => &mut self.imported,
        }
    }

    fn send(&mut self, event: Event, call: Option<Call>) -> (Vec<Effect>, bool) {
        let reply = next(&Request { state: self.state.clone(), event });
        self.state = reply.state;
        let mut result = false;
        for effect in reply.effects.clone() {
            match effect {
                Effect::ReadShared => {
                    self.shared_reads += 1;
                    let pair = self.shared.clone();
                    self.send(Event::SharedRead { pair }, None);
                }
                Effect::SeedImported { access, refresh } => {
                    self.imported = Pair { access, refresh: Some(refresh) };
                }
                Effect::Apply { store } => {
                    let call = call.expect("an apply answers a call");
                    let before = self.store(store).clone();
                    let target = self.store(store);
                    let compare = match call {
                        Call::Set(a, r) => {
                            *target = Pair { access: clean(a), refresh: clean(r) };
                            r.map(str::to_owned)
                        }
                        Call::Cas(c, r, a) => {
                            if target.refresh.as_deref() == Some(c) {
                                *target = Pair { access: clean(a), refresh: clean(r) };
                            }
                            Some(c.to_owned())
                        }
                        Call::Clear => {
                            *target = Pair::default();
                            None
                        }
                        Call::ClearIfCurrent(r) => {
                            result = target.refresh.as_deref() == Some(r);
                            if result {
                                *target = Pair::default();
                            }
                            None
                        }
                    };
                    let now = self.store(store).clone();
                    self.send(Event::Applied { store, compare, before, now }, None);
                }
                Effect::Clear { store } => *self.store(store) = Pair::default(),
                Effect::WriteShared { access, refresh } => {
                    self.shared = Pair { access, refresh: Some(refresh) };
                }
                Effect::WithdrawShared { refresh } => {
                    if self.shared.refresh.as_deref() == Some(refresh.as_str()) {
                        self.shared = Pair::default();
                    }
                }
            }
        }
        (reply.effects, result || reply.shared)
    }

    fn settle(&mut self, skip_import: bool) {
        let own_refresh = if skip_import { None } else { self.own.refresh.clone() };
        self.send(Event::Settle { skip_import, own_refresh }, None);
    }

    fn active(&self) -> &Pair {
        if self.state.uses_imported { &self.imported } else { &self.own }
    }

    fn refresh(&mut self) -> Option<String> {
        self.settle(false);
        self.active().refresh.clone()
    }

    fn access(&mut self) -> Option<String> {
        self.settle(false);
        self.active().access.clone()
    }

    fn call(&mut self, op: Op, refresh: Option<&str>, call: Call) -> bool {
        let skip = !matches!(op, Op::CompareAndSet);
        self.settle(skip);
        self.send(Event::Call { op, refresh: refresh.map(str::to_owned) }, Some(call)).1
    }

    fn set(&mut self, access: &str, refresh: &str) {
        self.call(Op::SetTokens, Some(refresh), Call::Set(Some(access), Some(refresh)));
    }

    fn cas(&mut self, compare: &str, refresh: Option<&str>, access: Option<&str>) {
        self.call(Op::CompareAndSet, Some(compare), Call::Cas(compare, refresh, access));
    }

    fn clear(&mut self) {
        self.call(Op::Clear, None, Call::Clear);
    }

    fn is_shared(&mut self, refresh: &str) -> bool {
        self.send(Event::IsShared { refresh: refresh.into() }, None).1
    }
}

#[test]
fn an_own_session_wins_over_the_shared_item() {
    let mut sim = Sim::with(Some(pair("a1", "r1")), Some(pair("a2", "r2")));
    assert_eq!(sim.refresh().as_deref(), Some("r1"));
    assert_eq!(sim.access().as_deref(), Some("a1"));
    assert!(!sim.is_shared("r1"));
    // The shared item is never read, and stays.
    assert_eq!(sim.shared_reads, 0);
    assert_eq!(sim.shared, pair("a2", "r2"));
}

#[test]
fn signed_out_it_imports_the_item_read_only_in_memory() {
    let mut sim = Sim::with(None, Some(pair("a2", "r2")));
    assert_eq!(sim.refresh().as_deref(), Some("r2"));
    assert_eq!(sim.access().as_deref(), Some("a2"));
    assert_eq!(sim.shared_reads, 1);
    // The writer's session: a sign-out here keeps it on the server.
    assert!(sim.is_shared("r2"));
    assert_eq!(sim.own.refresh, None);
    // A refresh stays in memory and is still the writer's session.
    sim.cas("r2", Some("r3"), Some("a3"));
    assert_eq!(sim.refresh().as_deref(), Some("r3"));
    assert!(sim.is_shared("r3"));
    assert_eq!(sim.own.refresh, None);
    assert_eq!(sim.shared, pair("a2", "r2"));
    // A sign-out forgets it and leaves the item.
    sim.clear();
    assert_eq!(sim.refresh(), None);
    assert_eq!(sim.shared, pair("a2", "r2"));
    // The import ran once.
    assert_eq!(sim.shared_reads, 1);
}

#[test]
fn a_rejected_import_signs_out_and_leaves_the_item() {
    let mut sim = Sim::with(None, Some(pair("a2", "r2")));
    assert_eq!(sim.refresh().as_deref(), Some("r2"));
    sim.cas("r2", None, None);
    assert_eq!(sim.refresh(), None);
    assert!(!sim.state.uses_imported);
    assert_eq!(sim.shared, pair("a2", "r2"));
}

#[test]
fn a_sign_in_is_stored_as_its_own_and_shared() {
    let mut sim = Sim::default();
    assert_eq!(sim.refresh(), None);
    sim.set("a1", "r1");
    assert_eq!(sim.own, pair("a1", "r1"));
    assert_eq!(sim.shared, pair("a1", "r1"));
    assert!(!sim.is_shared("r1"));
    // A refresh is shared too.
    sim.cas("r1", Some("r1b"), Some("a1b"));
    assert_eq!(sim.shared, pair("a1b", "r1b"));
    // Its sign-out removes the item it wrote.
    sim.clear();
    assert_eq!(sim.own.refresh, None);
    assert_eq!(sim.shared, Pair::default());
}

#[test]
fn a_rejected_own_refresh_withdraws_its_item() {
    let mut sim = Sim::default();
    sim.set("a1", "r1");
    sim.cas("r1", None, None);
    assert_eq!(sim.own, Pair::default());
    assert_eq!(sim.shared, Pair::default());
}

#[test]
fn a_sign_out_leaves_another_builds_item() {
    let mut sim = Sim::default();
    sim.set("a1", "r1");
    // Another Team-signed build signed in since and wrote its own session.
    sim.shared = pair("a9", "r9");
    sim.clear();
    assert_eq!(sim.shared, pair("a9", "r9"));
}

#[test]
fn a_clear_if_current_withdraws_only_when_it_cleared() {
    let mut sim = Sim::default();
    sim.set("a1", "r1");
    assert!(!sim.call(Op::ClearIfCurrent, None, Call::ClearIfCurrent("other")));
    assert_eq!(sim.shared, pair("a1", "r1"));
    assert!(sim.call(Op::ClearIfCurrent, None, Call::ClearIfCurrent("r1")));
    assert_eq!(sim.own, Pair::default());
    assert_eq!(sim.shared, Pair::default());
}

#[test]
fn a_clear_if_current_of_the_import_leaves_the_item() {
    let mut sim = Sim::with(None, Some(pair("a2", "r2")));
    assert_eq!(sim.refresh().as_deref(), Some("r2"));
    assert!(sim.call(Op::ClearIfCurrent, None, Call::ClearIfCurrent("r2")));
    assert!(!sim.state.uses_imported);
    assert_eq!(sim.shared, pair("a2", "r2"));
}

#[test]
fn a_sign_in_after_an_import_replaces_it_with_its_own() {
    let mut sim = Sim::with(None, Some(pair("a2", "r2")));
    assert_eq!(sim.refresh().as_deref(), Some("r2"));
    sim.set("a5", "r5");
    assert_eq!(sim.refresh().as_deref(), Some("r5"));
    assert_eq!(sim.own, pair("a5", "r5"));
    assert_eq!(sim.imported, Pair::default());
    assert_eq!(sim.shared, pair("a5", "r5"));
    assert!(!sim.is_shared("r5"));
}

#[test]
fn reseeding_the_imported_pair_keeps_it_in_memory() {
    let mut sim = Sim::with(None, Some(pair("a2", "r2")));
    assert_eq!(sim.refresh().as_deref(), Some("r2"));
    sim.set("a2b", "r2");
    assert_eq!(sim.imported, pair("a2b", "r2"));
    assert_eq!(sim.own.refresh, None);
    assert_eq!(sim.shared, pair("a2", "r2"));
}

#[test]
fn a_sign_in_before_the_first_read_never_imports() {
    let mut sim = Sim::with(None, Some(pair("a2", "r2")));
    sim.set("a1", "r1");
    assert_eq!(sim.refresh().as_deref(), Some("r1"));
    assert_eq!(sim.own, pair("a1", "r1"));
    assert!(!sim.is_shared("r2"));
    assert_eq!(sim.shared_reads, 0);
}

#[test]
fn an_empty_shared_item_imports_nothing() {
    let mut sim =
        Sim::with(None, Some(Pair { access: Some("a2".into()), refresh: Some(String::new()) }));
    assert_eq!(sim.refresh(), None);
    assert!(sim.state.settled);
    assert!(!sim.state.uses_imported);
    assert_eq!(sim.imported, Pair::default());
}

#[test]
fn the_wire_shape_is_the_apps() {
    let request: Request = serde_json::from_value(json!({
        "event": {"event": "applied", "store": "own", "before": {"refresh": "r1"},
                  "now": {"access": "a2", "refresh": "r2"}}
    }))
    .unwrap();
    assert_eq!(request.state, State::default());
    let reply = serde_json::to_value(next(&request)).unwrap();
    assert_eq!(
        reply,
        json!({"state": {"settled": false, "usesImported": false, "importedTokens": []},
               "effects": [{"kind": "write_shared", "access": "a2", "refresh": "r2"}],
               "shared": false})
    );
    let settle: Request = serde_json::from_value(
        json!({"state": {}, "event": {"event": "settle", "ownRefresh": null}}),
    )
    .unwrap();
    assert_eq!(
        serde_json::to_value(next(&settle)).unwrap()["effects"],
        json!([{"kind": "read_shared"}])
    );
}
