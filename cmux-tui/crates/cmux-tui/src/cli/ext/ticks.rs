//! A widget run in this process for a second tick and its timers: the `layout-shift` and
//! `hidden-timer` checks.
//!
//! The daemon owns a widget's tick (`cmux-tui-core/src/apps/widgets.rs`: every
//! `options.refresh.everySeconds`, only while the tile is visible) and has no request that ticks
//! now, so `ext dev` cannot ask it for a second scene. This runs the built script in the same app
//! host the daemon runs (`cmux_app_host::AppVm`), mounted with the context the daemon builds, and
//! ticks it once. Every call it makes is answered with no value, so a widget that renders from
//! fetched data shows its empty state here: the checks read what changes on a tick, not the data.
//! The daemon's probe stays the judge of whether the widget loads; this one failing is silent.
//!
//! - `layout-shift`: a tick that only changes words, where a Text's length changes in a row and
//!   moves what comes after it. A scene has no laid-out boxes, so only that case is caught: a
//!   tick that adds, removes or moves nodes is a new layout, not a shift, and is left alone.
//! - `hidden-timer`: a `cmux.timer.every` still armed after the mount, a `cmux.timer.after` that
//!   arms itself again when it fires, or a one-shot `after` of a second or more still pending.
//!   The host stops ticking a tile it does not show; an app's own timer keeps running (and
//!   redrawing) behind it. `cmux.watch`'s own polling is the host's, not counted.

use std::time::{Duration, Instant};

use cmux_app_host::{AppInfo, AppVm, FromHost, InitParams, Limits};
use serde_json::{Value, json};

use super::Field as _;
use super::design::{Finding, Findings, Tile};

/// The mount id of the in-process probe.
const MOUNT: &str = "ext-dev-probe";

/// Message rounds a mount or a tick may take to settle (calls answered, effects run).
const ROUNDS: usize = 32;

/// The daemon's floor on a widget's refresh (`refresh.everySeconds`).
const MIN_REFRESH_SECONDS: u64 = 60;

/// A one-shot `cmux.timer.after` at most this long (a debounce, a settle) is not a clock.
const SHORT_MS: f64 = 1000.0;

/// Prepended to the script (on its first line, so its line numbers stay): records each
/// `cmux.timer.after` and `every` the app arms, whether it is still armed, and whether it was
/// armed while a timer was firing.
const RECORD_TIMERS: &str = "(()=>{try{const t=globalThis.cmux&&globalThis.cmux.timer;if(!t||t.__dev)return;const log=[];const live=new Map();let firing=0;const after=t.after,every=t.every,clear=t.clear;t.after=(ms,fn)=>{const r={ms:Number(ms)||0,repeat:false,live:true,chained:firing>0};log.push(r);const id=after(ms,()=>{r.live=false;firing++;try{fn()}finally{firing--}});live.set(id,r);return id};t.every=(ms,fn)=>{const r={ms:Number(ms)||0,repeat:true,live:true,chained:firing>0};log.push(r);const id=every(ms,()=>{firing++;try{fn()}finally{firing--}});live.set(id,r);return id};t.clear=(id)=>{const r=live.get(id);if(r)r.live=false;return clear(id)};t.__dev=true;globalThis.__cmuxDevTimers=log}catch(e){}})();";

/// One app timer the probe saw.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Timer {
    pub ms: f64,
    pub repeat: bool,
    /// Armed and not cleared once the mount and its tick settled.
    pub pending: bool,
    /// Armed by a timer's own callback: a loop of `after`s.
    pub chained: bool,
}

/// What the in-process probe saw: the first scene's ops, the ops one tick sent, the timers.
#[derive(Debug, Default)]
pub(super) struct Ticked {
    pub first: Vec<Value>,
    pub tick: Vec<Value>,
    pub timers: Vec<Timer>,
}

/// The `layout-shift` and `hidden-timer` findings for the widget `export` of the built script
/// `main`, mounted at `context` (`{place, size, ...}`) in `tile`.
pub(super) fn check(
    app: &str,
    main: &str,
    export: &str,
    context: &Value,
    manifest: &Value,
    tile: &Tile,
) -> Vec<Finding> {
    let refresh = manifest
        .pointer("/implements/cmux.widget~11/options/refresh/everySeconds")
        .and_then(Value::as_u64)
        .map(|s| s.max(MIN_REFRESH_SECONDS));
    let Ok(ticked) = run(app, main, export, context, refresh) else { return Vec::new() };
    let mut findings = Findings::default();
    super::design_layout::layout_shift(&ticked.first, &ticked.tick, &mut findings);
    hidden_timers(&ticked.timers, &mut findings);
    let mut done = findings.done();
    for finding in &mut done {
        finding.sizes = vec![tile.size.clone()];
    }
    done
}

