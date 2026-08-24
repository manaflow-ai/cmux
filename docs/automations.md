# cmux automations

cmux can subscribe to its in-process event bus and run ordered actions from
~/.cmuxterm/automations.json. The file is versioned so it can be checked into
a repository and reviewed like any other configuration.

## Configuration

~~~json
{
  "version": 1,
  "rules": [
    {
      "id": "surface-needs-input",
      "when": { "event": "agent.needs_input" },
      "where": {
        "workspace.tag": "dispatch",
        "surface.kind": "terminal"
      },
      "rate_limit": { "interval_seconds": 30, "maximum": 1 },
      "then": [
        {
          "action": "notify",
          "title": "Agent needs input",
          "body": "Review {{payload.session_id}}"
        },
        {
          "action": "rpc",
          "method": "workspace.reorder",
          "params": { "index": 1 }
        }
      ]
    }
  ]
}
~~~

when.event and when.category accept exact names or a * prefix/suffix
wildcard. where values are matched against the event payload; the common
aliases are workspace.tag, workspace.title, title, agent, and
surface.kind. Predicate objects support equals, contains, prefix,
suffix, matches, in, and not. Rules are enabled by default; set "enabled": false
to keep a rule in the file without firing it.

Every rule has a rate limit. When rate_limit is omitted cmux uses one firing
per second. The engine also caps concurrent firings and keeps the most recent
256 firing records in memory.

## Actions

- notify uses the existing TerminalNotificationStore. workspace_id and
  surface_id default to the event target, and title, subtitle, body, and
  message support {{event.name}}, {{event.category}},
  {{event.source}}, and {{payload.<key>}} substitutions.
- rpc dispatches any v2 socket method through the normal dispatcher. Focus is
  suppressed by default. Set allow_focus: true (or focus: true) on the
  action when the rule intentionally selects a workspace/surface.
- run executes command (or cmd) through /bin/sh -c (60 seconds by default;
  set timeout_seconds to a value up to 300). The serialized
  event is available as CMUX_AUTOMATION_EVENT and
  CMUX_AUTOMATION_EVENT_JSON; CMUX_AUTOMATION_RULE_ID and
  CMUX_AUTOMATION_CHAIN identify the firing.
- webhook sends the event JSON as an HTTP POST to url. Optional string
  headers are added to the request.

Action-generated in-process events carry an automation_origin envelope with
the rule chain. A rule already present in that chain is skipped, which stops
direct self-triggering and multi-rule cycles.

## CLI

~~~text
cmux automation list
cmux automation show <id>
cmux automation test <id> --event <json>
cmux automation enable <id>
cmux automation disable <id>
cmux automation logs [--limit <n>]
cmux automation reload
~~~

test is a dry run: it reads the config and evaluates a synthetic event
without dispatching actions or changing rate-limit state. logs reports the
bounded in-memory firing ring from the running cmux process.
