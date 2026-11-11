title: A large saved session file gets small and stays small
category: fixed
docs: https://cmux.com/docs/session-restore

cmux rebuilds a large session file one time and then deletes old records as it runs. The old file stays at full size as workspace-registry.sqlite3.kept-before-cleanup for 7 days and 3 starts: quit cmux and rename it back to return.
