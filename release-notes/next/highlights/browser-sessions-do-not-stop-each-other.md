title: One agent's browser session no longer stops another's
category: fixed
docs: https://cmux.com/docs/browser-automation

When several agent sessions share the headless browser, one session's address rules now apply only to the tabs it drives. Pages another session loads no longer fail with ERR_ABORTED.
