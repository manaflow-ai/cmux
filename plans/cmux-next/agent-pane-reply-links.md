# Agent pane reply links: chips, images, Open in (D4, D5, D6)

Decisions: `.cmux-scratch/pane-protocol/lawrence-delegated-decisions-2026-10-06.md` D4 to D6. Security bar:
the markdown parity audit, section 4.3. Reply text is untrusted; the page draws inert elements and asks the
host for every effect. The page keeps `connect-src 'none'` and `img-src data:`.

## Page (webviews/src/agent-session/acpmux)
- `chips/paths.ts`: a markdown link to an absolute path or `file://` URL, and an inline code span that is an
  absolute path with an extension or a trailing slash, is a path chip. A deny-list path is plain text.
- `chips/LinkChips.tsx`: path chip (file or folder icon, the name in bold with a dotted underline, the full
  path in the tooltip, a lock outside the session's folders) and web chip (favicon from cmux's cache, else a
  globe). `chips/linkStore.ts` batches `link.inspect`.
- `chips/ReplyImage.tsx`: a local image loads at once; a web image follows `agentPane.images.remote`.
- `previewCard/OpenInMenu.tsx`: cmux's browser pane, the host's browsers, Copy link.

## Host ops (`AgentPaneReplyRequest`; fixed param keys, length caps; also `cmux.agent.*` page ops)
| Op | Params | Gesture | Effect |
| --- | --- | --- | --- |
| `link.inspect` | `paths[]`, `urls[]` (64 each) | no | none: place of each path, cached favicon and title, the policy |
| `link.openPath` | `path` | yes | file in the file pages (`file.open` tab), folder in Finder |
| `image.load` | `src` | web image with `click` only | data URL |
| `browser.list` | none | no | opaque ids, names, icons |
| `browser.openIn` | `url`, `browserId` | yes | `NSWorkspace.open(_:withApplicationAt:)`, or cmux's browser tab for `cmux` |

Paths (`AgentPaneReplyPaths`): `~/` and relative paths expand from the session's cwd; the deny list
(`~/.ssh`, `~/.gnupg`, `~/Library/Keychains`, `~/.aws`, `~/.config/gh`, `*.pem`, `*.key`, `.env*`) applies to
the spelling and to the canonical path (symlinks resolved); the roots check uses the canonical path; a path
outside the roots is never checked on disk, so the page cannot probe for files. The gesture is spent only
after both checks pass. `agentPane.links.outsideRoots`: `open` (the default), `confirm` (native sheet), `text`.

Web images (`AgentPaneSafeFetch`, `AgentPaneNetworkRules`): https only; every resolved address must be
public (no loopback, RFC 1918, link-local, CGNAT/Tailscale, ULA, multicast, documentation; embedded IPv4 in
mapped, NAT64 and 6to4 addresses is checked); each redirect is checked again (at most 3); the address each
transaction used (`URLSessionTaskMetrics`) must be known and public, or the body is dropped; ephemeral
session, no cookies, cache, credentials or proxy; 10 MB, 10 s; decoded and re-encoded as PNG (2048 px).
Local images: inside the roots, 10 MB, decoded by ImageIO; SVG rebuilt without script, handlers, foreign
content or links out.

## Known residuals
1. DNS rebinding: URLSession resolves the name again after the check, so one GET can reach a private
   address; its body never reaches the page. Follow-up: connect to the checked address (Network.framework,
   the checked endpoint with SNI and a Host header).
2. A folder swap between the check and a read is possible (read-only display). Any future write path must
   use openat with a directory descriptor.
3. `browserId: "cmux"` opens any validated http(s) URL in a cmux browser tab after a gesture.
