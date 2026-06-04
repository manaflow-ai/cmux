fn main() {
    println!("cargo:rustc-link-arg-bin=cmux-app=-Wl,-rpath,$ORIGIN");
}
