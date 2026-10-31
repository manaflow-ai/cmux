# Cloud Codex access-token handoff

The `codex-external-access-v1` acpmux capability identifies the app-server bridge for an explicitly authorized owner VM. The user's machine runs one Codex-managed auth holder. Only a short-lived access token is delivered to the VM; `auth.json`, ID tokens and refresh tokens are never transferred.

The native owner writes this JSON atomically to `/home/cmux/.config/cmux/codex-broker/access.json`, owned by the work user and with mode `0600`:

```json
{"schema":1,"bridge":"codex-external-access-v1","accessToken":"<short-lived bearer>","chatgptAccountId":"<authorized account>","expiresAt":1893456000}
```

`expiresAt` is an integer Unix timestamp. The bridge rejects a private-file or ownership failure, an unsupported version, and tokens with less than one minute remaining. An absent file preserves the existing login path. An invalid installed file fails closed instead of silently using another credential.

After app-server initialization, the bridge sends `account/login/start` with `chatgptAuthTokens` and waits for success before releasing agent startup. Replacement tokens stay pinned to that account. Credential fields are redacted from raw protocol taps before journaling.

The native owner renews grants before expiry. On an app-server `account/chatgptAuthTokens/refresh` request, the bridge correlates its response with the original request ID and reads the newest validated access file. A missing, expired or mismatched grant returns an error. The file bridge does not itself contact the local holder; renewal therefore requires the native owner to stay connected. A rejected token cannot be repaired by returning the same grant. Demand-driven renewal and wizard activation require their own integration and acceptance evidence.

The [managed-auth operational rules](https://learn.chatgpt.com/docs/auth/ci-cd-auth) apply to the single holder: serialize use of its auth cache, retain Codex's refreshed state, and keep the cache out of logs and artifacts. VM consumers use the [external-token app-server contract](https://learn.chatgpt.com/docs/app-server#auth-endpoints).
