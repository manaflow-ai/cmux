# A shell loop ringing the bell disconnects the sidebar ("mailbox overflow")

Run `while true; do printf '\a'; sleep 0.001; done` in a cmux terminal: after a moment the sidebar (a slow
subscriber) loses its connection to the daemon, and the daemon log says its mailbox overflowed.

`Mailbox` in `eventbox.py` is one subscriber's bounded queue of daemon events. It coalesces chatty events per surface
(titles, scrolls, output, ...) so a burst of them takes one slot instead of filling the queue, but every bell event
takes a slot of its own. Bells are just as chatty as titles and should not be able to overflow a mailbox either.
