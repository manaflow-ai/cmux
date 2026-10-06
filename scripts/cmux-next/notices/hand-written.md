# Third-Party Licenses

cmux includes the following third-party software:

---

## Agent brand marks

The coding agent and provider marks in `design/agent-icons/svg/` (and the
catalogs generated from them) are their owners' trademarks; they identify the
agent a session uses and imply no endorsement. `design/agent-icons/manifest.json`
records each mark's source and license. Simple Icons path data is CC0-1.0. The
Rovo Dev mark comes from `@atlaskit/logo` (Apache-2.0, Copyright Atlassian). The
GitHub Copilot mark is the Primer `copilot-24` octicon (MIT, below).

---

## Primer Octicons (selected diff viewer icons)

- **License:** MIT License
- **Copyright:** Copyright (c) 2026 GitHub Inc.
- **Source:** https://github.com/primer/octicons (v19.38.0)

Selected 16px path data is embedded in `webviews/src/icons.tsx`; the copilot-24
mark is in `design/agent-icons/svg/copilot.svg`.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Emoji data (icon picker)

- **Unicode emoji-test.txt 17.0** and **CLDR annotations 48.2.0** (`en`, `ja`):
  Unicode License v3, Copyright (c) 2004-2026 Unicode, Inc.
- **emojibase-data 17.0.0** GitHub shortcodes: MIT License, Copyright (c) 2017-2019 Miles Johnson.
- **Source:** pinned by URL and SHA-256 in `webviews/scripts/icon-picker/sources.json`.

The derived table is `webviews/src/icon-picker/generated/emoji-data.json`; the full license texts
are in `webviews/src/icon-picker/generated/LICENSES.md`.

---

## Ghostty

- **License:** MIT License
- **Copyright:** Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
- **Source:** https://github.com/ghostty-org/ghostty

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Ghostty vendors the simdutf amalgamation (pkg/simdutf/vendor/), which is
statically linked into libghostty (this app) and libghostty-vt (bin/cmux):

- **simdutf 9.0.0:** Apache License 2.0 or MIT License (dual-licensed; cmux elects MIT)
- **Source:** https://github.com/simdutf/simdutf/tree/ca7acbcea967b5dcbab490066e99e3a6e6925539

Copyright 2021 The simdutf authors

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

simdutf's CPU feature detection (include/simdutf/internal/isadetection.h) is
derived from PyTorch and carries this notice:

From
https://github.com/endorno/pytorch/blob/master/torch/lib/TH/generic/simd/simd.h
Highly modified.

Copyright (c) 2016-     Facebook, Inc            (Adam Paszke)
Copyright (c) 2014-     Facebook, Inc            (Soumith Chintala)
Copyright (c) 2011-2014 Idiap Research Institute (Ronan Collobert)
Copyright (c) 2012-2014 Deepmind Technologies    (Koray Kavukcuoglu)
Copyright (c) 2011-2012 NEC Laboratories America (Koray Kavukcuoglu)
Copyright (c) 2011-2013 NYU                      (Clement Farabet)
Copyright (c) 2006-2010 NEC Laboratories America (Ronan Collobert, Leon Bottou,
Iain Melvin, Jason Weston) Copyright (c) 2006      Idiap Research Institute
(Samy Bengio) Copyright (c) 2001-2004 Idiap Research Institute (Ronan Collobert,
Samy Bengio, Johnny Mariethoz)

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

3. Neither the names of Facebook, Deepmind Technologies, NYU, NEC Laboratories
America and IDIAP Research Institute nor the names of its contributors may be
   used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

---

## Ghostty shell integration

The app bundles Ghostty's shell integration scripts from ghostty-next (`Contents/Resources/ghostty/shell-integration/`), and `bin/cmux` and `bin/cmux-tui-ssh/*` embed the files marked (embedded). Each file and its license:

