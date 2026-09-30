# Representation comparison results

Tokenizer: o200k_base (js-tiktoken). Viewport 1280x800. Versions: {"stagehand":"4.1.0","browser-use":"0.13.10"}.

## Size (tokens) per page

| page | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| index | 219 | 162 | 279 | 248 | 420 | 144 | 185 | 376 | 178 | 373 |
| aria | 555 | 364 | 577 | 555 | 845 | 219 | 463 | 865 | 446 | 761 |
| states | 446 | 283 | 457 | 426 | 715 | 252 | 436 | 761 | 478 | 784 |
| frames | 129 | 119 | 131 | 129 | 291 | 46 | 44 | 181 | 108 | 170 |
| frame-inner | 62 | 62 | 64 | 78 | 168 | 23 | 12 | 90 | 32 | 51 |
| shadow | 104 | 75 | 106 | 120 | 202 | 23 | 46 | 146 | 41 | 103 |
| surface | 211 | 179 | 237 | 223 | 357 | 111 | 122 | 337 | 216 | 337 |
| dynamic | 143 | 127 | 145 | 159 | 247 | 90 | 70 | 201 | 95 | 145 |
| input | 434 | 141 | 211 | 225 | 509 | 161 | 312 | 567 | 284 | 568 |
| dialogs | 91 | 85 | 92 | 106 | 182 | 43 | 27 | 125 | 49 | 93 |
| files | 89 | 83 | 113 | 117 | 210 | 51 | 46 | 165 | 159 | 136 |
| nest | 170 | 136 | 116 | 100 | 269 | 47 | 75 | 210 | 166 | 187 |
| wikipedia | 19k | 9.1k | 20k | 18k | 33k | 2.5k | 43k | 56k | 4.2k | 38k |
| hn | 3.9k | 2.9k | 4.2k | 3.8k | 6.9k | 3.8k | 11k | 15k | 5.7k | 9.0k |
| github | 18k | 9.2k | 18k | 17k | 144k | 4.2k | 39k | 57k | 9.3k | 33k |
| mdn | 1.0k | 749 | 4.1k | 2.3k | 1.9k | 769 | 1.8k | 3.0k | 1.1k | 1.9k |
| amazon | 19k | 12k | 21k | 17k | 22k | 10k | 129k | 148k | 8.6k | 35k |
| vercel | 2.0k | 1.4k | 3.7k (redirected) | 3.4k (redirected) | 678 | 229 | 2.8k | 5.9k | 353 | 711 |
| amazon-frozen | 18k | 12k | 21k | 16k | 24k | 10.0k | 128k | 149k | 8.6k | 35k |
| **fixtures total** (index, aria, states, frames, frame-inner, shadow, surface, d) | 2.7k | 1.8k | 2.5k | 2.5k | 4.4k | 1.2k | 1.8k | 4.0k | 2.3k | 3.7k |
| **live total** (wikipedia, hn, github, mdn, amazon) | 60k | 34k | 68k | 58k | 208k | 21k | 224k | 278k | 29k | 117k |

## Tokens per addressable visible element (common live pages)

| set | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| wikipedia, hn, github, mdn, amazon | 34.7 | 19.9 | 40.3 | 34.5 | 117.6 | 60.3 | n/a | 159.0 | 44.0 | 68.1 |

## Addressable interactive recall (lenient; strict in parentheses)

