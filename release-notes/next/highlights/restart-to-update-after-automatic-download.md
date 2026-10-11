title: Restart to Update works when macOS downloaded the update on its own
category: fixed

When cmux had downloaded an update in the background with automatic updates turned on, clicking Restart to Update did nothing. The click now installs that update and reopens cmux. If an update can't start, cmux now says so instead of leaving the button without effect.
