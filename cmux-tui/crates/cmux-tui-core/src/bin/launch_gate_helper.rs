fn main() -> anyhow::Result<()> {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    match cmux_tui_core::launch_gate_entrypoint(&arguments) {
        Some(result) => result,
        None => anyhow::bail!("cmux launch-gate helper requires its private entrypoint argument"),
    }
}
