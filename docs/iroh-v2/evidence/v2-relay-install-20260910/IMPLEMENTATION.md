# Native relay credential installation

The endpoint owns one serialized installer. Receiving a new credential replaces the pending set; an install already in progress finishes before the newest pending credential runs. A failed native installation retries after 1, 2, 4, 8, 16 and then 30 seconds. A newer credential interrupts a sleeping retry immediately. Retries stop when the credential is unusable or the endpoint is closed. They do not mint another credential, remove a working relay, replace the endpoint or create a server heartbeat.

Endpoint shutdown clears its published state before asynchronous teardown. Each bind has its own identifier, so an old completion cannot erase a newer bind task. Permanent deactivation rejects subsequent binds. A failed or cancelled relay-readiness attempt also stops its installer. Native installation outcomes have separate events; the iOS credential-receipt event does not claim that installation finished.

Five installer tests exercise failure retry, serialization, superseding a pending token, interruption of backoff, shutdown, expiry and already-installed credentials. Two real endpoint tests cover reusable close versus permanent deactivation and shutdown after UDP binding while relay readiness is pending. The broader shared suite passes 48 tests in nine suites, and the actual iOS app compiles. Logs and matching source hashes are adjacent.

The installer tests control the native insertion boundary. They do not prove that the real relay accepts a replacement before retiring its old transport; that remains part of deployed rollover acceptance. The real endpoint tests use local sockets and an unavailable loopback relay, with no production traffic.
