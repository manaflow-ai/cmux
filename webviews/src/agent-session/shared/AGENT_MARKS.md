# Agent mark attributions

`AgentMark.tsx` draws each agent's mark from the paths below. By default a mark
fills in its vendor's own colors, so agent tabs sit beside browser tabs' full-color
favicons; the mono style fills every mark white on a dark theme and black on a
light one. Path data is copied unmodified from the listed file. The OpenAI view box
is cropped from the file's 716-unit canvas to the glyph plus a small margin, and
OpenCode's paths drop the file's full-canvas mask wrapper and gain `evenodd`, which
renders the same. Every mark was retrieved on 2026-10-01. The marks are trademarks
of their owners and identify the agent a session runs; they imply no endorsement.

| key               | source                   | owner     | page                                                                 | file (path inside the zip)                                                                                                                          | brand color (dark theme / light theme)                                                                                             |
| ----------------- | ------------------------ | --------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `claude`          | `anthropic:claude-spark` | Anthropic | https://www.anthropic.com/press-kit                                  | press kit zip, `Anthropic media resources/Anthropic logos/Claude logos/3 Claude Spark/SVG/Claude Spark - Clay.svg`                                  | Clay `#D97757`, the kit's only Spark color. The kit states no usage rules.                                                         |
| `openai`, `codex` | `openai:blossom`         | OpenAI    | https://openai.com/brand/                                            | https://cdn.openai.com/brand/openai-logos.zip, `OpenAI-logos/SVGs/OAI_OpenAI-Blossom_Black.svg`                                                     | `#fff` / `#000`. The Blossom comes only in black or white ("Don't add any colors to the Blossom"). OpenAI publishes no Codex mark. |
| `cursor`          | `cursor:cube-2d`         | Anysphere | https://cursor.com/brand                                             | brand assets zip, `General Logos/Cube/SVG/CUBE_2D_DARK.svg` (paths); `CUBE_2D_LIGHT.svg` (light color)                                              | `#EDECEC` / `#26251E`, from the dark and light files.                                                                              |
| `opencode`        | `opencode:logo`          | OpenCode  | https://opencode.ai/brand                                            | https://opencode.ai/opencode-brand-assets.zip, `OpenCode Brand Assets/Logo/opencode-logo-light.svg` (paths); `opencode-logo-dark.svg` (dark colors) | Frame `#F1ECEC` / `#211E1E`, inner block `#4B4646` / `#CFCECD`. In mono the inner block draws at 35% opacity.                      |
| `gemini`          | `lobe:gemini`            | Google    | Google publishes no public SVG (Partner Marketing Hub needs a login) | Lobe Icons `packages/static-svg/icons/gemini.svg` (paths); `gemini-color.svg` (colors)                                                              | `#3186FF` with Lobe's green, red and yellow gradient highlights.                                                                   |
| `amp`             | `lobe:amp`               | Amp       | https://ampcode.com/press-kit offers only a full-color wordmark tile | Lobe Icons `packages/static-svg/icons/amp.svg` (paths); `amp-color.svg` (color)                                                                     | `#F34E3F`.                                                                                                                         |

Lobe Icons files come from https://github.com/lobehub/lobe-icons at commit
`79b551cf26aab9ea4ac701fb807160950a5b860f`, under the MIT License:

> Copyright (c) 2023 LobeHub
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this
> software and associated documentation files (the "Software"), to deal in the Software
> without restriction, including without limitation the rights to use, copy, modify,
> merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
> permit persons to whom the Software is furnished to do so, subject to the following
> conditions:
>
> The above copyright notice and this permission notice shall be included in all copies
> or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
> INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
> PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
> HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
> CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
> OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
