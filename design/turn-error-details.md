# Turn error Details placement

The rate-limit card keeps its Details disclosure in a reserved full-width action row beneath the
recovery buttons. Opening the disclosure grows the raw error below that summary; it never changes
the summary's row, x position, or y position. The slot is present while closed, so the disclosure
does not jump inline beside the buttons.

The browser detector is `webviews/test/turn-error-details-placement.browser.test.ts`. It checks
wide and narrow rate-limit cards, including a long raw error, before and after opening Details.
