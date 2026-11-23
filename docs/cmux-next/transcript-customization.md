# Customize the agent chat transcript

The agent chat's transcript has a look: how far apart its rows sit, how wide its column is, how your
messages and its cards are drawn, and when times show. A look is data, not code. It is a set of
token values from one table, and you can change any token without a build or a restart. This page
covers the two settings keys, the tokens, the shipped looks, and how to ship a look of your own.

The table is `schemas/transcript-look/transcript-look.json`. cmux checks every value against it
(`cmux settings set`, `cmux theme check`), and the chat draws from the same file.

## Two keys

| Key | Value | Default |
|---|---|---|
| `agentPane.display.transcriptLook` | `cmux`, `claude`, `codex` or `studio` | `cmux` |
| `agentPane.display.transcriptTokens` | an object of token name to value | `{}` |

A token's value comes from the first of these that sets it:

1. `agentPane.display.transcriptTokens`.
2. The look named by `agentPane.display.transcriptLook`.
3. The chat's own default (what `cmux` draws).

The `cmux` look sets no token, so the chat draws as it always has. Four tokens overlap Agent Chat
settings you may already use. When you set one of those settings yourself, your setting wins over
the look:

| Token | Setting that wins |
|---|---|
| `messageWidth` | `agentPane.display.width` |
| `font` | `agentPane.display.font.preset` |
| `fontSize` | `agentPane.display.font.size` |
| `lineHeight` | `agentPane.display.font.lineHeight` |

The part tokens follow the same rule: `reply.font` and `userMessage.font` give way to
`agentPane.display.font.preset`, and `reply.fontSize` and `userMessage.fontSize` to
`agentPane.display.font.size`, when a look sets them. When you set them yourself in
`agentPane.display.transcriptTokens`, yours win over those settings too. A font pack's prose family
stays in front of `reply.font`.

```sh
cmux settings set agentPane.display.transcriptLook claude
cmux settings set agentPane.display.transcriptTokens '{"userMessage.radius": 20, "timestamps": "always"}'
cmux settings reset agentPane.display.transcriptLook
```

## Tokens

Names are `element.property`. A bare name (`density`, `font`) belongs to the whole surface. The
sidebar's looks use the same bare names.

| Token | Values | cmux draws | What it does |
|---|---|---|---|
| `density` | `compact`, `cozy`, `comfortable` | `cozy` | Spaces the rows. Gaps are scaled by 0.75, 1 or 1.25. |
| `rowSpacing` | 0.5 to 2 | 1 | Scales every gap between rows again, on top of `density`. |
| `messageWidth` | 480 to 4000 points | 800 | The widest the column gets. |
| `font` | `system`, `serif`, `mono` | `system` | The text face. |
| `fontSize` | 10 to 28 points | 14 | The text size. |
| `lineHeight` | 1.2 to 2.4 | 1.625 | Line height, as a multiple of the text size. |
| `reply.font` | `system`, `serif`, `mono` | the chat's face | The agent's reply prose face. `serif` is the system serif stack macOS ships (`"New York", ui-serif, "Iowan Old Style", Georgia, serif`); no font is bundled. Code and the reply's chrome keep theirs. |
| `reply.fontSize` | 10 to 28 points | the chat's size | The reply's text size, on lines of `lineHeight` times it. Headings scale with it; code keeps its size. |
| `userMessage.font` | `system`, `serif`, `mono` | the chat's face | Your messages' face. |
| `userMessage.fontSize` | 10 to 28 points | the chat's size | Your messages' size, on lines of `lineHeight` times it. |
| `userMessage.style` | `bubble`, `plain` | `bubble` | Your messages: a filled bubble, or plain text with a rule at the leading edge. |
| `userMessage.align` | `right`, `left` | `right` | The side of the column your messages sit on. |
| `userMessage.maxWidth` | 0.4 to 1 | 0.7 | The widest your message gets, as a share of the column. |
| `userMessage.radius` | 0 to 28 points | 12 | The bubble's corner radius. |
| `userMessage.paddingBlock` | 0 to 20 points | 10 | The space above and below the text in the bubble. |
| `userMessage.paddingInline` | 0 to 24 points | 16 | The space beside the text in the bubble. |
| `userMessage.fill` | 0 to 0.3 | 0.14 | How much of the text color the bubble's fill mixes in. 0 means no fill. |
| `toolCard.radius` | 0 to 20 points | 6 to 12, by card | The corner radius of the transcript's cards: tool output, errors, plans and questions. |
| `toolCard.border` | `hairline`, `none` | `hairline` | Whether those cards draw a hairline edge. |
| `toolCards` | `row`, `card`, `minimal` | `row` | How a run of tool calls draws: rows with icons, the rows on a card, or quiet rows with no icons. |
| `codeCard.radius` | 0 to 20 points | 16 | The corner radius of code blocks. |
| `timestamps` | `hover`, `always`, `off` | `hover` | When a message's time shows. |

