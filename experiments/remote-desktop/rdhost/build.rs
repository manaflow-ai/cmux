// Compiles the x264 shim only when the `x264` feature is on.
fn main() {
    println!("cargo:rerun-if-changed=csrc/x264_shim.c");
    if std::env::var_os("CARGO_FEATURE_X264").is_none() {
        return;
    }
    cc::Build::new().file("csrc/x264_shim.c").opt_level(2).compile("rd_x264_shim");
    println!("cargo:rustc-link-lib=static=x264");
    println!("cargo:rustc-link-lib=dylib=m");
    println!("cargo:rustc-link-lib=dylib=dl");
}
