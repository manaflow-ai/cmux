/// Concatenate string literals while prepending a ANSI control sequence introducer (`"\x1b["`)
#[macro_export]
#[doc(hidden)]
macro_rules! csi {
    ($( $l:expr ),*) => { concat!("\x1B[", $( $l ),*) };
}

/// Concatenate string literals while prepending a xterm Operating System Commands (OSC)
/// introducer (`"\x1b]"`) and appending a BEL (`"\x07"`).
#[macro_export]
#[doc(hidden)]
macro_rules! osc {
    ($( $l:expr ),*) => { concat!("\x1B]", $( $l ),*, "\x1B\\") };
}

/// Queues one or more command(s) for further execution.
///
/// Queued commands must be flushed to the underlying device to be executed.
/// This generally happens in the following cases:
///
/// * When `flush` is called manually on the given type implementing `io::Write`.
/// * The terminal will `flush` automatically if the buffer is full.
/// * Each line is flushed in case of `stdout`, because it is line buffered.
///
/// # Arguments
///
/// - [std::io::Writer](std::io::Write)
///
///     ANSI escape codes are written on the given 'writer', after which they are flushed.
///
/// - [Command](./trait.Command.html)
///
///     One or more commands
///
/// # Examples
///
/// ```rust
/// use std::io::{Write, stdout};
/// use crossterm::{queue, style::Print};
///
/// let mut stdout = stdout();
///
/// // `Print` will executed executed when `flush` is called.
/// queue!(stdout, Print("foo".to_string()));
///
/// // some other code (no execution happening here) ...
///
/// // when calling `flush` on `stdout`, all commands will be written to the stdout and therefore executed.
/// stdout.flush();
///
/// // ==== Output ====
/// // foo
/// ```
///
/// Have a look over at the [Command API](./index.html#command-api) for more details.
///
/// # Notes
///
/// In case of Windows versions lower than 10, a direct WinAPI call will be made.
/// The reason for this is that Windows versions lower than 10 do not support ANSI codes,
/// and can therefore not be written to the given `writer`.
/// Therefore, there is no difference between [execute](macro.execute.html)
/// and [queue](macro.queue.html) for those old Windows versions.
///
#[macro_export]
macro_rules! queue {
    ($writer:expr $(, $command:expr)* $(,)?) => {{
        use ::std::io::Write;

        // This allows the macro to take both mut impl Write and &mut impl Write.
        Ok($writer.by_ref())
            $(.and_then(|writer| $crate::QueueableCommand::queue(writer, $command)))*
            .map(|_| ())
    }}
}

/// Executes one or more command(s).
///
/// # Arguments
///
/// - [std::io::Writer](std::io::Write)
///
///   ANSI escape codes are written on the given 'writer', after which they are flushed.
///
/// - [Command](./trait.Command.html)
///
///   One or more commands
///
/// # Examples
///
/// ```rust
/// use std::io::{Write, stdout};
/// use crossterm::{execute, style::Print};
///
/// // will be executed directly
/// execute!(stdout(), Print("sum:\n".to_string()));
///
/// // will be executed directly
/// execute!(stdout(), Print("1 + 1 = ".to_string()), Print((1+1).to_string()));
///
/// // ==== Output ====
/// // sum:
/// // 1 + 1 = 2
/// ```
///
/// Have a look over at the [Command API](./index.html#command-api) for more details.
///
/// # Notes
///
/// * In the case of UNIX and Windows 10, ANSI codes are written to the given 'writer'.
/// * In case of Windows versions lower than 10, a direct WinAPI call will be made.
///   The reason for this is that Windows versions lower than 10 do not support ANSI codes,
///   and can therefore not be written to the given `writer`.
///   Therefore, there is no difference between [execute](macro.execute.html)
///   and [queue](macro.queue.html) for those old Windows versions.
#[macro_export]
macro_rules! execute {
    ($writer:expr $(, $command:expr)* $(,)? ) => {{
        use ::std::io::Write;

        // Queue each command, then flush
        $crate::queue!($writer $(, $command)*)
            .and_then(|()| {
                ::std::io::Write::flush($writer.by_ref())
            })
    }}
}

#[doc(hidden)]
#[macro_export]
macro_rules! impl_display {
    (for $($t:ty),+) => {
        $(impl ::std::fmt::Display for $t {
            fn fmt(&self, f: &mut ::std::fmt::Formatter<'_>) -> ::std::fmt::Result {
                $crate::command::execute_fmt(f, self)
            }
        })*
    }
}

#[doc(hidden)]
#[macro_export]
macro_rules! impl_from {
    ($from:path, $to:expr) => {
        impl From<$from> for ErrorKind {
            fn from(e: $from) -> Self {
                $to(e)
            }
        }
    };
}

#[cfg(test)]
#[path = "macros_tests.rs"]
mod tests;
