title: A remote browser tab says why it is not connected
category: fixed
action: remote.openBrowserTab | Try it

In development builds, a remote browser tab that finds no host, or whose host refuses it, shows “Not Connected” and the reason instead of a blank page. It never stores the host's secret.
