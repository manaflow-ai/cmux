#[tokio::main]
async fn main() {
    let env = |name: &str| std::env::var(name).ok();
    // `ssh` runs this binary as its askpass helper with the prompt as argv[1].
    let prompt = std::env::args_os()
        .nth(1)
        .and_then(|arg| arg.into_string().ok());
    if let Some(code) = cmux_vm::askpass(&env, prompt.as_deref(), &mut std::io::stdout().lock()) {
        std::process::exit(code);
    }
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
