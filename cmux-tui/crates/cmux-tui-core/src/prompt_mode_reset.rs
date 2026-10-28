//! The per-chunk output rewrite every parser of a terminal's stream runs:
//! the title stack and OSC 1 into OSC 2, and a dead program's modes reset
//! at the shell's prompt marks. It lives in `cmux-vt-stream`, so the
//! sandboxed parser process (`cmux-vt-worker`) runs the very same code.

pub(crate) use cmux_vt_stream::{ShellMarks, exit_reset, write_output};
