# A shell loop ringing the bell disconnects the sidebar ("mailbox overflow")

Run `while true; do printf '\a'; sleep 0.001; done` in a cmux terminal: after a moment the sidebar (a slow
subscriber) loses its connection to the daemon, and the daemon log says its mailbox overflowed. `Mailbox` in
`eventbox.py` is one subscriber's bounded queue of daemon events. Ringing the bell, however fast, should not be able to
disconnect anyone.
