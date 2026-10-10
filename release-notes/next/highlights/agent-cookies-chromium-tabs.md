title: Agents can read, set and clear cookies in Chromium tabs
category: fixed

An agent that read, set or cleared cookies in a Chromium tab got an error. These calls now work in Chromium tabs the same way they work in WebKit tabs. A clear removes only the tab's site, and cmux keeps a backup so the agent can undo the clear in that same tab.
