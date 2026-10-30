title: Terminals show their last screen the moment cmux opens
category: fixed
docs: https://cmux.com/docs/session-restore

After you quit and reopen cmux, each terminal on screen shows the screen it had when you quit, from
the first frame, until it reconnects. Before, the pane stayed empty while it attached.
