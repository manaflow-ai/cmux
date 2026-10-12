title: One agent's browser session no longer stops another session's page
category: fixed

When several agent sessions shared the headless browser, one session's address rule could stop a page that another session was loading. For example, a remote session could stop a local session's page that loaded through its own proxy, and the open failed with ERR_ABORTED. Each session's rule now stops only the tabs that session drives. A new tab belongs to the session that opened it before its first request.
