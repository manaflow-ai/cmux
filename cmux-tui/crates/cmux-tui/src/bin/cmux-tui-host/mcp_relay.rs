//! `cmux-tui-host __mcp-relay <fd>`: an agent's stdio MCP server when one
//! cmux MCP host serves every agent (`cmux mcp serve`, feature
//! `mcpCatalogHost`, cmux-tui `cli/mcp/host.rs`).
//!
//! `cmux mcp serve` connects to the host, says who calls, and replaces itself
//! with this relay on the connected socket `<fd>`. The relay only copies
//! bytes: stdin to the socket and the socket to stdout, with no runtime, no
//! catalog and no parsing, so an agent's server costs this small binary's
//! footprint instead of the whole cmux runtime. It ends when either side
//! closes: stdin at end of file (after the host has answered everything it
//! sent), or the host's side of the socket.

use std::fs::File;
use std::io::{self, Read, Write};
use std::mem::ManuallyDrop;
use std::net::Shutdown;
use std::os::fd::{FromRawFd, RawFd};
use std::os::unix::net::UnixStream;

pub(super) const VERB: &str = "__mcp-relay";

/// The copy thread's stack: it only holds the copy buffer.
const COPY_STACK: usize = 64 << 10;
const BUFFER: usize = 16 << 10;

/// Runs the relay on descriptor `fd` (its text form); returns the exit code.
pub(super) fn run(fd: &str) -> u8 {
    let Ok(fd) = fd.parse::<RawFd>() else {
        eprintln!("cmux-tui-host: {VERB} needs a descriptor number");
        return 2;
    };
    if fd < 3 {
        eprintln!("cmux-tui-host: {VERB} descriptor {fd} is a standard stream");
        return 2;
    }
    // SAFETY: `cmux mcp serve` hands this process the connected socket at
    // `fd` across exec and nothing else owns it.
    let socket = unsafe { UnixStream::from_raw_fd(fd) };
    let Ok(to_host) = socket.try_clone() else { return 1 };
    // An agent's requests are automation: they never compete with the
    // person (Utility, Chromium kUtility).
    let from_client = cmux_threads::spawn_with_stack(
        "cmux-mcp-relay",
        cmux_threads::ThreadQos::Utility,
        COPY_STACK,
        move || {
            // SAFETY: descriptor 0 stays open for the process's life; the
            // `ManuallyDrop` never closes it.
            let stdin = ManuallyDrop::new(unsafe { File::from_raw_fd(0) });
            copy(&*stdin, &to_host);
            // The client is done sending; the host answers what it has and
            // closes its side, which ends the copy below.
            let _ = to_host.shutdown(Shutdown::Write);
        },
    );
    if from_client.is_err() {
        return 1;
    }
    // SAFETY: as above, for descriptor 1.
    let stdout = ManuallyDrop::new(unsafe { File::from_raw_fd(1) });
    copy(&socket, &*stdout);
    // The host closed its side: nothing more will come. Returning from main
    // ends the process, and the stdin copy with it.
    0
}

/// Copies `from` into `to` until end of file or an error on either side.
fn copy(mut from: impl Read, mut to: impl Write) {
    let mut buffer = vec![0u8; BUFFER];
    loop {
        let read = match from.read(&mut buffer) {
            Ok(0) => return,
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        };
        // A read that reports more than the buffer holds broke the `Read`
        // contract: stop relaying instead of panicking.
        let Some(chunk) = buffer.get(..read) else { return };
        if to.write_all(chunk).is_err() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_copy_moves_every_byte_and_ends_at_end_of_file() {
        let input = (0..100_000u32).flat_map(u32::to_le_bytes).collect::<Vec<_>>();
        let mut output = Vec::new();
        copy(input.as_slice(), &mut output);
        assert_eq!(output, input);
    }
}
