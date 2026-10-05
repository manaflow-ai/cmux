//! OSC 52 clipboard reads, daemon broker (layer 3 of decision
//! CLIPBOARD-READ-BROKER; deny by default, the user grants each read).

#[cfg(all(test, unix))]
#[path = "clipboard_read_tests.rs"]
mod tests;
