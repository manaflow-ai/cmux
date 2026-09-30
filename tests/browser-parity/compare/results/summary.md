# Representation comparison results

Tokenizer: o200k_base (js-tiktoken). Viewport 1280x800. Versions: {"stagehand":"4.1.0","browser-use":"0.13.10"}.

## Size (tokens) per page

| page | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | chatgpt-live-ax | chatgpt-live-dom | chatgpt-live-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| index | 228 | 193 | 279 | 248 | 420 | 144 | 185 | 457 | 136 | 191 | 376 | 178 | 373 |
| aria | 557 | 456 | 577 | 555 | 845 | 219 | 463 | 890 | 266 | 463 | 865 | 446 | 761 |
| states | 439 | 315 | 457 | 426 | 715 | 252 | 436 | 751 | 258 | 437 | 761 | 478 | 784 |
| frames | 129 | 129 | 131 | 129 | 291 | 46 | 44 | 320 | 46 | 52 | 181 | 108 | 170 |
| frame-inner | 62 | 62 | 64 | 78 | 168 | 23 | 12 | 190 | 23 | 12 | 90 | 32 | 51 |
| shadow | 104 | 98 | 106 | 120 | 202 | 23 | 46 | 224 | 23 | 46 | 146 | 41 | 103 |
| surface | 211 | 189 | 237 | 223 | 357 | 111 | 122 | 380 | 107 | 130 | 337 | 216 | 337 |
| dynamic | 143 | 137 | 145 | 159 | 247 | 90 | 70 | 276 | 90 | 70 | 201 | 95 | 145 |
| input | 434 | 151 | 211 | 225 | 509 | 161 | 312 | 531 | 161 | 312 | 567 | 284 | 568 |
| dialogs | 91 | 85 | 92 | 106 | 182 | 43 | 27 | 204 | 43 | 27 | 125 | 49 | 93 |
| files | 89 | 83 | 113 | 117 | 210 | 51 | 46 | 239 | 51 | 46 | 165 | 159 | 136 |
| nest | 170 | 146 | 116 | 100 | 269 | 47 | 75 | 304 | 47 | 95 | 210 | 166 | 187 |
| corpus-bbc | 4.4k | 3.9k | 4.0k | 2.8k | 5.3k | 975 | 7.9k | 5.3k | 1.3k | 8.6k | 12k | 1.6k | 9.8k |
| corpus-books | 3.3k | 2.1k | 4.4k | 3.3k | 5.3k | 1.3k | 5.7k | 5.3k | 2.1k | 5.8k | 8.9k | 1.3k | 5.2k |
| corpus-github | 17k | 9.8k | 18k | 16k | 38k | 4.7k | 41k | 38k | 5.8k | 41k | 58k | 8.9k | 33k |
| corpus-hackernews | 3.3k | 2.9k | 4.3k | 3.9k | 7.0k | 5.0k | 12k | 7.0k | 6.1k | 12k | 17k | 5.8k | 9.1k |
| corpus-mdn-iframe | 11k | 6.2k | 15k | 11k | 14k | 4.2k | 23k | 14k | 4.5k | 23k | 34k | 1.5k | 28k |
| corpus-mdn | 5.4k | 3.6k | 7.7k | 5.4k | 7.1k | 3.9k | 11k | 7.1k | 4.2k | 11k | 17k | 1.4k | 12k |
| corpus-npr | 686 | 638 | 1.3k | 695 | 1.1k | 507 | 1.0k | 1.1k | 712 | 1.0k | 1.7k | 520 | 1.1k |
| corpus-vercel | 2.0k | 1.6k | 3.2k | 1.9k | 564 | 277 | 3.1k | 701 | 277 | 3.2k | 6.2k | 374 | 671 |
| corpus-wikipedia | 18k | 9.9k | 20k | 18k | 33k | 2.8k | 44k | 33k | 3.4k | 44k | 55k | 4.2k | 37k |
| wikipedia | 19k | 9.8k | 20k | 18k | 33k | 2.5k | 43k | n/a | n/a | n/a | 56k | 4.2k | 38k |
| hn | 3.3k | 2.9k | 4.2k | 3.8k | 6.9k | 3.9k | 11k | n/a | n/a | n/a | 15k | 5.7k | 9.0k |
| github | 17k | 9.8k | 18k | 17k | 144k | 4.2k | 39k | n/a | n/a | n/a | 57k | 9.3k | 33k |
| mdn | 1.2k | 1.0k | 4.1k | 2.3k | 1.9k | 765 | 1.7k | n/a | n/a | n/a | 3.0k | 1.1k | 1.4k |
| amazon | 135 (blocked) | 135 (blocked) | 21k | 16k | 22k | 9.9k | 114k | n/a | n/a | n/a | 132k | 10k | 32k |
| vercel | 2.0k | 1.6k | 3.7k (redirected) | 3.4k (redirected) | 678 | 229 | 2.8k | n/a | n/a | n/a | 5.9k | 353 | 711 |
| amazon-frozen | 19k | 14k | 21k | 16k | 24k | 9.9k | 128k | n/a | n/a | n/a | 148k | 8.6k | 34k |
| **fixtures total** (index, aria, states, frames, frame-inner, shadow, surface, d) | 2.7k | 2.0k | 2.5k | 2.5k | 4.4k | 1.2k | 1.8k | 4.8k | 1.3k | 1.9k | 4.0k | 2.3k | 3.7k |
| **corpus total** (corpus-bbc, corpus-books, corpus-github, corpus-hackernews, ) | 66k | 41k | 77k | 63k | 111k | 24k | 149k | 111k | 28k | 150k | 211k | 25k | 136k |
| **live total** (wikipedia, hn, github, mdn, amazon-frozen) | 59k | 37k | 68k | 58k | 210k | 21k | 223k | n/a | n/a | n/a | 279k | 29k | 116k |

