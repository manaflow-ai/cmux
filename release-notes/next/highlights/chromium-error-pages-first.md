title: Chromium tabs show Chrome's own error pages at once
category: fixed

A Chromium tab that cannot open a page now shows Chrome's own page directly: "Your connection is not private" for a certificate problem (with Advanced and Proceed), "This site can't be reached" for a name that does not resolve, a refused or reset connection or a timeout, and Chrome's pages for too many redirects and blocked sites. Before, cmux's "Can't open this page" view showed first for a moment.
