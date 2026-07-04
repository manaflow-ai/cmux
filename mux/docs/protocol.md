# Control socket protocol

As of protocol v5, every server speaks JSON Lines over a Unix domain socket. Send one JSON object per line. Every request receives one response line. `subscribe` and `attach-surface` also cause event lines to be pushed on the same connection.

Default socket path:

```text
$TMPDIR/cmux-mux-<uid>/<session>.sock
```

`identify` reports the protocol version:

```json
{"id":1,"cmd":"identify"}
{"id":1,"ok":true,"data":{"app":"cmux-mux","version":"...","protocol":5,"session":"main","pid":12345}}
```

Responses have this shape:

```json
{"id":1,"ok":true,"data":{}}
{"id":2,"ok":false,"error":"unknown surface 99"}
```

Bad JSON returns `ok:false` with no request id.

## Commands

`identify`

Request:

```json
{"id":1,"cmd":"identify"}
```

Response data: `app`, `version`, `protocol`, `session`, and `pid`.

`list-workspaces`

Request:

```json
{"id":2,"cmd":"list-workspaces"}
```

Response data:

```json
{
  "workspaces": [
    {
      "id": 3,
      "name": "1",
      "active": true,
      "screens": [
        {
          "id": 2,
          "name": null,
          "active": true,
          "active_pane": 1,
          "layout": {"type":"leaf","pane":1},
          "panes": [
            {
              "id": 1,
              "name": null,
              "active_tab": 0,
              "tabs": [
                {
                  "surface": 4,
                  "kind": "pty",
                  "browser_source": null,
                  "name": null,
                  "title": "zsh",
                  "size": {"cols":120,"rows":40},
                  "dead": false
                }
              ]
            }
          ]
        }
      ]
    }
  ]
}
```

Layout nodes are either `{"type":"leaf","pane":<pane-id>}` or `{"type":"split","dir":"right"|"down","ratio":<number>,"a":<node>,"b":<node>}`.

`send`

Writes to a PTY surface. Browser surfaces return an error.

```json
{"id":3,"cmd":"send","surface":4,"text":"ls\r"}
{"id":4,"cmd":"send","surface":4,"bytes":"bHMNCg=="}
```

`text` is UTF-8 text. `bytes` is base64 raw bytes. If both are present, text is written first.

`read-screen`

Returns plain text from a PTY surface's current screen.

```json
{"id":5,"cmd":"read-screen","surface":4}
```

Response data: `{"text":"..."}`.

`vt-state`

Returns a one-shot Ghostty VT replay for a PTY surface.

```json
{"id":6,"cmd":"vt-state","surface":4}
```

Response data: `{"cols":120,"rows":40,"data":"<base64-vt-replay>"}`.

`new-tab`

Creates a PTY tab in a pane. `pane` defaults to the active pane. If the session has no workspaces, this creates a workspace.

```json
{"id":7,"cmd":"new-tab","pane":1,"cwd":"/tmp","cols":120,"rows":40}
```

Response data: `{"surface":<surface-id>}`. `cwd`, `cols`, and `rows` are optional.

`new-browser-tab`

Creates a browser tab in a pane. `pane`, `cols`, and `rows` are optional.

```json
{"id":8,"cmd":"new-browser-tab","url":"example.com","pane":1,"cols":120,"rows":40}
```

Response data: `{"surface":<surface-id>}`.

`new-workspace`

Creates a workspace with one screen, pane, and PTY tab. `name`, `cols`, and `rows` are optional.

```json
{"id":9,"cmd":"new-workspace","name":"agents","cols":120,"rows":40}
```

Response data: `{"surface":<surface-id>}`.

`new-screen`

Creates a screen in a workspace. `workspace` defaults to the active workspace.

```json
{"id":10,"cmd":"new-screen","workspace":3,"cols":120,"rows":40}
```

Response data: `{"surface":<surface-id>}`.

`split`

Splits a pane and creates a PTY surface in the new pane.

```json
{"id":11,"cmd":"split","pane":1,"dir":"right","cols":60,"rows":40}
{"id":12,"cmd":"split","pane":1,"dir":"down"}
```

`dir` must be `"right"` or `"down"`. Response data: `{"surface":<surface-id>}`.

`set-ratio`

Sets the deepest split ratio in the requested direction on the path to `pane`. Ratio is clamped to 0.05 through 0.95.

