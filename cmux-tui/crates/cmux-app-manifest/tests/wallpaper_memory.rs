//! Checking `contributes.wallpapers` runs naga (cmux-wallpaper) over each
//! program. Nothing of it may stay alive after the check returns: no cached
//! module, validator or translation. Its own binary, for its own allocator
//! count (as tests/memory.rs).

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicIsize, Ordering};

use cmux_app_manifest::validate_package;

struct Counting;

static LIVE: AtomicIsize = AtomicIsize::new(0);

// SAFETY: forwards to the system allocator and only counts bytes.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        LIVE.fetch_add(layout.size() as isize, Ordering::Relaxed);
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size() as isize, Ordering::Relaxed);
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        LIVE.fetch_add(new_size as isize - layout.size() as isize, Ordering::Relaxed);
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static ALLOC: Counting = Counting;

/// Module named `apps` so `verify-cmux-tui-hosted.sh --filter apps::` selects
/// every app platform test in the workspace.
mod apps {
    use super::*;

    // The only test in this binary, so no other test allocates meanwhile.
    #[test]
    fn checking_wallpapers_retains_nothing() {
        // naga runs here: the dev-dependency turns on cmux-wallpaper/compile.
        const {
            assert!(cmux_wallpaper::CHECKS_PROGRAMS);
        }
        let dir = std::env::temp_dir()
            .join(format!("cmux-app-manifest-wallpaper-memory-{}", std::process::id()));
        let folder = dir.join("wallpapers/glow");
        std::fs::create_dir_all(&folder).expect("mkdir");
        std::fs::write(
            folder.join("wallpaper.json"),
            r#"{"id":"glow","name":"Glow","description":"A glow.","shader":"wallpaper.wgsl","fps":30,"scale":0.5,"interactive":true,"still":{"time":1,"pointer":[0.5,0.5]}}"#,
        )
        .expect("write");
        std::fs::write(
            folder.join("wallpaper.wgsl"),
            "fn wallpaper(px: vec2<f32>) -> vec4<f32> {\n    let d = distance(px, frame.pointer.xy) / frame.size.y;\n    return vec4<f32>(mix(frame.paper.rgb, frame.accent.rgb, exp(-d * 8.0)), 1.0);\n}\n",
        )
        .expect("write");
        let mut manifest = serde_json::json!({
            "manifestVersion": 2, "id": "local/x", "name": "X", "version": "1.0.0",
            "description": "d", "engines": { "cmux": "^2.0" }, "icon": { "symbol": "app" }
        });
        std::fs::write(dir.join("cmux-app.json"), manifest.to_string()).expect("write");

        // A run without wallpapers builds the schema validator, which stays for the
        // process (memory.rs); naga has not run yet.
        let first = validate_package(&dir);
        assert!(first.is_valid(), "{:?}", first.issues);
        drop(first);
        manifest["contributes"] =
            serde_json::json!({ "wallpapers": [{ "path": "wallpapers/glow" }] });
        std::fs::write(dir.join("cmux-app.json"), manifest.to_string()).expect("write");
        let before = LIVE.load(Ordering::Relaxed);
        for _ in 0..5 {
            let report = validate_package(&dir);
            assert!(report.is_valid(), "{:?}", report.issues);
        }
        let retained = LIVE.load(Ordering::Relaxed) - before;
        std::fs::remove_dir_all(&dir).ok();
        assert!(retained < 64 << 10, "checking wallpapers retained {retained} bytes");
    }
}