Only these tokens change where rows sit: `density`, `rowSpacing`, `messageWidth`, the font tokens
(`reply.*` moves only replies, `userMessage.font*` only your messages), and the `userMessage`
padding and width. Every other token changes only how rows are painted. The
chat measures rows with the same values it draws with, so switching a look never makes the
transcript jump.

## Shipped looks

| Look | Feel | Tokens it sets |
|---|---|---|
| `cmux` | The chat as cmux draws it. This is the default. | none |
| `claude` | Room to read: a narrower column, replies in a serif and your messages in the sans, larger text, quiet tool lines with no icons, soft bubbles and rounded cards, in the style of the Claude app | `density: comfortable`, `messageWidth: 720`, `fontSize: 15`, `lineHeight: 1.4`, `reply.font: serif`, `reply.fontSize: 16`, `userMessage.font: system`, `userMessage.fontSize: 15`, `toolCards: minimal`, `userMessage.radius: 16`, `userMessage.maxWidth: 0.8`, `userMessage.fill: 0.04`, `toolCard.radius: 12` |
| `codex` | A narrow column, a rounded bubble for your messages, borderless cards and no times, in the style of the Codex app | `messageWidth: 640`, `fontSize: 13`, `lineHeight: 1.6`, `userMessage.radius: 10`, `userMessage.paddingBlock: 7`, `userMessage.paddingInline: 12`, `userMessage.fill: 0.05`, `toolCard.radius: 10`, `toolCard.border: none`, `toolCards: minimal`, `timestamps: off` |
| `studio` | Dense work logs: tight rows, a rounded bubble, small radii | `density: compact`, `messageWidth: 736`, `userMessage.paddingBlock: 11`, `userMessage.paddingInline: 12`, `userMessage.fill: 0.05`, `toolCard.radius: 6`, `codeCard.radius: 6` |

The table file has every value of every look.

## Ship a look in a theme file

A theme file (`~/.config/cmux/themes/<name>.json`, [theme recipes](theme-recipes.md)) can carry both
keys, next to its colors. When you save the file, the running app repaints, with no relaunch:

```jsonc
// ~/.config/cmux/themes/paper.json
{
  "name": "Paper",
  "description": "Claude's spacing with square, left-aligned prompts.",
  "appearance.theme": "Claude Light",
  "agentPane.display.transcriptLook": "claude",
  "agentPane.display.transcriptTokens": {
    "userMessage.style": "plain",
    "userMessage.align": "left",
    "userMessage.maxWidth": 1,
    "timestamps": "always"
  }
}
```

Turn the file on with `cmux settings set appearance.themeFile paper`. When a token is unknown or a
value is out of range, `cmux theme check paper` names it, and the chat skips only that token. The
theme file schema (`themes/.schema.json`, written by `cmux theme schema`) lists every token with its
range, so an editor can complete them.

An extension or an app store listing ships a look the same way: as a theme file, or as a profile
that sets the two keys. A look never needs code, and it keeps working as the chat changes, because
the keys and tokens on this page are the stable surface.

## Stability

The two keys and the token names on this page are stable. A token may gain values, and new tokens
may be added. A token is never renamed or removed without a release note. If a newer token reaches
an older cmux, that cmux ignores it.
