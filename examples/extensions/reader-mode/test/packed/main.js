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
    toggle: () => toggle
  });
  var events_default = {
    $comment: "The event streams an extension can subscribe to (cmux.events.on, cmux.live). An event is an invalidation with no payload: the app reads again. The daemon delivers a stream only to an app that may call its `reads` op (apps/subscriptions.rs stream_readable), so that op's scope is the stream's scope. tools/gen-cmux-global.ts checks each `reads` against the catalog and writes the SDKs' table (cmux-extension-sdk/api.json); cmux-tui-core's routing tests check that every stream the daemon publishes is listed here.",
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
      "browser.page.back": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.page.eval": {
        scope: "browser:execute",
        class: "mutation"
      },
      "browser.page.forward": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.page.navigate": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.page.new_tab": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.page.reload": {
        scope: "browser:write",
        class: "mutation"
      },
      "browser.page.state": {
        scope: "browser:read",
        class: "read"
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
    RoundedRectangle
  } = g;
  function command(run) {
    return run;
  }
  function browserPage(c = cmux) {
    const run = (op, params) => c.call(`browser.page.${op}`, params);
    return {
      async eval(script, options = {}) {
        const source = typeof script === "function" ? `(${script.toString()})(...${JSON.stringify(options.args ?? [])})` : script;
        const reply = await run("eval", { tab: options.tab, script: source });
        return reply?.value;
      },
      state: (target = {}) => run("state", { ...target }),
      back: (target = {}) => run("back", { ...target }),
      forward: (target = {}) => run("forward", { ...target }),
      reload: (target = {}) => run("reload", { ...target }),
      navigate: (url, target = {}) => run("navigate", { ...target, url }),
      newTab: (url, target = {}) => run("new_tab", { ...target, url })
    };
  }
  var EVENT_STREAMS = Object.keys(events_default.events);

  // examples/extensions/reader-mode/src/page.js
  var page_default = `// Reader mode's page script: one expression that browserPage.eval runs in the page of the focused
// browser tab. Run once, it lays a clean copy of the article (title, byline, text, images) over the
// page; run again, it takes the copy away. The page itself is never changed: no reload, the scroll
// position and anything typed stay, and going back is instant. Its answer is small JSON:
// {reader: true, title, words, minutes} | {reader: false} | {reader: false, reason: "no_article"}.
(() => {
  const ID = "cmux-reader-mode"
  const root = document.documentElement
  const open = document.getElementById(ID)
  if (open) {
    open.remove()
    root.style.overflow = root.getAttribute("data-cmux-reader-overflow") ?? ""
    root.removeAttribute("data-cmux-reader-overflow")
    return { reader: false }
  }

  // ---- Find the article: the block whose paragraphs carry the most text (the readability idea).
  const NEGATIVE = /(^|[-_\\s])(ad|ads|advert|banner|breadcrumbs?|comments?|cookie|footer|footnotes?|masthead|menu|modal|nav|newsletter|outbrain|popup|promo|recirc|related|share|sharing|sidebar|social|sponsor(ed)?|subscribe|taboola|toolbar|widget)([-_\\s]|$)/i
  const POSITIVE = /article|body|content|entry|main|post|prose|story|text/i
  const text = (node) => (node.textContent || "").replace(/\\s+/g, " ").trim()
  const names = (node) => \`\${typeof node.className === "string" ? node.className : ""} \${node.id || ""}\`
  const linkDensity = (node) => {
    const all = text(node).length || 1
    let links = 0
    for (const a of node.querySelectorAll("a")) links += text(a).length
    return links / all
  }
  const TAG_WEIGHT = { ARTICLE: 25, MAIN: 15, SECTION: 5, DIV: 5, TD: 3, BLOCKQUOTE: 3, FORM: -10, UL: -5, OL: -5, LI: -5, ASIDE: -25, NAV: -25, FOOTER: -25, HEADER: -10 }
  const scores = new Map()
  const score = (node, add) => {
    if (!node || node === document.body || node === root) return
    if (!scores.has(node)) {
      let base = TAG_WEIGHT[node.tagName] ?? 0
      const label = names(node)
      if (NEGATIVE.test(label)) base -= 25
      if (POSITIVE.test(label)) base += 25
      scores.set(node, base)
    }
    scores.set(node, scores.get(node) + add)
  }
  for (const p of document.body.querySelectorAll("p, pre")) {
    const length = text(p).length
    if (length < 25) continue
    const points = 1 + text(p).split(/[,،、，]/).length + Math.min(3, Math.floor(length / 100))
    score(p.parentElement, points)
    score(p.parentElement?.parentElement, points / 2)
  }
  let best = null
  let bestScore = -Infinity
  for (const [node, value] of scores) {
    const weighted = value * (1 - linkDensity(node))
    if (weighted > bestScore) [best, bestScore] = [node, weighted]
  }
  best = best ?? document.querySelector("article, [itemprop=articleBody], main, [role=main]")
  if (!best) return { reader: false, reason: "no_article" }

  // A body split into blocks (an ad slot every few paragraphs, the lead image in a block of its
  // own) has its story a few levels up: take the ancestor that holds clearly more story text.
  // Paragraphs under an aside, nav, footer, form or a junk-named block are not story text.
  const junkUnder = (node, top) => {
    for (let at = node; at && at !== top; at = at.parentElement) {
      if (/^(ASIDE|NAV|FOOTER|FORM)$/.test(at.tagName) || NEGATIVE.test(names(at))) return true
    }
    return false
  }
  const storyText = (node) => {
    let length = 0
    for (const p of node.querySelectorAll("p, pre")) {
      const size = text(p).length
      if (size >= 25 && linkDensity(p) < 0.5 && !junkUnder(p, node)) length += size
    }
    return length
  }
  let story = storyText(best)
  for (let up = best.parentElement, depth = 0; up && up !== document.body && up !== root && depth < 8; up = up.parentElement, depth++) {
    const more = storyText(up)
    if (more >= story * 1.25 && linkDensity(up) < 0.35) [best, story] = [up, more]
  }

  // Sibling blocks that belong to the same story (bodies split across several columns).
  const parts = []
  const threshold = Math.max(10, bestScore * 0.2)
  for (const sibling of best.parentElement ? best.parentElement.children : [best]) {
    if (sibling === best) { parts.push(sibling); continue }
    const value = scores.get(sibling)
    const length = text(sibling).length
    if ((value !== undefined && value * (1 - linkDensity(sibling)) >= threshold) ||
        (sibling.tagName === "P" && length > 80 && linkDensity(sibling) < 0.25)) parts.push(sibling)
  }

  // ---- Clean a copy: keep text, headings, lists, quotes, code, tables and images; nothing else.
  const absolute = (value) => { try { return new URL(value, document.baseURI).href } catch { return null } }
  const firstOfSet = (set) => (set || "").split(",").map((s) => s.trim().split(/\\s+/)[0]).filter(Boolean).pop()
  const DROP = "script, style, noscript, template, iframe, form, button, input, select, textarea, nav, aside, footer, dialog, svg, canvas, object, embed, video, audio, [hidden], [aria-hidden=true], [role=dialog], [role=navigation], [role=complementary], " +
    ".byline, [data-component*=byline], [data-testid*=byline]" // the byline shows once, under the title
  const KEEP_ATTRS = { A: ["href", "title"], IMG: ["src", "alt", "title"], TD: ["colspan", "rowspan"], TH: ["colspan", "rowspan"], TIME: ["datetime"], OL: ["start"] }
  const clean = (source) => {
    const copy = source.cloneNode(true)
    for (const node of copy.querySelectorAll(DROP)) node.remove()
    for (const picture of copy.querySelectorAll("picture")) {
      const img = picture.querySelector("img")
      const set = picture.querySelector("source[srcset]")
      if (img && set && !img.getAttribute("src")) img.setAttribute("src", firstOfSet(set.getAttribute("srcset")))
      for (const s of picture.querySelectorAll("source")) s.remove()
    }
    for (const img of copy.querySelectorAll("img")) {
      const lazy = img.getAttribute("data-src") || img.getAttribute("data-lazy-src") || img.getAttribute("data-original") ||
        firstOfSet(img.getAttribute("data-srcset") || img.getAttribute("srcset"))
      const current = img.getAttribute("src") || ""
      const src = absolute(current && !current.startsWith("data:") ? current : lazy || current)
      const tiny = Number(img.getAttribute("width")) > 0 && Number(img.getAttribute("width")) < 48
      if (!src || tiny) img.remove()
      else img.setAttribute("src", src)
    }
    for (const node of [...copy.querySelectorAll("div, section, ul, ol, table, header, span, p")].reverse()) {
      if (!copy.contains(node)) continue // the copy is detached: isConnected is false for all of it
      const length = text(node).length
      const media = node.querySelector("img, pre, table")
      const junk = NEGATIVE.test(names(node)) && !POSITIVE.test(names(node))
      if ((junk && length < 600 && !media) || (length < 300 && linkDensity(node) > 0.5 && !media) || (length === 0 && !media)) node.remove()
    }
    for (const node of [copy, ...copy.querySelectorAll("*")]) {
      const keep = KEEP_ATTRS[node.tagName] ?? []
      for (const attr of [...node.attributes]) if (!keep.includes(attr.name)) node.removeAttribute(attr.name)
      if (node.tagName === "A") {
        const href = absolute(node.getAttribute("href") || "")
        if (href && /^https?:/.test(href)) node.setAttribute("href", href)
        else node.removeAttribute("href")
      }
    }
    return copy
  }

  const meta = (...keys) => {
    for (const key of keys) {
      const value = document.querySelector(\`meta[property="\${key}"], meta[name="\${key}"]\`)?.getAttribute("content")
      if (value && value.trim()) return value.trim()
    }
    return ""
  }
  const heading = document.querySelector("article h1, main h1, h1")
  const title = (heading && text(heading)) || meta("og:title", "twitter:title") || document.title
  // The byline: the names in it when it marks them (a byline block often also holds the date and
  // share buttons), else its text when that is short enough to be only a byline.
  const bylineOf = (block) => {
    if (!block) return ""
    const named = [...block.querySelectorAll("[itemprop=name], [rel=author], [class*=ContributorName], [class*=author-name], [class*=AuthorName]")]
      .map(text).filter(Boolean)
    if (named.length) return \`By \${[...new Set(named)].join(", ")}\`
    const whole = text(block)
    return whole.length <= 80 ? whole : ""
  }
  const byline = meta("author", "article:author", "parsely-author") ||
    bylineOf(document.querySelector("[rel=author], [itemprop=author], .byline, .author, [data-component*=byline], [data-testid*=byline]"))
  const site = meta("og:site_name", "application-name") || location.hostname.replace(/^www\\./, "")
  const body = document.createElement("div")
  for (const part of parts) body.append(clean(part))
  for (const h of body.querySelectorAll("h1")) if (text(h) === title) h.remove()
  const words = text(body).split(" ").filter(Boolean).length
  if (words < 60) return { reader: false, reason: "no_article" }
  const minutes = Math.max(1, Math.round(words / 230))

  // ---- Lay it over the page, in a shadow root so the page's styles never reach it.
  const host = document.createElement("div")
  host.id = ID
  host.setAttribute("style", "all: initial; position: fixed; inset: 0; z-index: 2147483647; display: block;")
  const shadow = host.attachShadow({ mode: "open" })
  shadow.innerHTML = \`<style>
    :host { color-scheme: light dark; }
    .page { position: absolute; inset: 0; overflow-y: auto; outline: none; background: #faf8f4; color: #1d1c1a;
      -webkit-font-smoothing: antialiased; }
    article { max-width: 680px; margin: 0 auto; padding: 64px 28px 120px; font: 400 20px/1.65 "Iowan Old Style", "Charter", Georgia, serif; }
    .site { font: 600 12px/1.4 -apple-system, system-ui, sans-serif; letter-spacing: .06em; text-transform: uppercase; color: #8a847a; }
    h1.title { font: 700 38px/1.18 -apple-system, system-ui, sans-serif; letter-spacing: -.02em; margin: 10px 0 12px; }
    .meta { font: 400 14px/1.5 -apple-system, system-ui, sans-serif; color: #8a847a; margin-bottom: 36px; }
    .body h2, .body h3, .body h4 { font-family: -apple-system, system-ui, sans-serif; line-height: 1.3; margin: 1.6em 0 .5em; }
    .body h2 { font-size: 26px; } .body h3 { font-size: 22px; } .body h4 { font-size: 19px; }
    .body p, .body ul, .body ol, .body blockquote, .body pre, .body table, .body figure { margin: 0 0 1.1em; }
    .body img { display: block; max-width: 100%; height: auto; margin: 1.4em auto; border-radius: 6px; }
    .body figure { margin: 1.6em 0; } .body figcaption, .body small { font: 400 14px/1.45 -apple-system, system-ui, sans-serif; color: #8a847a; }
    .body a { color: #2a5bd7; text-decoration-thickness: 1px; text-underline-offset: 2px; }
    .body blockquote { border-left: 3px solid #d8d2c6; padding-left: 18px; color: #4a4741; font-style: italic; }
    .body pre, .body code { font: 15px/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
    .body pre { overflow-x: auto; padding: 14px 16px; background: rgba(0,0,0,.05); border-radius: 6px; }
    .body table { border-collapse: collapse; font-size: 16px; } .body td, .body th { border: 1px solid #d8d2c6; padding: 6px 10px; }
    .hint { font: 400 12px/1.4 -apple-system, system-ui, sans-serif; color: #a9a397; margin-top: 56px; text-align: center; }
    @media (prefers-color-scheme: dark) {
      .page { background: #1c1b19; color: #e7e3dc; }
      .site, .meta, .body figcaption, .body small { color: #9a9488; }
      .body a { color: #8fb0ff; } .body blockquote { border-color: #46423b; color: #c9c4ba; }
      .body pre { background: rgba(255,255,255,.06); } .body td, .body th { border-color: #46423b; }
      .hint { color: #6d685f; }
    }
  </style><div class="page" tabindex="-1"><article>
    <div class="site"></div><h1 class="title"></h1><div class="meta"></div><div class="body"></div>
    <div class="hint">Reader mode. The same key or Escape goes back to the page.</div>
  </article></div>\`
  shadow.querySelector(".site").textContent = site
  shadow.querySelector(".title").textContent = title
  shadow.querySelector(".meta").textContent = [byline, \`\${minutes} min read\`].filter(Boolean).join(" · ")
  shadow.querySelector(".body").append(...body.childNodes)
  const page = shadow.querySelector(".page")
  page.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return
    event.stopPropagation()
    host.remove()
    root.style.overflow = root.getAttribute("data-cmux-reader-overflow") ?? ""
    root.removeAttribute("data-cmux-reader-overflow")
  })
  root.setAttribute("data-cmux-reader-overflow", root.style.overflow)
  root.style.overflow = "hidden"
  root.append(host)
  page.focus({ preventScroll: true })
  return { reader: true, title, words, minutes }
})()
`;
  var toggle = command(async (args, { cmux }) => {
    try {
      const value = await browserPage(cmux).eval(page_default, { tab: args?.tab });
      if (value?.reason === "no_article")
        await cmux.toast({ title: "No article to read on this page", tone: "warning" });
      return value;
    } catch (error) {
      if (error?.code !== "not_found")
        throw error;
      await cmux.toast({ title: "Reader mode works in a browser tab", tone: "warning" });
      return { reader: false, reason: "no_browser" };
    }
  });
  globalThis.__cmuxAppExports = { ...exports_main };
})();
