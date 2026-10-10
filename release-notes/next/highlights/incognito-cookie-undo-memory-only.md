title: An agent's incognito cookies never reach the disk
category: security

When an agent cleared cookies in an incognito browser store, cmux saved the removed cookies in an encrypted backup file on disk, and a backup that held a session cookie stayed there with no end date. Now an incognito store keeps this undo in memory only. The agent can still undo a clear while the store is open. When the store closes, the undo goes with it.
