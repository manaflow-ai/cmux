//! The SDK example extensions (`examples/extensions/*` with a `cmux-app.json`), packed as `cmux ext
//! dev` packs them and run in the native host's QuickJS VM with the shipped runtime
//! (`js/dist/cmux-app-runtime.js`). The bun tests mount them in another engine against a fake
//! host, which let a clock that called its `signal` tuple as a function pass while cmux showed
//! "TypeError: not a function".

mod common;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use cmux_app_host::Limits;
use common::Harness;
use serde_json::{Value, json};

/// Module named `apps` so `verify-cmux-tui-hosted.sh --filter apps::` selects it.
mod apps {
    use super::*;

    fn examples() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../examples/extensions")
    }

    /// Whether bun, which packs the examples, is on PATH (CI's cmux-tui job installs it).
    fn have_bun() -> bool {
        let found = Command::new("bun").arg("--version").output().is_ok_and(|o| o.status.success());
        if !found {
            eprintln!("SKIPPED: bun is not on PATH");
        }
        found
    }

    /// `dir` packed by `tools/pack.ts`, as `cmux ext dev` builds `src/main.ts`, once per test binary.
    /// pack.ts writes a wrapper into `src/` and removes it, so two packs of one folder at once
    /// (tests run in parallel) would race: they take turns, and each folder is packed once.
    fn packed(dir: &Path) -> String {
        static PACKED: Mutex<BTreeMap<PathBuf, String>> = Mutex::new(BTreeMap::new());
        let mut packed = PACKED.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        packed.entry(dir.to_path_buf()).or_insert_with(|| pack_now(dir)).clone()
    }

    fn pack_now(dir: &Path) -> String {
        let pack = Path::new(env!("CARGO_MANIFEST_DIR")).join("tools/pack.ts");
        let script = format!(
            "const {{ pack }} = await import({:?}); process.stdout.write(await pack(process.argv[1]))",
            pack.display().to_string()
        );
        let out = Command::new("bun")
            .args(["-e", &script, &dir.display().to_string()])
            .output()
            .unwrap_or_else(|e| panic!("bun (needed to pack the examples): {e}"));
        assert!(
            out.status.success(),
            "{}: pack failed: {}",
            dir.display(),
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).expect("utf8")
    }

    fn manifest(dir: &Path) -> Value {
        serde_json::from_str(&std::fs::read_to_string(dir.join("cmux-app.json")).expect("manifest"))
            .expect("manifest json")
    }

    fn harness(dir: &Path) -> Harness {
        let id = manifest(dir)["id"].as_str().unwrap_or("local/example").to_string();
        let init = json!({ "app": { "id": id, "version": "1.0.0" } });
        Harness::with(&packed(dir), init, Limits::default())
    }

    #[test]
    fn the_newtab_clock_draws_the_time_and_ticks_in_the_native_vm() {
        if !have_bun() {
            return;
        }
        let dir = examples().join("newtab-clock");
        let mut h = harness(&dir);
        assert_eq!(h.mount("m", "renderNewTab", json!({ "cwd": "/Users/someone/src" })), None);
        let texts = h.texts("m");
        let time = texts
            .iter()
            .find(|t| t.ends_with(" AM") || t.ends_with(" PM"))
            .unwrap_or_else(|| panic!("no time in {texts:?}"))
            .clone();
        assert!(texts.iter().any(|t| t == "Starting in ~/src"), "{texts:?}");
        // One tick a second later redraws the seconds.
        std::thread::sleep(Duration::from_millis(1100));
        h.vm.fire_due_timers(Instant::now() + Duration::from_secs(1)).expect("tick");
        h.pump().expect("pump");
        let after = h.texts("m");
        assert!(!after.contains(&time), "{time} still drawn after a tick: {after:?}");
        let errors: Vec<_> = h.logs.iter().filter(|(level, _)| level == "error").collect();
        assert!(errors.is_empty(), "{errors:?}");
    }

    #[test]
    fn a_render_error_names_the_script_line() {
        let main = common::app(
            "const read = [() => 1, () => {}];\nreturn { renderNewTab: () => read() };",
        );
        let mut h = Harness::new(&main);
        let error = h.mount("m", "renderNewTab", json!({})).expect("a render error");
        assert!(error.starts_with("TypeError: "), "{error}");
        assert!(error.contains("(main.js:"), "no script line in {error}");
    }

    #[test]
    fn every_newtab_example_draws_something_in_the_native_vm() {
        if !have_bun() {
            return;
        }
        let mut names: Vec<PathBuf> = std::fs::read_dir(examples())
            .expect("examples")
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.join("cmux-app.json").exists() && p.join("src/main.ts").exists())
            .collect();
        names.sort();
        let mut seen = 0;
        for dir in names {
            let implements = manifest(&dir)["implements"].clone();
            let Some(export) = implements["cmux.newtab/1"]["export"].as_str() else { continue };
            seen += 1;
            let mut h = harness(&dir);
            assert_eq!(h.mount("m", export, json!({})), None, "{}", dir.display());
            assert!(!h.texts("m").is_empty(), "{}: drew no text", dir.display());
        }
        assert!(seen > 0, "no example implements cmux.newtab/1");
    }
}
