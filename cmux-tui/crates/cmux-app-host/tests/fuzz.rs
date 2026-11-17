//! Hostile extensions against the QuickJS app host: no app, however broken, may crash the host,
//! hang it past its limits, or change what another app (or the supervisor) sees.
//!
//! Two halves:
//! - a fixed corpus of hostile snippets (throws, spins, recursion, huge allocations and
//!   messages, malformed native calls, re-entrant runtime calls, prototype tampering) placed in
//!   every lifecycle slot an app has (main script, render, handler, command, timer, event,
//!   call continuation, cleanup on unmount, settings);
//! - a seeded generator over the same shapes plus random supervisor traffic (weird bodies,
//!   unknown ids, unmount during a pending call), and random bytes on the fd 3 wire.
//!
//! After every step: the step returned within its deadline, a dead VM stays dead and refuses
//! entries, the VM's messages to the supervisor are well formed (calls it has pending, scenes
//! for mounts it has, one `fatal` and nothing after it), engine memory stays under its limit,
//! and bystander apps in the same thread keep rendering and counting exactly as before.
//!
//! `CMUX_APP_FUZZ_SEED=<n>` replays one seed; `CMUX_APP_FUZZ_ITERS=<n>` runs more. A failure
//! prints the seed and the case.

mod common;

use std::collections::BTreeSet;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::time::{Duration, Instant};

use cmux_app_host::host_loop::{self, Channel, exit};
use cmux_app_host::{AppInfo, AppVm, FatalReason, FromHost, InitParams, Limits, VmError};
use common::{Harness, app};
use serde_json::{Value, json};

/// Module named `apps` so `verify-cmux-tui-hosted.sh --filter apps::` selects
/// every app platform test in the workspace.
mod apps {
    use super::*;

    // ---------------------------------------------------------------- seeded generator

