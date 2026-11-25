# cmux design principles (P1 to P12)

Twelve rules a reviewer can fail a screenshot against. They sit on top of the Instrument v0.1
system (hq RFD 0034: three seeds, one corner rule, one ink ladder, hue only for status) and
[design-language.md](design-language.md), which own the numbers. These rules own behaviour: where
things go when content, width and state change. Every one comes from Leo's own words; the asks are
named so the source can be read in full (`leo-asks show ASK_ID`).

Leo, 2026-11-23 (ask-6a24624c5c):

> there is objectivity in design. we cannot miss these edge cases like this and let them languish.

> these things shouldn't even need hill climbing.

So each rule has a **Fail** line, and the [stress matrix](#the-stress-matrix) below lists the
gallery cells where it is checked. A PR that touches a surface names the principles it was
checked against and the matrix cells it was looked at in. A fix to one surface is checked on every
surface the same rule covers.

## The principles

### P1. What you reach for stays where your hand is

Controls you act on are anchored to the edge you reach from. Content growing, wrapping or
scrolling never moves them. The composer's buttons sit at its bottom edge however tall the draft
grows; a header's buttons sit in their own corner and are never glued into a row that can wrap.

> why the f\*\*\*, if your composer grows in length, should the buttons you f\*\*\*ing reach for stray
> away from you? obviously, just do it right. period. (ask-6a24624c5c)

> a banner at the top of a single f\*\*\*ing line that gets cut off and also inadvertently shifts the
> f\*\*\*ing buttons on the top right down with it because they got f\*\*\*ing glued in to the row.
> (ask-6a24624c5c)

**Fail:** any action button that moves when the draft, title or banner beside it changes length.

### P2. The narrowest pane is a real pane

Design the compressed width first; it is a common case, not an edge case. When space runs out a
group of controls changes form (into the ellipsis menu, from a row into a column, from labels into
symbols), it never clips, overlaps or wraps into a second row that pushes its neighbours.

> this is unusable at low widths. which is common. at leats im using it. which means it's a valid
> case, and we need to prepare for that, just like how we need to prepare for all of them.
> (ask-0a9ea3ca30)

> the f\*\*\*ing buttons on the top right NEED to be done right, especially when things are at
> compressed width panes. we have an ellipsis. maybe it can go from horizontal to vertical with a
> sweet -ass animation (ask-6a24624c5c)

**Fail:** a clipped control, overlapping text, or a wrapped control row at the matrix's narrow width.

### P3. State is a symbol, and only when you might act

Normal progress needs no words: running is shown by a mark, not by "running". Text appears when a
state asks you to look or act (needs you, failed). Many ongoing things are summarised as counts per
kind, each with its symbol (subagents, per harness; background commands), not as a list of rows.

> "running" doesn't need text. it can usually just be. you can put symbols for state. and state can
> f\*\*\*ing only be relevant when you may need to investigate/take action. (ask-d8553c485d)

> there's no point in even saying it's running. it's running or it's failed or it's done.
> (ask-e8cfa8b8aa)

> just listing the # of each type of ongoing thing would be better. symbol for subagents,
> potentially per harness, then whatever other commands with their own symbols, a sort of count of
> states of affairs. (ask-0a9ea3ca30)

**Fail:** the word "running" (or a synonym) on a surface that already shows a running mark; a list
of running things where a count would fit.

### P4. Truncate last

An ellipsis is the last resort, after the layout has given back every spare pixel: labels that
repeat state, reserved slots and padding go first. Long names (files, titles, commands) keep their
distinguishing end where it matters, and the full text is one hover away.

> the f\*\*\* are these cutting off into ellipses so soon anyways? (ask-0a9ea3ca30)

**Fail:** a truncated label beside empty space or beside a label that P3 says should not be there.

### P5. No space for nothing

A slot that holds nothing is not drawn. No icon column with no icon, no blank row kept for a
missing value, no padding that reserves room for a state that is not there.

> stupid, stupid f\*\*\*ing call to have a symbol making space for ABSOLUTLEY NOTHING and leaving so
> much bulls\*\*\* blank space there. (ask-87b0c2d6e7)

**Fail:** a gap the width of an icon or a row with nothing in it.

### P6. Show it when it changes

Transient aids (the scroll thumb, a length indicator, a hint) appear when the thing they describe
changes, then fade. They are never on all the time.

> it should only appear briefly when the length changes, or when you scroll. not all the time. never
> all the time. (ask-6a24624c5c)

**Fail:** a scroll thumb or hint visible in a still screenshot taken a second after the last change.

### P7. Shape follows content

A box's roundness comes from its smallest height (the Instrument corner rule; no capsules). A
single-line composer takes the tighter Claude Code roundness; a pill shape only makes sense for a box
whose baseline is more than one line, and then its highlight is a circle, not a rounded square. A
pill holds one line of content only if that line needs a pill at all.

> if you're going to have it be that round, it necessarily has to be at baseline longer than one
> line. and the highlight also necessarily has to be a circle instead of a rounded square. that's
> just design. (ask-4b9705c633)

> just do the claude code roundedness. ... the more minimal single line claude code version is more
> favourable. (ask-bfa9b41590)

> the f\*\*\* is a pill with 2 lines supposed to be for anyways? (ask-33e37575cb)

**Fail:** a corner the Instrument rule does not give; a round control highlight inside a square one
or the reverse.

### P8. Parity lives in the replicas

Another product's behaviour (ChatGPT's, Codex's) goes into its replica look or repo, never into
cmux's default. cmux adopts a behaviour only after it was studied as a whole, with everything it
depends on.

> that should've ONLY gone to the chatgpt replica repo (ask-0eca38a37c)

> it doesn't make sense because you guys didnt study the rest of it. (ask-260cfd9a59)

> "CHATGPT PARITY" F\*\*\* THAT WE ARE NOT PLAYING THE SAME GAME AS CHATGPT. (ask-3f17b71b9e)

**Fail:** a default-on behaviour whose PR names another product as its reason.

### P9. The view stays where you put it

An action never moves what you are looking at. Sending does not throw the transcript to the top;
pinning does not teleport the row out from under the cursor. The control you clicked is still under
the pointer and undoes what it did.

> oh god yeah dont do the chatgpt thing of sending it up. just dont (ask-9d49f9d87d)

> every single message i send, the gui shoots all the way up there. (ask-260cfd9a59)

> you pin and it sends it to the f\*\*\*ing top. ... where the f\*\*\* did my expected click go? ... and
> you cant click the button to unpin (ask-b5d3e0efb6)

**Fail:** a scroll jump or a moved row after a click or a send; a toggle that cannot be undone from
where it was clicked.

### P10. A changed item keeps its controls

Pinning, grouping or any other mark changes one thing about an item. Every other control it had
(close, its ellipsis menu with the same entries) stays, in the same place. Labels say what the item
is (a group is a group, not "pinned").

> and there's then no other buttons other than the ellipsis, which 1. no longer has the same
> behaviour as a regular chat. 2. is f\*\*\*ing displaced because the close cross was gone. why was it
> gone? no good f\*\*\*ing reason. (ask-b5d3e0efb6)

**Fail:** a control present on the plain item and missing or moved on the marked one.

### P11. Inline before aside

What you sent or asked to open appears in the flow where it belongs: pasted pictures inline where
you pasted them, a file opened inline in the chat. Opening off to the side is an option, not the
only way.

> the F\*\*\*ING inline pictures being sent and displayed inline instead of on the top.
> (ask-574afebc52)

> why haven't you followed my f\*\*\*ing request to have that be able to open up inline with the chat
> instead of only being able to open it off to the side? (ask-b5d3e0efb6)

**Fail:** an attachment drawn somewhere other than where it was placed; a file row whose only open
action is a side pane.

### P12. Say it once, quietly

No disclaimers in the main surface: detail goes behind an info circle or a hover. Something that
looks like a window behaves like one (it drags and dismisses). Motion is unobtrusive and earns its
place: no swap-in animation for a transient state, and the measure is perceived time to visible,
settled and interactive.

> NEVER THIS F\*\*\*ING TMI TREATING PEOPLE LIKE F\*\*\*ING CHILDREN. ... THERE ARE HOVERS AND QUESTION
> MARK CIRCLES AND INFO CIRCLES. THINK. F\*\*\*ING. HARDER. (ask-87b0c2d6e7)

> it pops up looking like a window and you can't drag it around like one (ask-87b0c2d6e7)

> just like how the "running a command" is inherently bulls\*\*\*, and the swap-in animation for it is
> even more additional bulls\*\*\*. (ask-0a9ea3ca30)

> just perceived time to visible/settled and percieved interactive time (ask-8708ee3a8d)

**Fail:** more than one line of explanatory text on a surface whose action is self-evident; a
window-shaped surface that cannot be dragged; an animation on a state that lasts under a second.

## The stress matrix

Leo, 2026-11-23 (ask-0a9ea3ca30):

> clearly, you guys haven't thought through and viewed all possible scenarios.

The gallery entry `design.principles-stress` (`webviews/src/gallery/principles/principlesStress.gallery.ts`)
draws the real agent pane in every cell below. Open it in the gallery shell, or render it with the
matrix runner (`webviews/src/gallery/ENTRIES.md`, "matrix"); never on Leo's Mac.

Axes, all crossed by the gallery itself:

| Axis | Values | Where it comes from |
|---|---|---|
| Pane width | narrow 300, normal 420, wide 1200 | the entry's `widths` |
| Scheme | light, dark, over a busy picture | the gallery env |
| Content | the variants below | the entry's `variants` |

| Variant | What it stresses | Principles |
|---|---|---|
| `baseline` | a short chat, empty composer: the reference every other cell is compared with | all |
| `draft-one-line` | a one-line draft: the composer at its smallest | P1, P7 |
| `draft-tall` | a 40-line draft: the composer at its tallest, buttons must stay at the bottom edge | P1, P6 |
| `title-long` | a 160-character chat title and a long branch: header controls at every width | P1, P2, P4 |
| `running-many` | three subagents and two background commands running at once | P2, P3, P4, P12 |
| `needs-you` | a permission waiting: the one state that should speak | P3 |
| `failed` | a failed tool call and a failed subagent | P3 |
| `file-long` | a tool row with a deep, long file path | P4, P11 |
| `command-long` | a long background shell command | P3, P4, P12 |
| `everything` | all of the above at once | all |

Reading a cell: put the screenshot beside the `baseline` cell at the same width and scheme, then
read each principle's Fail line for the principles in its row. P9 and P10 are about actions, not
stills: check them with a gallery play step (`webviews/src/gallery/play.ts`, `anchors`) on the
surface you change.

## Changing a principle

A principle changes the way an Instrument rule does: the rule is edited here, with the words that
moved it, and every surface it covers is checked again. A surface that cannot meet a rule is a
reason to change the rule, not to note an exception.
