//! `cmux-vm-pool`: the verbs of `cmux vm pool` as a small binary (CI and the scheduler's host).

use std::process::ExitCode;

fn main() -> ExitCode {
    let words: Vec<String> = std::env::args().skip(1).collect();
    let env = |name: &str| std::env::var(name).ok();
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("cmux-vm-pool: cannot start the runtime: {error}");
            return ExitCode::FAILURE;
        }
    };
    let code =
        runtime.block_on(cmux_vm_pool::cli::run(&words, &env, &mut std::io::stdout().lock()));
    ExitCode::from(u8::try_from(code).unwrap_or(1))
}
