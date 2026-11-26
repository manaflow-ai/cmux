# app-compile-placement: id: route-token-bot

Where: the `app-compile-placement` job in `.github/workflows/cmux-next.yml`, above `id: route-token-bot`.

Every run reads on cmux-bot's installation budget, so per-PR reads
stop draining the build controller's routing App (5067688 read 0 remaining at 02:17Z and
10:32Z on 2026-11-25 with the controller itself at 234 calls/h; an
even/odd run-id split only cut it to ~9.5k/h on 2026-11-26).
