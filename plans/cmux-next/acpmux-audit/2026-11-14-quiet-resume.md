# Recovered machine gaps stay out of chat history

For PL-acpmux: issue #42812 reports twelve pause notices during one running turn. The recovery request calls for quiet automatic recovery. `Hub::machine_resumed` keeps resetting stall/silent protection, logging the gap, publishing its resume count, and waking activity renewal, but no longer appends a `host_notice` chat record for a recovered gap. This applies to every client through Rust; no webview changes.

Detector: `stalled_turn::twelve_recovered_gaps_add_no_chat_records_and_keep_stall_protection` injects twelve nine-minute pauses/stops, expects zero notices and twelve subscriber updates, and verifies that a true stall still ends the turn after a fresh full period. Existing idle-watch behavior from #35416 is retained. The gap label is clock inference, not evidence that a Cloud policy paused a running turn; the cause investigation needs matching machine and activity logs.
