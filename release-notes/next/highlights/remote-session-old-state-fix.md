title: SSH hosts with an older cmux session connect again
category: fixed

On some SSH hosts, the remote session failed to start with the error "table session_journal has no column named actor". This happened when the host kept a saved session from an older cmux build. cmux now upgrades the saved session in place and keeps its history. When you set a state directory for an SSH host, the remote session now keeps its state in that directory.
