use anyhow::Result;
use cmux_env::run_server;

fn main() -> Result<()> {
    // Simple foreground server
    run_server()
}