```json
{"id":13,"cmd":"set-ratio","pane":1,"dir":"right","ratio":0.6}
```

`set-default-colors`

Sets host default colors used by libghostty-vt replies to OSC color queries. `fg` and `bg` are optional `#rrggbb` strings.

```json
{"id":14,"cmd":"set-default-colors","fg":"#ffffff","bg":"#000000"}
```

`close-surface`, `close-pane`, `close-screen`, `close-workspace`

```json
{"id":15,"cmd":"close-surface","surface":4}
{"id":16,"cmd":"close-pane","pane":1}
{"id":17,"cmd":"close-screen","screen":2}
{"id":18,"cmd":"close-workspace","workspace":3}
```

Closing a surface may collapse its pane, screen, and workspace if each becomes empty.

`rename-surface`, `rename-pane`, `rename-screen`, `rename-workspace`

```json
{"id":19,"cmd":"rename-surface","surface":4,"name":"editor"}
{"id":20,"cmd":"rename-pane","pane":1,"name":"server"}
{"id":21,"cmd":"rename-screen","screen":2,"name":"build"}
{"id":22,"cmd":"rename-workspace","workspace":3,"name":"agents"}
```

Empty surface, pane, and screen names clear back to generated labels. Workspace rename accepts the provided string.

`resize-surface`

Resizes a surface to at least 1 by 1 cells. If the size changes, subscribers receive `surface-resized` with the final size. Same-size resizes do not emit that event.

```json
{"id":23,"cmd":"resize-surface","surface":4,"cols":120,"rows":40}
```

`focus-pane`

Focuses a pane and makes its screen and workspace active.

```json
{"id":24,"cmd":"focus-pane","pane":1}
```

`select-tab`

Selects a tab within a pane. `pane` defaults to the active pane. Use either `index` or `delta`.

```json
{"id":25,"cmd":"select-tab","pane":1,"index":0}
{"id":26,"cmd":"select-tab","delta":1}
```

`select-screen`

Selects a screen in the active workspace by `index` or relative `delta`.

```json
{"id":27,"cmd":"select-screen","index":0}
{"id":28,"cmd":"select-screen","delta":1}
```

`select-workspace`

Selects a workspace by `index` or relative `delta`.

```json
{"id":29,"cmd":"select-workspace","index":0}
{"id":30,"cmd":"select-workspace","delta":1}
```

`scroll-surface`

Scrolls a PTY surface viewport by row delta. Browser surfaces return an error.

```json
{"id":31,"cmd":"scroll-surface","surface":4,"delta":-10}
```

`subscribe`

Starts event streaming on the connection.

```json
{"id":32,"cmd":"subscribe"}
```

Response data is `{}`. Future event lines may interleave with responses.

`attach-surface`

Streams a PTY surface. Browser surfaces return `browser panes are not supported over attach yet`.

```json
{"id":33,"cmd":"attach-surface","surface":4}
```

The server first sends:

```json
{"event":"vt-state","surface":4,"cols":120,"rows":40,"data":"<base64-vt-replay>"}
```

Then it sends output events:

```json
{"event":"output","surface":4,"data":"<base64-pty-bytes>"}
```

When the stream ends, it sends:

```json
{"event":"detached","surface":4}
```

## Events

`subscribe` can push:

```json
{"event":"surface-output","surface":4}
{"event":"surface-resized","surface":4,"cols":120,"rows":40}
{"event":"surface-exited","surface":4}
{"event":"title-changed","surface":4}
{"event":"bell","surface":4}
{"event":"tree-changed"}
{"event":"empty"}
```

`surface-resized` reports the final clamped cell size and is emitted only when the surface size actually changes.

## Attach sizing

Attach clients mirror PTY surfaces locally. On first render, the client can resize the server surface before requesting `attach-surface`, so the VT replay is captured at the visible geometry.

When several attach clients render the same surface at different sizes, sizing follows latest local interaction. A client reasserts its visible sizes after key input, mouse input, paste, focus gained, or terminal resize. Mux-driven redraws update local mirrors from `surface-resized` without reasserting an idle client's viewport.

## Browser limitations

Browser surfaces appear in `list-workspaces` as `kind: "browser"` with `browser_source: "external"` or `"launched"`. PTY/VT commands against browser surfaces return errors. `attach-surface` does not stream browser pixels as of protocol v5, and the remote TUI shows a placeholder for browser panes.
