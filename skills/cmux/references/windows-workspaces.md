# Windows and Workspaces

```bash
# inspect
cmux window list
cmux workspace list --json
cmux workspace current show --json

# lifecycle
cmux app new-window                       # app action
cmux workspace create --name api
cmux workspace ws_… focus
cmux workspace ws_… rename --name infra
cmux workspace ws_… close

# order and move
cmux workspace ws_… move --index 0
cmux workspace move-to-window --target ws_… --window <window-id>   # app action
```

Windows exist only in the app; their ids are the lowercase UUIDs `cmux window list` prints.

## Context-menu actions

Workspace right-click actions are app actions. List them with `cmux action list --noun workspace` and check arguments with `cmux action describe "workspace set-color"`.

```bash
cmux workspace set-color --target ws_… --color blue
cmux workspace edit-description --target ws_… --description "Ship checklist"
cmux workspace pin-unpin --target ws_…
cmux workspace clear-name --target ws_…
cmux workspace set-status --target ws_… --status inProgress
```

Colors: grey, blue, red, yellow, green, pink, purple, cyan, orange. Other actions include `mark-as-read`, `mark-as-unread`, `move-up`, `move-down`, `move-to-top`, `close-other`, `close-above` and `close-below`.

## Groups

```bash
cmux workspace group list
cmux workspace group create --name backend --color blue
cmux workspace group backend add --workspace ws_…
cmux workspace group remove --workspace ws_…
cmux workspace placement list --json      # personal sidebar order
```

Groups and rooms take their id or exact name. Both are personal: they live in this Mac's home session.

## Rooms

```bash
cmux room list --json
cmux room create --name Work --color blue
cmux room Work pin --workspace ws_…
cmux room unpin --workspace ws_…
cmux room Work follow --sessions s1,s2      # the complete follow set
cmux room Work update --icon briefcase --clear-color
cmux room Work move --index 0
cmux room Work delete --move-to Home
```

## Workspace metadata and closed history

```bash
cmux workspace ws_… update --title "API" --color "#336699" --icon server.rack
cmux closed list
cmux closed <closed_id> reopen
```
