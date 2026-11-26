title: SSH reconnects recover connection sharing
category: fixed
docs: https://cmux.com/docs/next/cli

SSH reconnects retry connection sharing after a temporary failure. A password prompt for one host leaves other hosts free to connect, and reconnect deadlines allow only the time actually spent authenticating.
