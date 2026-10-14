['cmux-prod-otel-traces']
| where _time > ago(24h) and name == 'cmux.mobile.feed.performance'
| extend p = ['attributes.custom']
| where tolong(p['cmux.mobile.feed.schema_version']) == 1
| extend build = tostring(p['cmux.mobile.feed.build_number']), sha = tostring(p['cmux.mobile.feed.build_sha']), bundle = tostring(p['cmux.mobile.feed.bundle_identifier']), os = tostring(p['cmux.mobile.feed.os_version']), simulator = tostring(p['cmux.mobile.feed.is_simulator'])
| extend h = parse_json(tostring(p['cmux.mobile.feed.callback_gap_histogram']))
| summarize windows=count(), callbacks=sum(tolong(p['cmux.mobile.feed.callback_count'])), scroll_ms=sum(tolong(p['cmux.mobile.feed.scroll_observed_ms'])), over50=sum(tolong(p['cmux.mobile.feed.gaps_over_50ms'])), over100=sum(tolong(p['cmux.mobile.feed.gaps_over_100ms'])), worst_ms=max(tolong(p['cmux.mobile.feed.callback_gap_max_ms'])), updates_during_scroll=sum(tolong(p['cmux.mobile.feed.updates_while_scrolling'])), max_items=max(tolong(p['cmux.mobile.feed.item_count'])), b8=sum(tolong(h[0])), b12=sum(tolong(h[1])), b17=sum(tolong(h[2])), b25=sum(tolong(h[3])), b34=sum(tolong(h[4])), b50=sum(tolong(h[5])), b100=sum(tolong(h[6])), b250=sum(tolong(h[7])), b1000=sum(tolong(h[8])), b_overflow=sum(tolong(h[9])) by build, sha, bundle, os, simulator
| where callbacks > 0
| extend gap_over50_percent = 100.0 * over50 / callbacks
