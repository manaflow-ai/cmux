['cmux-prod-otel-traces']
| where _time > ago(24h) and name == 'cmux.mobile.feed.scroll_anomaly'
| extend p = ['attributes.custom']
| project _time, observed_at = tostring(p['cmux.mobile.occurred_at']), window_id = tostring(p['cmux.mobile.feed.window_id']), sentry_event_id = tostring(p['cmux.mobile.feed.sentry_event_id']), build = tostring(p['cmux.mobile.feed.build_number']), sha = tostring(p['cmux.mobile.feed.build_sha']), simulator = tostring(p['cmux.mobile.feed.is_simulator']), worst_ms = tolong(p['cmux.mobile.feed.callback_gap_max_ms']), callbacks = tolong(p['cmux.mobile.feed.callback_count']), items = tolong(p['cmux.mobile.feed.item_count'])
| order by _time desc
| take 100