/// Mounts `export` with the daemon's widget context, then ticks it once and fires its timers.
pub(super) fn run(
    app: &str,
    main: &str,
    export: &str,
    context: &Value,
    refresh: Option<u64>,
) -> Result<Ticked, String> {
    let mut vm = AppVm::new(Limits::default())?;
    vm.init(InitParams {
        app: AppInfo { id: app.into(), version: "0.0.0".into() },
        settings: json!({}),
        api_version: cmux_app_manifest::capabilities::Capabilities::get().api_version.clone(),
        ops: None,
        known_ops: None,
        locale: None,
        strings: Value::Null,
        main: format!("{RECORD_TIMERS}{main}"),
        main_name: Some("dist/main.js".into()),
    })
    .map_err(|e| format!("init: {e:?}"))?;
    let mut ctx = json!({
        "surface": "widget",
        "place": context.field("place").as_str().unwrap_or("newtab"),
        "size": context.field("size").as_str().unwrap_or("small"),
        "instance": MOUNT,
        "settings": {},
        "refresh": refresh.map(|s| json!({ "everySeconds": s })),
        "locale": "en",
        "timeZone": "UTC",
    });
    if context.get("preview").is_some() {
        ctx["preview"] = context["preview"].clone();
    }
    let mut ticked = Ticked::default();
    pump(&mut vm, &mut Vec::new())?;
    if let Some(refused) = vm.mount(MOUNT, export, &ctx).map_err(|e| format!("{e:?}"))? {
        return Err(refused);
    }
    pump(&mut vm, &mut ticked.first)?;
    // The VM's own clock, which the mount's now() started from.
    let now =
        vm.eval_json("Date.now()").map_err(|e| format!("{e:?}"))??.as_f64().unwrap_or(0.0) as u64;
    let step = refresh.unwrap_or(MIN_REFRESH_SECONDS) * 1000;
    vm.tick(MOUNT, now + step).map_err(|e| format!("{e:?}"))?;
    pump(&mut vm, &mut ticked.tick)?;
    let pending = vm
        .eval_json("(globalThis.__cmuxDevTimers || []).map(t => t.live)")
        .map_err(|e| format!("{e:?}"))??;
    // Each armed timer fires once, as if an hour went by with the tile hidden.
    vm.fire_due_timers(Instant::now() + Duration::from_secs(3600)).map_err(|e| format!("{e:?}"))?;
    pump(&mut vm, &mut Vec::new())?;
    let log = vm.eval_json("globalThis.__cmuxDevTimers || []").map_err(|e| format!("{e:?}"))??;
    ticked.timers = log
        .as_array()
        .into_iter()
        .flatten()
        .enumerate()
        .map(|(i, t)| Timer {
            ms: t.field("ms").as_f64().unwrap_or(0.0),
            repeat: t.field("repeat").as_bool().unwrap_or(false),
            // Armed by a callback when the timers fired: pending only if it is still armed.
            pending: pending
                .get(i)
                .and_then(Value::as_bool)
                .unwrap_or_else(|| t.field("live").as_bool().unwrap_or(false)),
            chained: t.field("chained").as_bool().unwrap_or(false),
        })
        .collect();
    Ok(ticked)
}

/// Answers every call with no value until the VM is quiet; the scene ops land in `ops`.
fn pump(vm: &mut AppVm, ops: &mut Vec<Value>) -> Result<(), String> {
    for _ in 0..ROUNDS {
        let outbox = vm.take_outbox();
        if outbox.is_empty() {
            break;
        }
        for message in outbox {
            match message {
                FromHost::Scene { ops: batch, .. } => {
                    ops.extend(batch.as_array().cloned().unwrap_or_default());
                }
                FromHost::Call { cb, .. } => {
                    vm.resolve(cb, true, &json!({ "value": null }))
                        .map_err(|e| format!("{e:?}"))?;
                }
                FromHost::Fatal { .. } => return Err(format!("{message:?}")),
                _ => {}
            }
        }
    }
    Ok(())
}

fn hidden_timers(timers: &[Timer], findings: &mut Findings) {
    for timer in timers {
        let call = if timer.repeat { "cmux.timer.every" } else { "cmux.timer.after" };
        let how = if timer.chained && !timer.repeat {
            "arms itself again each time it fires"
        } else if timer.repeat && timer.pending {
            "stays armed after the widget renders"
        } else if timer.pending && timer.ms >= SHORT_MS {
            "is armed by the widget and fires on its own clock"
        } else {
            continue;
        };
        findings.add(
            "hidden-timer",
            None,
            format!(
                "{call}({:.0}) {how}: it keeps running while the tile is hidden, where cmux stops only its own tick",
                timer.ms
            ),
            "draw time from ctx.now() and set options.refresh.everySeconds (the host ticks only a shown tile); read data with cmux.watch".into(),
        );
    }
}

#[cfg(test)]
#[path = "ticks_tests.rs"]
mod tests;
