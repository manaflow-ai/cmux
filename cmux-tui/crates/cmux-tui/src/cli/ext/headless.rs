//! `cmux ext dev --once --headless`: the same validate and build as `ext dev --once`, then the
//! built script loaded and its view rendered once in this process by the real QuickJS app host
//! (`cmux-app-host`, the engine the daemon runs), with no cmux running. Where an agent has no
//! cmux to load into (a CI runner, a cloud VM, the scheduled copy-paste prompt check), it still
//! gets exit 0 only for an extension that validates, builds, loads and draws, and the scene
//! outline of what it drew. Every host call is answered with no value, so a view that reads
//! data renders its empty state; placement, install and the window are not checked here.

use serde_json::{Value, json};

use super::DevOptions;
use super::dev::{self, Outcome, Phase, Problem};

/// What the real app host renders when `export` of the script `main` mounts: QuickJS runs it
/// as the daemon's host does, every call it makes is answered with no value, and the scene's
/// op batches are returned in order (or the init or mount failure).
pub(super) fn host_scene(
    app: &str,
    main: &str,
    export: &str,
    context: &Value,
) -> Result<Value, String> {
    use cmux_app_host::{AppInfo, AppVm, FromHost, InitParams, Limits};
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
        main_name: Some("dist/main.js".into()),
    })
    .map_err(|e| format!("init: {e:?}"))?;
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

/// Loads a command extension's script and checks every catalog export without
/// invoking any of the command handlers.
pub(super) fn host_catalog(app: &str, main: &str, exports: &[String]) -> Result<(), String> {
    use cmux_app_host::{AppInfo, AppVm, InitParams, Limits};
    let names = serde_json::to_string(exports).map_err(|e| format!("catalog exports: {e}"))?;
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
        main_name: Some("dist/main.js".into()),
    })
    .map_err(|e| format!("init: {e:?}"))?;
    let source = format!(
        "(() => {{ const appExports = globalThis.__cmuxAppExports || {{}}; const expected = {names}; const types = {{}}; for (const name of expected) types[name] = typeof appExports[name]; return types; }})()"
    );
    let result = vm
        .eval_json(&source)
        .map_err(|e| format!("eval: {e:?}"))?
        .map_err(|e| format!("eval: {e}"))?;
    for name in exports {
        if result[name] != "function" {
            return Err(format!("catalog export {name} is {}", result[name].as_str().unwrap_or("missing")));
        }
    }
    Ok(())
}

/// Export names declared by the package's catalog. Package validation already
/// checks the catalog's schema and path, but reading it here keeps this check
/// independent from the daemon and gives headless mode the same source of
/// truth as the command runtime.
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
    outcome.next = Some(
        "headless: validated, built and rendered here; run `cmux ext dev` with cmux open to see it in the window"
            .to_owned(),
    );
    let interface = dev::probe_interface(&pkg.manifest);
    let exports = match catalog_exports(&pkg) {
        Ok(exports) => exports,
        Err(error) => return outcome.failed(Phase::Load, vec![Problem::message(error)]),
    };
    if interface.is_none() && exports.is_empty() {
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
    let Some(interface) = interface else {
        if !exports.is_empty() {
            if let Err(reason) = host_catalog(&pkg.id, &script, &exports) {
                return outcome.failed(Phase::Load, vec![dev::load_problem(&reason)]);
            }
            outcome.next = Some(
                "headless: validated, built and loaded catalog command exports here; run `cmux ext dev` with cmux open to use it in the window"
                    .to_owned(),
            );
        }
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
    match host_scene(&pkg.id, &script, export, &context) {
        Ok(ops) => {
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
