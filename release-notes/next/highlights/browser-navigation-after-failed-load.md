title: Agent navigation after a failed load waits for its own page
category: fixed
docs: https://cmux.com/docs/browser-automation

When an agent opens a page right after one that failed to load, it now waits for the page it asked for. The next script no longer fails with “has no document” on the old error page.
