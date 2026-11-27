title: Agent messages survive daemon updates
category: fixed

Waiting sends reconnect after a daemon restart and keep the same prompt ID. Planned machine updates let accepted sends finish before replacing the daemon.
