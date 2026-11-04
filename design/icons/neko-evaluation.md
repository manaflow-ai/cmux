# Neko icon family: licence and quality rounds

Leo asked for an optional neko family and set the bar clearly: “well i guess it's a future hill
climbing thing... but we just want the GOOD ones”. This round keeps the family opt-in and only ships
drawings that preserve the shared 1x/2x line weight, spacing and light/dark contrast.

The earlier `teamleaderleo/idlesse` and `teamleaderleo/ourchival` attempts were not available in this
lane's authorized checkout or reference attachments. The evaluation therefore does not invent a taste
brief for them; it uses the checked-in icon spec's cat rule (one small natural cue, never on status,
error, destructive or security marks) and Leo's explicit quality bar. The next art round should add
those references before proposing more fill-ins.

## Rounds

| Round | Set | Coverage | Action row | Spinner/status | 1x/2x light + dark judgement | Decision |
| --- | --- | ---: | ---: | ---: | --- | --- |
| 0 | Shared cmux pack | 0/331 neko drawings | 0/6 | shared token | 10/10 baseline; no neko cue | Comparison baseline |
| 1 | Existing authored Cat accents | 38/331 (11.5%) | 0/6 | 0/1, 0/6 | 8.4/10; coherent where the noun has a natural frame or tail, too sparse for an action theme | Gallery only |
| 2 | Neko curated (Cat accents + authored `copy` and `pin`) | 40/331 (12.1%) | 2/6 | 0/1, 0/6 | 8.7/10 at 1x and 2x in light and dark; cues stay on frame/top edges and do not alter semantics | Shipped as the optional family |
| 3 | Fluent System Icons (MIT), Lucide (ISC), Fluent Emoji (MIT), oneko.js (MIT) | 0/6 neko drawings | varies | varies | 5.5–7.6/10: useful coverage, but no single set matches cmux's line family and Neko cues | Not shipped; retain as hill-climb candidates |

The gallery entry `agent-pane.neko-icon-family` shows every round in light and dark. Round 2 is the
current pick; the action row keeps Retry, Speak and More on the shared tokens until matching drawings
clear the same comparison. The working spinner remains the settled `status.running` geometry and is
shown beside the Neko action row so a DEV capture exercises both surfaces without introducing a
mismatched status mark.

## Candidate licence survey

Each licence below was checked in the repository's actual licence file on 2026-11-04. No candidate
artwork is copied into cmux in this round.

| Repository | Actual file | Licence | Action/status coverage | Result |
| --- | --- | --- | --- | --- |
| [microsoft/fluentui-emoji](https://github.com/microsoft/fluentui-emoji/blob/main/LICENSE) | `LICENSE` | MIT | Cat artwork, no shared copy/retry/speak/bookmark/more/spinner family | Candidate for a later coloured set |
| [microsoft/fluentui-system-icons](https://github.com/microsoft/fluentui-system-icons/blob/main/LICENSE) | `LICENSE` | MIT | Broad action and status coverage, no neko treatment | Useful geometry reference, not shipped as Neko |
| [lucide-icons/lucide](https://github.com/lucide-icons/lucide/blob/main/LICENSE) | `LICENSE` | ISC | Broad line action/status coverage and loader, no neko treatment | Useful geometry reference, not shipped as Neko |
| [adryd325/oneko.js](https://github.com/adryd325/oneko.js/blob/main/LICENSE) | `LICENSE` | MIT | Animated desktop cat sprite only; no action/status map | Not an icon family |
| [googlefonts/noto-emoji](https://github.com/googlefonts/noto-emoji/blob/main/LICENSE) | `LICENSE` | OFL-1.1 | Cat glyphs, no action/status map | Excluded by the allowed licence list |
| [samuelmaddock/nekos-best](https://github.com/samuelmaddock/nekos-best) | no root `LICENSE` at the checked branch | unverified | Image API, not a glyph map | Excluded until a licence is verifiable |

Generated Neko geometry is authored in `scripts/icons/build_pack.py`; it is not copied third-party
artwork. If a later round vendors one of the candidates, its complete licence and attribution must be
added to the generated notices before that artwork is enabled.
