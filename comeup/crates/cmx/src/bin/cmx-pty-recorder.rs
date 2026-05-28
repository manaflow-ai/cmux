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

use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};

fn main() -> Result<()> {
    let args = Args::parse(std::env::args().skip(1))?;
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows: args.rows,
            cols: args.cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .context("open cmx pty")?;

    let mut cmx_path = std::env::current_exe().context("resolve recorder path")?;
    cmx_path.set_file_name("cmx");
    let mut command = CommandBuilder::new(cmx_path);
    command.arg("--socket");
    command.arg(args.socket);
    command.arg("--cols");
    command.arg(args.cols.to_string());
    command.arg("--rows");
    command.arg(args.rows.to_string());

    let child = pair.slave.spawn_command(command).context("spawn cmx")?;
    let mut killer = child.clone_killer();
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader().context("clone pty reader")?;
    let mut writer = pair.master.take_writer().context("take pty writer")?;
    let (event_tx, event_rx) = mpsc::channel::<RecorderEvent>();
    let watch_needles = args
        .send_after
        .iter()
        .map(|send_after| send_after.needle.clone())
        .collect::<Vec<_>>();

    std::thread::spawn(move || {
        let mut stdout = std::io::stdout();
        let mut buf = [0; 8192];
        let mut output = Vec::new();
        let mut sent = vec![false; watch_needles.len()];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => {
                    let _ = event_tx.send(RecorderEvent::Done(Ok(())));
                    return;
                }
                Ok(n) => {
                    if let Err(err) = stdout.write_all(&buf[..n]).and_then(|()| stdout.flush()) {
                        let _ = event_tx.send(RecorderEvent::Done(
                            Err(err).context("write cmx pty output"),
                        ));
                        return;
                    }
                    output.extend_from_slice(&buf[..n]);
                    let text = String::from_utf8_lossy(&output);
                    for (index, needle) in watch_needles.iter().enumerate() {
                        if !sent[index] && text.contains(needle) {
                            sent[index] = true;
                            let _ = event_tx.send(RecorderEvent::Needle(index));
                        }
                    }
                }
                Err(err) => {
                    let _ =
                        event_tx.send(RecorderEvent::Done(Err(err).context("read cmx pty output")));
                    return;
                }
            }
        }
    });

    loop {
        match event_rx.recv_timeout(Duration::from_secs(1)) {
            Ok(RecorderEvent::Needle(index)) => {
                let Some(send_after) = args.send_after.get(index) else {
                    continue;
                };
                writeln!(writer, "{}", send_after.line).context("write cmx pty command")?;
                writer.flush().context("flush cmx pty command")?;
            }
            Ok(RecorderEvent::Done(result)) => {
                let _ = killer.kill();
                return result;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = killer.kill();
                return Err(anyhow!("cmx pty recorder stopped without a result"));
            }
        }
    }
}

enum RecorderEvent {
    Needle(usize),
    Done(Result<()>),
}

struct SendAfter {
    needle: String,
    line: String,
}

struct Args {
    socket: PathBuf,
    cols: u16,
    rows: u16,
    send_after: Vec<SendAfter>,
}

impl Args {
    fn parse(args: impl IntoIterator<Item = String>) -> Result<Self> {
        let mut socket = None;
        let mut cols = 80;
        let mut rows = 24;
        let mut send_after = Vec::new();
        let mut iter = args.into_iter();
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--socket" => socket = iter.next().map(PathBuf::from),
                "--cols" => {
                    cols = iter
                        .next()
                        .ok_or_else(|| anyhow!("--cols requires a value"))?
                        .parse::<u16>()?;
                }
                "--rows" => {
                    rows = iter
                        .next()
                        .ok_or_else(|| anyhow!("--rows requires a value"))?
                        .parse::<u16>()?;
                }
                "--send-after" => {
                    let needle = iter
                        .next()
                        .ok_or_else(|| anyhow!("--send-after requires a needle"))?;
                    let line = iter
                        .next()
                        .ok_or_else(|| anyhow!("--send-after requires a command line"))?;
                    send_after.push(SendAfter { needle, line });
                }
                "-h" | "--help" => {
                    println!(
                        "usage: cmx-pty-recorder --socket PATH [--cols N] [--rows N] [--send-after NEEDLE LINE]"
                    );
                    std::process::exit(0);
                }
                _ => bail!("unknown argument: {arg}"),
            }
        }
        if cols == 0 {
            bail!("--cols must be greater than 0");
        }
        if rows == 0 {
            bail!("--rows must be greater than 0");
        }

        Ok(Self {
            socket: socket.ok_or_else(|| anyhow!("--socket is required"))?,
            cols,
            rows,
            send_after,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn args_reject_zero_dimensions() {
        assert!(
            Args::parse([
                "--socket".to_string(),
                "/tmp/comeup.sock".to_string(),
                "--cols".to_string(),
                "0".to_string(),
            ])
            .is_err()
        );
        assert!(
            Args::parse([
                "--socket".to_string(),
                "/tmp/comeup.sock".to_string(),
                "--rows".to_string(),
                "0".to_string(),
            ])
            .is_err()
        );
    }
}
