title: A remote browser tab says why it is not connected
category: fixed
action: remote.openBrowserTab | Try it

A remote browser tab whose host refuses it, or that finds no host, no longer stays blank. The tab shows "Not Connected" and says why in the page area. Open Remote Browser Tab now takes the host's secret file: a private file (chmod 600) with the host's secret on its first line. The tab keeps the file's path, never the secret.
