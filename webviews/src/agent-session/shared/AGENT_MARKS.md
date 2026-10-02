# Agent mark attributions

`AgentMark.tsx` draws each agent's mark from the paths below, filled in the theme's
text color unless its recolor rule says otherwise. Paths are copied unmodified from the listed file; only the OpenAI view box is cropped from the file's 716-unit canvas to the glyph, since the canvas pads it with clear space. Every mark was
retrieved on 2026-10-01. The marks are trademarks of their owners and identify the
agent a session runs; they imply no endorsement.

| key               | source                   | owner     | page                                                                 | file                                                                          | recolor                                                                                                                                                                                                                               |
| ----------------- | ------------------------ | --------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `claude`          | `anthropic:claude-spark` | Anthropic | https://www.anthropic.com/press-kit                                  | press kit zip, `Claude logos/3 Claude Spark/SVG/Claude Spark - Clay.svg`      | Tinted. The press kit states no usage rules; its brand color is Clay `#D97757` (`brandColor`).                                                                                                                                        |
| `openai`, `codex` | `openai:blossom`         | OpenAI    | https://openai.com/brand/                                            | https://cdn.openai.com/brand/openai-logos.zip, `OAI_OpenAI-Blossom_Black.svg` | Black or white only ("Don't add any colors to the Blossom"), so it draws pure white on a dark theme and pure black on a light one (the theme's background-against-text luminance) instead of tinting. OpenAI publishes no Codex mark. |
| `cursor`          | `cursor:cube-2d`         | Anysphere | https://cursor.com/brand                                             | brand assets zip, `Cube/SVG/CUBE_2D_DARK.svg`                                 | Tinted. The brand page states no color rules.                                                                                                                                                                                         |
| `opencode`        | `opencode:logo`          | OpenCode  | https://opencode.ai/brand                                            | https://opencode.ai/opencode-brand-assets.zip, `Logo/opencode-logo-light.svg` | Tinted. Two-tone in the original, so the inner block draws at 35% opacity.                                                                                                                                                            |
| `gemini`          | `lobe:gemini`            | Google    | Google publishes no public SVG (Partner Marketing Hub needs a login) | Lobe Icons `packages/static-svg/icons/gemini.svg`                             | Tinted.                                                                                                                                                                                                                               |
| `amp`             | `lobe:amp`               | Amp       | https://ampcode.com/press-kit offers only a full-color app-icon tile | Lobe Icons `packages/static-svg/icons/amp.svg`                                | Tinted.                                                                                                                                                                                                                               |

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
