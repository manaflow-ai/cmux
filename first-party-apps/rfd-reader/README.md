# RFDs: a reader for design documents

Design questions live as RFDs: Markdown files in a repository's `docs/rfd/NNNN-slug.md`, with front
matter (`state`, `authors`, `links`), discussed in a pull request. This extension reads them in a
cmux pane, built only on the public extension SDK (`cmux-extension-sdk/web`): a web pane, the
GitHub gateway and app storage. It is the proof that an internal tool can be a cmux extension.

- **The list**, newest change first, with state filters (prediscussion, ideation, discussion,
  published, committed, abandoned) and a title or number filter. An RFD on an open pull request
  shows that pull request's text and date.
- **Full-text search** (Cmd-K) over every RFD's text, with an excerpt per hit and a preview of the
  highlighted one; arrows move, Return opens.
- **Review comments beside their lines.** The pull request's line comments are read after the
  document is on screen and placed next to the block holding their line. Outdated comments (their
  line changed) are left out; replies join their thread. Reply opens the thread on GitHub.
- **Hover previews** of other RFDs: a link to `NNNN-slug.md` or `RFD N` in the text shows the
  RFD's title, state, authors and date; a click opens it here.
- **Jump to** (Cmd-/): an RFD by number or title, from anywhere in the pane.
- **New RFD** without a clone: fill in the title, state, authors and text; the next number is
  taken, and GitHub's new-file page opens with the file filled in. Committing it there on a new
  branch opens the pull request.

## Designs

Three, switched by the A, B, C chips in the bar (kept per person):

| | Design | Comments |
|---|---|---|
| A | **Directory**: the list beside the document | in the right margin, open |
| B | **Index**: a full-width table first, then the document alone | a marker beside the line that opens a card |
| C | **Focus**: the document alone, Cmd-/ to move | under their paragraph |

## Reads and the GitHub quota

Every read is a GET through `integration.request {provider: "github"}`: cmux's gateway runs `gh api`
as the person's own sign-in (where `gh` is a brokered shim, through that cache) and keeps each
answer's ETag, so a re-read that changed nothing is a free 304. Reads happen when the pane opens
and on Refresh; nothing polls. A refresh costs three reads (the folder, open pull requests, the
files of each RFD pull request); an RFD's text is read once per blob sha and kept in app storage,
and so is a file's last commit date. The list kept from the last read shows at once and stays when
GitHub refuses (a spent quota shows as a status line, not an empty pane).

The gateway's read paths for files (`contents`, `git/blobs`, `commits`, `pulls/N/files`,
`pulls/N/comments`) come with the gateway change that adds them; on a cmux without it the pane says
so.

## Scopes

| Scope | Why |
|---|---|
| `integration:github:read` | the RFD files, pull requests and review comments, through the person's own sign-in |
| `storage:local` | the kept list, texts by sha, the chosen design and the last RFD read |
| `workspace:write` | opening a pull request, a comment or a link in a browser tab |

## Develop

```sh
cd first-party-apps/rfd-reader
bun install                     # marked, pinned
bun build-web.ts                # web/ (shipped) and preview/dist/ (fixtures, not shipped)
bun test test                   # the model and the source, on fixtures
cmux ext dev .                  # load it into the running cmux; open "RFDs" from the palette
```

`preview/dist/index.html?variant=index&rfd=2` is the same page on made-up RFDs
(`preview/fixtures.ts`), with no cmux. `cd webviews && bun ../first-party-apps/rfd-reader/preview/shoot.ts OUT`
writes every design and state, light and dark, and a `gallery.html` of them.

## Gaps

- No write path: the gateway is read-only, so a new RFD opens GitHub's new-file page instead of
  committing from the pane.
- Comments map to a rendered block by line, so a comment on a line inside a long table or list
  shows beside the whole block.
- The id is `local/rfd-reader` so `cmux ext dev` installs it; it moves to `cmux/rfd-reader` when
  first-party apps load from the app bundle.
