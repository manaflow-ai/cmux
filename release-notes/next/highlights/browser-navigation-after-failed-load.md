title: Agent navigation after a failed load waits for its own page
category: fixed

When an agent opened a page that failed to load and then opened another page, the second navigation could finish early on the first page's error page, so the next script read failed with "has no document". The agent now waits for the page it asked for, and a script that runs during a page change keeps the new page's context.
