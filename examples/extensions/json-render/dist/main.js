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
    renderCard: () => renderCard,
    renderSection: () => renderSection
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
  function section(render) {
    return render;
  }
  function chatWidget(render) {
    return render;
  }
  var EVENT_STREAMS = Object.keys(events_default.events);
  var todo_default = {
    root: "main",
    elements: {
      main: {
        type: "Panel",
        props: {
          title: "Todos"
        },
        children: [
          "summary",
          "add-row",
          "div",
          "list",
          "empty"
        ]
      },
      summary: {
        type: "Stack",
        props: {
          direction: "horizontal",
          spacing: 6
        },
        children: [
          "count-text",
          "sp",
          "count-badge"
        ]
      },
      "count-text": {
        type: "Text",
        props: {
          text: "Tasks",
          font: "caption",
          color: "secondary"
        },
        children: []
      },
      sp: {
        type: "Spacer",
        props: {},
        children: []
      },
      "count-badge": {
        type: "Badge",
        props: {
          text: {
            $template: "${/todos/length}"
          },
          tone: "accent"
        },
        children: []
      },
      "add-row": {
        type: "Stack",
        props: {
          direction: "horizontal",
          spacing: 6
        },
        children: [
          "new-field",
          "add-btn"
        ]
      },
      "new-field": {
        type: "TextField",
        props: {
          value: {
            $bindState: "/newTodo"
          },
          placeholder: "Add a task"
        },
        on: {
          submit: {
            action: "pushState",
            params: {
              statePath: "/todos",
              value: {
                id: "$id",
                title: {
                  $state: "/newTodo"
                },
                done: false
              },
              clearStatePath: "/newTodo"
            }
          }
        },
        children: []
      },
      "add-btn": {
        type: "Button",
        props: {
          label: "Add"
        },
        on: {
          press: {
            action: "pushState",
            params: {
              statePath: "/todos",
              value: {
                id: "$id",
                title: {
                  $state: "/newTodo"
                },
                done: false
              },
              clearStatePath: "/newTodo"
            }
          }
        },
        children: []
      },
      div: {
        type: "Divider",
        props: {},
        children: []
      },
      list: {
        type: "Stack",
        props: {
          spacing: 4
        },
        repeat: {
          statePath: "/todos",
          key: "id"
        },
        children: [
          "item"
        ]
      },
      item: {
        type: "Stack",
        props: {
          direction: "horizontal",
          spacing: 6
        },
        children: [
          "item-toggle",
          "item-sp",
          "item-del"
        ]
      },
      "item-toggle": {
        type: "Toggle",
        props: {
          checked: {
            $bindItem: "done"
          },
          label: {
            $item: "title"
          }
        },
        children: []
      },
      "item-sp": {
        type: "Spacer",
        props: {},
        children: []
      },
      "item-del": {
        type: "Button",
        props: {
          label: "✕"
        },
        on: {
          press: {
            action: "removeState",
            params: {
              statePath: "/todos",
              index: {
                $index: true
              }
            }
          }
        },
        children: []
      },
      empty: {
        type: "Text",
        props: {
          text: "All clear. Add a task above.",
          font: "caption",
          color: "secondary"
        },
        visible: {
          $state: "/todos/length",
          eq: 0
        },
        children: []
      }
    },
    state: {
      newTodo: "",
      todos: [
        {
          id: "1",
          title: "Review open PRs",
          done: false
        },
        {
          id: "2",
          title: "Write release notes",
          done: false
        },
        {
          id: "3",
          title: "Reply to Aziz",
          done: true
        },
        {
          id: "4",
          title: "Fix sidebar spacing",
          done: false
        }
      ]
    }
  };
  var catalog_default = {
    "//": "The parts an agent may use, in json-render's catalog terms. The extension draws only these, each as a cmux kit view; generate/generate.ts turns the same file into json-render's prompt.",
    components: {
      Panel: { description: "A titled group on the app's card surface. Use one per widget.", children: true, props: { title: { type: "string" } } },
      Stack: { description: "Lays children out vertically (default) or horizontally.", children: true, props: { direction: { enum: ["vertical", "horizontal"] }, spacing: { type: "number" } } },
      Text: { description: "A label.", props: { text: { type: "string", required: true }, font: { enum: ["title3", "headline", "body", "callout", "caption"] }, color: { enum: ["primary", "secondary", "accent", "success", "warning", "danger"] } } },
      Row: { description: "A list row with a title, optional subtitle and SF Symbol.", props: { title: { type: "string", required: true }, subtitle: { type: "string" }, symbol: { type: "string" }, tint: { enum: ["primary", "secondary", "accent", "success", "warning", "danger"] } } },
      Button: { description: "A button. on.press runs an action.", events: ["press"], props: { label: { type: "string", required: true } } },
      TextField: { description: "A one-line text input. Bind value with $bindState. on.submit runs on Return.", events: ["submit"], props: { value: { type: "string" }, placeholder: { type: "string" } } },
      Toggle: { description: "A switch with a label. Bind checked with $bindState or $bindItem.", props: { checked: { type: "boolean" }, label: { type: "string" } } },
      Badge: { description: "A small count or status pill.", props: { text: { type: "string", required: true }, tone: { enum: ["secondary", "accent", "success", "warning", "danger"] } } },
      ProgressView: { description: "A progress bar, value 0 to 1.", props: { value: { type: "number" } } },
      EmptyState: { description: "A centered empty or error message.", props: { title: { type: "string", required: true }, message: { type: "string" }, symbol: { type: "string" } } },
      Divider: { description: "A thin separator line.", props: {} },
      Spacer: { description: "Flexible space inside a horizontal Stack.", props: {} }
    },
    actions: ["setState", "pushState", "removeState"],
    limits: { elements: 200, depth: 24 }
  };
  var CATALOG = catalog_default;
  var isObj = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
  function check(spec) {
    if (!isObj(spec) || typeof spec.root !== "string" || !isObj(spec.elements))
      return ["a spec is {root, elements, state?}"];
    const elements = spec.elements;
    const keys = Object.keys(elements);
    const issues = [];
    if (keys.length > CATALOG.limits.elements)
      issues.push(`${keys.length} elements, more than ${CATALOG.limits.elements}`);
    if (!(spec.root in elements))
      issues.push(`root "${spec.root}" is not an element`);
    for (const key of keys) {
      const el = elements[key];
      if (!isObj(el)) {
        issues.push(`${key}: not an object`);
        continue;
      }
      const part = CATALOG.components[String(el.type)];
      if (!part) {
        issues.push(`${key}: "${String(el.type)}" is not in the catalog`);
        continue;
      }
      const props = isObj(el.props) ? el.props : {};
      for (const name of Object.keys(props))
        if (!(name in part.props))
          issues.push(`${key}: ${el.type} has no prop "${name}"`);
      for (const [name, p] of Object.entries(part.props)) {
        const v = props[name];
        if (p.required && v == null)
          issues.push(`${key}: ${el.type} needs "${name}"`);
        if (p.enum && typeof v === "string" && !p.enum.includes(v))
          issues.push(`${key}: ${name} "${v}" is not one of ${p.enum.join(", ")}`);
      }
      const children = el.children ?? [];
      if (!Array.isArray(children))
        issues.push(`${key}: children is not a list`);
      else {
        if (children.length && !part.children && !el.repeat)
          issues.push(`${key}: ${el.type} takes no children`);
        for (const c of children)
          if (!(String(c) in elements))
            issues.push(`${key}: child "${String(c)}" is not an element`);
      }
      if (el.repeat !== undefined && !(isObj(el.repeat) && typeof el.repeat.statePath === "string"))
        issues.push(`${key}: repeat needs a statePath`);
      if (el.on !== undefined) {
        if (!isObj(el.on))
          issues.push(`${key}: on is not an object`);
        else
          for (const [event, b] of Object.entries(el.on)) {
            if (!(part.events ?? []).includes(event))
              issues.push(`${key}: ${el.type} has no event "${event}"`);
            if (!isObj(b) || !CATALOG.actions.includes(String(b.action)))
              issues.push(`${key}: action "${isObj(b) ? String(b.action) : "?"}" is not in the catalog`);
          }
      }
    }
    const walk = (key, path) => {
      if (path.includes(key)) {
        issues.push(`${key}: a cycle through ${path.join(" > ")}`);
        return;
      }
      if (path.length >= CATALOG.limits.depth) {
        issues.push(`${key}: deeper than ${CATALOG.limits.depth}`);
        return;
      }
      const el = elements[key];
      if (isObj(el) && Array.isArray(el.children)) {
        for (const c of el.children)
          if (String(c) in elements)
            walk(String(c), [...path, key]);
      }
    };
    if (!issues.length)
      walk(spec.root, []);
    return issues;
  }
  var parts = (pointer) => pointer.split("/").slice(1).map((p) => p.replace(/~1/g, "/").replace(/~0/g, "~"));
  function getAt(root, pointer) {
    let at = root;
    for (const p of parts(pointer))
      at = isObj(at) || Array.isArray(at) ? at[p] : undefined;
    return at;
  }
  function setAt(root, pointer, value) {
    const [head, ...rest] = parts(pointer);
    if (head === undefined)
      return value;
    const tail = rest.length ? "/" + rest.join("/") : "";
    if (Array.isArray(root)) {
      const copy = root.slice();
      copy[Number(head)] = tail ? setAt(copy[Number(head)], tail, value) : value;
      return copy;
    }
    const obj = isObj(root) ? root : {};
    return { ...obj, [head]: tail ? setAt(obj[head], tail, value) : value };
  }
  function createState(initial, save) {
    const [state, setState] = signal(initial);
    return {
      state,
      get: (pointer) => getAt(state(), pointer),
      set: (pointer, value) => {
        const next = setAt(state(), pointer, value);
        setState(next);
        save?.(next);
      }
    };
  }
  var itemPath = (scope, field) => scope.at ? `${scope.at().path}/${field}` : `/__none/${field}`;
  var nextId = 0;
  var newId = () => `${Date.now().toString(36)}-${(nextId++).toString(36)}`;
  function evaluate(cond, s, scope) {
    if (cond === undefined)
      return true;
    if (typeof cond === "boolean")
      return cond;
    if (Array.isArray(cond))
      return cond.every((c) => evaluate(c, s, scope));
    if (!isObj(cond))
      return false;
    if (Array.isArray(cond.$and))
      return cond.$and.every((c) => evaluate(c, s, scope));
    if (Array.isArray(cond.$or))
      return cond.$or.some((c) => evaluate(c, s, scope));
    const left = "$state" in cond ? s.get(String(cond.$state)) : ("$item" in cond) ? s.get(itemPath(scope, String(cond.$item))) : ("$index" in cond) ? scope.at?.().index : undefined;
    const right = (v) => isObj(v) && ("$state" in v) ? s.get(String(v.$state)) : v;
    let out = !!left;
    if ("eq" in cond)
      out = left === right(cond.eq);
    else if ("neq" in cond)
      out = left !== right(cond.neq);
    else if ("gt" in cond)
      out = Number(left) > Number(right(cond.gt));
    else if ("gte" in cond)
      out = Number(left) >= Number(right(cond.gte));
    else if ("lt" in cond)
      out = Number(left) < Number(right(cond.lt));
    else if ("lte" in cond)
      out = Number(left) <= Number(right(cond.lte));
    return cond.not === true ? !out : out;
  }
  function resolve(v, s, scope) {
    if (Array.isArray(v))
      return v.map((x) => resolve(x, s, scope));
    if (!isObj(v))
      return v === "$id" ? newId() : v;
    if ("$state" in v)
      return s.get(String(v.$state));
    if ("$bindState" in v)
      return s.get(String(v.$bindState));
    if ("$item" in v)
      return s.get(itemPath(scope, String(v.$item)));
    if ("$bindItem" in v)
      return s.get(itemPath(scope, String(v.$bindItem)));
    if ("$index" in v)
      return scope.at?.().index;
    if ("$cond" in v)
      return resolve(evaluate(v.$cond, s, scope) ? v.$then : v.$else, s, scope);
    if ("$template" in v)
      return String(v.$template).replace(/\$\{([^}]+)\}/g, (_, p) => String(s.get(p) ?? ""));
    return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, resolve(x, s, scope)]));
  }
  function bound(v, scope) {
    if (!isObj(v))
      return null;
    if ("$bindState" in v)
      return String(v.$bindState);
    if ("$bindItem" in v && scope.at)
      return itemPath(scope, String(v.$bindItem));
    return null;
  }
  function run(binding, s, scope) {
    if (!binding)
      return;
    const p = resolve(binding.params ?? {}, s, scope) ?? {};
    const path = String(p.statePath ?? "");
    if (binding.action === "setState")
      s.set(path, p.value);
    else if (binding.action === "pushState") {
      const list = s.get(path);
      s.set(path, [...Array.isArray(list) ? list : [], p.value]);
      if (typeof p.clearStatePath === "string")
        s.set(p.clearStatePath, "");
    } else if (binding.action === "removeState") {
      const list = s.get(path);
      if (Array.isArray(list))
        s.set(path, list.filter((_, i) => i !== Number(p.index)));
    }
  }
  function draw(spec, key, s, scope = {}) {
    const el = spec.elements[key];
    const props = el.props ?? {};
    const live = (name) => () => resolve(props[name], s, scope);
    const str = (name) => () => String(live(name)() ?? "");
    const kids = (sc) => (el.children ?? []).map((c) => draw(spec, c, s, sc));
    let children;
    if (el.repeat) {
      const path = el.repeat.statePath;
      const keyField = el.repeat.key;
      const items = computed(() => {
        const v = s.get(path);
        return Array.isArray(v) ? v : [];
      });
      children = [ForEach({ items, key: (item, i) => String(keyField && isObj(item) ? item[keyField] : i) }, (_item, itemKey) => {
        const at = () => {
          const index = items().findIndex((it, i) => String(keyField && isObj(it) ? it[keyField] : i) === itemKey);
          return { path: `${path}/${index}`, index };
        };
        return VStack({ spacing: 2 }, kids({ at }));
      })];
    } else
      children = kids(scope);
    let view;
    switch (el.type) {
      case "Panel":
        view = Panel({ title: props.title == null ? undefined : str("title") }, children);
        break;
      case "Stack":
        view = (props.direction === "horizontal" ? HStack : VStack)({ spacing: Number(props.spacing ?? 6) }, children);
        break;
      case "Text": {
        const t = Text(str("text"));
        if (props.font)
          t.font(String(props.font));
        if (props.color)
          t.color(String(props.color));
        view = t;
        break;
      }
      case "Row":
        view = Row({ title: str("title"), subtitle: props.subtitle == null ? undefined : str("subtitle"), symbol: props.symbol == null ? undefined : str("symbol"), tint: props.tint == null ? undefined : str("tint") });
        break;
      case "Button":
        view = Button(str("label"), () => run(el.on?.press, s, scope));
        break;
      case "TextField": {
        const binds = bound(props.value, scope) !== null;
        const write = (t) => {
          const to = bound(props.value, scope);
          if (to)
            s.set(to, t);
        };
        view = TextField(str("value"), {
          placeholder: props.placeholder == null ? undefined : String(props.placeholder),
          onEdit: binds ? write : undefined,
          onSubmit: (t) => {
            write(t);
            run(el.on?.submit, s, scope);
          }
        });
        break;
      }
      case "Toggle": {
        const binds = bound(props.checked, scope) !== null;
        const write = (on) => {
          const to = bound(props.checked, scope);
          if (to)
            s.set(to, on);
        };
        view = Toggle(() => !!live("checked")(), { label: props.label == null ? undefined : str("label"), onChange: binds ? write : undefined });
        break;
      }
      case "Badge":
        view = Badge(str("text"), () => String(live("tone")() ?? "secondary"));
        break;
      case "ProgressView":
        view = ProgressView(() => Number(live("value")() ?? 0));
        break;
      case "EmptyState":
        view = EmptyState({ title: str("title"), message: props.message == null ? undefined : str("message"), symbol: props.symbol == null ? undefined : str("symbol") });
        break;
      case "Divider":
        view = Divider();
        break;
      default:
        view = Spacer();
    }
    if (el.visible === undefined)
      return view;
    const shown = computed(() => evaluate(el.visible, s, scope));
    return VStack({ spacing: 0 }, [() => shown() ? view : null]);
  }
  function render(spec, state) {
    const issues = check(spec);
    if (issues.length)
      return EmptyState({ title: "This widget can't draw", message: issues.slice(0, 3).join("; "), symbol: "exclamationmark.triangle" });
    return draw(spec, spec.root, state ?? createState(spec.state ?? {}));
  }
  var PINNED = "pinned";
  var stateKey = (id) => `state:${id}`;
  function stored(spec, id) {
    const s = createState(spec.state ?? {}, (next) => cmux.storage.set(stateKey(id), next));
    cmux.storage.get(stateKey(id)).then((saved) => {
      if (isObj(saved))
        s.set("", saved);
    });
    return s;
  }
  var renderCard = chatWidget((context) => {
    const spec = context.props?.spec;
    const issues = check(spec);
    const view = render(spec, issues.length ? null : stored(spec, context.widget.key));
    if (issues.length)
      return view;
    return VStack({ spacing: 4 }, [
      view,
      HStack([Spacer(), Button("Pin to sidebar", () => {
        cmux.storage.set(PINNED, spec);
        setPinned(spec);
        cmux.toast({ title: "Pinned to the sidebar" });
      })])
    ]);
  });
  var [pinned, setPinned] = signal(null);
  var pinnedLoaded = false;
  var renderSection = section(() => {
    if (!pinnedLoaded) {
      pinnedLoaded = true;
      cmux.storage.get(PINNED).then((saved) => {
        if (!check(saved).length)
          setPinned(saved);
      });
    }
    return VStack([
      () => {
        const spec = pinned() ?? todo_default;
        return check(spec).length ? Text("No widget yet") : render(spec, stored(spec, pinned() ? PINNED : "todo"));
      }
    ]);
  });
  globalThis.__cmuxAppExports = { ...exports_main };
})();
