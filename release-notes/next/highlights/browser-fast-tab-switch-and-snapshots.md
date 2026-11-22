title: Faster browser tab switches and agent snapshots on large pages
category: improved

Switching between browser tabs in a pane no longer rebuilds the tab's toolbar and page window: the tab you leave stays in place, hidden, and shows again at once. Switching to the tab that already shows answers at once instead of waiting for a saved window record. Agent snapshots of large pages skip a full document walk when the page has no closed shadow roots, so a snapshot of a page with 100,000 elements is about a third faster.
