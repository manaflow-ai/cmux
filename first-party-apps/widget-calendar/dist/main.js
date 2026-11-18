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
    renderCalendar: () => renderCalendar,
    zoneOffset: () => zoneOffset
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
      "cloud.vm.attention.emit": {
        scope: "cloud:execute",
        class: "mutation"
      },
      "cloud.vm.event.emit": {
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
      "coderouter.app.connect_account": {
        scope: "coderouter:write",
        class: "mutation"
      },
      "coderouter.app.create_key": {
        scope: "coderouter:write",
        class: "mutation"
      },
      "coderouter.app.open": {
        scope: "coderouter:write",
        class: "mutation"
      },
      "coderouter.app.run_test": {
        scope: "coderouter:execute",
        class: "mutation"
      },
      "coderouter.app.start_onboarding": {
        scope: "coderouter:write",
        class: "mutation"
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
      "cloud.machine.create",
      "cloud.machine.delete",
      "cloud.machine.io",
      "cloud.machine.link_token",
      "cloud.machine.resize",
      "cloud.machine.share_chat",
      "cloud.owner.acpmux_keyed_start",
      "cloud.owner.acpmux_person_holds",
      "cloud.owner.fork_run",
      "cloud.owner.github_app",
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
      "settings.set",
      "sidebar_view.attach",
      "sso.connection.activate",
      "sso.connection.create",
      "sso.connection.disable",
      "sso.connection.list",
      "sso.connection.set_secret",
      "stream.cancel",
      "tab.close",
      "tab_group.close",
      "team.ai_limit.member.set",
      "team.ai_limit.set",
      "team.audit.list",
      "team.enrollment_token.create",
      "team.enrollment_token.list",
      "team.enrollment_token.revoke",
      "team.integration.release_lock",
      "team.members.remove",
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
    Line
  } = g;
  var EVENT_STREAMS = Object.keys(events_default.events);
  var localOffset = (at) => -new Date(at).getTimezoneOffset();
  var DAY = 24 * 60 * 60 * 1000;
  var HOUR = 60 * 60 * 1000;
  var WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  function wall(at, off = localOffset) {
    return new Date(at + off(at) * 60000);
  }
  function fromWall(wallMs, off, near) {
    const guess = wallMs - off(near) * 60000;
    return wallMs - off(guess) * 60000;
  }
  function startOfDay(at, off = localOffset) {
    const w = wall(at, off);
    return fromWall(Date.UTC(w.getUTCFullYear(), w.getUTCMonth(), w.getUTCDate()), off, at);
  }
  function startOfNextDay(at, off = localOffset) {
    const w = wall(at, off);
    return fromWall(Date.UTC(w.getUTCFullYear(), w.getUTCMonth(), w.getUTCDate() + 1), off, at + DAY);
  }
  function hourOfDay(at, dayStart, off = localOffset) {
    return (at + off(at) * 60000 - (dayStart + off(dayStart) * 60000)) / HOUR;
  }
  var READ = { days: 2, limit: 50 };
  function weekdayHeading(now, off = localOffset) {
    return WEEKDAYS[wall(now, off).getUTCDay()].toUpperCase();
  }
  function dayNumber(now, off = localOffset) {
    return String(wall(now, off).getUTCDate());
  }
  function agenda(events, now, off = localOffset) {
    const tomorrowStart = startOfNextDay(now, off);
    const tomorrowEnd = startOfNextDay(tomorrowStart, off);
    const out = { allDayToday: [], today: [], allDayTomorrow: [], tomorrow: [] };
    const sorted = [...events].sort((a, b) => a.start - b.start || a.end - b.end || a.title.localeCompare(b.title));
    for (const e of sorted) {
      if (e.allDay) {
        if (e.start < tomorrowStart && e.end > now)
          out.allDayToday.push(e);
        if (e.start < tomorrowEnd && e.end > tomorrowStart)
          out.allDayTomorrow.push(e);
        continue;
      }
      if (e.end <= now)
        continue;
      if (e.start < tomorrowStart)
        out.today.push(e);
      else if (e.start < tomorrowEnd)
        out.tomorrow.push(e);
    }
    return out;
  }
  function uses12Hour(locale, cycle = "system") {
    if (cycle !== "system")
      return cycle === "12h";
    const region = (locale.split(/[-_]/)[1] ?? "").toUpperCase();
    const language = (locale.split(/[-_]/)[0] ?? "en").toLowerCase();
    if (region)
      return ["US", "CA", "AU", "NZ", "IN", "PH", "PK", "EG", "SA", "MX", "CO"].includes(region);
    return language === "en";
  }
  function clock(at, twelve, off = localOffset) {
    const d = wall(at, off);
    const h = d.getUTCHours();
    const m = String(d.getUTCMinutes()).padStart(2, "0");
    if (!twelve)
      return { time: `${String(h).padStart(2, "0")}:${m}`, period: "" };
    return { time: `${h % 12 === 0 ? 12 : h % 12}:${m}`, period: h < 12 ? "AM" : "PM" };
  }
  function timeRange(e, twelve, off = localOffset) {
    const a = clock(e.start, twelve, off);
    const b = clock(e.end, twelve, off);
    if (!twelve)
      return `${a.time}–${b.time}`;
    if (a.period === b.period && startOfDay(e.start, off) === startOfDay(e.end, off))
      return `${a.time}–${b.time} ${b.period}`;
    return `${a.time} ${a.period}–${b.time} ${b.period}`;
  }
  function startTime(e, twelve, off = localOffset) {
    const a = clock(e.start, twelve, off);
    return twelve ? `${a.time} ${a.period}` : a.time;
  }
  function hourLabel(hour, twelve) {
    const h = (hour % 24 + 24) % 24;
    return twelve ? String(h % 12 === 0 ? 12 : h % 12) : String(h);
  }
  var HEX = /^#[0-9a-fA-F]{6}$/;
  function tintOf(color) {
    return color && HEX.test(color) ? `${color}2e` : "#1badf82e";
  }
  function barOf(color) {
    return color && HEX.test(color) ? color : "#1badf8";
  }
  var CALENDAR_RED = "#ff3b30";
  function gridColumn(events, dayStart, hours, off = localOffset, now) {
    const at = (e) => hourOfDay(e, dayStart, off);
    let first;
    if (now !== undefined)
      first = Math.floor(at(now));
    else {
      const earliest = events.length > 0 ? Math.min(...events.map((e) => at(e.start))) : 8;
      first = Math.floor(Math.max(0, earliest)) - 1;
    }
    const startHour = Math.max(0, Math.min(24 - hours, first));
    const endHour = startHour + hours;
    const shown = events.map((e) => ({ e, from: Math.max(startHour, at(e.start)), to: Math.min(endHour, at(e.end)) })).filter((b) => b.to > b.from).sort((a, b) => a.from - b.from || b.to - a.to);
    const blocks = lanes(shown);
    const column = { startHour, endHour, blocks };
    if (now !== undefined) {
      const h = at(now);
      if (h >= startHour && h <= endHour)
        column.now = h;
    }
    return column;
  }
  function lanes(sorted) {
    const out = [];
    let run = [];
    let runEnd = -Infinity;
    let ends = [];
    const close = () => {
      for (const b of run)
        b.lanes = Math.max(1, ends.length);
      run = [];
      ends = [];
    };
    for (const s of sorted) {
      if (s.from >= runEnd) {
        close();
        runEnd = -Infinity;
      }
      let lane = ends.findIndex((end) => end <= s.from);
      if (lane < 0)
        lane = ends.push(s.to) - 1;
      else
        ends[lane] = s.to;
      const block = { ...s, lane, lanes: 1 };
      run.push(block);
      out.push(block);
      runEnd = Math.max(runEnd, s.to);
    }
    close();
    return out;
  }
  var HOUR2 = 60 * 60 * 1000;
  function at(day, hour, minute, off) {
    return startOfDay(day, off) + hour * HOUR2 + minute * 60000;
  }
  var COLORS = { work: "#1badf8", home: "#63da38", family: "#cc73e1", birthdays: "#ff9500" };
  function event(id, title, start, minutes, calendar, location) {
    return {
      id,
      title,
      start,
      end: start + minutes * 60 * 1000,
      allDay: false,
      calendar: calendar[0].toUpperCase() + calendar.slice(1),
      color: COLORS[calendar],
      ...location ? { location } : {}
    };
  }
  function SAMPLE_EVENTS(now, off = localOffset) {
    const today = startOfDay(now, off);
    const tomorrow = startOfNextDay(today, off);
    return [
      event("yoga", "Yoga Class", at(today, 16, 0, off), 60, "family", "Golden Gate Park"),
      event("dinner", "Dinner with Ravi", at(today, 18, 0, off), 90, "home", "Nopa"),
      event("coffee", "Pick up coffee", at(tomorrow, 8, 30, off), 30, "home", "Coffee Shop"),
      event("standup", "Team standup", at(tomorrow, 10, 0, off), 15, "work", "Zoom")
    ];
  }
  var TYPE = { heading: 11, day: 32, title: 13, detail: 12, label: 11, hour: 11 };
  var GRID = { hour: 36, gutter: 20, label: 16, hours: 7 };
  var BLOCKS = {
    small: { left: 2, right: 0 },
    medium: { left: 1, right: 2 },
    large: { left: 5, right: 6 }
  };
  var t = (key, fallback, params) => cmux.t(key, fallback, params);
  function zoneOffset(zone) {
    if (!zone)
      return localOffset;
    const cache = new Map;
    return (at) => {
      const key = Math.floor(at / 900000);
      let minutes = cache.get(key);
      if (minutes === undefined) {
        try {
          minutes = cmux.time.zone(zone, at).offsetMinutes;
        } catch {
          minutes = localOffset(at);
        }
        if (cache.size > 256)
          cache.clear();
        cache.set(key, minutes);
      }
      return minutes;
    };
  }
  function renderCalendar(ctx) {
    const size = ctx.size ?? "small";
    const settings = ctx.settings ?? {};
    const twelve = uses12Hour(ctx.locale || cmux.app.locale || "en-US", settings.hourCycle);
    const off = zoneOffset(ctx.timeZone);
    const grid = size === "large" && settings.largeLayout !== "list";
    const now = () => ctx.now();
    const live = ctx.preview ? null : cmux.watch("system_calendar.events", { ...READ });
    const sample = { state: "ready", access: "granted", events: SAMPLE_EVENTS(ctx.now(), off) };
    const load = () => {
      if (!live)
        return sample;
      const answer = live.value();
      const error = live.error();
      if (!answer && error)
        return { state: "error", code: error.code ?? "operation.failed" };
      if (!answer)
        return { state: "loading" };
      return { state: "ready", access: answer.access, events: answer.events ?? [] };
    };
    const allow = () => {
      const again = () => live?.refresh();
      cmux.system_calendar.request_access({}).then(again, again);
    };
    const inset = ctx.place === "sidebar" ? WIDGET_INSET.sidebar : WIDGET_INSET.newtab;
    const body = () => {
      const current = load();
      const at = now();
      const header = dateHeader(at, off, grid);
      if (current.state !== "ready" || current.access !== "granted") {
        const notice = current.state === "loading" ? null : accessNotice(current, allow);
        return VStack({ spacing: 8, alignment: "leading" }, [header, notice, Spacer()]);
      }
      if (grid)
        return hourGrid(header, current.events, at, off, twelve);
      return layout(size, header, agenda(current.events, at, off), twelve, off);
    };
    return VStack({ alignment: "leading", spacing: 0 }, [body]).padding(inset).frame({ maxWidth: "infinity", maxHeight: "infinity", alignment: "topLeading" });
  }
  function dateHeader(at, off, grid = false) {
    const view = VStack({ spacing: 0, alignment: "leading" }, [
      Text(weekdayHeading(at, off)).font(TYPE.heading).weight("semibold").color(CALENDAR_RED).lineLimit(1),
      Text(dayNumber(at, off)).font(TYPE.day).weight("regular").lineLimit(1)
    ]);
    return grid ? view.frame({ height: GRID.label + GRID.hour, alignment: "topLeading" }) : view;
  }
  function hourGrid(header, events, at, off, twelve) {
    const day = agenda(events, at, off);
    const todayStart = startOfDay(at, off);
    const tomorrowStart = startOfNextDay(at, off);
    const allDay = day.allDayToday.length > 0 || day.allDayTomorrow.length > 0;
    const hours = GRID.hours - (allDay ? 1 : 0);
    const allDayRow = (list) => allDay ? VStack({ spacing: 2, alignment: "leading" }, [
      ...list.slice(0, 1).map((e) => allDayBlock(e)),
      list.length > 1 ? Text(t("more", "{count} more", { count: list.length - 1 })).font(TYPE.label).color("secondary") : null
    ]).frame({ maxWidth: "infinity", height: GRID.hour, alignment: "topLeading" }) : null;
    const today = gridColumn(day.today, todayStart, hours - 1, off, at);
    const tomorrow = gridColumn(day.tomorrow, tomorrowStart, hours, off);
    return HStack({ spacing: 14, alignment: "top" }, [
      VStack({ spacing: 0, alignment: "leading" }, [header, allDayRow(day.allDayToday), gridView(today, twelve, off, day.today.length === 0 ? t("noMoreToday", "No more events today") : null)]).frame({
        maxWidth: "infinity",
        alignment: "topLeading"
      }),
      VStack({ spacing: 0, alignment: "leading" }, [
        dayLabel(t("tomorrow", "TOMORROW")).frame({ height: GRID.label, alignment: "topLeading" }),
        allDayRow(day.allDayTomorrow),
        gridView(tomorrow, twelve, off, day.tomorrow.length === 0 ? t("noEventsTomorrow", "No events") : null)
      ]).frame({ maxWidth: "infinity", alignment: "topLeading" })
    ]).frame({ maxWidth: "infinity", alignment: "topLeading" });
  }
  function gridView(column, twelve, off, empty = null) {
    const height = (column.endHour - column.startHour) * GRID.hour + 1;
    const y = (hour) => (hour - column.startHour) * GRID.hour;
    const rows = [];
    for (let hour = column.startHour;hour <= column.endHour; hour++) {
      rows.push(HStack({ spacing: 0, alignment: "top" }, [
        Text(hourLabel(hour, twelve)).font(TYPE.hour).weight("semibold").color("secondary").lineLimit(1).frame({ width: GRID.gutter, alignment: "leading" }).offset({ y: -7 }),
        Line({ stroke: "separator" }).frame({ maxWidth: "infinity" })
      ]).frame({ maxWidth: "infinity", height: hour === column.endHour ? 1 : GRID.hour, alignment: "topLeading" }));
    }
    const children = [VStack({ spacing: 0, alignment: "leading" }, rows).frame({ maxWidth: "infinity" })];
    if (empty)
      children.push(HStack({ spacing: 0 }, [VStack([]).frame({ width: GRID.gutter }), Text(empty).font(TYPE.title).color("secondary").lineLimit(2), Spacer()]).frame({ maxWidth: "infinity" }));
    for (const b of column.blocks) {
      const h = Math.max(16, (b.to - b.from) * GRID.hour - 2);
      const lanes = [];
      for (let lane = 0;lane < b.lanes; lane++)
        lanes.push(lane === b.lane ? gridBlock(b.e, h, twelve, off) : VStack([]).frame({ maxWidth: "infinity", height: h }));
      children.push(HStack({ spacing: 2, alignment: "top" }, [VStack([]).frame({ width: GRID.gutter - 2 }), ...lanes]).frame({ maxWidth: "infinity", height: h }).offset({ y: y(b.from) + 1 + h / 2 - height / 2 }));
    }
    if (column.now !== undefined) {
      children.push(HStack({ spacing: 0, alignment: "center" }, [
        VStack([]).frame({ width: GRID.gutter - 3 }),
        Circle({ fill: CALENDAR_RED, size: 6 }),
        Line({ stroke: CALENDAR_RED, strokeWidth: 1.5 }).frame({ maxWidth: "infinity" })
      ]).frame({ maxWidth: "infinity", height: 6 }).offset({ y: y(column.now) - height / 2 }));
    }
    return ZStack(children).frame({ maxWidth: "infinity", height });
  }
  function gridBlock(e, height, twelve, off) {
    const color = barOf(e.color);
    const lines = [Text(e.title || t("untitled", "New Event")).font(TYPE.title).weight("medium").lineLimit(1)];
    if (height >= 34)
      lines.push(Text(startTime(e, twelve, off)).font(TYPE.detail).color(color).lineLimit(1));
    if (height >= 50 && e.location)
      lines.push(Text(e.location).font(TYPE.detail).color(color).lineLimit(1));
    return HStack({ spacing: 5, alignment: "top" }, [
      VStack([]).frame({ width: 3, maxHeight: "infinity" }).background(color).cornerRadius(1.5),
      VStack({ spacing: 0, alignment: "leading" }, lines),
      Spacer()
    ]).padding({ top: 3, bottom: 3, leading: 4, trailing: 4 }).background(tintOf(e.color)).cornerRadius(5).frame({ maxWidth: "infinity", height, alignment: "topLeading" });
  }
  function accessNotice(load, allow) {
    const note = (text) => Text(text).font(TYPE.detail).color("secondary").lineLimit(4);
    if (load.state === "error") {
      if (load.code === "scope.missing")
        return note(t("scope", "Turn on calendar access for Calendar in Settings > Apps."));
      return note(load.code === "provider.unavailable" || load.code === "operation.unsupported" ? t("unavailable", "Your calendar shows here in the cmux app on a Mac.") : t("failed", "Your calendar could not be read just now."));
    }
    switch (load.access) {
      case "unavailable":
        return note(t("unavailable", "Your calendar shows here in the cmux app on a Mac."));
      case "restricted":
        return note(t("restricted", "Calendar access is restricted on this Mac."));
      case "denied":
        return note(t("denied", "Calendar access is off. Turn it on for cmux in System Settings > Privacy & Security > Calendars."));
      default:
        return VStack({ spacing: 6, alignment: "leading" }, [
          note(t("ask", "See your next events here.")),
          Button(t("allow", "Allow Access"), allow)
        ]);
    }
  }
  function layout(size, header, day, twelve, off) {
    const blocks = BLOCKS[size];
    const todayItems = [
      ...day.allDayToday.map((e) => ({ kind: "allDay", e })),
      ...day.today.map((e) => ({ kind: "timed", e }))
    ];
    const tomorrowItems = [
      ...day.allDayTomorrow.map((e) => ({ kind: "allDay", e })),
      ...day.tomorrow.map((e) => ({ kind: "timed", e }))
    ];
    const nothingToday = todayItems.length === 0;
    const noMore = Text(t("noMoreToday", "No more events today")).font(TYPE.title).color("secondary").lineLimit(2);
    if (size === "small") {
      const shown = todayItems.slice(0, blocks.left);
      const rich = shown.length === 1;
      return VStack({ spacing: 6, alignment: "leading" }, [
        header,
        nothingToday ? noMore : null,
        ...shown.map((item) => itemView(item, twelve, rich, off)),
        Spacer()
      ]);
    }
    if (size === "medium") {
      const left = todayItems.slice(0, blocks.left);
      const rest = todayItems.slice(blocks.left);
      const right = [];
      let room = blocks.right;
      for (const item of rest.slice(0, room))
        right.push(itemView(item, twelve, true, off));
      room -= Math.min(rest.length, room);
      if (room > 0 && tomorrowItems.length > 0) {
        right.push(dayLabel(t("tomorrow", "TOMORROW")));
        for (const item of tomorrowItems.slice(0, room))
          right.push(itemView(item, twelve, true, off));
      } else if (nothingToday && tomorrowItems.length === 0) {
        right.push(dayLabel(t("tomorrow", "TOMORROW")));
        right.push(Text(t("noEventsTomorrow", "No events")).font(TYPE.detail).color("secondary"));
      }
      return HStack({ spacing: 12, alignment: "top" }, [
        column([header, nothingToday ? noMore : null, ...left.map((item) => itemView(item, twelve, true, off))]),
        column(right)
      ]).frame({ maxWidth: "infinity", alignment: "topLeading" });
    }
    const more = (count) => count > 0 ? Text(t("more", "{count} more", { count })).font(TYPE.label).weight("semibold").color("secondary") : null;
    const tomorrowColumn = [dayLabel(t("tomorrow", "TOMORROW")).padding({ top: 4, bottom: 14 })];
    if (tomorrowItems.length === 0)
      tomorrowColumn.push(Text(t("noEventsTomorrow", "No events")).font(TYPE.detail).color("secondary"));
    for (const item of tomorrowItems.slice(0, blocks.right))
      tomorrowColumn.push(itemView(item, twelve, true, off));
    tomorrowColumn.push(more(tomorrowItems.length - blocks.right));
    return HStack({ spacing: 12, alignment: "top" }, [
      column([
        header,
        nothingToday ? noMore : null,
        ...todayItems.slice(0, blocks.left).map((item) => itemView(item, twelve, true, off)),
        more(todayItems.length - blocks.left)
      ]),
      column(tomorrowColumn)
    ]).frame({ maxWidth: "infinity", alignment: "topLeading" });
  }
  function column(children) {
    return VStack({ spacing: 6, alignment: "leading" }, [...children, Spacer()]).frame({ maxWidth: "infinity", maxHeight: "infinity", alignment: "topLeading" });
  }
  function dayLabel(text) {
    return Text(text).font(TYPE.label).weight("semibold").color("secondary").lineLimit(1);
  }
  function itemView(item, twelve, rich, off) {
    return item.kind === "allDay" ? allDayBlock(item.e) : eventBlock(item.e, twelve, rich, off);
  }
  function eventBlock(e, twelve, rich, off) {
    const color = barOf(e.color);
    const lines = [Text(e.title || t("untitled", "New Event")).font(TYPE.title).weight("medium").lineLimit(1)];
    if (rich && e.location)
      lines.push(Text(e.location).font(TYPE.detail).color(color).lineLimit(1));
    lines.push(Text(rich ? timeRange(e, twelve, off) : startTime(e, twelve, off)).font(TYPE.detail).color(color).lineLimit(1));
    return block(color, e.color, VStack({ spacing: 0, alignment: "leading" }, lines));
  }
  function allDayBlock(e) {
    const color = barOf(e.color);
    return block(color, e.color, Text(e.title || t("untitled", "New Event")).font(TYPE.title).weight("medium").lineLimit(1));
  }
  function block(bar, color, content) {
    return HStack({ spacing: 6, alignment: "top" }, [
      VStack([]).frame({ width: 3, minHeight: 14, maxHeight: "infinity" }).background(bar).cornerRadius(1.5),
      content,
      Spacer()
    ]).padding({ top: 4, bottom: 4, leading: 5, trailing: 6 }).background(tintOf(color)).cornerRadius(6).frame({ maxWidth: "infinity" });
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
