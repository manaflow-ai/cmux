---
title: Acme 2.4 release notes
---

<!-- _class: title -->
# Acme 2.4
## Release notes

<!-- Thirty seconds per slide. Open with the one number people will remember: search is faster. -->

---

## What shipped

- Checkout totals use integer cents
- Dark mode toggle in Settings
- p95 search latency down 38%
- Billing moved to the new ledger
- React 19 across the app

<!-- Five changes, one line each. Details are on the next slides; skip ahead if time is short. -->

---

## Checkout rounding, fixed

- Totals are now computed in integer cents (#412)
- No more one-cent drift on discounted carts

---

<!-- _class: center -->
# 412 ms → 255 ms

p95 search latency

<!-- The search-p95 work: a narrower index read and a cached ranker. Say "38 percent" out loud; the slide shows the raw numbers. -->

---

## Under the hood

- Billing migration: the new ledger, no downtime
- React 19 upgrade: faster first paint

---

<!-- _class: center -->
# Thanks

Questions?
