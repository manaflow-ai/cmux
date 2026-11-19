# RFDs: a reader for design documents and reading notes

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

## Reading notes

The same repository's `docs/reading/YYYY-MM-DD-slug.md`: one note per article, talk, thread or repo
we read, with what it says, what we already do, what we take from it as of the read date and what
we did. Front matter: `state` (read, acting, adopted, rejected, stale), `source`, `source_author`,
`published`, `read`, `read_by`, `shared_by`, `ask`, `access`, `tags`, `links`. They are the
**Reading** tab in the bar, beside **RFDs** (the tab is kept per person); `README.md` (the index)
and `_template.md` are not listed.

- **The list**, newest `read` date first, with state filters and tag filters (tags narrow
  together), and a title, date or tag filter. A note on an open pull request shows that pull
  request's text.
- **The header**: Open the source (in a browser tab), who wrote and published it, when and by whom
  it was read, who shared it and their words, its tags (a click filters the list) and its links.
- **Search** (Cmd-K) and **Jump to** (Cmd-/) cover RFDs and notes together.
- **Review comments** beside their lines, from the note's open pull request, else the pull request
  that last changed it (the `(#N)` of its newest commit's subject, kept by blob sha).
- **Hover previews** both ways: a note's link to an RFD (`../rfd/NNNN-slug.md`, `RFD N`) previews
  the RFD, and an RFD's link to a note (`../reading/YYYY-MM-DD-slug.md`) previews the note.
- **New reading note**: the form fills in `_template.md`'s front matter and four sections, and
  GitHub's new-file page opens with the note; committing it on a new branch opens the pull
  request. The gateway only reads, so its row in the index (`README.md`) is the second commit on
  that branch: the form shows the row, and until the pull request changes `README.md` the note's
  header offers **Add its index row** (the row to copy, and `README.md` opened on the branch).

Where the notes sit was chosen from three placements in the preview gallery (`?notes=`): **tabs**
(shipped: one list at a time, the open tab named in the bar), **sections** (one list, RFDs then
notes) and **mixed** (one list by date with a kind label). Tabs keeps each kind's filters
meaningful (RFD states and note states and tags never mix) and leaves every RFD view as it was.

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
and on Refresh; nothing polls. A refresh costs three reads for RFDs (the folder, open pull
requests, the files of each RFD pull request) and three for reading notes, read side by side (the
folder, open pull requests, the files of each note pull request); a text is read once per blob sha
and kept in app storage, and so is a file's last commit date (RFDs) or the pull request that last
changed it (notes, read when the note opens). The list kept from the last read shows at once and stays when
GitHub refuses (a spent quota shows as a status line, not an empty pane).

The gateway's read paths for files (`contents`, `git/blobs`, `commits`, `pulls/N/files`,
`pulls/N/comments`) come with the gateway change that adds them; on a cmux without it the pane says
so.

## Scopes

| Scope | Why |
|---|---|
| `integration:github:read` | the RFD and reading note files, pull requests and review comments, through the person's own sign-in |
| `storage:local` | the kept lists, texts by sha, the chosen design and tab, and the last RFD and note read |
| `workspace:write` | opening a pull request, a comment or a link in a browser tab |

## Develop

```sh
cd first-party-apps/rfd-reader
bun install                     # marked, pinned
bun build-web.ts                # web/ (shipped) and preview/dist/ (fixtures, not shipped)
bun test test                   # the model and the source, on fixtures
cmux ext dev .                  # load it into the running cmux; open "RFDs" from the palette
```

`preview/dist/index.html?variant=index&rfd=2` (or `&note=2026-11-18-lazy-checkouts`) is the same
page on made-up RFDs and notes (`preview/fixtures.ts`), with no cmux; `&notes=sections|mixed`
shows the placements tabs was chosen over. `bun preview/real.ts HQ_CHECKOUT preview/dist/real.json`
then `?real=1` shows a checkout's real `docs/rfd` and `docs/reading` instead (keep that file out
of commits: it is that repository's text). `cd webviews && bun ../first-party-apps/rfd-reader/preview/shoot.ts OUT`
writes every design and state, light and dark, and a `gallery.html` of them.

## Gaps

- No write path: the gateway is read-only, so a new RFD or reading note opens GitHub's new-file
  page, and a note's index row is a second commit on its branch, instead of
  committing from the pane.
- Comments map to a rendered block by line, so a comment on a line inside a long table or list
  shows beside the whole block.
- The id is `local/rfd-reader` so `cmux ext dev` installs it; it moves to `cmux/rfd-reader` when
  first-party apps load from the app bundle.
