#[tokio::main]
async fn main() {
    let env = |name: &str| std::env::var(name).ok();
    let code = cmux_vm::run(
        std::env::args_os(),
        &env,
        &mut cmux_vm::StdinPrompt,
        &mut std::io::stdout().lock(),
        &mut std::io::stderr().lock(),
    )
    .await;
    std::process::exit(code);
}