## Tokens per addressable visible element (common live pages)

| set | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | chatgpt-live-ax | chatgpt-live-dom | chatgpt-live-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| wikipedia, hn, github, mdn, amazon-frozen | 33.0 | 20.8 | 38.9 | 33.3 | 117.0 | 59.1 | n/a | n/a | n/a | n/a | 156.8 | 43.5 | 64.8 |

## Addressable interactive recall (lenient; strict in parentheses)

| page | GT | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | chatgpt-live-ax | chatgpt-live-dom | chatgpt-live-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| index | 9 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 78% (78%) | 0% (0%) | 100% (100%) | 78% (78%) | 0% (0%) | 100% (100%) | 78% (67%) | 100% (100%) |
| aria | 22 | 100% (100%) | 100% (100%) | 91% (91%) | 91% (91%) | 100% (100%) | 55% (55%) | 0% (0%) | 100% (100%) | 73% (73%) | 0% (0%) | 95% (95%) | 100% (82%) | 95% (95%) |
| states | 15 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 67% (67%) | 0% (0%) | 100% (100%) | 67% (67%) | 0% (0%) | 100% (100%) | 100% (93%) | 100% (100%) |
| frames | 4 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| frame-inner | 2 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| shadow | 2 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| surface | 8 | 100% (100%) | 100% (100%) | 88% (88%) | 88% (88%) | 88% (88%) | 75% (75%) | 0% (0%) | 88% (88%) | 75% (75%) | 0% (0%) | 88% (88%) | 100% (63%) | 100% (100%) |
| dynamic | 8 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| input | 7 | 100% (100%) | 100% (100%) | 86% (86%) | 86% (86%) | 86% (86%) | 100% (100%) | 0% (0%) | 86% (86%) | 100% (100%) | 0% (0%) | 100% (100%) | 86% (86%) | 86% (86%) |
| dialogs | 4 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| files | 4 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 50% (50%) | 0% (0%) | 100% (100%) | 50% (50%) | 0% (0%) | 100% (100%) | 100% (75%) | 100% (100%) |
| nest | 5 | 100% (100%) | 100% (100%) | 60% (60%) | 60% (60%) | 80% (80%) | 80% (80%) | 0% (0%) | 80% (80%) | 80% (80%) | 0% (0%) | 80% (80%) | 100% (100%) | 60% (60%) |
| corpus-bbc | 121 | 99% (99%) | 99% (99%) | 100% (100%) | 92% (92%) | 99% (99%) | 31% (31%) | 0% (0%) | 99% (99%) | 36% (36%) | 0% (0%) | 100% (100%) | 41% (40%) | 100% (100%) |
| corpus-books | 114 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 37% (37%) | 0% (0%) | 100% (100%) | 56% (56%) | 0% (0%) | 100% (100%) | 82% (82%) | 100% (100%) |
| corpus-github | 487 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 21% (21%) | 0% (0%) | 100% (100%) | 21% (21%) | 0% (0%) | 100% (100%) | 40% (40%) | 100% (100%) |
| corpus-hackernews | 197 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 71% (71%) | 0% (0%) | 100% (100%) | 87% (87%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| corpus-mdn-iframe | 455 | 99% (99%) | 99% (99%) | 98% (98%) | 98% (98%) | 100% (100%) | 29% (29%) | 0% (0%) | 100% (100%) | 31% (31%) | 0% (0%) | 98% (98%) | 19% (18%) | 100% (100%) |
| corpus-mdn | 247 | 100% (100%) | 100% (100%) | 96% (96%) | 96% (96%) | 100% (100%) | 50% (50%) | 0% (0%) | 100% (100%) | 54% (54%) | 0% (0%) | 96% (96%) | 32% (30%) | 100% (100%) |
| corpus-npr | 28 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 46% (46%) | 0% (0%) | 100% (100%) | 68% (68%) | 0% (0%) | 100% (100%) | 100% (100%) | 100% (100%) |
| corpus-vercel | 15 | 87% (87%) | 87% (87%) | 87% (87%) | 87% (87%) | 73% (73%) | 73% (73%) | 0% (0%) | 73% (73%) | 73% (73%) | 0% (0%) | 87% (87%) | 73% (73%) | 73% (73%) |
| corpus-wikipedia | 582 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 17% (17%) | 0% (0%) | 100% (100%) | 20% (20%) | 0% (0%) | 97% (97%) | 23% (22%) | 100% (100%) |
| wikipedia | 671 | 100% (100%) | 100% (100%) | 99% (99%) | 99% (99%) | 100% (100%) | 15% (15%) | 0% (0%) | - | - | - | 98% (98%) | 21% (20%) | 100% (100%) |
| hn | 197 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 72% (72%) | 0% (0%) | - | - | - | 100% (100%) | 100% (100%) | 100% (100%) |
| github | 489 | 100% (100%) | 100% (100%) | 98% (97%) | 98% (97%) | 100% (100%) | 12% (12%) | 0% (0%) | - | - | - | 100% (100%) | 40% (40%) | 100% (100%) |
| mdn | 51 | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 100% (100%) | 55% (55%) | 0% (0%) | - | - | - | 100% (100%) | 100% (100%) | 84% (84%) |
| amazon | 414 | 0% (0%) (blocked) | 0% (0%) (blocked) | 82% (82%) | 82% (82%) | 93% (93%) | 8% (8%) | 0% (0%) | - | - | - | 92% (92%) | 24% (24%) | 83% (83%) |
| vercel | 17 | 76% (76%) | 76% (76%) | 6% (6%) (redirected) | 6% (6%) (redirected) | 65% (65%) | 65% (65%) | 0% (0%) | - | - | - | 76% (76%) | 65% (65%) | 65% (65%) |
| amazon-frozen | 453 | 92% (92%) | 91% (91%) | 85% (85%) | 85% (85%) | 92% (92%) | 7% (7%) | 0% (0%) | - | - | - | 92% (92%) | 21% (21%) | 92% (92%) |
| **fixtures (micro)** |  | 100% (100%) | 100% (100%) | 93% (93%) | 93% (93%) | 97% (97%) | 76% (76%) | 0% (0%) | 97% (97%) | 80% (80%) | 0% (0%) | 97% (97%) | 97% (86%) | 96% (96%) |
| **corpus (micro)** |  | 100% (100%) | 100% (100%) | 99% (99%) | 99% (99%) | 100% (100%) | 31% (31%) | 0% (0%) | 100% (100%) | 36% (36%) | 0% (0%) | 98% (98%) | 39% (38%) | 100% (100%) |
| **live (micro)** |  | 98% (98%) | 98% (98%) | 93% (93%) | 93% (93%) | 97% (97%) | 18% (18%) | 0% (0%) | n/a (n/a) | n/a (n/a) | n/a (n/a) | 96% (96%) | 34% (34%) | 95% (95%) |

## In-viewport recall (lenient)

| set | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | chatgpt-live-ax | chatgpt-live-dom | chatgpt-live-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| fixtures | 100% | 100% | 93% | 93% | 96% | 80% | 0% | 96% | 80% | 0% | 96% | 98% | 96% |
| corpus | 100% | 99% | 99% | 99% | 100% | 98% | 0% | 100% | 96% | 0% | 99% | 76% | 100% |
| live | 99% | 99% | 96% | 97% | 99% | 79% | 0% | n/a | n/a | n/a | 99% | 94% | 97% |

## Precision and hidden-content leaks

Cell: leaked interactive items / interactive items emitted (+ hidden items the tool flags as hidden), leaked hidden texts / hidden texts on the page.

| page | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | chatgpt-live-ax | chatgpt-live-dom | chatgpt-live-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| index | 0/9, 0/0 | 0/9, 0/0 | 0/9, 0/0 | 0/9, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/0, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/0, 0/0 | 0/9, 0/0 | 0/7, 0/0 | 0/11, 0/0 |
| aria | 0/19, 0/4 | 0/19, 0/4 | 0/18, 0/4 | 0/18, 0/4 | 0/19, 0/4 | 0/16, 1/4 | 0/0, 0/4 | 0/19, 0/4 | 0/18, 1/4 | 0/0, 0/4 | 0/17, 0/4 | 0/19, 0/4 | 0/17, 0/4 |
| states | 0/16, 0/0 | 0/16, 0/0 | 0/16, 0/0 | 0/16, 0/0 | 0/12, 0/0 | 0/17, 0/0 | 0/0, 0/0 | 0/12, 0/0 | 0/17, 0/0 | 0/0, 0/0 | 0/18, 0/0 | 0/18, 0/0 | 0/20, 0/0 |
| frames | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 |
| frame-inner | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/0, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/0, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 |
| shadow | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/0, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/0, 0/0 | 0/2, 0/0 | 0/2, 0/0 | 0/2, 0/0 |
| surface | 0/8, 0/1 | 0/8, 0/1 | 0/7, 0/1 | 0/7, 0/1 | 0/8, 0/1 | 0/8, 1/1 | 0/0, 0/1 | 0/8, 0/1 | 0/8, 1/1 | 0/0, 0/1 | 0/7, 0/1 | 0/8, 0/1 | 0/7, 0/1 |
| dynamic | 0/8, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/0, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/0, 0/0 | 0/8, 0/0 | 0/8, 0/0 | 0/8, 0/0 |
| input | 0/6, 0/0 | 0/6, 0/0 | 0/6, 0/0 | 0/6, 0/0 | 0/5, 0/0 | 0/5, 0/0 | 0/0, 0/0 | 0/5, 0/0 | 0/5, 0/0 | 0/0, 0/0 | 0/5, 0/0 | 0/5, 0/0 | 0/5, 0/0 |
| dialogs | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 |
| files | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/5, 0/0 | 0/2, 0/0 |
| nest | 0/5, 0/0 | 0/5, 0/0 | 0/3, 0/0 | 0/3, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/4, 0/0 | 0/0, 0/0 | 0/4, 0/0 | 0/5, 0/0 | 0/3, 0/0 |
| corpus-bbc | 2/127, 1/49 | 2/127, 1/49 | 4/127, 1/49 | 4/127, 1/49 | 3/126, 1/49 | 0/38, 1/49 | 0/0, 1/49 | 3/126, 1/49 | 0/44, 1/49 | 0/0, 1/49 | 3/127, 1/49 | 0/51, 0/49 | 4/127, 1/49 |
| corpus-books | 0/114, 0/0 | 0/114, 0/0 | 0/114, 0/0 | 0/114, 0/0 | 0/114, 0/0 | 0/42, 0/0 | 0/0, 0/0 | 0/114, 0/0 | 0/64, 0/0 | 0/0, 0/0 | 0/114, 0/0 | 0/93, 0/0 | 0/114, 0/0 |
| corpus-github | 0/537, 5/78 | 0/537, 5/78 | 28/556, 5/78 | 28/556, 5/78 | 29/614, 7/78 | 1/105, 3/78 | 0/0, 7/78 | 29/614, 7/78 | 2/107, 3/78 | 0/0, 7/78 | 28/612, 7/78 | 3/208, 4/78 | 28/614, 7/78 |
| corpus-hackernews | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 | 0/163, 0/0 | 0/0, 0/0 | 0/229, 0/0 | 0/200, 0/0 | 0/0, 0/0 | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 |
| corpus-mdn-iframe | 0/458, 0/48 | 0/458, 0/48 | 0/454, 3/48 | 0/453, 3/48 | 0/463, 0/48 | 0/140, 6/48 | 0/0, 1/48 | 0/463, 0/48 | 0/149, 6/48 | 0/0, 1/48 | 0/463, 1/48 | 0/89, 0/48 | 0/469, 0/48 |
| corpus-mdn | 0/250, 0/10 | 0/250, 0/10 | 0/242, 2/10 | 0/242, 2/10 | 0/251, 0/10 | 0/128, 2/10 | 0/0, 0/10 | 0/251, 0/10 | 0/138, 2/10 | 0/0, 0/10 | 0/241, 0/10 | 0/90, 0/10 | 0/241, 0/10 |
| corpus-npr | 0/28, 0/0 | 0/28, 0/0 | 0/29, 0/0 | 0/28, 0/0 | 0/31, 0/0 | 0/13, 0/0 | 0/0, 0/0 | 0/31, 0/0 | 0/19, 0/0 | 0/0, 0/0 | 0/29, 0/0 | 0/28, 0/0 | 0/30, 0/0 |
| corpus-vercel | 3/103, 3/15 | 3/103, 3/15 | 3/101, 3/15 | 3/101, 3/15 | 0/12, 0/15 | 0/11, 0/15 | 0/0, 8/15 | 0/12, 0/15 | 0/11, 0/15 | 0/0, 8/15 | 0/98, 8/15 | 0/11, 0/15 | 0/12, 0/15 |
| corpus-wikipedia | 84/698, 2/107 | 84/698, 2/107 | 83/702, 2/107 | 83/697, 2/107 | 83/700, 3/107 | 0/101, 0/107 | 0/0, 3/107 | 83/700, 3/107 | 0/119, 0/107 | 0/0, 3/107 | 4/581, 3/107 | 0/147, 1/107 | 83/700, 2/107 |
| wikipedia | 3/698, 2/107 | 3/698, 2/107 | 3/710, 2/107 | 3/705, 2/107 | 3/700, 3/107 | 0/101, 0/107 | 0/0, 3/107 | - | - | - | 4/682, 3/107 | 0/147, 1/107 | 3/700, 2/107 |
| hn | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 | 0/164, 0/0 | 0/0, 0/0 | - | - | - | 0/229, 0/0 | 0/229, 0/0 | 0/229, 0/0 |
| github | 0/540, 5/78 | 0/540, 5/78 | 30/585, 5/78 | 30/584, 5/78 | 30/616, 7/78 | 1/63, 3/78 | 0/0, 7/78 | - | - | - | 27/614, 7/78 | 3/210, 4/78 | 28/616, 7/78 |
| mdn | 2/56, 0/57 | 2/56, 0/57 | 81/147, 57/57 | 81/147, 57/57 | 2/56, 0/57 | 0/32, 0/57 | 0/0, 1/57 | - | - | - | 1/56, 1/57 | 1/55, 0/57 | 1/46, 0/57 |
| amazon | 0/5, 0/119 (blocked) | 0/5, 0/119 (blocked) | 47/553, 17/119 | 47/548, 17/119 | 43/481, 65/119 | 16/59, 6/119 | 0/0, 67/119 | - | - | - | 29/596, 67/119 | 36/174, 10/119 | 49/548, 61/119 |
| vercel | 3/103, 0/5 | 3/103, 0/5 | 0/181, 0/5 (redirected) | 0/181, 0/5 (redirected) | 0/12, 0/5 | 0/11, 0/5 | 0/0, 0/5 | - | - | - | 0/98, 0/5 | 0/11, 1/5 | 0/12, 0/5 |
| amazon-frozen | 19/484, 20/114 | 19/483, 14/114 | 43/554, 15/114 | 43/549, 15/114 | 41/520, 60/114 | 17/59, 6/114 | 0/0, 62/114 | - | - | - | 25/644, 62/114 | 38/156, 9/114 | 41/585, 60/114 |

## Structure probes

| probe | cmux | cmux-i | aside | aside-i | chatgpt-ax | chatgpt-dom | chatgpt-pw | chatgpt-live-ax | chatgpt-live-dom | chatgpt-live-pw | pw-mcp | browser-use | stagehand |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| frames: frames-both | yes | yes | yes | yes | yes | yes | **no** | yes | yes | **no** | yes | yes | yes |
| frames: frame-nested-srcdoc | yes | yes | yes | yes | **no** | yes | **no** | **no** | yes | **no** | yes | yes | **no** |
| frames: frame-deep | yes | yes | **no** | **no** | yes | yes | **no** | yes | yes | **no** | yes | yes | **no** |
| frames: frame-srcdoc | yes | yes | yes | yes | yes | yes | **no** | yes | yes | **no** | yes | yes | yes |
| links: link-target | **no** | **no** | **no** | **no** | yes | yes | yes | yes | yes | yes | yes | **no** | **no** |
| security: hidden-details | yes | yes | yes | yes | yes | **no** | yes | yes | **no** | yes | yes | yes | yes |
| security: password | yes | yes | yes | yes | yes | yes | **no** | yes | yes | yes | **no** | yes | yes |
| shadow: shadow-open | yes | yes | yes | yes | yes | yes | **no** | yes | yes | **no** | yes | yes | yes |
| shadow: shadow-closed | yes | yes | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** | yes | **no** |
| states: value | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| states: placeholder | yes | yes | yes | yes | **no** | **no** | yes | **no** | **no** | yes | yes | **no** | **no** |
| states: select-options | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| states: checked | yes | yes | yes | yes | yes | **no** | yes | yes | **no** | yes | yes | **no** | yes |
| states: expanded | yes | yes | **no** | **no** | yes | **no** | **no** | yes | **no** | **no** | **no** | yes | **no** |
| states: selected | yes | yes | yes | yes | yes | **no** | yes | yes | **no** | yes | yes | yes | yes |
| states: pressed | yes | yes | **no** | **no** | yes | **no** | yes | yes | **no** | yes | yes | yes | **no** |
| states: slider-value | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes | **no** |
| states: mixed | yes | yes | **no** | **no** | yes | **no** | yes | yes | **no** | yes | yes | **no** | **no** |
| states: required | yes | yes | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** |
| states: invalid | yes | yes | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** |
| states: readonly | yes | yes | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** | **no** |
| states: disabled | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes | **no** | **no** |
| structure: list | yes | **no** | yes | **no** | **no** | **no** | yes | **no** | **no** | yes | yes | **no** | **no** |
| structure: heading-level | yes | yes | yes | yes | yes | **no** | yes | yes | **no** | yes | yes | **no** | **no** |
| structure: heading-role | yes | yes | yes | yes | yes | **no** | yes | yes | **no** | yes | yes | **no** | yes |
| structure: landmark-nav | yes | yes | yes | yes | **no** | **no** | yes | **no** | **no** | yes | yes | **no** | yes |
| structure: landmark-main | yes | yes | yes | yes | **no** | **no** | yes | **no** | **no** | yes | yes | **no** | yes |
| structure: landmark-footer | yes | **no** | yes | yes | **no** | **no** | yes | **no** | **no** | yes | yes | **no** | yes |
| structure: table | yes | **no** | yes | **no** | yes | **no** | yes | yes | **no** | yes | yes | **no** | yes |
| structure: table-cell | yes | **no** | **no** | **no** | **no** | **no** | yes | **no** | **no** | yes | yes | yes | yes |
| structure: dialog | yes | yes | yes | yes | yes | **no** | yes | yes | **no** | yes | yes | **no** | yes |
| structure: alert | yes | **no** | yes | yes | **no** | **no** | yes | **no** | **no** | yes | yes | **no** | **no** |
| structure: table-header | yes | **no** | **no** | **no** | **no** | **no** | yes | **no** | **no** | yes | yes | **no** | yes |
| widgets: onclick-div | yes | yes | yes | yes | yes | **no** | **no** | yes | yes | **no** | yes | yes | yes |
| widgets: contenteditable | yes | yes | yes | yes | **no** | yes | **no** | **no** | yes | **no** | **no** | yes | **no** |
| widgets: scrollable | yes | yes | **no** | **no** | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| **passed** | 35/36 | 29/36 | 24/36 | 22/36 | 22/36 | 13/36 | 23/36 | 22/36 | 14/36 | 24/36 | 29/36 | 18/36 | 19/36 |

## Change reporting (small form page)

| tool | output after action | full | shown/full | value | checked | focus |
| --- | --- | --- | --- | --- | --- | --- |
| cmux | diff | 635 B | 46% | yes | yes | yes |
| cmux-i | diff | 537 B | 55% | yes | yes | yes |
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
| cmux | diff | 12k B | 2% | yes | yes | yes |
| cmux-i | diff | 5.6k B | 5% | yes | yes | yes |
| aside | diff | 8.2k B | 3% | yes | yes | yes |
| aside-i | diff | 7.8k B | 3% | yes | yes | yes |
| chatgpt-ax | diff | 18k B | 2% | no | yes | yes |
| chatgpt-dom | full | 4.1k B | 100% | no | no | no |
| chatgpt-pw | full | 18k B | 100% | yes | yes | yes |
| pw-mcp | diff | 27k B | 2% | yes | yes | yes |
| browser-use | full | 10k B | 100% | yes | yes | no |
| stagehand | full | 19k B | 100% | yes | yes | no |

## Action flow (fill Email, check terms, submit; what the tool prints next)

| tool | printed | full | value | checked | submit result |
| --- | --- | --- | --- | --- | --- |
| cmux | 383 B | 682 B | yes | yes | yes |
| cmux-i | 334 B | 537 B | yes | yes | no |
| aside | 420 B | 874 B | yes | yes | yes |
| aside-i | 390 B | 774 B | yes | yes | yes |
| chatgpt-ax | 1.2k B | 1.2k B | yes | yes | yes |
| chatgpt-live-ax | 1.2k B | 1.2k B | yes | yes | yes |
| pw-mcp | 797 B | 1.2k B | yes | yes | yes |

## Offline stand-ins vs live ChatGPT (lines shared / offline lines / live lines, bytes offline to live)

| page | chatgpt-ax vs live | chatgpt-dom vs live | chatgpt-pw vs live |
| --- | --- | --- | --- |
| index | 34/35/35, 1.1k to 1.1k B | 6/8/8, 488 to 466 B | 27/27/28, 577 to 594 B |
| aria | 75/77/77, 2.4k to 2.4k B | 15/17/21, 715 to 877 B | identical 63/63/63, 1.5k to 1.5k B |
| states | 66/71/71, 2.0k to 2.0k B | 15/17/17, 773 to 802 B | 59/60/60, 1.5k to 1.5k B |
| frames | identical 16/16/16, 794 to 794 B | identical 4/4/4, 169 to 169 B | 5/7/7, 152 to 177 B |
| frame-inner | identical 7/7/7, 412 to 412 B | identical 2/2/2, 84 to 84 B | identical 2/2/2, 47 to 47 B |
| shadow | identical 12/12/12, 505 to 505 B | identical 2/2/2, 86 to 86 B | identical 6/6/6, 156 to 156 B |
| surface | 25/26/26, 1.0k to 1.0k B | 8/9/9, 388 to 377 B | 18/20/20, 424 to 450 B |
| dynamic | identical 15/15/15, 644 to 644 B | identical 8/8/8, 299 to 299 B | identical 11/11/11, 231 to 231 B |
| input | identical 48/48/48, 1.2k to 1.2k B | identical 7/7/7, 475 to 475 B | identical 42/42/42, 851 to 851 B |
| dialogs | identical 9/9/9, 449 to 449 B | identical 4/4/4, 145 to 145 B | identical 5/5/5, 99 to 99 B |
| files | 11/13/13, 529 to 531 B | identical 4/4/4, 176 to 176 B | identical 8/8/8, 156 to 156 B |
| nest | 14/20/20, 730 to 766 B | identical 4/4/4, 159 to 159 B | 7/11/11, 259 to 303 B |
| corpus-bbc | identical 190/190/190, 20k to 20k B | 39/39/45, 3.1k to 4.5k B | 441/442/468, 31k to 34k B |
| corpus-books | identical 442/442/442, 17k to 17k B | 42/42/64, 4.3k to 7.2k B | 476/476/489, 19k to 20k B |
| corpus-github | identical 2112/2112/2112, 138k to 138k B | 89/107/109, 16k to 20k B | 2518/2518/2549, 141k to 142k B |
| corpus-hackernews | identical 646/646/646, 21k to 21k B | 163/163/200, 15k to 18k B | identical 944/944/944, 48k to 48k B |
| corpus-mdn-iframe | identical 1032/1032/1032, 56k to 56k B | 142/142/151, 16k to 17k B | 1927/1927/1968, 94k to 95k B |
| corpus-mdn | identical 535/535/535, 29k to 29k B | 133/133/143, 15k to 16k B | 905/905/914, 46k to 46k B |
| corpus-npr | identical 50/50/50, 3.7k to 3.7k B | 13/13/19, 1.7k to 2.4k B | identical 70/70/70, 3.5k to 3.5k B |
| corpus-vercel | 44/44/55, 2.1k to 2.5k B | identical 11/11/11, 891 to 891 B | 317/317/329, 11k to 12k B |
| corpus-wikipedia | identical 2297/2297/2297, 112k to 112k B | 101/101/119, 9.6k to 11k B | 2557/2557/2562, 149k to 149k B |

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
| chatgpt-live-ax | Alpha=5, Beta=8, Out=9 | Zero=13, Minus=16, Beta renamed=8, Out=9 | yes | no | Alpha: Accessibility element 5 is stale or missing; Out: "Out clicked" |
| pw-mcp | Alpha=e4, Beta=e6, Out=e7 | Zero=e9, Minus=e11, Beta renamed=e12, Out=e7 | **no** | no | Alpha: locator.textContent: Timeout 1500ms exceeded.; Beta: locator.textContent: Timeout 1500ms exceeded.; Out: "Out" |
| browser-use | Alpha=21, Beta=25, Out=12 | Zero=30, Minus=32, Beta renamed=25, Out=12 | yes | no | - |
| stagehand | Alpha=0-19, Beta=0-23, Out=0-25 | Zero=0-29, Minus=0-31, Beta renamed=0-23, Out=0-25 | yes | no | - |
