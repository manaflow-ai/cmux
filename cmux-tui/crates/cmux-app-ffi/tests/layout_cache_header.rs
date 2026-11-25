use std::{path::Path, process::Command};

/// The header compiles as C, its prototypes match the Rust functions' C types, and every function
/// it declares is in the packaged library's exports.
#[test]
fn layout_cache_header_compiles_and_is_exported() {
    let crate_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let temporary = Path::new(env!("CARGO_TARGET_TMPDIR"));
    let source = temporary.join("layout_cache_header.c");
    let object = temporary.join("layout_cache_header.o");
    std::fs::write(
        &source,
        "#include \"cmux_layout_cache.h\"\n\
void (*string_free)(char *) = cmux_layout_cache_string_free;\n\
char *(*path)(const char *) = cmux_layout_cache_path;\n\
char *(*read_cache)(const char *) = cmux_layout_cache_read;\n\
int32_t (*write_cache)(const char *, const char *) = cmux_layout_cache_write;\n\
char *(*usable)(const char *, const char *) = cmux_layout_cache_usable;\n\
char *(*reconcile)(const char *, const char *) = cmux_layout_cache_reconcile;\n\
char *(*strip)(const char *, const char *, double) = cmux_layout_cache_reconcile_strip;\n\
char *(*rows)(const char *, const char *, double) = cmux_layout_cache_reconcile_rows;\n\
double (*shift)(const char *, const char *, const char *) = cmux_layout_cache_shift_score;\n\
uint64_t (*swap_wait)(uint8_t, uint32_t, uint32_t, uint64_t) = cmux_layout_cache_swap_wait_ms;\n\
CmuxLayoutCacheCoalescer *(*co_new)(void) = cmux_layout_cache_coalescer_new;\n\
void (*co_free)(CmuxLayoutCacheCoalescer *) = cmux_layout_cache_coalescer_free;\n\
void (*co_note)(CmuxLayoutCacheCoalescer *, uint64_t) = cmux_layout_cache_coalescer_note;\n\
bool (*co_due)(CmuxLayoutCacheCoalescer *, uint64_t) = cmux_layout_cache_coalescer_due;\n\
int64_t (*co_next)(CmuxLayoutCacheCoalescer *) = cmux_layout_cache_coalescer_next_due_ms;\n\
bool (*co_flush)(CmuxLayoutCacheCoalescer *) = cmux_layout_cache_coalescer_flush_now;\n\
int32_t (*co_write)(CmuxLayoutCacheCoalescer *, const char *, const char *) = cmux_layout_cache_coalescer_write;\n\
bool (*co_wrote)(CmuxLayoutCacheCoalescer *, const char *) = cmux_layout_cache_coalescer_wrote;\n",
    )
    .unwrap();
    let output = Command::new("cc")
        .arg("-std=c11")
        .arg("-Werror")
        .arg("-I")
        .arg(crate_dir.join("../cmux-layout-cache/include"))
        .arg("-c")
        .arg(&source)
        .arg("-o")
        .arg(&object)
        .output()
        .unwrap();
    assert!(output.status.success(), "C header: {}", String::from_utf8_lossy(&output.stderr));
    let exports = Command::new("bash")
        .arg(crate_dir.join("../../../scripts/cmux-next/build-app-ffi.sh"))
        .arg("--list-exports")
        .output()
        .unwrap();
    assert!(exports.status.success(), "{}", String::from_utf8_lossy(&exports.stderr));
    let exports = String::from_utf8(exports.stdout).unwrap();
    let missing: Vec<&str> = [
        "_cmux_layout_cache_string_free",
        "_cmux_layout_cache_path",
        "_cmux_layout_cache_read",
        "_cmux_layout_cache_write",
        "_cmux_layout_cache_usable",
        "_cmux_layout_cache_reconcile",
        "_cmux_layout_cache_reconcile_strip",
        "_cmux_layout_cache_reconcile_rows",
        "_cmux_layout_cache_shift_score",
        "_cmux_layout_cache_swap_wait_ms",
        "_cmux_layout_cache_coalescer_new",
        "_cmux_layout_cache_coalescer_free",
        "_cmux_layout_cache_coalescer_note",
        "_cmux_layout_cache_coalescer_due",
        "_cmux_layout_cache_coalescer_next_due_ms",
        "_cmux_layout_cache_coalescer_flush_now",
        "_cmux_layout_cache_coalescer_write",
        "_cmux_layout_cache_coalescer_wrote",
    ]
    .into_iter()
    .filter(|symbol| !exports.lines().any(|line| line == *symbol))
    .collect();
    assert!(missing.is_empty(), "missing packaged symbols: {missing:?}");
}
