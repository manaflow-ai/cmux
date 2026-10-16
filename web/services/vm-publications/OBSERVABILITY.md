# Publication authorization traces

`requestTelemetry.ts` instruments `/api/freestyle/forward-auth`. Normal requests
follow the existing trace sampling ratio. Every request taking at least 750 ms,
or returning 5xx, also produces `cmux.publication_auth.outcome` through the
priority sampler. It includes operation offsets, durations, and failure flags,
even when the original request trace was not sampled. Its response carries the
retained trace id. Export is flushed in `after()`, outside response latency.

Use `cmux.publication_auth.duration_ms` for the full request duration. An outcome
span records a completed decision, so its own span duration is not request
latency. Parent and child operation timings overlap; do not sum them.

Operation names and decision categories are fixed by code. Request URLs, cookie
values, authorization codes, SQL parameters, and exception messages are not
recorded here. At most 32 operation events are retained per request. Check
`cmux.publication_auth.dropped_operations` before treating the list as complete.
Database operation time currently includes connection wait and query execution.

Find every retained slow or failed request:

```apl
['cmux-prod-otel-traces']
| where name == 'cmux.publication_auth.outcome'
| project _time, trace_id,
    duration_ms = ['attributes.custom']['cmux.publication_auth.duration_ms'],
    decision = ['attributes.custom']['cmux.publication_auth.decision'],
    events
```

Estimate normal request latency from the sampled request spans, not the
deliberately biased slow/failure stream. Do not combine the two streams: a
sampled slow request has both records.

```apl
['cmux-prod-otel-traces']
| where name == 'cmux.publication_auth.request'
| extend ms = todouble(['attributes.custom']['cmux.publication_auth.duration_ms'])
| summarize requests=count(), p50=percentile(ms, 50), p95=percentile(ms, 95), p99=percentile(ms, 99)
```

Preview export verification uses `cmux-preview-otel-traces` and service
`cmux-publication-auth-verification`. Synthetic checks are not production
performance measurements.
