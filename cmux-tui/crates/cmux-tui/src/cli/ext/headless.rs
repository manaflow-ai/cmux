//! `cmux ext dev --once --headless`: the same validate and build as `ext dev --once`, then the
//! built script loaded and its view rendered once in this process by the real QuickJS app host
//! (`cmux-app-host`, the engine the daemon runs), with no cmux running. Where an agent has no
//! cmux to load into (a CI runner, a cloud VM, the scheduled copy-paste prompt check), it still
//! can validate manifest-only extensions, load catalog handlers, and get a scene outline for views.
//! Every host call is answered with no value, so a view that reads data renders its empty state; placement, install and the window are not checked here.

use cmux_app_host::{AppInfo, AppVm, FromHost, InitParams, Limits};
use serde_json::{Value, json};

use super::DevOptions;
use super::dev::{self, Outcome, Phase, Problem};

fn load_script(app: &str, main: &str, path: &str) -> Result<AppVm, String> {
    let mut vm = AppVm::new(Limits::default())?;
    vm.init(InitParams {
        app: AppInfo { id: app.into(), version: "0.1.0".into() },
        settings: json!({}),
        api_version: cmux_app_manifest::capabilities::Capabilities::get().api_version.clone(),
        ops: None,
        known_ops: None,
        locale: None,
        strings: Value::Null,
        main: main.into(),
        main_name: Some(path.into()),
    })
    .map_err(|e| format!("init: {e:?}"))?;
    Ok(vm)
}

#[cfg(test)]
pub(super) fn host_scene(
    app: &str,
    main: &str,
    export: &str,
    context: &Value,
) -> Result<Value, String> {
    let mut vm = load_script(app, main, "dist/main.js")?;
    mount_scene(&mut vm, export, context)
}

fn mount_scene(vm: &mut AppVm, export: &str, context: &Value) -> Result<Value, String> {
    if let Some(refused) = vm.mount("probe", export, context).map_err(|e| format!("{e:?}"))? {
        return Err(refused);
    }
    let mut ops = Vec::new();
    for _ in 0..32 {
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
    Ok(Value::Array(ops))
}

/// Check registration without invoking a command or modifying the extension's exports.
fn check_catalog(vm: &mut AppVm, exports: &[String]) -> Result<(), String> {
    if exports.is_empty() {
        return Ok(());
    }
    let names = serde_json::to_string(exports).map_err(|e| e.to_string())?;
    let expression = format!(
        r#"(() => {{
            const handlers = globalThis.__cmuxAppExports ?? {{}};
            return {names}.filter(name =>
                !Object.hasOwn(handlers, name) || typeof handlers[name] !== "function");
        }})()"#
    );
    let missing =
        vm.eval_json(&expression).map_err(|e| format!("checking catalog exports: {e:?}"))??;
    let missing: Vec<String> = serde_json::from_value(missing).map_err(|e| e.to_string())?;
    if missing.is_empty() {
        Ok(())
    } else {
        Err(format!("missing catalog command function: {}", missing.join(", ")))
    }
}

/// Export names declared by the package's catalog. Package validation already
/// checks the catalog's schema and path, but reading it here keeps this check
/// independent from the daemon and gives headless mode the same source of
/// truth as the command runtime.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn catalog_exports(pkg: &dev::Package) -> Result<Vec<String>, String> {
    let Some(path) = pkg.manifest.pointer("/catalog").and_then(Value::as_str) else {
        return Ok(Vec::new());
    };
    let catalog: Value = serde_json::from_str(
        &std::fs::read_to_string(pkg.dir.join(path)).map_err(|e| format!("{path}: {e}"))?,
    )
    .map_err(|e| format!("{path}: {e}"))?;
    Ok(catalog["operations"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|op| op["export"].as_str().map(str::to_owned))
        .collect())
}

