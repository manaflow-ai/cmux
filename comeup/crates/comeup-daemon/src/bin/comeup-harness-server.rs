#![cfg_attr(
    not(test),
    deny(
        clippy::expect_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented,
        clippy::unwrap_used
    )
)]

use std::path::PathBuf;

use anyhow::{Result, anyhow, bail};
use comeup_daemon::{
    ComeupServer, ServerOptions, serve_tcp_text_harness, serve_unix_socket_with_server,
};
use comeup_protocol::Viewport;

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse(std::env::args().skip(1))?;
    let server = ComeupServer::start(ServerOptions {
        shell: args.shell,
        cwd: args.cwd,
        initial_viewport: Viewport {
            cols: args.cols,
            rows: args.rows,
        },
    })?;

    let unix = serve_unix_socket_with_server(&args.socket, server.clone());
    let tcp = serve_tcp_text_harness(&args.tcp, server);
    tokio::try_join!(unix, tcp)?;
    Ok(())
}

struct Args {
    socket: PathBuf,
    tcp: String,
    shell: String,
    cwd: Option<PathBuf>,
    cols: u16,
    rows: u16,
}

impl Args {
    fn parse(args: impl IntoIterator<Item = String>) -> Result<Self> {
        let mut socket = None;
        let mut tcp = None;
        let mut shell = "/bin/cat".to_string();
        let mut cwd = None;
        let mut cols = 80;
        let mut rows = 24;
        let mut iter = args.into_iter();
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--socket" => socket = iter.next().map(PathBuf::from),
                "--tcp" => tcp = iter.next(),
                "--shell" => {
                    shell = iter
                        .next()
                        .ok_or_else(|| anyhow!("--shell requires value"))?
                }
                "--cwd" => cwd = iter.next().map(PathBuf::from),
                "--cols" => {
                    cols = iter
                        .next()
                        .ok_or_else(|| anyhow!("--cols requires value"))?
                        .parse()?;
                }
                "--rows" => {
                    rows = iter
                        .next()
                        .ok_or_else(|| anyhow!("--rows requires value"))?
                        .parse()?;
                }
                _ => bail!("unknown argument: {arg}"),
            }
        }
        Ok(Self {
            socket: socket.ok_or_else(|| anyhow!("--socket is required"))?,
            tcp: tcp.ok_or_else(|| anyhow!("--tcp is required"))?,
            shell,
            cwd,
            cols,
            rows,
        })
    }
}