| page | GT | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| index | 9 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 78% (78%) | 0% (0%) | 100% (100%) | 78% (67%) | 100% (100%) |
| aria | 22 | 100% (100%) | 100% (100%) | 91% (91%) | 91% (91%) | 100% (100%) | 55% (55%) | 0% (0%) | 95% (95%) | 100% (82%) | 95% (95%) |
| states | 15 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 67% (67%) | 0% (0%) | 100% (100%) | 100% (93%) | 100% (100%) |
| frames | 4 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| frame-inner | 2 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| shadow | 2 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| surface | 8 | 100% (100%) | 100% (100%) | 88% (88%) | 88% (88%) | 88% (88%) | 75% (75%) | 0% (0%) | 88% (88%) | 100% (63%) | 100% (100%) |
| dynamic | 8 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| input | 7 | 100% (100%) | 100% (100%) | 86% (86%) | 86% (86%) | 86% (86%) | 100% (100%) | 0% (0%) | 100% (100%) | 86% (86%) | 86% (86%) |
| dialogs | 4 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| files | 4 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 50% (50%) | 0% (0%) | 100% (100%) | 100% (75%) | 100% (100%) |
| nest | 5 | 100% (100%) | 100% (100%) | 60% (60%) | 60% (60%) | 80% (80%) | 80% (80%) | 0% (0%) | 80% (80%) | 100% (100%) | 60% (60%) |
| wikipedia | 671 | 100% (100%) | 100% (100%) | 99% (99%) | 99% (99%) | 100% (100%) | 15% (15%) | 0% (0%) | 98% (98%) | 20% (20%) | 100% (100%) |
| hn | 197 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 71% (71%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| github | 486 | 100% (100%) | 100% (100%) | 97% (97%) | 98% (97%) | 100% (100%) | 12% (12%) | 0% (0%) | 100% (100%) | 40% (40%) | 100% (100%) |
| mdn | 51 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 55% (55%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| amazon | 421 | 84% (83%) | 83% (83%) | 76% (76%) | 76% (76%) | 93% (93%) | 7% (7%) | 0% (0%) | 92% (92%) | 21% (21%) | 81% (81%) |
| vercel | 17 | 76% (76%) | 76% (76%) | 6% (6%) (redirected) | 6% (6%) (redirected) | 65% (65%) | 65% (65%) | 0% (0%) | 76% (76%) | 65% (65%) | 65% (65%) |
| amazon-frozen | 458 | 92% (92%) | 91% (91%) | 85% (85%) | 85% (85%) | 92% (92%) | 7% (7%) | 0% (0%) | 92% (92%) | 21% (21%) | 92% (92%) |
| **fixtures (micro)** |  | 100% (100%) | 100% (100%) | 93% (93%) | 93% (93%) | 97% (97%) | 76% (76%) | 0% (0%) | 97% (97%) | 97% (86%) | 96% (96%) |
| **live (micro)** |  | 95% (95%) | 95% (95%) | 92% (91%) | 92% (92%) | 97% (97%) | 18% (18%) | 0% (0%) | 96% (96%) | 34% (33%) | 95% (95%) |

## In-viewport recall (lenient)

| set | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| fixtures | 100% | 100% | 93% | 93% | 96% | 80% | 0% | 96% | 98% | 96% |
| live | 99% | 99% | 96% | 97% | 99% | 78% | 0% | 99% | 94% | 97% |

## Precision and hidden-content leaks

Cell: leaked interactive items / interactive items emitted (+ hidden items the tool flags as hidden), leaked hidden texts / hidden texts on the page.

| page | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| index | 0/9, 0/0 | 0/9, 0/0 | 0/9, 0/0 | 0/9, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/0, 0/0 | 0/9, 0/0 | 0/7, 0/0 | 0/11, 0/0 |
| aria | 0/19, 0/4 | 0/19, 0/4 | 0/18, 0/4 | 0/18, 0/4 | 0/19, 0/4 | 0/16, 1/4 | 0/0, 0/4 | 0/17, 0/4 | 0/19, 0/4 | 0/17, 0/4 |
| states | 0/16, 0/0 | 0/16, 0/0 | 0/16, 0/0 | 0/16, 0/0 | 0/12, 0/0 | 0/17, 0/0 | 0/0, 0/0 | 0/18, 0/0 | 0/18, 0/0 | 0/20, 0/0 |
| frames | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 |
| frame-inner | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/0, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 |
| shadow | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/0, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 |
| surface | 0/8, 0/1 | 0/8, 0/1 | 0/7, 0/1 | 0/7, 0/1 | 0/8, 0/1 | 0/8, 1/1 | 0/0, 0/1 | 0/7, 0/1 | 0/8, 0/1 | 0/7, 0/1 |
| dynamic | 0/8, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/0, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/8, 0/0 |
| input | 0/6, 0/0 | 0/6, 0/0 | 0/6, 0/0 | 0/6, 0/0 | 0/5, 0/0 | 0/5, 0/0 | 0/0, 0/0 | 0/5, 0/0 | 0/5, 0/0 | 0/5, 0/0 |
| dialogs | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 |
| files | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/5, 0/0 | 0/2, 0/0 |
| nest | 0/5, 0/0 | 0/5, 0/0 | 0/3, 0/0 | 0/3, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/5, 0/0 | 0/3, 0/0 |
| wikipedia | 3/698, 2/107 | 3/698, 2/107 | 3/702, 2/107 | 3/697, 2/107 | 3/700, 3/107 | 0/101, 0/107 | 0/0, 3/107 | 4/682, 3/107 | 0/147, 1/107 | 3/700, 2/107 |
| hn | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 | 0/163, 0/0 | 0/0, 0/0 | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 |
| github | 28/607, 5/78 | 28/607, 5/78 | 30/583, 5/78 | 30/582, 5/78 | 30/614, 7/78 | 1/63, 3/78 | 0/0, 7/78 | 27/612, 7/78 | 3/208, 4/78 | 28/614, 7/78 |
| mdn | 1/56, 0/57 | 1/56, 0/57 | 81/147, 57/57 | 81/147, 57/57 | 2/56, 0/57 | 0/32, 0/57 | 0/0, 1/57 | 1/56, 1/57 | 1/55, 0/57 | 1/56, 0/57 |
| amazon | 45/524, 17/119 | 45/524, 16/119 | 47/558, 14/119 | 47/553, 14/119 | 42/494, 64/119 | 17/55, 7/119 | 0/0, 66/119 | 28/608, 66/119 | 37/156, 10/119 | 44/592, 59/119 |
| vercel | 3/103, 0/5 | 3/103, 0/5 | 0/181, 0/5 (redirected) | 0/181, 0/5 (redirected) | 0/12, 0/5 | 0/11, 0/5 | 0/0, 0/5 | 0/98, 0/5 | 0/11, 1/5 | 0/12, 0/5 |
| amazon-frozen | 44/523, 24/123 | 44/523, 20/123 | 46/559, 22/123 | 46/554, 22/123 | 44/525, 65/123 | 16/59, 7/123 | 0/0, 67/123 | 30/651, 67/123 | 38/156, 12/123 | 46/594, 63/123 |

## Structure probes

| probe | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| frames: frames-both | yes | yes | yes | yes | yes | yes | **no** | yes | yes | yes |
| frames: frame-nested-srcdoc | yes | yes | yes | yes | **no** | yes | **no** | yes | yes | **no** |
| frames: frame-deep | yes | yes | **no** | **no** | yes | yes | **no** | yes | yes | **no** |
| frames: frame-srcdoc | yes | yes | yes | yes | yes | yes | **no** | yes | yes | yes |
| links: link-target | **no** | **no** | **no** | **no** | yes | yes | yes | yes | **no** | **no** |
| security: hidden-details | yes | yes | yes | yes | yes | **no** | yes | yes | yes | yes |
| security: password | yes | yes | yes | yes | yes | yes | **no** | **no** | yes | yes |
| shadow: shadow-open | yes | yes | yes | yes | yes | yes | **no** | yes | yes | yes |
| shadow: shadow-closed | yes | yes | **no** | **no** | **no** | **no** | **no** | **no** | yes | **no** |
| states: value | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| states: placeholder | yes | yes | yes | yes | **no** | **no** | yes | yes | **no** | **no** |
| states: select-options | **no** | **no** | yes | yes | yes | yes | yes | yes | yes | yes |
| states: checked | yes | yes | yes | yes | yes | **no** | yes | yes | **no** | yes |
| states: expanded | yes | yes | **no** | **no** | yes | **no** | **no** | **no** | yes | **no** |
| states: selected | yes | yes | yes | yes | yes | **no** | yes | yes | yes | yes |
| states: pressed | yes | yes | **no** | **no** | yes | **no** | yes | yes | yes | **no** |
| states: slider-value | yes | yes | yes | yes | yes | yes | yes | yes | yes | **no** |
| states: mixed | yes | yes | **no** | **no** | yes | **no** | yes | yes | **no** | **no** |
| states: required | yes | yes | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** |
| states: invalid | yes | yes | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** |
| states: readonly | yes | yes | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** |
| states: disabled | yes | yes | yes | yes | yes | yes | yes | yes | **no** | **no** |
| structure: list | yes | **no** | yes | **no** | **no** | **no** | yes | yes | **no** | **no** |
| structure: heading-level | yes | **no** | yes | yes | yes | **no** | yes | yes | **no** | **no** |
| structure: heading-role | yes | **no** | yes | yes | yes | **no** | yes | yes | **no** | yes |
| structure: landmark-nav | yes | yes | yes | yes | **no** | **no** | yes | yes | **no** | yes |
| structure: landmark-main | yes | **no** | yes | yes | **no** | **no** | yes | yes | **no** | yes |
| structure: landmark-footer | yes | **no** | yes | yes | **no** | **no** | yes | yes | **no** | yes |
| structure: table | yes | **no** | yes | **no** | yes | **no** | yes | yes | **no** | yes |
| structure: table-cell | yes | **no** | **no** | **no** | **no** | **no** | yes | yes | yes | yes |
| structure: dialog | yes | yes | yes | yes | yes | **no** | yes | yes | **no** | yes |
| structure: alert | yes | **no** | yes | yes | **no** | **no** | yes | yes | **no** | **no** |
| structure: table-header | **no** | **no** | **no** | **no** | **no** | **no** | yes | yes | **no** | yes |
| widgets: onclick-div | yes | yes | yes | yes | yes | **no** | **no** | yes | yes | yes |
| widgets: contenteditable | yes | yes | yes | yes | **no** | yes | **no** | **no** | yes | **no** |
| widgets: scrollable | yes | yes | **no** | **no** | yes | yes | yes | yes | yes | yes |
| **passed** | 33/36 | 25/36 | 24/36 | 22/36 | 22/36 | 13/36 | 23/36 | 29/36 | 18/36 | 19/36 |

## Change reporting (small form page)

| tool | output after action | full | shown/full | value | checked | focus |
| --- | --- | --- | --- | --- | --- | --- |
| cmux | diff | 608 B | 63% | yes | yes | yes |
| cmux-i | diff | 456 B | 100% | yes | yes | yes |
| aside | diff | 827 B | 32% | yes | yes | yes |
| aside-i | diff | 727 B | 32% | yes | yes | yes |
| chatgpt-ax | diff | 1.2k B | 100% | no | yes | yes |
| chatgpt-dom | full | 503 B | 100% | no | no | no |
| chatgpt-pw | full | 617 B | 100% | yes | yes | yes |
| pw-mcp | diff | 1.2k B | 61% | yes | yes | yes |
| browser-use | full | 588 B | 100% | yes | yes | no |
| stagehand | full | 1.2k B | 100% | yes | yes | no |

## Change reporting (big page, ~300 elements)

| tool | output after action | full | shown/full | value | checked | focus |
| --- | --- | --- | --- | --- | --- | --- |
| cmux | diff | 12k B | 3% | yes | yes | yes |
| cmux-i | diff | 5.2k B | 6% | yes | yes | yes |
| aside | diff | 8.2k B | 3% | yes | yes | yes |
| aside-i | diff | 7.8k B | 3% | yes | yes | yes |
| chatgpt-ax | diff | 18k B | 2% | no | yes | yes |
| chatgpt-dom | full | 4.1k B | 100% | no | no | no |
| chatgpt-pw | full | 18k B | 100% | yes | yes | yes |
| pw-mcp | diff | 27k B | 2% | yes | yes | yes |
| browser-use | full | 11k B | 100% | yes | yes | no |
| stagehand | full | 19k B | 100% | yes | yes | no |

## Ref stability

| tool | before | after | survivors keep ref | removed ref reused | old refs after new snapshot |
| --- | --- | --- | --- | --- | --- |
| cmux | Alpha=e1, Beta=e2, Out=e3 | Zero=e4, Minus=e5, Beta renamed=e2, Out=e3 | yes | no | Alpha: ref e1 is stale: the element was removed; take a n; Beta: "Beta renamed"; Out: "Out" |
| cmux-i | Alpha=e1, Beta=e2, Out=e3 | Zero=e4, Minus=e5, Beta renamed=e2, Out=e3 | yes | no | - |
| aside | Alpha=e2, Beta=e4, Out=e5 | Zero=e7, Minus=e9, Beta renamed=e11, Out=e5 | **no** | no | Alpha: Ref "e1" is stale — the element was removed or the; Beta: Ref "e3" is stale — the element was removed or the; Out: "Out" |
| aside-i | Alpha=e2, Beta=e4, Out=e5 | Zero=e7, Minus=e9, Beta renamed=e11, Out=e5 | **no** | no | - |
| chatgpt-ax | Alpha=4, Beta=7, Out=8 | Zero=11, Minus=14, Beta renamed=7, Out=8 | yes | no | - |
| chatgpt-dom | Alpha=1, Beta=2, Out=3 | Zero=4, Minus=5, Beta renamed=2, Out=3 | yes | no | - |
| chatgpt-pw | Alpha=none, Beta=none, Out=none | Zero=none, Minus=none, Beta renamed=none, Out=none | no refs | - | - |
| pw-mcp | Alpha=e4, Beta=e6, Out=e7 | Zero=e9, Minus=e11, Beta renamed=e12, Out=e7 | **no** | no | Alpha: locator.textContent: Timeout 1500ms exceeded.; Beta: locator.textContent: Timeout 1500ms exceeded.; Out: "Out" |
| browser-use | Alpha=20, Beta=24, Out=11 | Zero=29, Minus=31, Beta renamed=24, Out=11 | yes | no | - |
| stagehand | Alpha=0-20, Beta=0-24, Out=0-26 | Zero=0-30, Minus=0-32, Beta renamed=0-24, Out=0-26 | yes | no | - |
