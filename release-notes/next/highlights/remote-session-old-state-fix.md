title: SSH hosts with an older cmux session connect again
category: fixed
docs: https://cmux.com/docs/ssh

SSH hosts that kept a session from an older cmux no longer fail with “table session_journal has no column named actor”. cmux upgrades the saved session in place and keeps its history.
