# Usage meter: what your agents spend, live

`local/leo-usage` imports nothing but `cmux-extension-sdk`. Per provider (Claude, Codex, ...) it
shows the 5-hour and weekly limits as rings that spring to each new value, a token and dollar
counter for the last 24 hours that ticks up, a pace badge that pulses near a limit, and reset
countdowns, in a sidebar section and a pane.

```sh
cmux ext dev examples/extensions/leo-usage
```

- Data: `cmux.watch("usage.meter")` (scope `chat:read`), pushed when a chat changes. Set `source`
  to `demo` (Settings > Apps > Usage meter) to preview it with invented accounts.
- Design: the `variant` setting picks `rings`, `bars` or `neon`. Edit `src/main.ts`; the model
  (pace, countdowns, demo data) is `src/meter.ts`.
