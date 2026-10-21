//! Runs the Rex parity bench as a test so a fleet `cmux-tui-rust-check.sh
//! test api_compat_bench` step measures it on a mini (the measure-script
//! allowlist lives in HQ). Results go to `.build/api-compat-bench.txt` at the
//! repository root; fetch them with `cmux-ci run ... --artifact
//! .build/api-compat-bench.txt`. It asserts correctness only, never timings.

#[path = "../benches/rex_parity.rs"]
mod rex_parity;

mod api_compat_bench {
    #[test]
    fn api_compat_bench_rex_parity() {
        let mut out = Vec::new();
        let host = std::process::Command::new("sysctl")
            .args(["-n", "machdep.cpu.brand_string"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
            .unwrap_or_default();
        out.extend_from_slice(format!("cpu={host}\n").as_bytes());
        super::rex_parity::run(&mut out, 2000);
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("api-compat-bench.txt"), &out).unwrap();
        print!("{}", String::from_utf8_lossy(&out));
    }
}
