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
    renderProjects: () => renderProjects
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
      "cloud.machine.chief_start",
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
  var linearGradient = g.linearGradient ?? ((colors, angle) => ({ linear: angle === undefined ? { colors: [...colors] } : { colors: [...colors], angle } }));
  var radialGradient = g.radialGradient ?? ((colors) => ({ radial: { colors: [...colors] } }));
  var EVENT_STREAMS = Object.keys(events_default.events);
  var COUNT = { small: 4, medium: 8, large: 8 };
  var READ = { limit: 16 };
  var TILE_COLORS = ["#ff3b30", "#ff9500", "#34c759", "#00c7be", "#30b0c7", "#007aff", "#5856d6", "#af52de", "#ff2d55", "#a2845e"];
  function hash(text) {
    let h = 2166136261;
    for (let i = 0;i < text.length; i++) {
      h ^= text.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    return h;
  }
  function colorOf(key) {
    return TILE_COLORS[hash(key) % TILE_COLORS.length];
  }
  function displayName(p) {
    const rename = p.overlay?.rename?.trim();
    return rename || p.name || p.path.split("/").filter(Boolean).pop() || p.path;
  }
  function letterOf(name) {
    const match = /[\p{L}\p{N}]/u.exec(name);
    return match ? match[0].toLocaleUpperCase() : "?";
  }
  var lastUsed = (p) => Number(p.last_used_ms) || 0;
  function recent(projects, count) {
    return projects.filter((p) => p.state !== "missing" && !p.overlay?.hidden).slice().sort((a, b) => {
      const pa = a.overlay?.pinned ? 1 : 0;
      const pb = b.overlay?.pinned ? 1 : 0;
      if (pa !== pb)
        return pb - pa;
      if (pa && pb) {
        const oa = a.overlay?.order ?? Number.MAX_SAFE_INTEGER;
        const ob = b.overlay?.order ?? Number.MAX_SAFE_INTEGER;
        if (oa !== ob)
          return oa - ob;
      }
      return lastUsed(b) - lastUsed(a) || displayName(a).localeCompare(displayName(b));
    }).slice(0, count);
  }
  function shortPath(path) {
    const home = /^(\/Users\/[^/]+|\/home\/[^/]+|\/root)(?=\/|$)/.exec(path);
    return home ? `~${path.slice(home[0].length)}` : path;
  }
  function age(lastUsedMs, now) {
    const minutes = Math.floor(Math.max(0, now - lastUsedMs) / 60000);
    if (minutes < 1)
      return "now";
    if (minutes < 60)
      return `${minutes}m`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24)
      return `${hours}h`;
    const days = Math.floor(hours / 24);
    if (days < 7)
      return `${days}d`;
    return `${Math.floor(days / 7)}w`;
  }
  function machineColor(id, name) {
    return colorOf(`machine:${id || name}`);
  }
  var MINUTE = 60000;
  var p = (name, path, minutesAgo, now, overlay = {}) => ({
    path,
    name,
    last_used_ms: String(now - minutesAgo * MINUTE),
    overlay,
    state: "present"
  });
  var SAMPLE_MACHINE = { id: "machine_sample", name: "MacBook Pro" };
  function SAMPLE_PROJECTS(now) {
    return [
      p("cmux", "/Users/me/code/cmux", 2, now, { pinned: true, order: 0 }),
      p("website", "/Users/me/code/website", 25, now),
      p("api", "/Users/me/code/api", 3 * 60, now),
      p("dotfiles", "/Users/me/dotfiles", 26 * 60, now),
      p("notes", "/Users/me/Documents/notes", 3 * 24 * 60, now),
      p("ios-app", "/Users/me/code/ios-app", 5 * 24 * 60, now),
      p("design-system", "/Users/me/code/design-system", 9 * 24 * 60, now),
      p("blog", "/Users/me/code/blog", 20 * 24 * 60, now)
    ];
  }
  var TYPE = { heading: 11, name: 11, row: 13, detail: 11 };
  var TILE = { small: 40, medium: 40, large: 28 };
  var t = (key, fallback, params) => cmux.t(key, fallback, params);
  function renderProjects(ctx) {
    const size = ctx.size ?? "small";
    const preview = Boolean(ctx.preview);
    const list = preview ? null : cmux.live("project.list", { ...READ });
    const machine = preview ? null : cmux.live("machine.get", {});
    if (list) {
      let first = true;
      effect(() => {
        ctx.now();
        if (first)
          first = false;
        else
          list.refresh();
      });
    }
    const load = () => {
      if (!list)
        return { state: "ready", projects: SAMPLE_PROJECTS(ctx.now()) };
      const answer = list();
      const error = list.error();
      if (!answer && error)
        return { state: "error", code: error.code ?? "operation.failed" };
      if (!answer)
        return { state: "loading" };
      return { state: "ready", projects: answer.projects ?? [] };
    };
    const machineNow = () => machine ? machine() ?? null : SAMPLE_MACHINE;
    const open = (p) => {
      if (preview)
        return;
      cmux.workspace.create({ initial_content: "terminal", cwd: p.path, name: displayName(p), focus: true }).catch(() => cmux.toast({ title: t("openFailed", "Could not open {name}", { name: displayName(p) }), tone: "warning" }));
    };
    const inset = ctx.place === "sidebar" ? WIDGET_INSET.sidebar : WIDGET_INSET.newtab;
    const body = () => {
      const current = load();
      const head = header(machineNow(), size === "small");
      if (current.state === "loading")
        return VStack({ spacing: 8, alignment: "leading" }, [head, Spacer()]);
      if (current.state === "error")
        return VStack({ spacing: 8, alignment: "leading" }, [head, notice(errorText(current.code)), Spacer()]);
      const shown = recent(current.projects, COUNT[size]);
      if (shown.length === 0)
        return VStack({ spacing: 8, alignment: "leading" }, [head, notice(t("empty", "Open a folder in cmux and it shows here.")), Spacer()]);
      if (size === "large")
        return VStack({ spacing: 8, alignment: "leading" }, [head, ...shown.map((p) => row(p, ctx.now(), open)), Spacer()]);
      return VStack({ spacing: 10, alignment: "leading" }, [head, grid(shown, size === "small" ? 2 : 4, open), Spacer()]);
    };
    return VStack({ alignment: "leading", spacing: 0 }, [body]).padding(inset).frame({ maxWidth: "infinity", maxHeight: "infinity", alignment: "topLeading" });
  }
  function header(machine, compact) {
    const title = Text(t("title", "PROJECTS")).font(TYPE.heading).weight("semibold").color("secondary").lineLimit(1);
    return HStack({ spacing: 6, alignment: "center" }, [
      compact && machine?.name ? null : title,
      compact && machine?.name ? null : Spacer(),
      machine?.name ? HStack({ spacing: 4, alignment: "center" }, [
        VStack([]).frame({ width: 7, height: 7 }).background(machineColor(machine.id, machine.name)).cornerRadius(3.5),
        Text(machine.name).font(TYPE.heading).weight("semibold").lineLimit(1)
      ]) : null
    ]).frame({ maxWidth: "infinity" });
  }
  function tile(p, side) {
    return ZStack([
      VStack([]).frame({ width: side, height: side }).background(colorOf(p.path)).cornerRadius(side * 0.225),
      Text(letterOf(displayName(p))).font(Math.round(side * 0.5)).weight("semibold").color("#ffffff")
    ]).frame({ width: side, height: side });
  }
  function grid(projects, columns, open) {
    const rows = [];
    for (let i = 0;i < projects.length; i += columns) {
      const cells = projects.slice(i, i + columns).map((p) => VStack({ spacing: 4, alignment: "center" }, [tile(p, TILE.small), Text(displayName(p)).font(TYPE.name).lineLimit(1)]).frame({ maxWidth: "infinity" }).onTap(() => open(p)));
      while (cells.length < columns)
        cells.push(VStack([]).frame({ maxWidth: "infinity" }));
      rows.push(HStack({ spacing: 8, alignment: "top" }, cells).frame({ maxWidth: "infinity" }));
    }
    return VStack({ spacing: 8, alignment: "leading" }, rows).frame({ maxWidth: "infinity" });
  }
  function row(p, now, open) {
    return HStack({ spacing: 8, alignment: "center" }, [
      tile(p, TILE.large),
      VStack({ spacing: 0, alignment: "leading" }, [
        Text(displayName(p)).font(TYPE.row).weight("medium").lineLimit(1),
        Text(shortPath(p.path)).font(TYPE.detail).color("secondary").lineLimit(1)
      ]),
      Spacer(),
      Text(age(Number(p.last_used_ms) || 0, now)).font(TYPE.detail).color("secondary").lineLimit(1)
    ]).frame({ maxWidth: "infinity" }).onTap(() => open(p));
  }
  function notice(text) {
    return Text(text).font(TYPE.detail).color("secondary").lineLimit(4);
  }
  function errorText(code) {
    if (code === "scope.missing")
      return t("scope", "Turn on project access for Projects in Settings > Apps.");
    return t("failed", "Your projects could not be read just now.");
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
