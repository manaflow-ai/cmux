title: Going back to a cmux build from before November 9
category: fixed
docs: https://cmux.com/docs/session-restore

A build from before November 9, 2026 does not read the smaller session file in full, so its agent list can be empty. The kept file workspace-registry.sqlite3.kept-before-cleanup is the way back for 7 days.
