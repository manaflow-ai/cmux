# Transcript oddities: the read-back in a running app

The fixes in `design/transcript-oddities.md` were proven in tests and headless Chromium. This page is
the run that proves them in the app: one session on a Mac with a signed-in desktop (air-blue), in a
copy of cmux NIGHTLY, never in the NIGHTLY a person is using. Each step has the assertion that makes
it pass or fail. Write the result under [Results](#results) with a screenshot or a short video per
step.

Leo, 2026-11-21: "there are various oddities in our transcription display that we absolutely must
round up and scrutinize."

## Before you start

1. The nightly must hold every fix. In a cmux checkout at `origin/feat-cmux-next`, each of these
   must be an ancestor of the commit the nightly was built from
   (`git merge-base --is-ancestor SHA NIGHTLY_SHA`):

   | Fix | Commit |
   |---|---|
   | T1, cmux#48601 | `c534ebb6854c` |
   | T2 and T3, cmux#48609 | `5e676c5ecdf0` |
   | T4, cmux#48597 and cmux#48701 | `2f17202e0cd6`, `af4bc681457a` |
   | T5, cmux#48689 | `0ffdb431156d` |
   | T7 and T8, cmux#48711 | `e0c141734dde` |
   | Follow-ups, cmux#48904 | its merge commit |

   If the nightly is older, put the web code in over it: `cmux app try feat-cmux-next` (every fix
   here is web code, so no build is needed).
2. Start the copy: `cmux app try .` in that checkout. It prints the copy's socket; drive the copy
   with `cmux --app-socket SOCKET ...` and computer use. When done: `cmux app try . --stop`.
3. Open one Claude chat in the copy, in a scratch directory. Every step below uses that chat unless
   it says otherwise. Record the screen at 60 frames a second for R3, R4 and R6.

## Steps

### R1. A reply in a background finish's turn draws (T1)

1. Send: `Run "sleep 20; echo done" in the background, then stop and wait.`
2. Wait for the turn to end. About 20 s later the finish opens a turn by itself.
3. While that turn runs, send: `When it finishes, tell me in three sentences what it printed.`

Assert: the three-sentence reply is drawn under your message when the turn ends. Fail: the pane shows
only "Used a tool" or "Worked for" lines and then nothing, or the next turn's words.

### R2. Replies after a daemon restart draw (T2, T3)

1. Start another background command (`sleep 600`), and while it runs, restart the copy's daemon
   (quit and reopen the copy; never the person's NIGHTLY).
2. Reopen the chat and send: `Say hello in one sentence.`

Assert: the reply draws as the turn's answer. Fail: no reply drawn, or the reply sits folded inside
a background line while the turn's answer slot is empty.

### R3. The room above the live line (T4)

1. Send: `Read three files in this directory one at a time, thinking between each.`
2. While it works, take a screenshot each time a tool row sits directly above the live Thinking line.

Assert: from the tool row's text centre to the live line's text centre is 30 px (within 1 px) in
every screenshot, and the live line does not jump when a step switches to a reply. Fail: 43 px, or
any other value, or a visible jump.

### R4. The settled reply appears in place (T5)

1. Send a prompt that makes a long turn with a final reply: `List this directory, read two files,
   then summarise them in two paragraphs.`
2. Record the turn's end. Step through the video frame by frame from the last frame of work to the
   first frame where the reply is fully drawn.
3. Repeat three times, once with the pane scrolled up by a screen when the turn ends, and once
   sending the next prompt within a second of the end.

Assert, on every frame: the reply's text is never drawn anywhere but its final place (no frame with
it left of or above where it lands), it is never drawn over another row's text, and its ink only
rises (no frame fainter than the one before, no step from faint to full in one frame). Fail: any
frame with the reply away from its place, doubled text, or a jump in ink.

### R5. Thought rows open on every click (T7)

1. In a chat with at least three folded Thought lines, click each one at five places along its row:
   on the glyph, on the first word, on the last word, 50 px past the last word, and near the row's
   right edge.

Assert: all 15 clicks open (or close) the Thought. The words light up only while the pointer is on
the glyph, the words or the chevron, not over the empty part of the row. Fail: any click that does
nothing, or words still lit with the pointer past them.

### R6. Fork under a finished turn while a later turn runs, and the fork itself (T8)

1. With one finished turn A in the chat, send: `Run "sleep 45" and then say done.` This is turn B.
2. While B runs (the live line is showing), move the pointer over turn A's reply and over A's prompt.

   Assert: Fork is shown under A's reply and under A's prompt, and stays through B's tool calls. Fail:
   Fork missing while B runs, or appearing only when a tool call ends.
3. Still while B runs, click Fork under A's reply.

   Assert: a new chat opens holding the chat through turn A and nothing of turn B. Fail: an error, no
   new chat, or B's rows in the fork.
4. Look back at the first chat.

   Assert: turn B is still running there and ends with "done". Fail: B stopped, or the chat shows an
   error.
5. Repeat steps 1 to 4 in a Codex chat.
6. In a chat of an agent that forks only at a chat's end (any but Claude and Codex), repeat steps 1
   and 2.

   Assert: no Fork under A while B runs, and Fork returns when B ends.

### R7. The reply Leo did not see (the first report)

1. Open a chat that gets messages from other agents and background finishes (a coordinator's chat in
   the copy, or two chats in the copy sending to each other with `acpmux send`).
2. While a turn that a finish or another agent's message started is running, send a message with an
   image attached.

Assert: the agent's reply to that message is drawn under it when the turn ends. Fail: the message is
followed by work lines and then the next turn, with no reply.

## Results

Not run yet. The run needs a nightly built after cmux#48689 and cmux#48711 merged (2026-11-21), or
`cmux app try feat-cmux-next` over an older one.

| Step | Date, build | Pass or fail | Evidence |
|---|---|---|---|
| R1 | | | |
| R2 | | | |
| R3 | | | |
| R4 | | | |
| R5 | | | |
| R6 | | | |
| R7 | | | |
