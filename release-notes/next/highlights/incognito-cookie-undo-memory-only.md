title: An agent's incognito cookies never reach the disk
category: security
docs: https://cmux.com/docs/browser-automation

When an agent clears cookies in an incognito browser, the copy kept for undo now stays in memory and is never written to disk. The agent can undo while incognito is open; closing it discards the copy.
