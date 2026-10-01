# @mux/local

The local form of mux (GPL): a server on this Mac with no sign-in. Each
conversation's mux is an acpmux agent session; chats live in SQLite and memory
in a git repo under `~/.cmux/mux/`. cmux next's Home loads it by default.

```bash
vp run @mux/local#start      # from mux/: http://127.0.0.1:47820 (builds nothing; run `vp run -r build` first)
```

Environment: `MUX_LOCAL_PORT` (47820), `MUX_LOCAL_DIR` (~/.cmux/mux),
`MUX_LOCAL_HARNESS` (claude), `MUX_LOCAL_POLICY` (approve-all), `MUX_WEB_DIST`
(../apps/web/dist).
