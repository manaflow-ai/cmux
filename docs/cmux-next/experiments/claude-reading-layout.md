# Claude reading layout experiment

The first slice of the example reading look is its chat layout: a 720-point column,
system text at 15 points, and 1.5 line height. The experiment is **off by default**.
It leaves the sidebar, palette, composer controls and saved preferences alone.

In the gallery, open **Experimental → Claude reading layout → Compare arms**
(`agent-pane.claude-reading-layout`). Compare the current settings, the reading
layout, and type only. The standard, custom and full-width fixtures use the real
chat renderer, including its prompt, tool output, reply, code block and link.

For a disposable app's chat, the existing experiment override is:

```js
localStorage.setItem("cmux.experiments", JSON.stringify({
  ...JSON.parse(localStorage.getItem("cmux.experiments") || "{}"),
  "claude-reading-layout": "reading"
}));
```

Reload that pane to apply it. Choose `"type"` to keep the saved column, or `"off"`
and reload to restore all saved display values. It writes no chat settings.

The layout uses the same public settings as a setup profile:

```json
{
  "agentPane.display.font.preset": "system",
  "agentPane.display.font.size": 15,
  "agentPane.display.font.lineHeight": 1.5,
  "agentPane.display.width": 720,
  "agentPane.display.fullWidth": false
}
```

The existing resolver supplies both the CSS and the virtual transcript's row
measurements. At unit scale, the default column/type is 800/14; the reading arm
is 720/15 with 22.5-point lines. Width still fits the pane, and text follows the
existing density and zoom controls. No public token or new setting is introduced.

Design: `manaflow-ai/cmuxterm-hq/docs/rfd/0008-customization-sdk-parity/looks/claude-look/README.md`
and its `cmux-setup.json`. The remaining palette, sidebar and SDK gaps retain
their owners in RFD 0008.
