// Built by cmux app pack from src/main.ts. Do not edit.
(() => {
  var __defProp = Object.defineProperty;
  var __returnValue = (v) => v;
  function __exportSetter(name, newValue) {
    this[name] = __returnValue.bind(null, newValue);
  }
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, {
        get: all[name],
        enumerable: true,
        configurable: true,
        set: __exportSetter.bind(all, name)
      });
  };
  var exports_main = {};
  __export(exports_main, {
    load: () => load,
    renderWeather: () => renderWeather
  });
  var events_default = {
    $comment: "The event streams an extension can subscribe to (cmux.events.on, cmux.live). An event is an invalidation with no payload: the app reads again (a stream fed from outside this machine, github.changed, may say {\"live\": bool} about its push channel). The daemon delivers a stream only to an app that may call its `reads` op with its optional `readsParams` (apps/subscriptions.rs stream_readable), so that op's scope is the stream's scope; a `reads` op whose catalog scope has a <placeholder> (integration.request) names the narrowed scope in `scope`. tools/gen-cmux-global.ts checks each `reads` against the catalog and writes the SDKs' table (cmux-extension-sdk/api.json); cmux-tui-core's routing tests check that every stream the daemon publishes is listed here.",
    version: 1,
    events: {
      "workspace.changed": {
        docs: "A workspace was created, closed, renamed, reordered, selected or restyled.",
        reads: "workspace.list"
      },
      "screen.changed": {
        docs: "A screen (a workspace's layout) changed.",
        reads: "screen.list"
      },
      "pane.changed": {
        docs: "A pane was split, closed, resized or focused.",
        reads: "pane.list"
      },
      "system_calendar.changed": {
        docs: "An event in a calendar on this Mac was added, changed or removed, or calendar access changed (EventKit's EKEventStoreChanged, sent by the cmux Mac app). Read system_calendar.events again.",
        reads: "system_calendar.events"
      },
      "tab.changed": {
        docs: "A tab was opened, closed, moved or selected.",
        reads: "tab.list"
      },
      "terminal.changed": {
        docs: "A terminal started, ended or changed its title or folder.",
        reads: "terminal.list"
      },
      "agent.changed": {
        docs: "An agent's state changed (working, blocked, idle, done).",
        reads: "agent.list"
      },
      "media.changed": {
        docs: "What plays changed: another track, play or pause, a seek, or new artwork.",
        reads: "media.get"
      },
      "agent_chat.changed": {
        docs: "An agent chat was added, closed, renamed, read or changed state.",
        reads: "agent_chat.list"
      },
      "chat.changed": {
        docs: "A listed field of an agent chat changed (state, title, unread, pin, step, pull requests); not fired for updated_ms alone.",
        reads: "chat.list"
      },
      "settings.changed": {
        docs: "A cmux setting changed (cmux-next.json, a managed layer, Settings, the CLI or an agent). Read the keys you use again with settings.get; the event names none and carries no values.",
        reads: "settings.get"
      },
      "github.changed": {
        docs: `GitHub data the person can read changed: a pull request, a review, a check run or suite, or a commit status, on a repository a GitHub connection covers. The Cloud turns the GitHub App's verified webhook into this invalidation within seconds; read GitHub again through integration.request. The body is {} for a change, or {"live": bool} when the push channel goes up or down (signed out, offline, no GitHub connection): a new subscriber hears {"live": ...} first. While it is not live, keep a slow re-read.`,
        reads: "integration.request",
        readsParams: { provider: "github", method: "GET" },
        scope: "integration:github:read"
      },
      "theme.changed": {
        docs: "The theme changed: the theme, app theme, theme file, theme edits, accent, hue, saturation or highlight color. Theme tones (cmux.theme) repaint on their own; read settings.get again for anything you derive from them.",
        reads: "settings.get"
      }
    }
  };
  var scopes_default = {
    apiVersion: "1.0.0",
    ops: {
      "action.list": {
        scope: "actions:run",
        class: "read"
      },
      "action.run": {
        scope: "actions:run",
        class: "mutation"
      },
      "agent_chat.list": {
        scope: "agent_chat:read",
        class: "read"
      },
      "agent_cli.list": {
        scope: "agent_cli:read",
        class: "read"
      },
      "agent.list": {
        scope: "agent:read",
        class: "read"
      },
      "agent.report": {
        scope: "agent:write",
        class: "mutation"
      },
      "agents.check_updates": {
        scope: "agents:read",
        class: "read"
      },
      "agents.cycle_variant": {
        scope: "agents:write",
        class: "mutation"
      },
      "agents.open": {
        scope: "agents:write",
        class: "mutation"
      },
      "app.pane.close": {
        scope: "none",
        class: "runtime"
      },
      "app.pane.open": {
        scope: "none",
        class: "runtime"
      },
      "app.storage.delete": {
        scope: "storage:local",
        class: "mutation"
      },
      "app.storage.get": {
        scope: "storage:local",
        class: "read"
      },
      "app.storage.keys": {
        scope: "storage:local",
        class: "read"
      },
      "app.storage.set": {
        scope: "storage:local",
        class: "mutation"
      },
      "app.view.state": {
        scope: "none",
        class: "runtime"
      },
      "automation.audit.list": {
        scope: "automation:read",
        class: "read"
      },
      "automation.create": {
        scope: "automation:write",
        class: "mutation"
      },
      "automation.deploy": {
        scope: "automation:execute",
        class: "mutation"
      },
      "automation.get": {
        scope: "automation:read",
        class: "read"
      },
      "automation.import": {
        scope: "automation:write",
        class: "mutation"
      },
      "automation.list": {
        scope: "automation:read",
        class: "read"
      },
      "automation.run": {
        scope: "automation:execute",
        class: "mutation"
      },
      "automation.runs.list": {
        scope: "automation:read",
        class: "read"
      },
      "automation.settings.get": {
        scope: "automation:read",
        class: "read"
      },
      "automation.teleport.abort": {
        scope: "automation:write",
        class: "mutation"
      },
      "automation.teleport.begin": {
        scope: "automation:write",
        class: "mutation"
      },
      "automation.teleport.complete": {
        scope: "automation:write",
        class: "mutation"
      },
      "automation.update": {
        scope: "automation:write",
        class: "mutation"
      },
      "browser.activate": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.back": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.devices.add_custom": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.devices.list": {
        scope: "browser:read",
        class: "read"
      },
      "browser.devices.remove_custom": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.forward": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.get": {
        scope: "browser:read",
        class: "read"
      },
      "browser.input.key": {
        scope: "browser:execute",
        class: "mutation"
      },
      "browser.input.mouse": {
        scope: "browser:execute",
        class: "mutation"
      },
      "browser.input.text": {
        scope: "browser:execute",
        class: "mutation"
      },
      "browser.input.wheel": {
        scope: "browser:execute",
        class: "mutation"
      },
      "browser.list": {
        scope: "browser:read",
        class: "read"
      },
      "browser.navigate": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.profile.create": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.profile.list": {
        scope: "browser:read",
        class: "read"
      },
      "browser.profile.open": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.reload": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.tab.emulate": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.tab.emulate.clear": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.tab.set_profile": {
        scope: "browser:write",
        class: "mutation"
      },
      "caffeinate.cycle_variant": {
        scope: "caffeinate:write",
        class: "mutation"
      },
      "caffeinate.keep_awake": {
        scope: "caffeinate:write",
        class: "mutation"
      },
      "caffeinate.keep_awake_hour": {
        scope: "caffeinate:write",
        class: "mutation"
      },
      "caffeinate.list": {
        scope: "caffeinate:read",
        class: "read"
      },
      "caffeinate.show": {
        scope: "caffeinate:write",
        class: "mutation"
      },
      "caffeinate.start": {
        scope: "caffeinate:write",
        class: "mutation"
      },
      "caffeinate.stop": {
        scope: "caffeinate:write",
        class: "mutation"
      },
      "caffeinate.stop_all": {
        scope: "caffeinate:write",
        class: "mutation"
      },
      "calendar.calendars.list": {
        scope: "calendar:read",
        class: "read"
      },
      "calendar.event.create": {
        scope: "calendar:external",
        class: "mutation"
      },
      "calendar.event.respond": {
        scope: "calendar:external",
        class: "mutation"
      },
      "calendar.events.list": {
        scope: "calendar:read",
        class: "read"
      },
      "channel.create": {
        scope: "channel:write",
        class: "mutation"
      },
      "chat.list": {
        scope: "chat:read",
        class: "read"
      },
      "chat.mark_read": {
        scope: "chat:write",
        class: "mutation"
      },
      "chat.pin": {
        scope: "chat:write",
        class: "mutation"
      },
      "chief.automation.list": {
        scope: "chief:read",
        class: "read"
      },
      "chief.automation.update": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.continue": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.create": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.engine.get": {
        scope: "chief:read",
        class: "read"
      },
      "chief.engine.set": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.list": {
        scope: "chief:read",
        class: "read"
      },
      "chief.profile.adopt": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.profile.avatar.get": {
        scope: "chief:read",
        class: "read"
      },
      "chief.profile.avatar.set": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.profile.create": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.profile.delete": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.profile.get": {
        scope: "chief:read",
        class: "read"
      },
      "chief.profile.history": {
        scope: "chief:read",
        class: "read"
      },
      "chief.profile.list": {
        scope: "chief:read",
        class: "read"
      },
      "chief.profile.undo": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.profile.update": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.retry": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.stop": {
        scope: "chief:write",
        class: "mutation"
      },
      "chief.update": {
        scope: "chief:write",
        class: "mutation"
      },
      "clipboard.write": {
        scope: "clipboard:write",
        class: "mutation"
      },
      "closed.delete": {
        scope: "closed:write",
        class: "mutation"
      },
      "closed.list": {
        scope: "closed:read",
        class: "read"
      },
      "closed.reopen": {
        scope: "closed:write",
        class: "mutation"
      },
      "cloud.auth.status": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.browser.open": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.environment.list": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.environment.set": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.file.pull": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.file.push": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.file.transfer.cancel": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.file.transfer.list": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.fs.list": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.fs.mkdir": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.fs.read": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.fs.stat": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.fs.write": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.machine.connect": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.machine.connect_info": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.machine.disconnect": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.machine.get": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.machine.idle_policy.set": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.machine.keep": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.machine.list": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.machine.pause": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.machine.pause_all": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.machine.rename": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.machine.start": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.machine.upgrade": {
        scope: "cloud:execute",
        class: "mutation"
      },
      "cloud.machine.watch": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.migration.start": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.migration.status": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.plan.get": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.port.forward": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.port.list": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.rescue.open": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.retention.set": {
        scope: "cloud:write",
        class: "mutation"
      },
      "cloud.shell.open": {
        scope: "cloud:execute",
        class: "mutation"
      },
      "cloud.snapshot.list": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.surge.preview": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.usage.current": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.vm.attention.emit": {
        scope: "cloud:execute",
        class: "mutation"
      },
      "cloud.vm.event.emit": {
        scope: "cloud:execute",
        class: "mutation"
      },
      "cloud.vm.machine.request": {
        scope: "cloud:execute",
        class: "mutation"
      },
      "cloud.vm.network_policy": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.vm.receiver.lifecycle": {
        scope: "cloud:execute",
        class: "mutation"
      },
      "cloud.vm.self.get": {
        scope: "cloud:read",
        class: "read"
      },
      "cloud.vm.status.report": {
        scope: "cloud:execute",
        class: "mutation"
      },
      "codemirror.cycle_variant": {
        scope: "codemirror:write",
        class: "mutation"
      },
      "codemirror.open": {
        scope: "codemirror:write",
        class: "mutation"
      },
      "codemirror.revert": {
        scope: "codemirror:write",
        class: "mutation"
      },
      "codemirror.save": {
        scope: "codemirror:write",
        class: "mutation"
      },
      "codemirror.toggle_read_only": {
        scope: "codemirror:write",
        class: "mutation"
      },
      "coderouter.accounts.list": {
        scope: "coderouter:read",
        class: "read"
      },
      "coderouter.detect": {
        scope: "coderouter:read",
        class: "read"
      },
      "coderouter.status": {
        scope: "coderouter:read",
        class: "read"
      },
      "coderouter.usage.get": {
        scope: "coderouter:read",
        class: "read"
      },
      "column.update": {
        scope: "column:write",
        class: "mutation"
      },
      "conversation.create": {
        scope: "conversation:write",
        class: "mutation"
      },
      "conversation.draft": {
        scope: "conversation:write",
        class: "mutation"
      },
      "conversation.get": {
        scope: "conversation:read",
        class: "read"
      },
      "conversation.history": {
        scope: "conversation:read",
        class: "read"
      },
      "conversation.import": {
        scope: "conversation:write",
        class: "mutation"
      },
      "conversation.import.commit": {
        scope: "conversation:write",
        class: "mutation"
      },
      "conversation.list": {
        scope: "conversation:read",
        class: "read"
      },
      "conversation.members": {
        scope: "conversation:read",
        class: "read"
      },
      "conversation.search": {
        scope: "conversation:read",
        class: "read"
      },
      "conversation.send": {
        scope: "conversation:write",
        class: "mutation"
      },
      "conversation.settings.set": {
        scope: "conversation:write",
        class: "mutation"
      },
      "conversation.snapshot": {
        scope: "conversation:read",
        class: "read"
      },
      "conversation.thread": {
        scope: "conversation:read",
        class: "read"
      },
      "conversation.typing": {
        scope: "conversation:write",
        class: "mutation"
      },
      "diff.comments.delete": {
        scope: "diff:write",
        class: "mutation"
      },
      "diff.comments.list": {
        scope: "diff:read",
        class: "read"
      },
      "diff.comments.save": {
        scope: "diff:write",
        class: "mutation"
      },
      "diff.comments.thread": {
        scope: "diff:write",
        class: "mutation"
      },
      "diffs.cycle_variant": {
        scope: "diffs:write",
        class: "mutation"
      },
      "diffs.open_changes": {
        scope: "diffs:write",
        class: "mutation"
      },
      "diffs.open_diff": {
        scope: "diffs:write",
        class: "mutation"
      },
      "diffs.review": {
        scope: "diffs:write",
        class: "mutation"
      },
      "diffs.review_latest": {
        scope: "diffs:write",
        class: "mutation"
      },
      "diffs.toggle_layout": {
        scope: "diffs:write",
        class: "mutation"
      },
      "dm.open": {
        scope: "dm:write",
        class: "mutation"
      },
      "domain.list": {
        scope: "domain:read",
        class: "read"
      },
      "feed.adopt": {
        scope: "feed:write",
        class: "mutation"
      },
      "feed.adopt.cancel": {
        scope: "feed:write",
        class: "mutation"
      },
      "feed.answer": {
        scope: "feed:write",
        class: "mutation"
      },
      "feed.archive": {
        scope: "feed:write",
        class: "mutation"
      },
      "feed.cancel": {
        scope: "feed:write",
        class: "mutation"
      },
      "feed.counts": {
        scope: "feed:read",
        class: "read"
      },
      "feed.get": {
        scope: "feed:read",
        class: "read"
      },
      "feed.kinds": {
        scope: "feed:read",
        class: "read"
      },
      "feed.list": {
        scope: "feed:read",
        class: "read"
      },
      "feed.post": {
        scope: "feed:write",
        class: "mutation"
      },
      "feed.prefs.set": {
        scope: "feed:write",
        class: "mutation"
      },
      "feed.read": {
        scope: "feed:write",
        class: "mutation"
      },
      "feed.seen": {
        scope: "feed:write",
        class: "mutation"
      },
      "feed.snooze": {
        scope: "feed:write",
        class: "mutation"
      },
      "feed.unarchive": {
        scope: "feed:write",
        class: "mutation"
      },
      "finder.add_folder": {
        scope: "finder:write",
        class: "mutation"
      },
      "finder.connect_host": {
        scope: "finder:write",
        class: "mutation"
      },
      "finder.cycle_variant": {
        scope: "finder:write",
        class: "mutation"
      },
      "finder.open": {
        scope: "finder:write",
        class: "mutation"
      },
      "git.branches": {
        scope: "git:read",
        class: "read"
      },
      "git.checkpoint.create": {
        scope: "git:write",
        class: "mutation"
      },
      "git.checkpoint.diff": {
        scope: "git:read",
        class: "read"
      },
      "git.checkpoint.get": {
        scope: "git:read",
        class: "read"
      },
      "git.checkpoint.list": {
        scope: "git:read",
        class: "read"
      },
      "git.checkpoint.pin": {
        scope: "git:write",
        class: "mutation"
      },
      "git.checkpoint.unpin": {
        scope: "git:write",
        class: "mutation"
      },
      "git.commit": {
        scope: "git:execute",
        class: "mutation"
      },
      "git.diff": {
        scope: "git:read",
        class: "read"
      },
      "git.files.list": {
        scope: "git:read",
        class: "read"
      },
      "git.files.search": {
        scope: "git:read",
        class: "read"
      },
      "git.fingerprint": {
        scope: "git:read",
        class: "read"
      },
      "git.push": {
        scope: "git:external",
        class: "mutation"
      },
      "git.review.comment": {
        scope: "git:write",
        class: "mutation"
      },
      "git.review.post": {
        scope: "git:external",
        class: "mutation"
      },
      "git.review.start": {
        scope: "git:execute",
        class: "mutation"
      },
      "git.status": {
        scope: "git:read",
        class: "read"
      },
      "git.worktree.apply": {
        scope: "git:execute",
        class: "mutation"
      },
      "git.worktree.create": {
        scope: "git:execute",
        class: "mutation"
      },
      "git.worktree.remove": {
        scope: "git:execute",
        class: "mutation"
      },
      "git.worktree.setup": {
        scope: "git:read",
        class: "read"
      },
      "git.worktree.setup.run": {
        scope: "git:execute",
        class: "mutation"
      },
      "github.issue.comment": {
        scope: "github:external",
        class: "mutation"
      },
      "group.add_workspace": {
        scope: "group:write",
        class: "mutation"
      },
      "group.archive": {
        scope: "group:write",
        class: "mutation"
      },
      "group.create": {
        scope: "group:write",
        class: "mutation"
      },
      "group.get": {
        scope: "group:read",
        class: "read"
      },
      "group.list": {
        scope: "group:read",
        class: "read"
      },
      "group.members.list": {
        scope: "group:read",
        class: "read"
      },
      "group.members.remove": {
        scope: "group:write",
        class: "mutation"
      },
      "group.members.set": {
        scope: "group:write",
        class: "mutation"
      },
      "group.rename": {
        scope: "group:write",
        class: "mutation"
      },
      "home.search": {
        scope: "home:read",
        class: "read"
      },
      "inbox_app.cycle_variant": {
        scope: "inbox_app:write",
        class: "mutation"
      },
      "inbox_app.mark_all_read": {
        scope: "inbox_app:write",
        class: "mutation"
      },
      "inbox_app.mark_done": {
        scope: "inbox_app:write",
        class: "mutation"
      },
      "inbox_app.next_item": {
        scope: "inbox_app:write",
        class: "mutation"
      },
      "inbox_app.open": {
        scope: "inbox_app:write",
        class: "mutation"
      },
      "inbox_app.open_item": {
        scope: "inbox_app:write",
        class: "mutation"
      },
      "inbox_app.previous_item": {
        scope: "inbox_app:write",
        class: "mutation"
      },
      "inbox_app.snooze": {
        scope: "inbox_app:write",
        class: "mutation"
      },
      "inbox.archive": {
        scope: "inbox:write",
        class: "mutation"
      },
      "inbox.dm_peer": {
        scope: "inbox:read",
        class: "read"
      },
      "inbox.list": {
        scope: "inbox:read",
        class: "read"
      },
      "inbox.mark_unread": {
        scope: "inbox:write",
        class: "mutation"
      },
      "inbox.mute": {
        scope: "inbox:write",
        class: "mutation"
      },
      "inbox.pin": {
        scope: "inbox:write",
        class: "mutation"
      },
      "integration.list": {
        scope: "integration:read",
        class: "read"
      },
      "integration.policy.get": {
        scope: "integration:read",
        class: "read"
      },
      "integration.request": {
        scope: "integration:<provider>",
        class: "runtime"
      },
      "integrations.connect": {
        scope: "integrations:write",
        class: "mutation"
      },
      "integrations.cycle_variant": {
        scope: "integrations:write",
        class: "mutation"
      },
      "integrations.import_api": {
        scope: "integrations:write",
        class: "mutation"
      },
      "integrations.open": {
        scope: "integrations:write",
        class: "mutation"
      },
      "invite.approve_join": {
        scope: "invite:write",
        class: "mutation"
      },
      "invite.create": {
        scope: "invite:external",
        class: "mutation"
      },
      "invite.revoke": {
        scope: "invite:write",
        class: "mutation"
      },
      "keybindings.get": {
        scope: "keybindings:read",
        class: "read"
      },
      "linear.issue.create": {
        scope: "linear:write",
        class: "mutation"
      },
      "linear.teams.list": {
        scope: "linear:read",
        class: "read"
      },
      "machine.get": {
        scope: "machine:read",
        class: "read"
      },
      "machine.list": {
        scope: "machine:read",
        class: "read"
      },
      "mail.get": {
        scope: "mail:read",
        class: "read"
      },
      "mail.modify": {
        scope: "mail:write",
        class: "mutation"
      },
      "mail.search": {
        scope: "mail:read",
        class: "read"
      },
      "mail.send": {
        scope: "mail:external",
        class: "mutation"
      },
      "mail.thread.get": {
        scope: "mail:read",
        class: "read"
      },
      "mail.threads.peek": {
        scope: "mail:read",
        class: "read"
      },
      "media.control": {
        scope: "media:control",
        class: "mutation"
      },
      "media.get": {
        scope: "media:read",
        class: "read"
      },
      "memory_app.cycle_variant": {
        scope: "memory_app:write",
        class: "mutation"
      },
      "memory_app.open": {
        scope: "memory_app:write",
        class: "mutation"
      },
      "memory_app.reload": {
        scope: "memory_app:read",
        class: "read"
      },
      "memory.search": {
        scope: "memory:read",
        class: "read"
      },
      "message.edit": {
        scope: "message:write",
        class: "mutation"
      },
      "message.retract": {
        scope: "message:write",
        class: "mutation"
      },
      "message.send": {
        scope: "message:write",
        class: "mutation"
      },
      "mux.ack": {
        scope: "mux:write",
        class: "mutation"
      },
      "mux.configure": {
        scope: "mux:write",
        class: "mutation"
      },
      "net.fetch": {
        scope: "net:<host>",
        class: "runtime"
      },
      "notes.append": {
        scope: "notes:write",
        class: "mutation"
      },
      "notes.capture": {
        scope: "notes:write",
        class: "mutation"
      },
      "notes.create": {
        scope: "notes:write",
        class: "mutation"
      },
      "notes.cycle_variant": {
        scope: "notes:write",
        class: "mutation"
      },
      "notes.export": {
        scope: "notes:write",
        class: "mutation"
      },
      "notes.import": {
        scope: "notes:write",
        class: "mutation"
      },
      "notes.list": {
        scope: "notes:read",
        class: "read"
      },
      "notes.new_note": {
        scope: "notes:write",
        class: "mutation"
      },
      "notes.open": {
        scope: "notes:write",
        class: "mutation"
      },
      "notes.read": {
        scope: "notes:read",
        class: "read"
      },
      "notes.search": {
        scope: "notes:read",
        class: "read"
      },
      "notification.ack": {
        scope: "notification:write",
        class: "mutation"
      },
      "notification.clear": {
        scope: "notification:write",
        class: "mutation"
      },
      "notification.create": {
        scope: "notification:write",
        class: "mutation"
      },
      "notification.list": {
        scope: "notification:read",
        class: "read"
      },
      "page.follow": {
        scope: "page:write",
        class: "mutation"
      },
      "page.hints": {
        scope: "page:write",
        class: "mutation"
      },
      "page.read": {
        scope: "page:read",
        class: "read"
      },
      "palette_usage.forget": {
        scope: "palette_usage:write",
        class: "mutation"
      },
      "palette_usage.get": {
        scope: "palette_usage:read",
        class: "read"
      },
      "palette_usage.hide": {
        scope: "palette_usage:write",
        class: "mutation"
      },
      "palette_usage.import": {
        scope: "palette_usage:write",
        class: "mutation"
      },
      "palette_usage.record": {
        scope: "palette_usage:write",
        class: "mutation"
      },
      "pane.create": {
        scope: "workspace:write",
        class: "mutation"
      },
      "pane.focus": {
        scope: "workspace:write",
        class: "mutation"
      },
      "pane.focus_direction": {
        scope: "workspace:write",
        class: "mutation"
      },
      "pane.get": {
        scope: "workspace:read",
        class: "read"
      },
      "pane.list": {
        scope: "workspace:read",
        class: "read"
      },
      "pane.move": {
        scope: "workspace:write",
        class: "mutation"
      },
      "pane.neighbor.get": {
        scope: "workspace:read",
        class: "read"
      },
      "pane.rename": {
        scope: "workspace:write",
        class: "mutation"
      },
      "pane.run": {
        scope: "workspace:execute",
        class: "mutation"
      },
      "pane.split": {
        scope: "workspace:write",
        class: "mutation"
      },
      "pane.split_ratio.set": {
        scope: "workspace:write",
        class: "mutation"
      },
      "pane.swap": {
        scope: "workspace:write",
        class: "mutation"
      },
      "pane.viewport_width.set": {
        scope: "workspace:write",
        class: "mutation"
      },
      "pane.zoom": {
        scope: "workspace:write",
        class: "mutation"
      },
      "participant.avatar.get": {
        scope: "participant:read",
        class: "read"
      },
      "participant.avatar.set": {
        scope: "participant:write",
        class: "mutation"
      },
      "participants.add": {
        scope: "participants:write",
        class: "mutation"
      },
      "participants.set_role": {
        scope: "participants:write",
        class: "mutation"
      },
      "participants.unban": {
        scope: "participants:write",
        class: "mutation"
      },
      "project.actions.list": {
        scope: "project:read",
        class: "read"
      },
      "project.add": {
        scope: "project:write",
        class: "mutation"
      },
      "project.list": {
        scope: "project:read",
        class: "read"
      },
      "project.observe": {
        scope: "project:write",
        class: "mutation"
      },
      "project.remove": {
        scope: "project:write",
        class: "mutation"
      },
      "project.source.update": {
        scope: "project:write",
        class: "mutation"
      },
      "project.sync": {
        scope: "project:write",
        class: "mutation"
      },
      "project.update": {
        scope: "project:write",
        class: "mutation"
      },
      "push.target.register": {
        scope: "push:write",
        class: "mutation"
      },
      "push.target.remove": {
        scope: "push:write",
        class: "mutation"
      },
      "rd.audit.list": {
        scope: "rd:read",
        class: "read"
      },
      "rd.bench": {
        scope: "rd:read",
        class: "read"
      },
      "rd.control.release": {
        scope: "rd:write",
        class: "mutation"
      },
      "rd.control.request": {
        scope: "rd:execute",
        class: "mutation"
      },
      "rd.host.disable": {
        scope: "rd:write",
        class: "mutation"
      },
      "rd.host.enable": {
        scope: "rd:write",
        class: "mutation"
      },
      "rd.host.grant": {
        scope: "rd:execute",
        class: "mutation"
      },
      "rd.host.revoke": {
        scope: "rd:write",
        class: "mutation"
      },
      "rd.host.stop_all": {
        scope: "rd:write",
        class: "mutation"
      },
      "rd.session.list": {
        scope: "rd:read",
        class: "read"
      },
      "rd.session.start": {
        scope: "rd:execute",
        class: "mutation"
      },
      "rd.session.stop": {
        scope: "rd:write",
        class: "mutation"
      },
      "rd.view.open": {
        scope: "rd:write",
        class: "mutation"
      },
      "reaction.add": {
        scope: "reaction:write",
        class: "mutation"
      },
      "reaction.remove": {
        scope: "reaction:write",
        class: "mutation"
      },
      "read_cursor.set": {
        scope: "read_cursor:write",
        class: "mutation"
      },
      "room.create": {
        scope: "room:write",
        class: "mutation"
      },
      "room.delete": {
        scope: "room:write",
        class: "mutation"
      },
      "room.follow": {
        scope: "room:write",
        class: "mutation"
      },
      "room.list": {
        scope: "room:read",
        class: "read"
      },
      "room.move": {
        scope: "room:write",
        class: "mutation"
      },
      "room.pin": {
        scope: "room:write",
        class: "mutation"
      },
      "room.unpin": {
        scope: "room:write",
        class: "mutation"
      },
      "room.update": {
        scope: "room:write",
        class: "mutation"
      },
      "run.get": {
        scope: "run:read",
        class: "read"
      },
      "run.list": {
        scope: "run:read",
        class: "read"
      },
      "saved_tab_group.delete": {
        scope: "saved_tab_group:write",
        class: "mutation"
      },
      "saved_tab_group.list": {
        scope: "saved_tab_group:read",
        class: "read"
      },
      "saved_tab_group.reopen": {
        scope: "saved_tab_group:write",
        class: "mutation"
      },
      "saved_tab_group.save": {
        scope: "saved_tab_group:write",
        class: "mutation"
      },
      "screen_group.add_screens": {
        scope: "screen_group:write",
        class: "mutation"
      },
      "screen_group.create": {
        scope: "screen_group:write",
        class: "mutation"
      },
      "screen_group.get": {
        scope: "screen_group:read",
        class: "read"
      },
      "screen_group.list": {
        scope: "screen_group:read",
        class: "read"
      },
      "screen_group.remove_screens": {
        scope: "screen_group:write",
        class: "mutation"
      },
      "screen_group.ungroup": {
        scope: "screen_group:write",
        class: "mutation"
      },
      "screen_group.update": {
        scope: "screen_group:write",
        class: "mutation"
      },
      "screen.create": {
        scope: "workspace:write",
        class: "mutation"
      },
      "screen.focus": {
        scope: "workspace:write",
        class: "mutation"
      },
      "screen.get": {
        scope: "workspace:read",
        class: "read"
      },
      "screen.layout.export": {
        scope: "workspace:read",
        class: "read"
      },
      "screen.layout.undo": {
        scope: "workspace:write",
        class: "mutation"
      },
      "screen.list": {
        scope: "workspace:read",
        class: "read"
      },
      "screen.move": {
        scope: "workspace:write",
        class: "mutation"
      },
      "screen.rename": {
        scope: "workspace:write",
        class: "mutation"
      },
      "screen.update": {
        scope: "workspace:write",
        class: "mutation"
      },
      "search_app.clear_recent": {
        scope: "search_app:write",
        class: "mutation"
      },
      "search_app.cycle_variant": {
        scope: "search_app:write",
        class: "mutation"
      },
      "search_app.search": {
        scope: "search_app:read",
        class: "read"
      },
      "server.network.confirm": {
        scope: "server:write",
        class: "mutation"
      },
      "session.get": {
        scope: "session:read",
        class: "read"
      },
      "session.journal.append": {
        scope: "session:write",
        class: "mutation"
      },
      "session.journal.checkpoint.create": {
        scope: "session:write",
        class: "mutation"
      },
      "session.journal.checkpoint.list": {
        scope: "session:read",
        class: "read"
      },
      "session.journal.hook.list": {
        scope: "session:read",
        class: "read"
      },
      "session.journal.hook.put": {
        scope: "session:execute",
        class: "mutation"
      },
      "session.journal.producer.list": {
        scope: "session:read",
        class: "read"
      },
      "session.journal.producer.put": {
        scope: "session:write",
        class: "mutation"
      },
      "session.journal.restore.preview": {
        scope: "session:read",
        class: "read"
      },
      "session.journal.segment.list": {
        scope: "session:read",
        class: "read"
      },
      "session.journal.segment.seal": {
        scope: "session:write",
        class: "mutation"
      },
      "session.list": {
        scope: "session:read",
        class: "read"
      },
      "session.ping": {
        scope: "session:read",
        class: "read"
      },
      "session.snapshot": {
        scope: "session:read",
        class: "read"
      },
      "session.terminal_defaults.update": {
        scope: "session:write",
        class: "mutation"
      },
      "session.window.title.clear": {
        scope: "session:write",
        class: "mutation"
      },
      "session.window.title.set": {
        scope: "session:write",
        class: "mutation"
      },
      "settings.get": {
        scope: "settings:read",
        class: "read"
      },
      "settings.history": {
        scope: "settings:read",
        class: "read"
      },
      "settings.list": {
        scope: "settings:read",
        class: "read"
      },
      "settings.schema": {
        scope: "settings:read",
        class: "read"
      },
      "settings.snapshot": {
        scope: "settings:read",
        class: "read"
      },
      "sidebar_layout.get": {
        scope: "sidebar_layout:read",
        class: "read"
      },
      "sidebar_layout.update": {
        scope: "sidebar_layout:write",
        class: "mutation"
      },
      "sidebar_view.ensure": {
        scope: "sidebar_view:write",
        class: "mutation"
      },
      "sidebar_view.get": {
        scope: "sidebar_view:read",
        class: "read"
      },
      "sidebar_view.input": {
        scope: "sidebar_view:write",
        class: "mutation"
      },
      "sidebar_view.reload": {
        scope: "sidebar_view:write",
        class: "mutation"
      },
      "sidebar_view.resize": {
        scope: "sidebar_view:write",
        class: "mutation"
      },
      "sidebar.adopt": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.apply": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.get": {
        scope: "sidebar:read",
        class: "read"
      },
      "sidebar.group.create": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.group.ungroup": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.group.update": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.item.add": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.item.remove": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.item.remove_ref": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.item.update": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.move": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.pin": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.reset": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.section.add": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.section.move": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.section.remove": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.section.update": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "sidebar.unpin": {
        scope: "sidebar:write",
        class: "mutation"
      },
      "signal.publish": {
        scope: "none",
        class: "mutation"
      },
      "signal.read": {
        scope: "none",
        class: "read"
      },
      "signal.sources.list": {
        scope: "none",
        class: "read"
      },
      "skills_app.cycle_variant": {
        scope: "skills_app:write",
        class: "mutation"
      },
      "skills_app.open": {
        scope: "skills_app:write",
        class: "mutation"
      },
      "skills_app.reload": {
        scope: "skills_app:read",
        class: "read"
      },
      "slack.post_as_bot": {
        scope: "slack:external",
        class: "mutation"
      },
      "stash.create": {
        scope: "stash:write",
        class: "mutation"
      },
      "stash.delete": {
        scope: "stash:write",
        class: "mutation"
      },
      "stash.import": {
        scope: "stash:write",
        class: "mutation"
      },
      "stash.list": {
        scope: "stash:read",
        class: "read"
      },
      "stash.restore": {
        scope: "stash:write",
        class: "mutation"
      },
      "system_calendar.events": {
        scope: "system_calendar:read",
        class: "read"
      },
      "system_calendar.request_access": {
        scope: "system_calendar:read",
        class: "mutation"
      },
      "tab_group.add_tabs": {
        scope: "tab_group:write",
        class: "mutation"
      },
      "tab_group.create": {
        scope: "tab_group:write",
        class: "mutation"
      },
      "tab_group.get": {
        scope: "tab_group:read",
        class: "read"
      },
      "tab_group.list": {
        scope: "tab_group:read",
        class: "read"
      },
      "tab_group.move": {
        scope: "tab_group:write",
        class: "mutation"
      },
      "tab_group.remove_tabs": {
        scope: "tab_group:write",
        class: "mutation"
      },
      "tab_group.ungroup": {
        scope: "tab_group:write",
        class: "mutation"
      },
      "tab_group.update": {
        scope: "tab_group:write",
        class: "mutation"
      },
      "tab.create_browser": {
        scope: "workspace:write",
        class: "mutation"
      },
      "tab.create_terminal": {
        scope: "workspace:write",
        class: "mutation"
      },
      "tab.focus": {
        scope: "workspace:write",
        class: "mutation"
      },
      "tab.get": {
        scope: "workspace:read",
        class: "read"
      },
      "tab.list": {
        scope: "workspace:read",
        class: "read"
      },
      "tab.move": {
        scope: "workspace:write",
        class: "mutation"
      },
      "tab.pin": {
        scope: "workspace:write",
        class: "mutation"
      },
      "tab.rename": {
        scope: "workspace:write",
        class: "mutation"
      },
      "tab.unpin": {
        scope: "workspace:write",
        class: "mutation"
      },
      "tab.update": {
        scope: "workspace:write",
        class: "mutation"
      },
      "team_vm.accounts": {
        scope: "team_vm:read",
        class: "read"
      },
      "team_vm.ensure_awake": {
        scope: "team_vm:write",
        class: "mutation"
      },
      "team_vm.journal.append": {
        scope: "team_vm:write",
        class: "mutation"
      },
      "team_vm.journal.high_water": {
        scope: "team_vm:read",
        class: "read"
      },
      "team_vm.journal.read": {
        scope: "team_vm:read",
        class: "read"
      },
      "team_vm.lease.release": {
        scope: "team_vm:write",
        class: "mutation"
      },
      "team_vm.ssh_ca": {
        scope: "team_vm:read",
        class: "read"
      },
      "team_vm.ssh_cert": {
        scope: "team_vm:execute",
        class: "mutation"
      },
      "team_vm.ssh_cert.revoke": {
        scope: "team_vm:write",
        class: "mutation"
      },
      "team_vm.status": {
        scope: "team_vm:read",
        class: "read"
      },
      "team.ai_limit.get": {
        scope: "team:read",
        class: "read"
      },
      "team.cloud.session.archive": {
        scope: "team:write",
        class: "mutation"
      },
      "team.cloud.session.follow": {
        scope: "team:write",
        class: "mutation"
      },
      "team.cloud.session.get": {
        scope: "team:read",
        class: "read"
      },
      "team.cloud.session.list": {
        scope: "team:read",
        class: "read"
      },
      "team.cloud.session.publish": {
        scope: "team:write",
        class: "mutation"
      },
      "team.cloud.session.reassign": {
        scope: "team:write",
        class: "mutation"
      },
      "team.cloud.session.remove": {
        scope: "team:write",
        class: "mutation"
      },
      "team.cloud.session.viewing": {
        scope: "team:write",
        class: "mutation"
      },
      "team.device.compliance": {
        scope: "team:read",
        class: "read"
      },
      "team.device.enroll": {
        scope: "team:write",
        class: "mutation"
      },
      "team.device.policy": {
        scope: "team:read",
        class: "read"
      },
      "team.device.release": {
        scope: "team:write",
        class: "mutation"
      },
      "team.device.report_status": {
        scope: "team:write",
        class: "mutation"
      },
      "team.directory": {
        scope: "team:read",
        class: "read"
      },
      "team.hosts.list": {
        scope: "team:read",
        class: "read"
      },
      "team.members.list": {
        scope: "team:read",
        class: "read"
      },
      "team.policy.get": {
        scope: "team:read",
        class: "read"
      },
      "team.policy.history": {
        scope: "team:read",
        class: "read"
      },
      "team.policy.rollback": {
        scope: "team:write",
        class: "mutation"
      },
      "team.policy.update": {
        scope: "team:write",
        class: "mutation"
      },
      "terminal.attach": {
        scope: "terminal:execute",
        class: "stream_open"
      },
      "terminal.copy": {
        scope: "terminal:read",
        class: "read"
      },
      "terminal.get": {
        scope: "terminal:read",
        class: "read"
      },
      "terminal.history.read": {
        scope: "terminal:read",
        class: "read"
      },
      "terminal.input.focus": {
        scope: "terminal:write",
        class: "mutation"
      },
      "terminal.input.keys": {
        scope: "terminal:execute",
        class: "mutation"
      },
      "terminal.input.mouse": {
        scope: "terminal:execute",
        class: "mutation"
      },
      "terminal.input.write": {
        scope: "terminal:execute",
        class: "mutation"
      },
      "terminal.list": {
        scope: "terminal:read",
        class: "read"
      },
      "terminal.move": {
        scope: "terminal:write",
        class: "mutation"
      },
      "terminal.output_read": {
        scope: "terminal:read",
        class: "read"
      },
      "terminal.process.get": {
        scope: "terminal:read",
        class: "read"
      },
      "terminal.project": {
        scope: "terminal:execute",
        class: "mutation"
      },
      "terminal.screen.read": {
        scope: "terminal:read",
        class: "read"
      },
      "terminal.state.read": {
        scope: "terminal:read",
        class: "read"
      },
      "terminal.viewport.scroll": {
        scope: "terminal:write",
        class: "mutation"
      },
      "terminal.wait": {
        scope: "terminal:read",
        class: "read"
      },
      "terminal.wait_exit": {
        scope: "terminal:read",
        class: "read"
      },
      "theme.scheme.convert": {
        scope: "theme:read",
        class: "read"
      },
      "theme.scheme.export": {
        scope: "theme:read",
        class: "read"
      },
      "theme.scheme.from_image": {
        scope: "theme:read",
        class: "read"
      },
      "theme.slots.resolve": {
        scope: "theme:read",
        class: "read"
      },
      "thread.update": {
        scope: "thread:write",
        class: "mutation"
      },
      "title.set": {
        scope: "title:write",
        class: "mutation"
      },
      "toast.show": {
        scope: "none",
        class: "mutation"
      },
      "usage_app.cycle_variant": {
        scope: "usage_app:write",
        class: "mutation"
      },
      "usage_app.refresh": {
        scope: "usage_app:write",
        class: "mutation"
      },
      "usage_app.show": {
        scope: "usage_app:write",
        class: "mutation"
      },
      "usage_app.status": {
        scope: "usage_app:read",
        class: "read"
      },
      "usage.summary": {
        scope: "usage:read",
        class: "read"
      },
      "window_record.delete": {
        scope: "window_record:write",
        class: "mutation"
      },
      "window_record.list": {
        scope: "window_record:read",
        class: "read"
      },
      "window_record.put": {
        scope: "window_record:write",
        class: "mutation"
      },
      "workspace_checklist.add": {
        scope: "workspace_checklist:write",
        class: "mutation"
      },
      "workspace_checklist.list": {
        scope: "workspace_checklist:read",
        class: "read"
      },
      "workspace_checklist.remove": {
        scope: "workspace_checklist:write",
        class: "mutation"
      },
      "workspace_checklist.update": {
        scope: "workspace_checklist:write",
        class: "mutation"
      },
      "workspace_group.create": {
        scope: "workspace_group:write",
        class: "mutation"
      },
      "workspace_group.delete": {
        scope: "workspace_group:write",
        class: "mutation"
      },
      "workspace_group.list": {
        scope: "workspace_group:read",
        class: "read"
      },
      "workspace_group.move": {
        scope: "workspace_group:write",
        class: "mutation"
      },
      "workspace_group.update": {
        scope: "workspace_group:write",
        class: "mutation"
      },
      "workspace_log.append": {
        scope: "workspace_log:write",
        class: "mutation"
      },
      "workspace_log.clear": {
        scope: "workspace_log:write",
        class: "mutation"
      },
      "workspace_log.list": {
        scope: "workspace_log:read",
        class: "read"
      },
      "workspace_progress.clear": {
        scope: "workspace_progress:write",
        class: "mutation"
      },
      "workspace_progress.set": {
        scope: "workspace_progress:write",
        class: "mutation"
      },
      "workspace_status.clear": {
        scope: "workspace_status:write",
        class: "mutation"
      },
      "workspace_status.list": {
        scope: "workspace_status:read",
        class: "read"
      },
      "workspace_status.set": {
        scope: "workspace_status:write",
        class: "mutation"
      },
      "workspace.create": {
        scope: "workspace:write",
        class: "mutation"
      },
      "workspace.ensure_app": {
        scope: "workspace:write",
        class: "mutation"
      },
      "workspace.ensure_home": {
        scope: "workspace:write",
        class: "mutation"
      },
      "workspace.focus": {
        scope: "workspace:write",
        class: "mutation"
      },
      "workspace.get": {
        scope: "workspace:read",
        class: "read"
      },
      "workspace.layout.apply": {
        scope: "workspace:write",
        class: "mutation"
      },
      "workspace.list": {
        scope: "workspace:read",
        class: "read"
      },
      "workspace.move": {
        scope: "workspace:write",
        class: "mutation"
      },
      "workspace.place": {
        scope: "workspace:write",
        class: "mutation"
      },
      "workspace.placement.list": {
        scope: "workspace:read",
        class: "read"
      },
      "workspace.rename": {
        scope: "workspace:write",
        class: "mutation"
      },
      "workspace.run": {
        scope: "workspace:execute",
        class: "mutation"
      },
      "workspace.update": {
        scope: "workspace:write",
        class: "mutation"
      }
    },
    never: [
      "agent.message.list",
      "agent.message.mark",
      "agent.message.release",
      "agent.message.send",
      "agent.message.unsend",
      "automation.delete",
      "automation.secret.list",
      "automation.secret.remove",
      "automation.secret.set",
      "automation.settings.set",
      "automation.webhook.get",
      "browser.attach",
      "browser.close",
      "browser.viewer.release",
      "browser.viewer.resize",
      "browser_import.read",
      "chief.archive",
      "chief.delete",
      "classic_import.plan",
      "classic_import.record",
      "client.cell_pixels.set",
      "client.detach",
      "client.get",
      "client.list",
      "client.metadata.update",
      "client.sizing.release",
      "client.sizing.set",
      "cloud.billing.checkout",
      "cloud.environment.boot",
      "cloud.environment.build",
      "cloud.environment.delete",
      "cloud.fs.remove",
      "cloud.machine.archive_delete",
      "cloud.machine.chat_access",
      "cloud.machine.chief_resize",
      "cloud.machine.chief_start",
      "cloud.machine.create",
      "cloud.machine.delete",
      "cloud.machine.fork",
      "cloud.machine.io",
      "cloud.machine.link_token",
      "cloud.machine.resize",
      "cloud.machine.share_chat",
      "cloud.owner.acpmux_keyed_start",
      "cloud.owner.acpmux_person_holds",
      "cloud.owner.fork_run",
      "cloud.owner.github_app",
      "cloud.owner.github_connect",
      "cloud.owner.github_repos",
      "cloud.owner.handoff_begin_turn",
      "cloud.owner.handoff_open",
      "cloud.owner.handoff_wait",
      "cloud.owner.handoffs",
      "cloud.owner.harness_login_copy",
      "cloud.owner.turn_checkpoint",
      "cloud.owner.turn_rewind",
      "cloud.owner.turns",
      "cloud.port.close",
      "cloud.previews.create_link",
      "cloud.previews.refresh",
      "cloud.previews.revoke_link",
      "cloud.runs.cancel",
      "cloud.runs.create",
      "cloud.runs.sandbox",
      "cloud.runs.start",
      "cloud.runs.wait",
      "cloud.snapshot.create",
      "cloud.snapshot.delete",
      "cloud.snapshot.restore",
      "cloud.surge.create",
      "cloud.vm.domains",
      "cloud.vm.firewall_create",
      "cloud.vm.firewall_delete",
      "cloud.vm.firewall_get",
      "cloud.vm.firewall_list",
      "cloud.vm.networks",
      "cloud.vm.provision_api",
      "cloud.vm.publication_api_keys",
      "cloud.vm.publications",
      "cloud.vm.revoke_publication_api_key",
      "cloud.vm.scp_endpoint",
      "cloud.vm.tunnel_attach",
      "cloud.vm.tunnel_detach",
      "cloud.vm.tunnel_enroll",
      "cloud.vm.tunnel_revoke",
      "cloud.vm.tunnel_rotate_key",
      "conductor_import.plan",
      "conductor_import.record",
      "conversation.events",
      "credential.mint",
      "credential.rotate",
      "credential.verify",
      "diff.comments.send",
      "domain.claim",
      "domain.release",
      "domain.verify",
      "firewall.create",
      "firewall.delete",
      "firewall.get",
      "firewall.list",
      "frontend_projection.get",
      "frontend_projection.put",
      "grant.create",
      "grant.revoke",
      "history.backups.purge",
      "history.clear",
      "history.entries.list",
      "history.entries.remove",
      "history.restore",
      "history.site.remove",
      "history.trail.record",
      "history.visit.import",
      "history.visit.record",
      "history.visit.remove",
      "history.visit.summaries",
      "history.visit.title",
      "home.requests.list",
      "home.settings.set",
      "host.enroll",
      "host.network.bind",
      "host.network.policy",
      "host.network.target",
      "host.remove",
      "host.replica.purge",
      "install.list",
      "install.register",
      "install.rename",
      "install.revoke",
      "install.sign_out",
      "integration.approval.get",
      "integration.complete",
      "integration.connect",
      "integration.policy.set",
      "integration.revoke",
      "invite.accept",
      "invite.accept_verified",
      "keybindings.remove",
      "keybindings.reset",
      "keybindings.set",
      "language_packs.ensure",
      "layout.bulk",
      "network.list",
      "origin.confirmation.issue",
      "ownership.transfer",
      "pairing_request.list",
      "pairing_request.resolve",
      "palette.rank",
      "pane.close",
      "participants.remove",
      "request.cancel",
      "request.dismiss",
      "screen.close",
      "server.pair.approve",
      "server.pair.invite",
      "server.pair.preview",
      "server.revoke",
      "session.creation.resolve",
      "session.events",
      "session.journal.subscribe",
      "session.open",
      "session.reload_config",
      "session.shutdown",
      "settings.edit",
      "settings.reset",
      "settings.reset_all",
      "settings.reset_group",
      "settings.restore",
      "settings.set",
      "settings.undo",
      "sidebar_view.attach",
      "sso.connection.activate",
      "sso.connection.create",
      "sso.connection.disable",
      "sso.connection.list",
      "sso.connection.set_secret",
      "stream.cancel",
      "tab.close",
      "tab_group.close",
      "team.agent_key.remove",
      "team.agent_key.set",
      "team.agent_key.status",
      "team.ai_limit.member.set",
      "team.ai_limit.set",
      "team.audit.list",
      "team.enrollment_token.create",
      "team.enrollment_token.list",
      "team.enrollment_token.revoke",
      "team.integration.release_lock",
      "team.members.remove",
      "team.models_policy.get",
      "team.models_policy.set",
      "team_vm.rebuild",
      "team_vm.retired.delete",
      "team_vm.retired.export",
      "team_vm.ssh_ca.rotate",
      "team_vm.ssh_cert.challenge",
      "team_vm.taint.accept",
      "terminal.close",
      "terminal.history.clear",
      "terminal.renderer_grant.create",
      "terminal.viewer.release",
      "terminal.viewer.resize",
      "tunnel.attach",
      "tunnel.detach",
      "tunnel.rotate-key",
      "usage.cap.set",
      "user.ensure",
      "user.presence_key.list",
      "user.presence_key.revoke",
      "user.teams.list",
      "user.text_confirm.get",
      "user.text_confirm.level.set",
      "user.text_confirm.lower",
      "user.text_confirm.lower.challenge",
      "workspace.agent_folder.set",
      "workspace.agent_start.get",
      "workspace.close",
      "workspace.open_url"
    ]
  };
  var TYPE_ROLES = {
    numeral: { size: 34, weight: "semibold" },
    heading: { size: 20, weight: "semibold" },
    title: { size: 15, weight: "semibold" },
    label: { size: 13, weight: "semibold" },
    body: { size: 13, weight: "regular" },
    caption: { size: 12, weight: "regular" },
    footnote: { size: 11, weight: "regular" }
  };
  var WIDGET_TYPE = {
    bigNumber: TYPE_ROLES.numeral.size,
    title: TYPE_ROLES.title.size,
    label: TYPE_ROLES.label.size,
    body: TYPE_ROLES.body.size,
    caption: TYPE_ROLES.caption.size,
    footnote: TYPE_ROLES.footnote.size
  };
  function widget(render) {
    return render;
  }
  var WIDGET_INSET = { newtab: 16, sidebar: 12 };
  var API_VERSION = scopes_default.apiVersion;
  var g = globalThis;
  var RUNTIME_VERSION = String(globalThis.__cmuxAppRuntimeVersion ?? "");
  var cmux = g.cmux;
  var { signal, computed, effect, onCleanup, untrack } = g;
  var {
    VStack,
    HStack,
    ZStack,
    LazyVStack,
    Group,
    ForEach,
    Reorderable,
    Text,
    Icon,
    Image,
    Button,
    Menu,
    Spacer,
    Divider,
    Row,
    Badge,
    EmptyState,
    Panel,
    Toggle,
    Slider,
    TextField,
    ProgressView,
    Circle,
    Capsule,
    Rectangle,
    RoundedRectangle,
    Line,
    Particles
  } = g;
  var linearGradient = g.linearGradient ?? ((colors, angle) => ({ linear: angle === undefined ? { colors: [...colors] } : { colors: [...colors], angle } }));
  var radialGradient = g.radialGradient ?? ((colors) => ({ radial: { colors: [...colors] } }));
  var EVENT_STREAMS = Object.keys(events_default.events);
  var HOURS_SHOWN = 6;
  var DAYS_SHOWN = 6;
  var FAHRENHEIT = new Set(["US", "BS", "BZ", "KY", "LR", "PW", "FM", "MH", "PR", "GU", "VI", "AS", "MP", "UM"]);
  var TWELVE_HOUR = new Set(["US", "CA", "AU", "NZ", "IN", "PH", "PK", "BD", "EG", "SA", "CO", "MY", "PR", "GU", "VI", "AS", "MP"]);
  function localeRegion(locale) {
    const parts = locale.replace(/_/g, "-").split("-").slice(1);
    return (parts.find((part) => /^[A-Za-z]{2}$/.test(part)) ?? "").toUpperCase();
  }
  function unitsFor(locale, setting, country = "") {
    const region = localeRegion(locale) || country.toUpperCase();
    const fahrenheit = setting === "fahrenheit" ? true : setting === "celsius" ? false : FAHRENHEIT.has(region);
    return { fahrenheit, twelveHour: TWELVE_HOUR.has(region) };
  }
  function shown(celsius, units) {
    const value = units.fahrenheit ? celsius * 9 / 5 + 32 : celsius;
    return Math.round(value) || 0;
  }
  function describe(code, day) {
    if (code === 0)
      return day ? { text: "Sunny", symbol: "sun.max.fill" } : { text: "Clear", symbol: "moon.stars.fill" };
    if (code === 1)
      return day ? { text: "Mostly Sunny", symbol: "sun.max.fill" } : { text: "Mostly Clear", symbol: "moon.stars.fill" };
    if (code === 2)
      return { text: "Partly Cloudy", symbol: day ? "cloud.sun.fill" : "cloud.moon.fill" };
    if (code === 3)
      return { text: "Cloudy", symbol: "cloud.fill" };
    if (code === 45 || code === 48)
      return { text: "Foggy", symbol: "cloud.fog.fill" };
    if (code >= 51 && code <= 55)
      return { text: "Drizzle", symbol: "cloud.drizzle.fill" };
    if (code === 56 || code === 57)
      return { text: "Freezing Drizzle", symbol: "cloud.sleet.fill" };
    if (code === 61 || code === 63)
      return { text: "Rain", symbol: "cloud.rain.fill" };
    if (code === 65)
      return { text: "Heavy Rain", symbol: "cloud.heavyrain.fill" };
    if (code === 66 || code === 67)
      return { text: "Freezing Rain", symbol: "cloud.sleet.fill" };
    if (code === 71 || code === 73)
      return { text: "Snow", symbol: "cloud.snow.fill" };
    if (code === 75)
      return { text: "Heavy Snow", symbol: "snowflake" };
    if (code === 77)
      return { text: "Flurries", symbol: "cloud.snow.fill" };
    if (code === 80 || code === 81)
      return { text: "Showers", symbol: day ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill" };
    if (code === 82)
      return { text: "Heavy Showers", symbol: "cloud.heavyrain.fill" };
    if (code === 85 || code === 86)
      return { text: "Snow Showers", symbol: "cloud.snow.fill" };
    if (code >= 95)
      return { text: "Thunderstorms", symbol: "cloud.bolt.rain.fill" };
    return { text: "Cloudy", symbol: "cloud.fill" };
  }
  function symbolColor(symbol) {
    return symbol === "sun.max.fill" ? "#FFD60A" : "#FFFFFF";
  }
  function skyFor(code, day) {
    if (code >= 95)
      return "storm";
    if (code === 45 || code === 48)
      return "fog";
    if (code >= 71 && code <= 77 || code === 85 || code === 86)
      return "snow";
    if (code >= 51)
      return day ? "rain-day" : "rain-night";
    if (code === 3)
      return day ? "cloudy-day" : "cloudy-night";
    return day ? "clear-day" : "clear-night";
  }
  var SKY_GRADIENTS = {
    "clear-day": ["#235C9B", "#3076B4"],
    "clear-night": ["#0B1A3A", "#253B6E", "#3A4E86"],
    "cloudy-day": ["#526B82", "#607589"],
    "cloudy-night": ["#1D2636", "#3C485C"],
    "rain-day": ["#354D63", "#566F85"],
    "rain-night": ["#151D2B", "#2E3C50"],
    snow: ["#425B73", "#60758A"],
    fog: ["#435661", "#5C707C"],
    storm: ["#24283A", "#5A5874"]
  };
  function hourLabel(time, twelveHour) {
    const hour = Number(time.slice(11, 13));
    if (!twelveHour)
      return String(hour).padStart(2, "0");
    const h = hour % 12 === 0 ? 12 : hour % 12;
    return `${h} ${hour < 12 ? "AM" : "PM"}`;
  }
  var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  function weekday(date) {
    const [y, m, d] = date.split("-").map(Number);
    return WEEKDAYS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
  }
  function toForecast(body) {
    const now = body.current.time;
    const nowHour = now.slice(0, 13);
    let start = body.hourly.time.findIndex((t) => t.slice(0, 13) > nowHour);
    if (start < 0)
      start = body.hourly.time.length;
    const hours = [];
    for (let i = start;i < body.hourly.time.length && hours.length < HOURS_SHOWN; i++) {
      hours.push({ time: body.hourly.time[i], temperature: body.hourly.temperature_2m[i], code: body.hourly.weather_code[i], day: body.hourly.is_day[i] === 1 });
    }
    const today = now.slice(0, 10);
    let first = body.daily.time.indexOf(today);
    if (first < 0)
      first = 0;
    const days = [];
    for (let i = first;i < body.daily.time.length && days.length < DAYS_SHOWN; i++) {
      days.push({
        date: body.daily.time[i],
        today: i === first,
        code: body.daily.weather_code[i],
        high: body.daily.temperature_2m_max[i],
        low: body.daily.temperature_2m_min[i]
      });
    }
    const temperature = body.current.temperature_2m;
    const todayRange = days[0] ?? { high: temperature, low: temperature };
    return {
      temperature,
      code: body.current.weather_code,
      day: body.current.is_day === 1,
      high: Math.max(todayRange.high, temperature),
      low: Math.min(todayRange.low, temperature),
      hours,
      days
    };
  }
  function isForecast(body) {
    const b = body;
    return !!b?.current && Array.isArray(b.hourly?.time) && Array.isArray(b.daily?.time);
  }
  function forecastURL(place) {
    return `https://api.open-meteo.com/v1/forecast?latitude=${place.latitude.toFixed(3)}&longitude=${place.longitude.toFixed(3)}` + "&current=temperature_2m,weather_code,is_day" + "&hourly=temperature_2m,weather_code,is_day&forecast_hours=24" + `&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=${DAYS_SHOWN + 1}&timezone=auto`;
  }
  var GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search?count=1&name=";
  var IP_LOCATION_URL = "https://get.geojs.io/v1/ip/geo.json";
  function placeFromGeoJS(body) {
    const latitude = Number(body.latitude);
    const longitude = Number(body.longitude);
    if (body.latitude == null || body.longitude == null || !Number.isFinite(latitude) || !Number.isFinite(longitude))
      return null;
    const name = body.city || body.region || body.country || "Your area";
    const region = body.city ? body.region || body.country || "" : body.country || "";
    return { name, region, country: body.country_code ?? "", latitude, longitude, source: "approximate" };
  }
  function placeFromGeocode(body) {
    const hit = body.results?.[0];
    if (!hit)
      return null;
    return {
      name: hit.name,
      region: hit.admin1 ?? hit.country ?? "",
      country: hit.country_code ?? "",
      latitude: hit.latitude,
      longitude: hit.longitude,
      source: "typed"
    };
  }
  function weekRange(days, units) {
    if (days.length === 0)
      return { min: 0, max: 1 };
    const min = Math.min(...days.map((d) => shown(d.low, units)));
    const max = Math.max(...days.map((d) => shown(d.high, units)));
    return { min, max: max === min ? min + 1 : max };
  }
  var SAMPLE_PLACE = { name: "Cupertino", region: "California", country: "US", latitude: 37.323, longitude: -122.032, source: "approximate" };
  var hours = [
    ["10", 25, 0],
    ["11", 26.7, 1],
    ["12", 27.2, 2],
    ["13", 27.2, 2],
    ["14", 29.4, 0],
    ["15", 31.1, 0]
  ];
  var days = [
    ["2026-06-05", 0, 23.9, 15],
    ["2026-06-06", 1, 26, 14],
    ["2026-06-07", 2, 24, 13],
    ["2026-06-08", 3, 21, 12],
    ["2026-06-09", 61, 18, 11],
    ["2026-06-10", 0, 22, 12]
  ];
  var SAMPLE_FORECAST = {
    temperature: 21.1,
    code: 0,
    day: true,
    high: 23.9,
    low: 15,
    hours: hours.map(([h, temperature, code]) => ({ time: `2026-06-05T${h}:00`, temperature, code, day: true })),
    days: days.map(([date, code, high, low], i) => ({ date, today: i === 0, code, high, low }))
  };
  var REUSE_MS = 10 * 60000;
  var REFRESH_MS = 15 * 60000;
  var IP_PLACE_MS = 6 * 60 * 60000;
  var STORE_READING = "reading";
  var STORE_IP_PLACE = "ip-place";
  var t = (key, fallback, params) => cmux.t(key, fallback, params);
  var [reading, setReading] = signal(null);
  var [problem, setProblem] = signal(null);
  var typedPlace = (s) => String(s.place ?? "").trim();
  var keyOf = (s) => typedPlace(s).toLowerCase();
  function explain(error) {
    const e = error;
    if (e?.code === "scope.missing")
      return t("problem.network", "Allow network access for Weather in Settings > Apps.");
    return e?.message ?? String(error);
  }
  async function getJSON(url) {
    const response = await cmux.net.fetch(url);
    if (!response.ok)
      throw new Error(t("problem.status", "The weather service answered {status}.", { status: response.status }));
    return response.json();
  }
  async function locate(name) {
    if (name) {
      const place = placeFromGeocode(await getJSON(GEOCODE_URL + encodeURIComponent(name)));
      if (!place)
        throw new Error(t("problem.noPlace", "No place called {name}.", { name }));
      return place;
    }
    const kept = await cmux.storage.get(STORE_IP_PLACE).catch(() => null);
    if (kept && Date.now() - kept.at < IP_PLACE_MS)
      return kept.place;
    const place = placeFromGeoJS(await getJSON(IP_LOCATION_URL));
    if (!place)
      throw new Error(t("problem.noLocation", "Couldn't tell where you are. Type a place in Settings > Apps > Weather."));
    cmux.storage.set(STORE_IP_PLACE, { place, at: Date.now() }).catch(() => {
      return;
    });
    return place;
  }
  var restored = null;
  function restore() {
    restored ??= cmux.storage.get(STORE_READING).then((kept) => {
      if (kept?.forecast && !reading())
        setReading(kept);
    }).catch(() => {
      return;
    });
    return restored;
  }
  var inflight = new Map;
  function load(settings, force = false) {
    const key = keyOf(settings);
    const running = inflight.get(key);
    if (running)
      return running;
    const job = (async () => {
      await restore();
      const last = reading();
      if (!force && last?.key === key && Date.now() - last.at < REUSE_MS)
        return;
      try {
        const place = last?.key === key ? last.place : await locate(typedPlace(settings));
        const body = await getJSON(forecastURL(place));
        if (!isForecast(body))
          throw new Error(t("problem.shape", "The weather service sent an answer Weather can't read."));
        const next = { key, place, forecast: toForecast(body), at: Date.now() };
        setReading(next);
        setProblem(null);
        cmux.storage.set(STORE_READING, next).catch(() => {
          return;
        });
      } catch (error) {
        setProblem(explain(error));
      } finally {
        inflight.delete(key);
      }
    })();
    inflight.set(key, job);
    return job;
  }
  var degrees = (celsius, look) => `${shown(celsius, look.units)}°`;
  function symbol(name, size, look) {
    const color = symbolColor(name);
    const icon = Icon(name).size(size).font(size).color(look.sky || color !== "#FFFFFF" ? color : look.text);
    return look.sky ? icon.symbolRendering("multicolor") : icon;
  }
  function header(r, look, big) {
    return VStack({ spacing: 0 }, [
      HStack({ spacing: 3 }, [
        Text(r.place.name).font(15).weight("semibold").color(look.text).lineLimit(1),
        r.place.source === "approximate" ? Icon("location.fill").size(10).font(10).color(look.text) : null
      ]),
      Text(degrees(r.forecast.temperature, look)).font(big).weight("regular").color(look.text).lineLimit(1)
    ]);
  }
  function conditionLines(r, look, alignment) {
    const c = describe(r.forecast.code, r.forecast.day);
    return VStack({ spacing: 2, alignment }, [
      symbol(c.symbol, 16, look),
      Text(t(`condition.${c.text}`, c.text)).font(13).weight("semibold").color(look.text).lineLimit(1),
      Text(t("highLow", "H:{high} L:{low}", { high: degrees(r.forecast.high, look), low: degrees(r.forecast.low, look) })).font(13).weight("semibold").color(look.text).lineLimit(1)
    ]);
  }
  function hourColumn(h, look) {
    return VStack({ spacing: 5, alignment: "center" }, [
      Text(hourLabel(h.time, look.units.twelveHour)).font(11).weight("semibold").color(look.secondary).lineLimit(1),
      symbol(describe(h.code, h.day).symbol, 18, look),
      Text(degrees(h.temperature, look)).font(14).weight("semibold").color(look.text).lineLimit(1)
    ]).frame({ maxWidth: "infinity" });
  }
  function hourStrip(r, look) {
    return HStack({ spacing: 0 }, r.forecast.hours.flatMap((h, i) => i === 0 ? [hourColumn(h, look)] : [Spacer(), hourColumn(h, look)]));
  }
  var BAR_WIDTH = 72;
  function rangeBar(d, span, look) {
    const scale = BAR_WIDTH / (span.max - span.min);
    const from = Math.max(0, Math.round((shown(d.low, look.units) - span.min) * scale));
    const to = Math.min(BAR_WIDTH, Math.max(from + 6, Math.round((shown(d.high, look.units) - span.min) * scale)));
    return HStack({ spacing: 0 }, [
      HStack([]).frame({ width: from, height: 4 }),
      HStack([]).frame({ width: to - from, height: 4 }).background(look.sky ? "#FFD60A" : cmux.theme.accent).cornerRadius(2),
      Spacer()
    ]).frame({ width: BAR_WIDTH, height: 4 }).background(look.sky ? "#FFFFFF33" : cmux.theme.separator).cornerRadius(2);
  }
  function dayRow(d, span, look) {
    const name = d.today ? t("today", "Today") : t(`weekday.${weekday(d.date)}`, weekday(d.date));
    return HStack({ spacing: 8 }, [
      Text(name).font(14).weight("semibold").color(look.text).lineLimit(1).frame({ width: 48 }),
      symbol(describe(d.code, true).symbol, 16, look).frame({ width: 24 }),
      Spacer(),
      Text(degrees(d.low, look)).font(14).weight("semibold").color(look.secondary).frame({ width: 32 }),
      rangeBar(d, span, look),
      Text(degrees(d.high, look)).font(14).weight("semibold").color(look.text).frame({ width: 32 })
    ]);
  }
  function small(r, look) {
    return VStack({ spacing: 0 }, [header(r, look, 44), Spacer(), conditionLines(r, look, "leading")]);
  }
  function top(r, look) {
    return HStack({ spacing: 8 }, [header(r, look, 40), Spacer(), conditionLines(r, look, "trailing")]);
  }
  function medium(r, look) {
    return VStack({ spacing: 0 }, [top(r, look), Spacer(), hourStrip(r, look)]);
  }
  function large(r, look) {
    const span = weekRange(r.forecast.days, look.units);
    return VStack({ spacing: 10 }, [
      top(r, look),
      hourStrip(r, look),
      HStack([]).frame({ height: 1, maxWidth: "infinity" }).background(look.sky ? "#FFFFFF40" : cmux.theme.separator),
      VStack({ spacing: 6 }, r.forecast.days.map((d) => dayRow(d, span, look))),
      Spacer()
    ]);
  }
  function waiting(look, message) {
    return VStack({ spacing: 4 }, [
      Text(t("title", "Weather")).font(15).weight("semibold").color(look.text),
      Text("--°").font(44).weight("light").color(look.text),
      Spacer(),
      Text(message ?? t("loading", "Finding the weather near you…")).font(12).weight("medium").color(look.secondary).lineLimit(3)
    ]);
  }
  var drawWeather = widget((ctx = {}) => {
    const size = ctx.size ?? "small";
    const preview = ctx.preview === true;
    const settings = computed(() => ({ ...cmux.app.settings(), ...ctx.settings ?? {} }));
    if (!ctx.now && !preview)
      cmux.timer.every(REFRESH_MS, () => void load(settings()));
    let seen = null;
    const watchKey = () => {
      if (preview)
        return null;
      const key = `${keyOf(settings())}|${ctx.now?.() ?? 0}`;
      if (key !== seen) {
        seen = key;
        load(settings());
      }
      return null;
    };
    const shownReading = computed(() => preview ? { key: keyOf(settings()), place: SAMPLE_PLACE, forecast: SAMPLE_FORECAST, at: 0 } : reading());
    const look = computed(() => {
      const s = settings();
      const units = unitsFor(ctx.locale || cmux.app.locale || "en", s.units, shownReading()?.place.country ?? "");
      return s.look === "plain" ? { sky: false, text: cmux.theme.text.primary, secondary: cmux.theme.text.secondary, units } : { sky: true, text: "#FFFFFF", secondary: "#FFFFFF", units };
    });
    const sky = computed(() => {
      if (!look().sky)
        return null;
      const r = shownReading();
      return linearGradient(SKY_GRADIENTS[r ? skyFor(r.forecast.code, r.forecast.day) : "clear-day"], 180);
    });
    return VStack({ spacing: 0 }, [
      watchKey,
      () => {
        const r = shownReading();
        const l = look();
        if (!r || r.key !== keyOf(settings()))
          return waiting(l, problem());
        if (size === "large")
          return large(r, l);
        if (size === "medium")
          return medium(r, l);
        return small(r, l);
      }
    ]).padding(ctx.place === "sidebar" ? WIDGET_INSET.sidebar : WIDGET_INSET.newtab).frame({ maxWidth: "infinity", maxHeight: "infinity" }).background(sky).contextMenu(() => preview ? [] : [Button(t("refresh", "Refresh weather"), () => load(settings(), true))]);
  });
  function renderWeather(ctx) {
    return drawWeather(ctx);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