    /// splitmix64: small, seedable, and the same on every platform.
    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
            z ^ (z >> 31)
        }

        fn below(&mut self, n: usize) -> usize {
            (self.next() % n.max(1) as u64) as usize
        }

        fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
            &items[self.below(items.len())]
        }

        fn chance(&mut self, percent: u64) -> bool {
            self.next() % 100 < percent
        }
    }

    fn seeds() -> Vec<u64> {
        if let Some(seed) = std::env::var("CMUX_APP_FUZZ_SEED").ok().and_then(|s| s.parse().ok()) {
            return vec![seed];
        }
        let iters: u64 =
            std::env::var("CMUX_APP_FUZZ_ITERS").ok().and_then(|s| s.parse().ok()).unwrap_or(48);
        // A fresh base per run widens coverage over time; the seed of a failure is printed.
        let base = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(1, |d| d.as_nanos() as u64);
        (0..iters).map(|i| base.wrapping_add(i.wrapping_mul(0x9e37_79b9))).collect()
    }

    // ---------------------------------------------------------------- the hostile corpus

    /// Hostile JS statements. Each runs inside a function body in some lifecycle slot.
    const HOSTILE: &[&str] = &[
        // Throwing, sync and async, with values that are awkward to describe.
        "throw new Error('boom')",
        "throw undefined",
        "throw null",
        "throw 42",
        "throw Symbol('s')",
        "throw Object.create(null)",
        "throw { get message() { throw new Error('m') }, get stack() { throw 1 }, toString() { throw 2 } }",
        "throw new Proxy({}, { get() { throw 3 }, getPrototypeOf() { throw 4 }, has() { throw 5 } })",
        "throw { get message() { for (;;) {} } }",
        "Promise.reject(new Error('async boom'))",
        "(async () => { throw 1 })()",
        "(async () => { await null; throw { toString() { for (;;) {} } } })()",
        "Promise.resolve().then(() => { throw new Proxy({}, { get() { throw 6 } }) })",
        // CPU.
        "for (;;) {}",
        "while (true) { try { for (;;) {} } catch (e) {} }",
        "try { for (;;) {} } finally { for (;;) {} }",
        "(function f() { Promise.resolve().then(f) })()",
        "(async () => { for (;;) await 0 })()",
        "/(a+)+$/.test('a'.repeat(32) + 'b')",
        "/(x+x+)+y/.test('x'.repeat(5000))",
        "'a'.repeat(1 << 20).replace(/a/g, () => 'bb')",
        "Error.prepareStackTrace = () => { for (;;) {} }; null.x",
        // Recursion and deep structures.
        "(function f() { f() })()",
        "(function f() { try { f() } catch (e) { f() } })()",
        "(function f(n) { return n ? f(n - 1) + 1 : 0 })(1e7)",
        "Error.prepareStackTrace = (e, s) => { throw e }; (function f() { f() })()",
        "Error.prepareStackTrace = function p() { return p() }; (function f() { f() })()",
        "let a = []; for (let i = 0; i < 1e6; i++) a = [a]; String(a)",
        "let o = {}; for (let i = 0; i < 1e6; i++) o = { o }; JSON.stringify(o)",
        "let p = {}; for (let i = 0; i < 2e5; i++) p = new Proxy(p, {}); p.x",
        "let f = function () {}; for (let i = 0; i < 2e5; i++) f = f.bind(null); f()",
        "let s = Symbol(); let o = {}; for (let i = 0; i < 1e5; i++) o = Object.create(o); o[s]",
        "eval('['.repeat(1e6))",
        "eval('('.repeat(1e6))",
        "eval('{'.repeat(1e6))",
        "eval('a='.repeat(1e6) + '1')",
        "new RegExp('('.repeat(1e5))",
        "new RegExp('(?:'.repeat(1e5) + 'a' + ')*'.repeat(1e5)).test('aaaa')",
        "JSON.parse('['.repeat(1e6))",
        "JSON.parse('{\"a\":'.repeat(1e6))",
        "Function('return ' + '-'.repeat(1e6) + '1')()",
        "let g = () => 0; for (let i = 0; i < 1e5; i++) { const h = g; g = () => h() } g()",
        "class A {}; let C = A; for (let i = 0; i < 1e5; i++) C = class extends C {}; new C()",
        "let o = {}; o.toString = () => String(o); String(o)",
        "let x = { valueOf() { return x + 1 } }; x + 1",
        // Memory.
        "'x'.repeat(1 << 29)",
        "new ArrayBuffer(2 ** 31)",
        "new Uint8Array(1 << 30)",
        "const keep = []; for (;;) keep.push({})",
        "let s = 'x'; for (;;) s += s",
        "new Array(1e9).fill(0)",
        "Array.from({ length: 1e8 })",
        "'x'.repeat(1 << 22).split('')",
        "try { 'x'.repeat(1 << 29) } catch (e) {} globalThis.survived = 1",
        "const m = new Map(); for (let i = 0; ; i++) m.set(i, String(i))",
        "for (let i = 0; i < 1e5; i++) new WeakRef({})",
        "new FinalizationRegistry(() => { for (;;) {} }).register({}, 1); 'x'.repeat(1 << 24)",
        // Huge or many messages to the supervisor.
        "__cmuxAppNative.log('info', 'x'.repeat(1 << 24))",
        "__cmuxAppNative.call('workspace.list', 'x'.repeat(1 << 23), '{}', 1)",
        "__cmuxAppNative.call('workspace.list', '[' + '[],'.repeat(2e6) + '[]]', '{}', 1)",
        "__cmuxAppNative.scene('m', '[' + '{},'.repeat(2e6) + '{}]')",
        "for (let i = 0; i < 1e7; i++) __cmuxAppNative.call('workspace.list', '{}', '{}', i)",
        "globalThis.__cmuxAppResolve = () => { let x = 0; for (let i = 0; i < 1500; i++) x += i }; for (let i = 0; ; i++) __cmuxAppNative.call('a', '{}', '{}', i)",
        "for (let i = 0; i < 1e7; i++) __cmuxAppNative.scene('m', '[]')",
        "for (let i = 0; i < 1e6; i++) cmux.log('x'.repeat(100))",
        "for (let i = 0; i < 1e4; i++) cmux.timer.after(1, () => {})",
        "for (let i = 0; i < 1e4; i++) cmux.events.on('x.changed', () => {})",
        "for (let i = 0; i < 1e4; i++) cmux.workspace.list({}).catch(() => {})",
        // Malformed native calls: wrong types, NaN, infinities, invalid strings.
        "__cmuxAppNative.call(1, 2, 3, 4)",
        "__cmuxAppNative.call()",
        "__cmuxAppNative.call('a', '{', '}', NaN)",
        "__cmuxAppNative.call('a', '{}', '{}', -1)",
        "__cmuxAppNative.call('a', '{}', '{}', Infinity)",
        "__cmuxAppNative.call('a', '{}', '{}', 2 ** 64)",
        "__cmuxAppNative.call('\\ud800', '\"\\ud800\"', '{\"x\":\"\\udfff\"}', 3)",
        "__cmuxAppNative.call('a', '[NaN, Infinity, -0, 1e400]', '{}', 4)",
        "__cmuxAppNative.call('a', '['.repeat(1e5), '{}', 5)",
        "__cmuxAppNative.call({ toString() { for (;;) {} } }, '{}', '{}', 6)",
        "__cmuxAppNative.timer(NaN, true)",
        "__cmuxAppNative.timer(1e308, false)",
        "__cmuxAppNative.timer(Infinity, true)",
        "__cmuxAppNative.timer(Number.MAX_VALUE, true)",
        "__cmuxAppNative.timer(2 ** 64, false)",
        "__cmuxAppNative.timer(-1, true)",
        "cmux.timer.after(1e308, () => {}); cmux.timer.every(1e308, () => {})",
        "cmux.timer.after(NaN, () => {}); cmux.timer.every(-Infinity, () => {})",
        "__cmuxAppNative.clearTimer(NaN); __cmuxAppNative.clearTimer({})",
        "__cmuxAppNative.unsubscribe(-Infinity); __cmuxAppNative.unsubscribe(1e308)",
        "__cmuxAppNative.subscribe('\\udc00', '{')",
        "__cmuxAppNative.subscribe(null, null)",
        "__cmuxAppNative.zone('\\u0000', NaN)",
        "__cmuxAppNative.zone('America/New_York', 1e300)",
        "__cmuxAppNative.zone('America/New_York', -1e300)",
        "__cmuxAppNative.zone('x'.repeat(1 << 22), 0)",
        "__cmuxAppNative.commandDone(NaN, 'yes', '{')",
        "__cmuxAppNative.commandDone(1, true, 'x'.repeat(1 << 23))",
        "__cmuxAppNative.log({}, [])",
        "__cmuxAppNative.log('\\ud800', '\\udfff')",
        "__cmuxAppNative.scene(1, 2)",
        "__cmuxAppNative.scene('m', '{\"op\": \"root\"}')",
        "__cmuxAppNative.scene('other-mount', '[{\"op\":\"remove\",\"id\":\"n1\"}]')",
        // Cyclic and lying values through the cmux API.
        "const o = {}; o.o = o; cmux.workspace.list(o)",
        "cmux.workspace.list({ toJSON() { for (;;) {} } })",
        "cmux.workspace.list({ toJSON() { throw new Error('tojson') } })",
        "cmux.workspace.list({ get x() { throw 1 } })",
        "cmux.workspace.list(new Proxy({}, { ownKeys() { throw 1 } }))",
        "cmux.workspace.list({ big: 10n })",
        // Re-entrant calls into the runtime's entry points and the host.
        "__cmuxAppFlush(); __cmuxAppFlush()",
        "__cmuxAppResolve(1, true, '{}'); __cmuxAppResolve(NaN, 'x', {})",
        "__cmuxAppInit('{}'); __cmuxAppInit('{')",
        "__cmuxAppMount('m', 'render', '{}'); __cmuxAppMount('m', 'render', '{')",
        "__cmuxAppUnmount('m'); __cmuxAppUnmount('m')",
        "__cmuxAppDispatch('m', 'n1', 'tap', '{'); __cmuxAppDispatch('m', 'n2', 'tap', '{}')",
        "__cmuxAppTimer(1); __cmuxAppEvent(1, '{')",
        "__cmuxAppRunCommand('cmd', '{', 1, '{'); __cmuxAppRunCommand('cmd', '{}', NaN)",
        "__cmuxAppSetSettings('{'); __cmuxAppSetSettings('null')",
        "for (let i = 0; i < 1000; i++) __cmuxAppMount('r' + i, 'render', '{}')",
        // Tampering with the realm the runtime shares with the app.
        "globalThis.__cmuxAppFlush = null",
        "globalThis.__cmuxAppResolve = () => { for (;;) {} }",
        "globalThis.__cmuxAppTimer = () => { throw 1 }",
        "delete globalThis.__cmuxAppNative",
        "Object.defineProperty(globalThis, '__cmuxAppFlush', { get() { throw 1 } })",
        "Object.defineProperty(globalThis, '__cmuxAppMount', { get() { for (;;) {} } })",
        "Object.freeze(globalThis); Object.freeze(Object.prototype)",
        "Object.prototype.toJSON = () => { throw 1 }",
        "Object.prototype.toJSON = function () { return this }",
        "JSON.stringify = () => undefined; JSON.parse = () => { for (;;) {} }",
        "JSON.stringify = () => ({ toString() { throw 1 } })",
        "Array.prototype[Symbol.iterator] = function* () { for (;;) yield 1 }",
        "Promise.prototype.then = null; Function.prototype.call = null; Function.prototype.apply = null",
        "Object.defineProperty(Object.prototype, 'then', { get() { throw 1 } })",
        "Array.prototype.push = function () { for (;;) {} }",
        "String.prototype.repeat = () => { throw 1 }; Map.prototype.get = () => { throw 1 }",
        "Error.prototype.toString = () => { throw 1 }; Symbol.prototype.toString = null",
        "Object.setPrototypeOf(Object.prototype, new Proxy({}, { get() { throw 1 } }))",
    ];

    /// Where a hostile statement runs.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Slot {
        Main,
        Render,
        Handler,
        Command,
        AsyncCommand,
        Timer,
        Event,
        Continuation,
        Cleanup,
        Settings,
    }

    const SLOTS: &[Slot] = &[
        Slot::Main,
        Slot::Render,
        Slot::Handler,
        Slot::Command,
        Slot::AsyncCommand,
        Slot::Timer,
        Slot::Event,
        Slot::Continuation,
        Slot::Cleanup,
        Slot::Settings,
    ];

    /// The app around one hostile statement: a render with a button, a command, a timer, an
    /// event subscription, a call continuation, a cleanup and a settings effect, one of which
    /// runs `bad`.
    fn hostile_app(slot: Slot, bad: &str) -> String {
        let at = |s: Slot| if s == slot { bad } else { "" };
        let main = at(Slot::Main);
        let render = at(Slot::Render);
        let handler = at(Slot::Handler);
        let command = at(Slot::Command);
        let async_command = at(Slot::AsyncCommand);
        let timer = at(Slot::Timer);
        let event = at(Slot::Event);
        let continuation = at(Slot::Continuation);
        let cleanup = at(Slot::Cleanup);
        let settings = at(Slot::Settings);
        app(&format!(
            r#"{main}
            const [n, setN] = signal(0)
            return {{
              render: () => {{
                cmux.timer.after(1, () => {{ {timer} }})
                cmux.events.on("x.changed", () => {{ {event} }})
                cmux.workspace.list({{}}).then(() => {{ {continuation} }}, () => {{ {continuation} }})
                onCleanup(() => {{ {cleanup} }})
                effect(() => {{ if (cmux.app.settings().poke) {{ {settings} }} }})
                {render}
                return VStack([Text(() => "n=" + n()), Button("inc", () => {{ setN((v) => v + 1); {handler} }})])
              }},
              cmd: () => {{ {command} }},
              acmd: async () => {{ await null; {async_command} }},
            }}"#
        ))
    }

    // ---------------------------------------------------------------- the checked supervisor

    /// Stands in for the supervisor around one VM and checks everything the VM sends.
    struct Checked {
        vm: AppVm,
        label: String,
        limits: Limits,
        mounts: BTreeSet<String>,
        pending: BTreeSet<u64>,
        subs: BTreeSet<u64>,
        fatal: Option<FatalReason>,
        logs: usize,
    }

    /// Wall time one entry may take: its deadline, plus the slack of a loaded runner and of an
    /// unoptimized engine (the deadline is checked every few thousand engine steps).
    fn bound(limits: &Limits) -> Duration {
        limits.entry_deadline + Duration::from_secs(2)
    }

    impl Checked {
        fn new(label: String, main: &str, limits: Limits) -> Self {
            let mut vm = AppVm::new(limits).expect("an empty VM always starts");
            let started = Instant::now();
            let init = vm.init(InitParams {
                app: AppInfo { id: "local/hostile".into(), version: "1.0.0".into() },
                settings: json!({}),
                api_version: "1.0.0".into(),
                ops: None,
                known_ops: None,
                locale: None,
                strings: Value::Null,
                main: main.to_string(),
                main_name: Some("main.js".into()),
            });
            let mut checked = Self {
                vm,
                label,
                limits,
                mounts: BTreeSet::new(),
                pending: BTreeSet::new(),
                subs: BTreeSet::new(),
                fatal: None,
                logs: 0,
            };
            checked.after(
                "init",
                started,
                init.map(|_| ()).or_else(|e| match e {
                    VmError::Init(_) => Ok(()),
                    fatal => Err(fatal),
                }),
            );
            checked
        }

        /// Checks the invariants after one entry and forwards its messages.
        fn after(&mut self, what: &str, started: Instant, outcome: Result<(), VmError>) {
            let took = started.elapsed();
            assert!(
                took <= bound(&self.limits),
                "{}: {what} took {took:?}, past its deadline {:?}",
                self.label,
                self.limits.entry_deadline
            );
            let was_dead = self.fatal;
            if let Err(error) = &outcome {
                let VmError::Fatal { reason, .. } = error else {
                    panic!("{}: {what}: only init fails with Init: {error:?}", self.label)
                };
                if let Some(before) = was_dead {
                    assert_eq!(*reason, before, "{}: a dead VM keeps its reason", self.label);
                }
                self.fatal = Some(*reason);
            }
            assert_eq!(self.vm.dead(), self.fatal, "{}: {what}: dead() agrees", self.label);
            let outbox = self.vm.take_outbox();
            if was_dead.is_some() {
                assert!(outbox.is_empty(), "{}: {what}: a dead VM sent {outbox:?}", self.label);
            }
            let mut fatal_seen = false;
            for message in outbox {
                assert!(!fatal_seen, "{}: {what}: a message after fatal: {message:?}", self.label);
                match message {
                    FromHost::Call { cb, .. } => {
                        assert!(was_dead.is_none(), "{}: a call from a dead VM", self.label);
                        assert!(
                            self.pending.insert(cb),
                            "{}: {what}: call {cb} sent twice while pending",
                            self.label
                        );
                    }
                    FromHost::Subscribe { sub, .. } => {
                        assert!(self.subs.insert(sub), "{}: sub {sub} twice", self.label);
                    }
                    FromHost::Unsubscribe { sub } => {
                        assert!(self.subs.remove(&sub), "{}: unknown unsub {sub}", self.label);
                    }
                    // An app can call the native scene function with any JSON; the supervisor
                    // validates scene ops, so only the line's shape is checked here.
                    FromHost::Scene { .. } => {}
                    FromHost::Log { message, level } => {
                        assert!(message.chars().count() <= 4096, "{}: log too long", self.label);
                        assert!(
                            matches!(level.as_str(), "debug" | "info" | "warn" | "error"),
                            "{}: log level {level}",
                            self.label
                        );
                        self.logs += 1;
                    }
                    FromHost::Fatal { reason, .. } => {
                        assert_eq!(Some(reason), self.fatal, "{}: {what}: fatal line", self.label);
                        assert!(was_dead.is_none(), "{}: fatal sent twice", self.label);
                        fatal_seen = true;
                    }
                    FromHost::Done { .. } | FromHost::Mounted { .. } => {}
                    other => panic!("{}: {what}: the VM sent {other:?}", self.label),
                }
            }
            if self.fatal.is_some() && was_dead.is_none() {
                assert!(fatal_seen, "{}: {what}: died without a fatal line", self.label);
            }
            assert!(
                self.pending.len() <= self.limits.max_pending_calls,
                "{}: {} calls pending past the cap",
                self.label,
                self.pending.len()
            );
            if self.fatal.is_none() {
                // A dead VM is dropped; only a live one must agree with what the supervisor saw.
                assert_eq!(
                    self.vm.pending_calls(),
                    self.pending.len(),
                    "{}: {what}: pending {:?}",
                    self.label,
                    self.pending
                );
                assert!(
                    self.vm.memory_used() <= self.limits.memory_bytes,
                    "{}: {} bytes past the {} limit",
                    self.label,
                    self.vm.memory_used(),
                    self.limits.memory_bytes
                );
            }
        }

        fn step(&mut self, what: &str, f: impl FnOnce(&mut AppVm) -> Result<(), VmError>) {
            let started = Instant::now();
            let outcome = f(&mut self.vm);
            if self.fatal.is_some() {
                // An unknown id is ignored without an entry (Ok, and `after` checks nothing
                // was sent); every entry is refused.
                assert!(
                    started.elapsed() < Duration::from_millis(100),
                    "{}: a dead VM's refusal is immediate",
                    self.label
                );
            }
            self.after(what, started, outcome);
        }

        fn mount(&mut self, mount: &str, export: &str, ctx: &Value) {
            let started = Instant::now();
            let outcome = self.vm.mount(mount, export, ctx);
            if let Ok(None) = outcome {
                self.mounts.insert(mount.to_string());
            }
            self.after("mount", started, outcome.map(|_| ()));
        }

        fn unmount(&mut self, mount: &str) {
            self.mounts.remove(mount);
            let mount = mount.to_string();
            self.step("unmount", move |vm| vm.unmount(&mount));
        }

        /// Answers every pending call with `body`, a few rounds.
        fn answer_all(&mut self, ok: bool, body: &Value) {
            for _ in 0..4 {
                let pending: Vec<u64> = self.pending.iter().copied().collect();
                if pending.is_empty() {
                    return;
                }
                for cb in pending {
                    if self.fatal.is_some() {
                        return;
                    }
                    self.pending.remove(&cb);
                    let body = body.clone();
                    self.step("resolve", move |vm| vm.resolve(cb, ok, &body));
                }
            }
        }

        fn emit_all(&mut self, body: &Value) {
            let subs: Vec<u64> = self.subs.iter().copied().collect();
            for sub in subs {
                let body = body.clone();
                self.step("event", move |vm| vm.event(sub, &body));
            }
        }

        /// Fires every timer as if its due time came.
        fn fire_timers(&mut self) {
            if let Some(due) = self.vm.next_timer_due() {
                let at = due.max(Instant::now());
                self.step("timer", move |vm| vm.fire_due_timers(at));
            }
        }

        /// The full lifecycle the hostile app's slots hang off.
        fn exercise(&mut self, ctx: &Value) {
            self.mount("m", "render", ctx);
            self.answer_all(true, &json!({ "value": [] }));
            self.fire_timers();
            self.emit_all(&json!({ "kind": "x.changed" }));
            self.step("settings", |vm| vm.set_settings(&json!({ "poke": true })));
            self.step("dispatch", |vm| vm.dispatch("m", "n3", "tap", &json!({ "gesture": "g" })));
            self.step("command", |vm| vm.run_command(1, "cmd", &json!({}), None));
            self.step("command", |vm| vm.run_command(2, "acmd", &json!({}), None));
            self.answer_all(false, &json!({ "code": "x", "message": "no" }));
            self.unmount("m");
            // A second life: mount again after the unmount.
            self.mount("m2", "render", &json!({}));
            self.unmount("m2");
        }
    }

    // ---------------------------------------------------------------- bystanders

    /// A well-behaved counter app sharing the thread with the hostile ones.
    struct Bystander {
        h: Harness,
        count: u64,
    }

    impl Bystander {
        fn new() -> Self {
            let mut h = Harness::new(&app(r#"const [n, setN] = signal(0)
            return { render: () => VStack([Text(() => "n=" + n()), Button("inc", () => setN((v) => v + 1))]) }"#));
            assert_eq!(h.mount("m", "render", json!({})), None);
            Self { h, count: 0 }
        }

        /// The bystander's tree is exactly what its own clicks made it, and one more click works.
        fn check(&mut self, context: &str) {
            assert_eq!(self.h.vm.dead(), None, "bystander died: {context}");
            assert_eq!(
                self.h.texts("m"),
                [format!("n={}", self.count), "inc".into()],
                "bystander: {context}"
            );
            let button = self
                .h
                .find("m", |n| n.props.get("title") == Some(&json!("inc")))
                .expect("bystander button");
            self.h.dispatch("m", &button, "tap", json!({}));
            self.count += 1;
            assert_eq!(
                self.h.texts("m"),
                [format!("n={}", self.count), "inc".into()],
                "bystander: {context}"
            );
            assert!(self.h.fatal.is_none(), "bystander fatal: {context}");
        }
    }

    /// Tighter limits than an app's so a spin or a hog costs tens of milliseconds, not hundreds.
    fn fuzz_limits() -> Limits {
        Limits {
            memory_bytes: 16 * 1024 * 1024,
            entry_deadline: Duration::from_millis(60),
            max_pending_calls: 16,
            cpu: Some(cmux_app_host::CpuBudget::default()),
        }
    }

    fn run_case(label: &str, main: &str, limits: Limits, ctx: &Value) -> Checked {
        let mut checked = Checked::new(label.to_string(), main, limits);
        if checked.fatal.is_none() {
            checked.exercise(ctx);
        }
        checked
    }

    /// Every hostile statement in every slot, under the default app limits and the tight ones.
    #[test]
    fn every_hostile_statement_in_every_slot_is_contained() {
        let mut bystanders: Vec<Bystander> = (0..3).map(|_| Bystander::new()).collect();
        let mut failures = Vec::new();
        for (i, bad) in HOSTILE.iter().enumerate() {
            for slot in SLOTS {
                // Default limits for every statement in one slot per statement, tight elsewhere.
                let limits =
                    if SLOTS[i % SLOTS.len()] == *slot { Limits::default() } else { fuzz_limits() };
                let label = format!("corpus #{i} in {slot:?}: {bad}");
                let main = hostile_app(*slot, bad);
                let outcome = catch_unwind(AssertUnwindSafe(|| {
                    drop(run_case(&label, &main, limits, &json!({})));
                }));
                if let Err(panic) = outcome {
                    failures.push(format!("{label}: {}", panic_text(&panic)));
                }
            }
            for b in &mut bystanders {
                b.check(&format!("after corpus #{i}: {bad}"));
            }
        }
        assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
    }

    fn panic_text(panic: &Box<dyn std::any::Any + Send>) -> String {
        panic
            .downcast_ref::<String>()
            .cloned()
            .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_else(|| "a panic".into())
    }

    // ---------------------------------------------------------------- random shapes

    /// A random JSON value: deep, wide, huge strings, lone-surrogate escapes, extreme numbers.
    fn random_value(rng: &mut Rng, depth: usize) -> Value {
        match rng.below(if depth > 0 { 10 } else { 7 }) {
            0 => Value::Null,
            1 => json!(rng.chance(50)),
            2 => json!(*rng.pick(&[0.0, -0.0, 1e308, -1e308, 5e-324, 9007199254740993.0])),
            3 => json!(*rng.pick(&[u64::MAX, 0, 1, 1 << 53])),
            4 => json!(*rng.pick(&[i64::MIN, -1])),
            5 => {
                let s =
                    *rng.pick(&["", "x", "\u{0}", "\u{feff}", "é", "😀", "\"}\n{", "__proto__"]);
                let cap = if rng.chance(5) { 1 << 16 } else { 8 };
                Value::String(s.repeat(1 + rng.below(cap)))
            }
            6 => Value::String("y".repeat(rng.below(1 << 12))),
            7 | 8 => {
                let n = rng.below(6);
                Value::Array((0..n).map(|_| random_value(rng, depth - 1)).collect())
            }
            _ => {
                let mut map = serde_json::Map::new();
                for _ in 0..rng.below(6) {
                    let key = (*rng.pick(&[
                        "__proto__",
                        "constructor",
                        "toJSON",
                        "then",
                        "gesture",
                        "poke",
                        "value",
                        "code",
                        "",
                    ]))
                    .to_string();
                    map.insert(key, random_value(rng, depth - 1));
                }
                Value::Object(map)
            }
        }
    }

    /// A random hostile app: one to three corpus statements, each in a random slot and maybe
    /// wrapped (try/catch, async, a timer, a microtask), concatenated.
    fn random_app(rng: &mut Rng) -> (String, String) {
        let slot = *rng.pick(SLOTS);
        let mut body = String::new();
        let mut described = format!("{slot:?}:");
        for _ in 0..1 + rng.below(3) {
            let bad = *rng.pick(HOSTILE);
            let wrapped = match rng.below(6) {
                0 => format!("try {{ {bad} }} catch (e) {{}}"),
                1 => format!("(async () => {{ {bad} }})()"),
                2 => format!("cmux.timer.after(1, () => {{ {bad} }})"),
                3 => format!("Promise.resolve().then(() => {{ {bad} }})"),
                _ => bad.to_string(),
            };
            described.push_str(&format!(" [{wrapped}]"));
            body.push_str(&format!("{{ {wrapped} }};\n"));
        }
        (hostile_app(slot, &body), described)
    }

    /// One seed: a random hostile app driven by random supervisor traffic, including unknown
    /// ids, unmount while calls are pending, and dropping the VM with work outstanding.
    fn fuzz_one(seed: u64) {
        let mut rng = Rng(seed);
        let (main, described) = random_app(&mut rng);
        let label = format!("seed {seed}: {described}");
        let limits = if rng.chance(20) { Limits::default() } else { fuzz_limits() };
        let mut c = Checked::new(label, &main, limits);
        for _ in 0..rng.below(24) {
            if c.fatal.is_some() && rng.chance(70) {
                break;
            }
            let body = random_value(&mut rng, 6);
            match rng.below(13) {
                0 => {
                    let mount = (*rng.pick(&["m", "m2", "", "\u{0}"])).to_string();
                    let export = *rng.pick(&["render", "cmd", "nope", "__proto__", "constructor"]);
                    c.mount(&mount, export, &body);
                }
                1 => {
                    let mount = (*rng.pick(&["m", "m2", "x"])).to_string();
                    c.unmount(&mount);
                }
                2 => {
                    let node = format!("n{}", rng.below(12));
                    let event =
                        (*rng.pick(&["tap", "change", "submit", "", "__proto__"])).to_string();
                    c.step("dispatch", move |vm| vm.dispatch("m", &node, &event, &body));
                }
                3 => c.answer_all(rng.chance(50), &body),
                4 => {
                    // An id the VM never sent.
                    let cb = *rng.pick(&[0, u64::MAX, 1 << 53, 7]);
                    if !c.pending.contains(&cb) {
                        c.step("resolve unknown", move |vm| vm.resolve(cb, true, &body));
                    }
                }
                5 => c.emit_all(&body),
                6 => {
                    let sub = *rng.pick(&[0, u64::MAX, 3]);
                    c.step("event unknown", move |vm| vm.event(sub, &body));
                }
                7 => c.step("settings", move |vm| vm.set_settings(&body)),
                8 => {
                    let cb = rng.next();
                    let export = *rng.pick(&["cmd", "acmd", "render", "nope", "toString"]);
                    let gesture = rng.chance(50).then_some("g");
                    c.step("command", move |vm| vm.run_command(cb, export, &body, gesture));
                }
                9 => c.fire_timers(),
                10 => {
                    let by = Duration::from_millis(rng.below(20_000) as u64);
                    c.vm.advance_clock(by);
                }
                11 => {
                    // Unmount while calls are pending, then answer them.
                    c.unmount("m");
                    c.answer_all(true, &body);
                }
                _ => c.exercise(&body),
            }
        }
        // Dropping the VM with calls, timers and subscriptions outstanding must be clean.
        drop(c);
    }

    #[test]
    fn seeded_hostile_apps_and_traffic_are_contained() {
        let mut bystanders: Vec<Bystander> = (0..2).map(|_| Bystander::new()).collect();
        for seed in seeds() {
            let outcome = catch_unwind(AssertUnwindSafe(|| fuzz_one(seed)));
            if let Err(panic) = outcome {
                panic!("CMUX_APP_FUZZ_SEED={seed} reproduces this failure: {}", panic_text(&panic));
            }
            for b in &mut bystanders {
                b.check(&format!("after seed {seed}"));
            }
        }
    }

    /// Many VMs at once in one thread, most hostile: the healthy ones keep working through it.
    #[test]
    fn many_vms_at_once_keep_the_healthy_ones_working() {
        let mut rng = Rng(seeds()[0]);
        let mut bystanders: Vec<Bystander> = (0..8).map(|_| Bystander::new()).collect();
        let mut hostile: Vec<Checked> = (0..24)
            .map(|i| {
                let (main, described) = random_app(&mut rng);
                Checked::new(format!("vm {i}: {described}"), &main, fuzz_limits())
            })
            .collect();
        for round in 0..3 {
            for c in &mut hostile {
                if c.fatal.is_none() {
                    c.exercise(&json!({}));
                }
            }
            for b in &mut bystanders {
                b.check(&format!("round {round}"));
            }
        }
    }

    // ---------------------------------------------------------------- refused calls

    /// Calls past the pending cap are answered `app.limit` after the entry, one runtime call per
    /// refused id, while the entry's deadline is still armed. The interrupt handler fires once per
    /// few thousand engine steps, so after the deadline each answer that fits in that budget ran
    /// to completion: an app that refused itself a million calls in its 250 ms, with a resolver
    /// worth a few thousand steps, held the host for seconds past the deadline. The answers now
    /// stop at the first limit, so the entry ends within its deadline.
    #[test]
    fn refused_calls_past_the_cap_end_within_the_entry_deadline() {
        let limits = Limits::default();
        let mut h = Harness::with(
            &app(r#"return { go: () => {
              // Each answer costs a few thousand engine steps, under one interrupt poll.
              globalThis.__cmuxAppResolve = () => { let x = 0; for (let i = 0; i < 1500; i++) x += i; return x }
              for (let i = 0; ; i++) __cmuxAppNative.call("workspace.list", "{}", "{}", i)
            } }"#),
            json!({}),
            limits,
        );
        let started = Instant::now();
        let error = h.vm.run_command(1, "go", &json!({}), None).expect_err("stopped");
        let took = started.elapsed();
        assert!(
            took < limits.entry_deadline + Duration::from_millis(500),
            "the entry ran {took:?}, its deadline is {:?}",
            limits.entry_deadline
        );
        // The deadline or the refused-call budget, whichever the app reaches first.
        assert!(
            matches!(
                error,
                VmError::Fatal { reason: FatalReason::Interrupt | FatalReason::Memory, .. }
            ),
            "{error:?}"
        );
    }

    // ---------------------------------------------------------------- unload during a call

    /// Unmount while a call is pending, then answer it: the continuation runs (it is the app's
    /// own promise) but no scene reaches the unmounted mount, and nothing is left behind.
    #[test]
    fn unmount_during_a_pending_call_leaves_nothing_behind() {
        let mut h = Harness::new(&app(r#"const [n, setN] = signal("…")
        return { render: () => {
          cmux.workspace.list({}).then((v) => { setN("got"); cmux.timer.after(10, () => setN("late")) })
          cmux.events.on("x.changed", () => setN("event"))
          return Text(() => n())
        } }"#));
        h.auto_answer = false;
        h.mount("m", "render", json!({}));
        assert_eq!(h.unanswered.len(), 1);
        let scenes_before = h.batches("m").len();
        h.vm.unmount("m").expect("unmount");
        h.pump().expect("pump");
        assert!(h.subscriptions.is_empty(), "unmount drops the subscription");
        let cb = h.unanswered[0].cb;
        h.answer(cb, true, json!({ "value": [] })).expect("late answer");
        if let Some(due) = h.vm.next_timer_due() {
            h.vm.fire_due_timers(due).expect("timers");
            h.pump().expect("pump");
        }
        assert_eq!(h.batches("m").len(), scenes_before, "no scene for an unmounted mount");
        assert_eq!(h.vm.dead(), None);
        assert_eq!(h.vm.pending_calls(), 0);
    }

    // ---------------------------------------------------------------- the fd 3 wire

    /// An in-memory fd 3: reads come from a byte buffer; the read never times out.
    struct Wire(std::io::Cursor<Vec<u8>>);

    impl std::io::Read for Wire {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            self.0.read(buf)
        }
    }

    impl Channel for Wire {
        fn set_read_deadline(&self, _timeout: Option<Duration>) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// Runs the host loop over `input` and returns its exit code and output lines.
    fn host(input: Vec<u8>, limits: Limits) -> (i32, Vec<Value>) {
        let mut out = Vec::new();
        let code = host_loop::run(Wire(std::io::Cursor::new(input)), &mut out, limits);
        let lines = out
            .split(|b| *b == b'\n')
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_slice(l).expect("the host writes JSON lines"))
            .collect();
        (code, lines)
    }

    fn init_line(main: &str) -> String {
        json!({ "t": "init", "app": { "id": "local/w", "version": "1.0.0" }, "api_version": "1.0.0", "main": main })
            .to_string()
    }

    /// Malformed lines end the host with a protocol error, never a panic or a hang.
    #[test]
    fn malformed_lines_end_the_host_with_a_protocol_error() {
        let ok = init_line(&app("return { render: () => Text('w') }"));
        let deep = "[".repeat(100_000);
        let cases: Vec<(&str, Vec<u8>)> = vec![
            ("invalid utf-8", b"{\"t\":\"shutdown\xff\"}\n".to_vec()),
            ("NaN", b"{\"t\":\"resolve\",\"cb\":NaN,\"ok\":true}\n".to_vec()),
            ("cb past u64", b"{\"t\":\"resolve\",\"cb\":1e30,\"ok\":true}\n".to_vec()),
            ("negative cb", b"{\"t\":\"resolve\",\"cb\":-1,\"ok\":true}\n".to_vec()),
            ("wrong types", b"{\"t\":\"mount\",\"mount\":1,\"export\":[]}\n".to_vec()),
            ("unknown tag", b"{\"t\":\"explode\"}\n".to_vec()),
            ("not an object", b"[]\n".to_vec()),
            ("deep nesting", format!("{{\"t\":\"settings\",\"values\":{deep}}}\n").into_bytes()),
            ("before init", b"{\"t\":\"mount\",\"mount\":\"m\",\"export\":\"render\"}\n".to_vec()),
            ("init twice", format!("{ok}\n{ok}\n").into_bytes()),
            ("no newline at the end", ok.clone().into_bytes()),
            ("nul bytes", b"\0\0\0\n".to_vec()),
            ("oversized", {
                let mut v = b"{\"t\":\"log\",\"x\":\"".to_vec();
                v.resize(cmux_app_host::protocol::MAX_LINE_BYTES + 16, b'a');
                v.extend_from_slice(b"\"}\n");
                v
            }),
        ];
        for (name, input) in cases {
            let (code, _) = host(input, Limits::default());
            assert_eq!(code, exit::PROTOCOL, "{name}");
        }
    }

    /// A deeply nested but well-formed line after init: the host either refuses it as a
    /// protocol error or hands it to the app; it never overflows its own stack.
    #[test]
    fn deep_values_inside_the_line_limit_never_overflow_the_host() {
        let ok = init_line(&app("return { render: () => Text('w') }"));
        for depth in [100, 127, 128, 129, 1000, 1_000_000] {
            let deep = format!("{}{}", "[".repeat(depth), "]".repeat(depth));
            let input = format!("{ok}\n{{\"t\":\"settings\",\"values\":{deep}}}\n");
            let (code, _) = host(input.into_bytes(), Limits::default());
            assert!(matches!(code, exit::OK | exit::PROTOCOL), "depth {depth}: {code}");
        }
    }

    /// Random bytes and mutated valid lines on the wire: a defined exit code every time.
    #[test]
    fn random_wire_bytes_give_a_defined_exit_code() {
        let valid = [
            init_line(&app("return { render: () => Button('b', () => cmux.workspace.list({})) }")),
            json!({ "t": "mount", "mount": "m", "export": "render", "ctx": {} }).to_string(),
            json!({ "t": "dispatch", "mount": "m", "node": "n1", "event": "tap", "payload": {} })
                .to_string(),
            json!({ "t": "resolve", "cb": 1, "ok": true, "body": { "value": [] } }).to_string(),
            json!({ "t": "event", "sub": 1, "body": {} }).to_string(),
            json!({ "t": "settings", "values": { "a": 1 } }).to_string(),
            json!({ "t": "run", "cb": 3, "export": "render", "args": {} }).to_string(),
            json!({ "t": "unmount", "mount": "m" }).to_string(),
        ];
        for seed in seeds() {
            let outcome = catch_unwind(AssertUnwindSafe(|| {
                let mut rng = Rng(seed);
                let mut input = Vec::new();
                for _ in 0..1 + rng.below(10) {
                    let mut line = rng.pick(&valid).clone().into_bytes();
                    for _ in 0..rng.below(4) {
                        if line.is_empty() {
                            break;
                        }
                        let at = rng.below(line.len());
                        match rng.below(4) {
                            0 => line[at] = rng.next() as u8,
                            1 => {
                                line.remove(at);
                            }
                            2 => line.insert(at, *rng.pick(b"{}[]\",:\\\xff\x00\n")),
                            _ => line.truncate(at),
                        }
                    }
                    input.extend_from_slice(&line);
                    input.push(b'\n');
                }
                let started = Instant::now();
                let (code, lines) = host(input, fuzz_limits());
                assert!(
                    matches!(code, exit::OK | exit::PROTOCOL | exit::FATAL),
                    "exit code {code}"
                );
                assert!(started.elapsed() < Duration::from_secs(20), "the host hung");
                if code == exit::FATAL {
                    assert!(
                        lines.iter().any(|l| l["t"] == "fatal" || l["t"] == "init-failed"),
                        "exit 70 without a fatal line: {lines:?}"
                    );
                }
            }));
            if let Err(panic) = outcome {
                panic!(
                    "CMUX_APP_FUZZ_SEED={seed} reproduces this wire failure: {}",
                    panic_text(&panic)
                );
            }
        }
    }
}
