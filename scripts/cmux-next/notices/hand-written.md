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

- **Package license:** MIT AND Apache-2.0
- **Herdr-derived material:** Apache License 2.0
- **Source:** https://github.com/herdrdev/herdr
- **Detector source reference:** commit `7b675f42af35508eab66ac42fe1598628597a893`
- **Pi bundled-launcher correction:** commit `b1ff4582e9688f52ffb943cfa8bee4871ae122e4`
- **Manifest snapshot:** commit `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`
- **Included manifest fixes:** Claude MCP elicitation `f807b697353cfa00aa912c7cde4830e863001cf5`, Claude background-shell state `987b070fbfa187e85009b45cd7e208fc6175ff6a`, Codex weak-blocker scope `f457cff4f2648eee85d176f8a41861241d4e8428`, and Copilot background-agent activity `2290257acb2085ce6842ba5c7e3ca50c3ba64f02`
- **License text:** cmux-owned code is covered by
  `cmux-tui/bindings/examples/rust-agent-screen-detection/LICENSE-MIT`; the
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
code adapted from executor in the MIT package `libs/integrations-core/`
(`@cmux/integrations-core`). The `cmux/integrations` app bundles that package
into `first-party-apps/integrations/dist/main.js`.

- **License:** MIT License
- **Copyright:** Copyright (c) 2026 Rhys Sullivan
- **Source:** https://github.com/UsefulSoftwareCo/executor (commit `98d606bd2b47b9dcc2c03a129a14b5134d9852c8`)
- **License text and adapted-file list:** `libs/integrations-core/LICENSE` and
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
  `Iroh.framework`
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