/// One headless reload: validate, build, validate again, then load and render the probe.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
pub(super) fn once(options: &DevOptions) -> Outcome {
    let builds =
        dev::build_will_run(&options.dir, options.build.as_deref(), options.bun.as_deref());
    let mut outcome = Outcome::new(Phase::Manifest);
    let pkg = match dev::load_package_unbuilt(&options.dir, builds) {
        Ok(pkg) => pkg,
        Err(errors) => return outcome.failed(Phase::Manifest, errors),
    };
    outcome.app = Some(pkg.id.clone());
    let plan = dev::build_plan(&pkg, options.build.as_deref(), options.bun.as_deref());
    let started = std::time::Instant::now();
    if let Err(errors) = dev::build(&pkg, &plan, options.build_timeout) {
        return outcome.failed(Phase::Build, errors);
    }
    outcome.build = match &plan {
        dev::BuildPlan::Command(_) => Some("command"),
        dev::BuildPlan::Pack(_) => Some("pack"),
        dev::BuildPlan::None { note } => {
            outcome.build_note = note.clone();
            None
        }
    };
    if outcome.build.is_some() {
        outcome.build_ms = Some(started.elapsed().as_millis());
    }
    let pkg = match dev::load_package(&options.dir) {
        Ok(pkg) => pkg,
        Err(errors) => return outcome.failed(Phase::Manifest, errors),
    };
    let interface = dev::probe_interface(&pkg.manifest);
    let exports = match catalog_exports(&pkg) {
        Ok(exports) => exports,
        Err(error) => return outcome.failed(Phase::Load, vec![Problem::message(error)]),
    };
    if interface.is_none() && exports.is_empty() {
        outcome.next = Some(
            "headless: manifest validated; run `cmux ext dev` with cmux open to use this extension"
                .into(),
        );
        outcome.phase = Phase::Done;
        return outcome;
    }
    let main_path =
        pkg.manifest.pointer("/runtime/main").and_then(Value::as_str).unwrap_or("dist/main.js");
    let script = match std::fs::read_to_string(pkg.dir.join(main_path)) {
        Ok(script) => script,
        Err(error) => {
            return outcome
                .failed(Phase::Load, vec![Problem::message(format!("{main_path}: {error}"))]);
        }
    };
    let mut vm = match load_script(&pkg.id, &script, main_path) {
        Ok(vm) => vm,
        Err(reason) => return outcome.failed(Phase::Load, vec![dev::load_problem(&reason)]),
    };
    if let Err(reason) = check_catalog(&mut vm, &exports) {
        return outcome.failed(Phase::Load, vec![dev::load_problem(&reason)]);
    }
    let Some(interface) = interface else {
        outcome.next = Some("headless: loaded catalog command exports; run `cmux ext dev` with cmux open to use the commands".into());
        outcome.phase = Phase::Done;
        return outcome;
    };
    outcome.probe = Some(interface.clone());
    let export = pkg.manifest["implements"][&interface]["export"].as_str().unwrap_or("");
    // As the daemon does (cmux-tui-core apps/widgets.rs): a widget renders with
    // `surface: "widget"`, which gives its ctx the host-owned now() clock.
    let mut context = dev::probe_context(&pkg.manifest, &interface);
    if interface == "cmux.widget/1" && context.is_object() {
        context["surface"] = json!("widget");
    }
    match mount_scene(&mut vm, export, &context) {
        Ok(ops) => {
            outcome.next = Some(
                "headless: validated, built and rendered here; run `cmux ext dev` with cmux open to see it in the window".into(),
            );
            outcome.scene = super::scene::outline(&[&ops]);
            let (system, problem) = super::design_system::System::load(&pkg.dir);
            outcome.design = problem
                .into_iter()
                .chain(super::design::check_in(
                    &[&ops],
                    super::design::Surface::of(&interface),
                    &system,
                ))
                .collect();
            outcome.phase = Phase::Done;
            outcome
        }
        Err(reason) => outcome.failed(Phase::Load, vec![dev::load_problem(&reason)]),
    }
}
