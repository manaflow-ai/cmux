//! The parser queue's memory (HOST-MEM cut 3). The bounded channel
//! (`sync_channel(HOST_PARSER_QUEUE_CAPACITY)`) allocates every slot, a
//! command and its stamp, when the host starts, and writes each stamp, so all
//! of it is dirty in every host for the host's life. A rare command with a
//! large payload must not set the size of all the slots.

use super::*;

/// The most the queue may hold dirty from the start: one 16 KiB page.
const PARSER_QUEUE_BYTES: usize = 16 * 1024;

#[test]
fn the_parser_queue_takes_at_most_one_page() {
    // A slot of std's bounded channel is the message and a usize stamp.
    let slot = size_of::<ParserCommand>() + size_of::<usize>();
    let queue = HOST_PARSER_QUEUE_CAPACITY * slot;
    assert!(
        queue <= PARSER_QUEUE_BYTES,
        "the parser queue holds {queue} bytes from the start ({HOST_PARSER_QUEUE_CAPACITY} slots of \
         {slot} bytes), more than {PARSER_QUEUE_BYTES}"
    );
}