- `README.md`: Ghostty (ghostty-next); MIT (Ghostty's license, in the Ghostty section)
- `bash/bash-preexec.sh` (embedded): bash-preexec 0.7.0 (Ryan Caloras and contributors, https://github.com/rcaloras/bash-preexec), modified by Ghostty (__bp_adjust_histcontrol commented out); MIT (text below)
- `bash/ghostty.bash` (embedded): Ghostty (ghostty-next), parts based on Kitty's bash integration (https://github.com/kovidgoyal/kitty); GPL-3.0-or-later (the GNU GPL text is `Contents/Resources/LICENSE`)
- `elvish/lib/ghostty-integration.elv`: Ghostty (ghostty-next); MIT (Ghostty's license, in the Ghostty section)
- `fish/vendor_conf.d/ghostty-shell-integration.fish` (embedded): Ghostty (ghostty-next); MIT (Ghostty's license, in the Ghostty section)
- `nushell/vendor/autoload/ghostty.nu`: Ghostty (ghostty-next); MIT (Ghostty's license, in the Ghostty section)
- `zsh/.zshenv` (embedded): Ghostty (ghostty-next), based on Kitty's zsh integration (https://github.com/kovidgoyal/kitty); GPL-3.0-or-later (the GNU GPL text is `Contents/Resources/LICENSE`)
- `zsh/ghostty-integration` (embedded): Ghostty (ghostty-next), based on Kitty's zsh integration (https://github.com/kovidgoyal/kitty); GPL-3.0-or-later (the GNU GPL text is `Contents/Resources/LICENSE`)

bash-preexec 0.7.0 (https://github.com/rcaloras/bash-preexec, tag 0.7.0), MIT License:

```text
The MIT License

Copyright (c) 2017 Ryan Caloras and contributors (see https://github.com/rcaloras/bash-preexec)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

---

## FreeType

GhosttyNextKit (Ghostty's terminal library in this app) statically links FreeType for font rendering. This app uses FreeType under the FreeType License (FTL). `Contents/Resources/ghostty-next-licenses/` holds FreeType's LICENSE.TXT, the FTL text (docs/FTL.TXT) and the X11-style terms of the parts of FreeType that the app compiles in: the BDF driver (src/bdf/README), the PCF driver (src/pcf/README) and src/base/fthash.c. The FTL asks binary distributions to credit the FreeType Project:

This software is based in part on the work of the FreeType Team (FreeType 2.13.2, https://freetype.org). Portions of this software are copyright © 2023 The FreeType Project (www.freetype.org).  All rights reserved.

---

## cmux-cua engine

- **License:** MIT License
- **Copyright:** Copyright (c) 2025 Cua AI, Inc.
- **Source:** https://github.com/manaflow-ai/cmux-cua

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## herdr agent-detection plugin

cmux includes a userland agent-detection plugin derived from herdr. Its
manifests and adapted detector sources live under
`cmux-tui/bindings/examples/rust-agent-screen-detection/`.

- **Package license:** GPL-3.0-or-later AND Apache-2.0
- **Herdr-derived material:** Apache License 2.0
- **Source:** https://github.com/herdrdev/herdr
- **Detector source reference:** commit `7b675f42af35508eab66ac42fe1598628597a893`
- **Pi bundled-launcher correction:** commit `b1ff4582e9688f52ffb943cfa8bee4871ae122e4`
- **Manifest snapshot:** commit `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`
- **Included manifest fixes:** Claude MCP elicitation `f807b697353cfa00aa912c7cde4830e863001cf5`, Claude background-shell state `987b070fbfa187e85009b45cd7e208fc6175ff6a`, Codex weak-blocker scope `f457cff4f2648eee85d176f8a41861241d4e8428`, and Copilot background-agent activity `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`
- **License text:** cmux-owned code is covered by
  `cmux-tui/bindings/examples/rust-agent-screen-detection/LICENSE`; the
  herdr-derived files use
  `cmux-tui/bindings/examples/rust-agent-screen-detection/manifests/LICENSE`
- **Latest agent-surface capability audit:** commit `987b070fbfa187e85009b45cd7e208fc6175ff6a`. The herdr repository tip checked on 2026-09-02 is `94f6d9c0d9bb9cf9ffae99d8bbfb09e9bf2fc9e0`; commits after the audit pin change client rendering, terminal reads, graphics ownership, Windows input and worktree handling, or sidebar focus, with no further `src/detect` or manifest changes. The audit includes the exact Pi bundled CLI path correction from `b1ff4582e9688f52ffb943cfa8bee4871ae122e4` and the Claude background-shell state correction from `987b070fbfa187e85009b45cd7e208fc6175ff6a`, both adapted and tested in the userland package. The first-acquisition OSC retention fix from `82e6a80eb3ae39fb3d3ebd4d1fed19389767e605` is adapted in the userland tracker. The foreground group-leader CWD fix from `3a3792622e59c7f2dc20f9c0236167161e4a5035` is already covered by cmux's generic `foreground_cwd` resource. The shell-render refactor in `207be3c771d281baae6e5fa0fb74be9a056e97a2` and independent multi-client tab views in `6c0bb273d5d5405a00985621b17e36f8b4d64609` are application/client architecture and are not copied. The delayed-agent-prompt fix in `8633a398e653eee47b375c963996c78a8a14aa48` changes PTY input sequencing, and `5616196942cbe752cc0659b9bd0fb616b2a6ed5c` hardens malformed Windows process environments in portable-pty. These changes are outside detector behavior and are not copied. SDK endpoint-generation compatibility remains a standalone-release requirement; review the Windows changes before publishing a Windows package.

Nineteen manifests are unchanged from the manifest snapshot. `claude.toml` is
byte-identical to upstream commit `987b070fbfa187e85009b45cd7e208fc6175ff6a`.
`grok.toml` is based on the snapshot file and contains one documented cmux
precedence correction. `github-copilot.toml` is byte-identical to the snapshot
and uses upstream version `2026.08.29.1`. The manifest engine, process discovery, state detector, and update
logic are adapted for the cmux userland plugin contract. The source paths,
commits, license, and adaptations are recorded in
`cmux-tui/bindings/examples/rust-agent-screen-detection/ATTRIBUTIONS.md`.
The SHA256SUMS file is a checked-in byte-provenance record verified before the
bundled manifests are compiled. It detects accidental drift, but it is not a
cryptographic release signature for remote updates.

---

## executor (integration ingestion and tool policy)

cmux includes integration ingestion (OpenAPI, GraphQL and MCP) and tool policy
code adapted from executor in the package `libs/integrations-core/`
(`@cmux/integrations-core`, GPL-3.0-or-later AND MIT). The `cmux/integrations` app bundles that package
into `first-party-apps/integrations/dist/main.js`.

- **License:** MIT License
- **Copyright:** Copyright (c) 2026 Rhys Sullivan
- **Source:** https://github.com/UsefulSoftwareCo/executor (commit `98d606bd2b47b9dcc2c03a129a14b5134d9852c8`)
- **License text and adapted-file list:** `libs/integrations-core/LICENSE-executor` and
  `libs/integrations-core/NOTICE`; the app's notice is
  `first-party-apps/integrations/LICENSE-executor`

---

## Sparkle

- **License:** MIT License
- **Copyright:** Copyright (c) 2006-2013 Andy Matuschak, 2009-2013 Elgato Systems GmbH, 2011-2014 Kornel Lesinski, 2015-2017 Sparkle Project
- **Source:** https://github.com/sparkle-project/Sparkle

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## PostHog iOS

- **License:** MIT License
- **Copyright:** Copyright (c) 2020 PostHog
- **Source:** https://github.com/PostHog/posthog-ios

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Sentry Cocoa

- **License:** MIT License
- **Copyright:** Copyright (c) 2015 Sentry
- **Source:** https://github.com/getsentry/sentry-cocoa

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Markdown Viewer Web Assets

cmux bundles these files under `Resources/markdown-viewer/` so the markdown
viewer has no runtime CDN dependency.

### marked

- **Version:** 13.0.3
- **License:** MIT License
- **Copyright:** Copyright (c) 2011-2024, Christopher Jeffrey
- **Source:** https://github.com/markedjs/marked/releases/tag/v13.0.3

### highlight.js

- **Version:** 11.10.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2006-2024 Josh Goebel and other contributors
- **Source:** https://github.com/highlightjs/highlight.js/releases/tag/11.10.0

### github-markdown-css

- **Version:** 5.6.1
- **License:** MIT License
- **Copyright:** Copyright (c) Sindre Sorhus
- **Source:** https://github.com/sindresorhus/github-markdown-css/tree/v5.6.1

### Mermaid

- **Version:** 11.4.1
- **License:** MIT License
- **Copyright:** Copyright (c) 2014-2024 Knut Sveidqvist and Mermaid contributors
- **Source:** https://github.com/mermaid-js/mermaid/releases/tag/mermaid%4011.4.1

### Vega

- **Version:** 5.30.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2015-2024 University of Washington Interactive Data Lab and contributors
- **Source:** https://github.com/vega/vega/releases/tag/v5.30.0

### Vega-Lite

- **Version:** 5.21.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2015-2024 University of Washington Interactive Data Lab and contributors
- **Source:** https://github.com/vega/vega-lite/releases/tag/v5.21.0

### Vega-Embed

- **Version:** 6.26.0
- **License:** BSD 3-Clause License
- **Copyright:** Copyright (c) 2015-2024 University of Washington Interactive Data Lab and contributors
- **Source:** https://github.com/vega/vega-embed/releases/tag/v6.26.0

BSD 3-Clause License:

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

---

## Swift Package Dependencies

The following packages are linked into the cmux app binary.

### MarkdownUI (swift-markdown-ui)

- **License:** MIT License
- **Copyright:** Copyright (c) 2020 Guillermo Gonzalez
- **Source:** https://github.com/gonzalezreal/swift-markdown-ui

### NetworkImage

- **License:** MIT License
- **Copyright:** Copyright (c) 2020 Guille Gonzalez
- **Source:** https://github.com/gonzalezreal/NetworkImage

### swift-cmark (cmark / cmark-gfm)

- **License:** BSD 2-Clause License (and MIT-licensed portions; see upstream COPYING)
- **Copyright:** Copyright (c) 2014, John MacFarlane; cmark-gfm portions Copyright (c) 2017, GitHub, Inc.
- **Source:** https://github.com/swiftlang/swift-cmark

### iroh-ffi

- **License:** MIT License or Apache License 2.0 (dual-licensed; cmux elects MIT)
- **Copyright:** Copyright 2025 N0, INC.
- **Source:** https://github.com/manaflow-ai/iroh-ffi (fork of https://github.com/n0-computer/iroh-ffi)

### Swift Crypto and Swift ASN.1

- **License:** Apache License 2.0
- **Copyright:** Copyright (c) Apple Inc. and the SwiftCrypto / SwiftASN1 project authors
- **Source:** https://github.com/apple/swift-crypto, https://github.com/apple/swift-asn1

### Stack Auth Swift SDK

- **License:** MIT License (per Stack Auth's published per-package licensing policy,
  under which client SDKs are MIT-licensed; the vendored prerelease does not yet
  include its own LICENSE file)
- **Copyright:** Copyright (c) Stack Auth (HexClave, Inc.)
- **Source:** https://github.com/stack-auth/stack

---

## Diff Viewer Highlighting Assets

cmux bundles compiled syntax-highlighting code and grammars (shiki and its
Oniguruma WASM engine, built from `webviews/` with `@pierre/diffs`) inside the
generated `Resources/markdown-viewer/webviews-app/` bundle so the diff viewer
has no runtime CDN dependency.

### shiki

- **License:** MIT License
- **Copyright:** Copyright (c) 2021 Pine Wu; Copyright (c) 2023 Anthony Fu and Shiki contributors
- **Source:** https://github.com/shikijs/shiki

### vscode-textmate

- **License:** MIT License
- **Copyright:** Copyright (c) Microsoft Corporation
- **Source:** https://github.com/microsoft/vscode-textmate

### vscode-oniguruma

- **License:** MIT License
- **Copyright:** Copyright (c) Microsoft Corporation
- **Source:** https://github.com/microsoft/vscode-oniguruma

### Oniguruma

- **License:** BSD 2-Clause License
- **Copyright:** Copyright (c) 2002-2019 K.Kosako
- **Source:** https://github.com/kkos/oniguruma (bundled as WebAssembly via vscode-oniguruma)

---

## Agent Pane Math Assets

The cmux-next agent pane bundles KaTeX and its fonts (inlined into
`Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/`) to
typeset TeX in agent replies with no runtime CDN dependency.

### KaTeX

- **License:** MIT License
- **Copyright:** Copyright (c) 2013-2020 Khan Academy and other contributors
- **Source:** https://github.com/KaTeX/KaTeX/releases/tag/v0.16.25

---

## Code Editor Assets

The cmux-next code editor page (`webviews/src/pages/editor`) bundles the Monaco editor into the
generated `Resources/markdown-viewer/webviews-app/` bundle (lazy chunks loaded only by that page), with
Shiki's Monaco adapter. It uses the shiki, vscode-textmate and Oniguruma code listed above.

### Monaco Editor

- **License:** MIT License
- **Copyright:** Copyright (c) 2016 - present Microsoft Corporation
- **Source:** https://github.com/microsoft/monaco-editor (0.57.0), including its codicon font (CC-BY-4.0, https://github.com/microsoft/vscode-codicons)

### marked (vendored in Monaco)

- **License:** MIT License
- **Copyright:** Copyright (c) 2011-2024, Christopher Jeffrey (marked v14.0.0)
- **Source:** https://github.com/markedjs/marked

### DOMPurify (vendored in Monaco)

- **License:** Apache License 2.0 or Mozilla Public License 2.0
- **Copyright:** Copyright (c) Cure53 and other contributors
- **Source:** https://github.com/cure53/DOMPurify (3.4.15)

### @shikijs/monaco

- **License:** MIT License
- **Copyright:** Copyright (c) 2021 Pine Wu; Copyright (c) 2023 Anthony Fu and Shiki contributors
- **Source:** https://github.com/shikijs/shiki/tree/main/packages/monaco

---

## cmux browser host runtime JavaScript

`bin/cmux-browser-host` embeds its runtime JavaScript (cmux-tui `crates/cmux-browser-host/js`, every file of `js/manifest.json`). Three embedded files are third-party code; the rest is cmux's own code (GPL-3.0-or-later, `Contents/Resources/LICENSE`). Rows: `cmux-tui/build-support/notices/browser-host/browser-host-js.json`.

- `vendor/acorn.js`: acorn 8.16.0 (https://github.com/acornjs/acorn), `dist/acorn.js` unmodified; MIT (text below)
- `vendor/playwright-injected.js`: Playwright (playwright-core 1.57.0, https://github.com/microsoft/playwright), `lib/generated/injectedScriptSource.js` (the evaluated source string, unmodified); Apache-2.0 (LICENSE and NOTICE below)
- `vendor/playwright-locator-utils.js`: Playwright (playwright-core 1.57.0), `lib/utils/isomorphic/locatorUtils.js` and the escape helpers of `lib/utils/isomorphic/stringUtils.js`; the functions are unchanged, the module wrapper was changed by cmux (the file header says so); Apache-2.0 (LICENSE and NOTICE below)

acorn 8.16.0, `LICENSE` from the npm package:

```text
MIT License

Copyright (C) 2012-2022 by various contributors (see AUTHORS)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

playwright-core 1.57.0, `NOTICE` from the npm package:

```text
Playwright
Copyright (c) Microsoft Corporation

This software contains code derived from the Puppeteer project (https://github.com/puppeteer/puppeteer),
available under the Apache 2.0 license (https://github.com/puppeteer/puppeteer/blob/master/LICENSE).
```

playwright-core 1.57.0, `LICENSE` from the npm package (Apache License 2.0; shown with LF line endings):

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Portions Copyright (c) Microsoft Corporation.
   Portions Copyright 2017 Google Inc.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

---

## x264 (remote desktop host encoder)

- **License:** GNU General Public License v2.0 or later (GPL-2.0-or-later)
- **Copyright:** Copyright (C) 2003-2023 x264 project (Laurent Aimar, Loren Merritt, Fiona Glaser and others)
- **Source:** https://code.videolan.org/videolan/x264 at commit 31e19f9 (r3108, X264_BUILD 164), as packaged by Ubuntu 24.04 `libx264-dev` 2:0.164.3108+git31e19f9-1

`cmux-rd` (crate `cmux-tui/crates/cmux-rd-host`) links libx264 statically when it is
built with its default `x264` feature. cmux-tui is GPL-3.0-or-later, and GPL-2.0-or-later
code may be combined with it. The complete GPL-2.0 text is at
https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt. The corresponding x264 source is
the commit named above. H.264 encoding may need a separate patent license; see
`plans/cmux-next/remote-desktop.md` (D-RD1).

---

## OpenH264 (remote desktop alternative encoder and bench decoder)

- **License:** BSD 2-Clause License
- **Copyright:** Copyright (c) 2013, Cisco Systems
- **Source:** https://github.com/cisco/openh264 version 2.6.0, built from source through the
  `openh264` and `openh264-sys2` 0.9.8 Rust crates (also BSD-2-Clause)

Used by `cmux-rd` with `--codec openh264` and by its bench client. Because it is built
from source, Cisco's royalty-free H.264 patent license for its prebuilt binary does not
apply.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

---

## Rust and Zig Standard Libraries

Every Rust binary in this app statically links the Rust standard library
(`std`, `core`, `alloc`, `compiler_builtins` and the crates they vendor) of
the rustc that built it. The Rust project publishes the notices for that code
with each release as `COPYRIGHT-library.html`. This app ships that file,
unchanged, for each rustc that built one of its binaries:

- `Contents/Resources/toolchain-licenses/rust-1.95.0/COPYRIGHT-library.html`:
  `bin/cmux`, `bin/cmux-tui-ssh/*`, `bin/cmux-app-host` and `bin/cmux-cloud`
- `Contents/Resources/toolchain-licenses/rust-1.91.0/COPYRIGHT-library.html`:
  iroh-ffi (`Iroh.framework`; Release builds merge its code into the app binary)
- `Contents/Resources/toolchain-licenses/rust-1.88.0/COPYRIGHT-library.html`:
  `bin/cmux-diff-sidecar`

The app (GhosttyNextKit), `bin/cmux` and `bin/cmux-tui-ssh/*` (libghostty-vt)
and `bin/ghostty` link the Zig 0.16.0 standard library and compiler_rt:

- **License:** MIT License (Expat)
- **Copyright:** Copyright (c) Zig contributors
- **Source:** https://ziglang.org/download/0.16.0/zig-0.16.0.tar.xz
- **License text:** `Contents/Resources/toolchain-licenses/zig-0.16.0/LICENSE`

The MIT License (Expat)

Copyright (c) Zig contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

---

## musl (in the Zig standard library)

GhosttyNextKit (Ghostty's terminal library in this app) contains code from the Zig standard library that Zig ported from musl: std.math.cbrt (musl src/math/cbrtf.c and src/math/cbrt.c), which Ghostty's terminal I/O uses to generate its 256-color palette. musl is licensed under the MIT license. The text below is the COPYRIGHT file of musl 1.2.5 (https://musl.libc.org/releases/musl-1.2.5.tar.gz), the musl release that Zig 0.16.0 bundles.

```text
musl as a whole is licensed under the following standard MIT license:

----------------------------------------------------------------------
Copyright © 2005-2020 Rich Felker, et al.

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
----------------------------------------------------------------------

Authors/contributors include:

A. Wilcox
Ada Worcester
Alex Dowad
Alex Suykov
Alexander Monakov
Andre McCurdy
Andrew Kelley
Anthony G. Basile
Aric Belsito
Arvid Picciani
Bartosz Brachaczek
Benjamin Peterson
Bobby Bingham
Boris Brezillon
Brent Cook
Chris Spiegel
Clément Vasseur
Daniel Micay
Daniel Sabogal
Daurnimator
David Carlier
David Edelsohn
Denys Vlasenko
Dmitry Ivanov
Dmitry V. Levin
Drew DeVault
Emil Renner Berthing
Fangrui Song
Felix Fietkau
Felix Janda
Gianluca Anzolin
Hauke Mehrtens
He X
Hiltjo Posthuma
Isaac Dunham
Jaydeep Patil
Jens Gustedt
Jeremy Huntwork
Jo-Philipp Wich
Joakim Sindholt
John Spencer
Julien Ramseier
Justin Cormack
Kaarle Ritvanen
Khem Raj
Kylie McClain
Leah Neukirchen
Luca Barbato
Luka Perkov
M Farkas-Dyck (Strake)
Mahesh Bodapati
Markus Wichmann
Masanori Ogino
Michael Clark
Michael Forney
Mikhail Kremnyov
Natanael Copa
Nicholas J. Kain
orc
Pascal Cuoq
Patrick Oppenlander
Petr Hosek
Petr Skocik
Pierre Carrier
Reini Urban
Rich Felker
Richard Pennington
Ryan Fairfax
Samuel Holland
Segev Finer
Shiz
sin
Solar Designer
Stefan Kristiansson
Stefan O'Rear
Szabolcs Nagy
Timo Teräs
Trutz Behn
Valentin Ochs
Will Dietz
William Haddon
William Pitcock

Portions of this software are derived from third-party works licensed
under terms compatible with the above MIT license:

The TRE regular expression implementation (src/regex/reg* and
src/regex/tre*) is Copyright © 2001-2008 Ville Laurikari and licensed
under a 2-clause BSD license (license text in the source files). The
included version has been heavily modified by Rich Felker in 2012, in
the interests of size, simplicity, and namespace cleanliness.

Much of the math library code (src/math/* and src/complex/*) is
Copyright © 1993,2004 Sun Microsystems or
Copyright © 2003-2011 David Schultz or
Copyright © 2003-2009 Steven G. Kargl or
Copyright © 2003-2009 Bruce D. Evans or
Copyright © 2008 Stephen L. Moshier or
Copyright © 2017-2018 Arm Limited
and labelled as such in comments in the individual source files. All
have been licensed under extremely permissive terms.

The ARM memcpy code (src/string/arm/memcpy.S) is Copyright © 2008
The Android Open Source Project and is licensed under a two-clause BSD
license. It was taken from Bionic libc, used on Android.

The AArch64 memcpy and memset code (src/string/aarch64/*) are
Copyright © 1999-2019, Arm Limited.

The implementation of DES for crypt (src/crypt/crypt_des.c) is
Copyright © 1994 David Burren. It is licensed under a BSD license.

The implementation of blowfish crypt (src/crypt/crypt_blowfish.c) was
originally written by Solar Designer and placed into the public
domain. The code also comes with a fallback permissive license for use
in jurisdictions that may not recognize the public domain.

The smoothsort implementation (src/stdlib/qsort.c) is Copyright © 2011
Valentin Ochs and is licensed under an MIT-style license.

The x86_64 port was written by Nicholas J. Kain and is licensed under
the standard MIT terms.

The mips and microblaze ports were originally written by Richard
Pennington for use in the ellcc project. The original code was adapted
by Rich Felker for build system and code conventions during upstream
integration. It is licensed under the standard MIT terms.

The mips64 port was contributed by Imagination Technologies and is
licensed under the standard MIT terms.

The powerpc port was also originally written by Richard Pennington,
and later supplemented and integrated by John Spencer. It is licensed
under the standard MIT terms.

All other files which have no copyright comments are original works
produced specifically for use as part of this library, written either
by Rich Felker, the main author of the library, or by one or more
contibutors listed above. Details on authorship of individual files
can be found in the git version control history of the project. The
omission of copyright and license comments in each file is in the
interest of source tree size.

In addition, permission is hereby granted for all public header files
(include/* and arch/*/bits/*) and crt files intended to be linked into
applications (crt/*, ldso/dlstart.c, and arch/*/crt_arch.h) to omit
the copyright notice and permission notice otherwise required by the
license, and to use these files without any requirement of
attribution. These files include substantial contributions from:

Bobby Bingham
John Spencer
Nicholas J. Kain
Rich Felker
Richard Pennington
Stefan Kristiansson
Szabolcs Nagy

all of whom have explicitly granted such permission.

This file previously contained text expressing a belief that most of
the files covered by the above exception were sufficiently trivial not
to be subject to copyright, resulting in confusion over whether it
negated the permissions granted in the license. In the spirit of
permissive licensing, and of not having licensing issues being an
obstacle to adoption, that text has been removed.
```

---

## Shared License Texts

MIT-licensed components above are distributed under the MIT License text
reproduced in the sections earlier in this document. BSD 2-Clause components
are distributed under the following text:

BSD 2-Clause License:

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Apache-2.0-licensed components are distributed under the Apache License,
Version 2.0. A copy of the license is available at
http://www.apache.org/licenses/LICENSE-2.0 and in each component's source
repository listed above.

---

## Go supplementary libraries (golang.org/x/crypto, golang.org/x/net, golang.org/x/sys)

- **License:** BSD 3-Clause License
- **Copyright:** Copyright 2009 The Go Authors.
- **Source:** https://go.googlesource.com/crypto, https://go.googlesource.com/net, https://go.googlesource.com/sys (`golang.org/x/sys` is compiled into the remote daemon, `daemon/remote`)

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google LLC nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
