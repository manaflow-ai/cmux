title: Restart to Update works after a background download
category: fixed
action: palette.checkForUpdates | Check for Updates

When cmux had downloaded an update in the background, Restart to Update did nothing. It now installs the update and reopens cmux, or says why it can't.
