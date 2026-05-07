use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

fn main() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }

    println!("cargo:rerun-if-env-changed=DEP_GHOSTTY_VT_INCLUDE");
    println!("cargo:rerun-if-env-changed=GHOSTTY_SOURCE_DIR");
    println!("cargo:rerun-if-env-changed=LIBGHOSTTY_VT_SYS_NO_VENDOR");

    if let Some(lib_dir) = libghostty_lib_dir() {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
    }
}

fn libghostty_lib_dir() -> Option<PathBuf> {
    env::var_os("DEP_GHOSTTY_VT_INCLUDE")
        .map(PathBuf::from)
        .and_then(|include| {
            let lib = include.parent()?.join("lib");
            has_libghostty(&lib).then_some(lib)
        })
        .or_else(find_lib_dir_in_target)
}

fn find_lib_dir_in_target() -> Option<PathBuf> {
    let out_dir = PathBuf::from(env::var_os("OUT_DIR")?);
    let build_dir = out_dir.ancestors().nth(2)?;
    newest_lib_dir(build_dir)
}

fn newest_lib_dir(build_dir: &Path) -> Option<PathBuf> {
    let mut best: Option<(SystemTime, PathBuf)> = None;
    for entry in fs::read_dir(build_dir).ok()?.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !name.starts_with("libghostty-vt-sys-") {
            continue;
        }
        let lib = path.join("out").join("ghostty-install").join("lib");
        if !has_libghostty(&lib) {
            continue;
        }
        let modified = fs::metadata(&lib)
            .and_then(|metadata| metadata.modified())
            .unwrap_or(SystemTime::UNIX_EPOCH);
        match &best {
            Some((best_time, _)) if *best_time >= modified => {}
            _ => best = Some((modified, lib)),
        }
    }
    best.map(|(_, path)| path)
}

fn has_libghostty(path: &Path) -> bool {
    path.join("libghostty-vt.dylib").exists() || path.join("libghostty-vt.0.1.0.dylib").exists()
}
