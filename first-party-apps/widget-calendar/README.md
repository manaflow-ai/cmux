# Calendar (`cmux/calendar`)

A widget (`cmux.widget/1`) with your next events from the calendars on your Mac, like Apple's Calendar
"Up Next" widget. A store app: listed in the App Store, installed with one click, not bundled (a `STORE`
marker, no `BUNDLED`).

| Size | Shows |
| --- | --- |
| small | the weekday in red over the big day number, then the next one or two events (one keeps its place line) |
| medium | the same on the left; the rest of today and then `TOMORROW` on the right |
| large | the rest of today on the left (up to five events, then "N more"), tomorrow on the right |

Each event is a block tinted with its calendar's color, with a bar of that color on its leading edge:
title, place and time (`4:00–5:00 PM`). All-day events come first, title only. Events that have ended
drop out on the minute. When nothing is left today it says "No more events today", as Apple does.

## First install

The widget needs no setup. Until macOS has been asked, it shows the date and "See your next events
here." with an **Allow Access** button. The tap shows macOS's Calendars prompt
(`system_calendar.request_access`, which needs the tap's gesture), and the events follow at once. After a
refusal macOS cannot ask again, so it says where to turn access on (System Settings > Privacy & Security >
Calendars). Off the Mac (no cmux Mac app connected) it says the calendar shows in the cmux app on a Mac.

## Data

Only the public SDK (`cmux-extension-sdk`) and the host ops `cmux.system_calendar.events({days, limit})`
and `cmux.system_calendar.request_access()` (scope `system_calendar:read`). The Mac app reads EventKit;
the daemon bounds the read (31 days, 50 events) and caches granted answers for 30 s, so every tile on New
Tab and in the sidebar of every window costs one EventKit read per window of time. The widget reads the
next two days once, again every 5 minutes and when the day changes; the minute tick only drops ended
events. A read never prompts. Each event carries its calendar's color; without one it draws in
Calendar's default blue.

Settings: `hourCycle` (`system`, `12h`, `24h`).

## Development

```bash
bun test first-party-apps/widget-calendar                 # logic and the packed widget in the fake host
bun first-party-apps/widget-calendar/preview/build.ts     # preview/scenes.json for the gallery
bun first-party-apps/build.ts widget-calendar             # dist/main.js and the manifest check
cmux ext dev first-party-apps/widget-calendar             # live in a running cmux
```

Gallery: `apps.calendar-widget` draws `preview/scenes.json` (a fixed Tuesday 1:12 PM in Los Angeles with
a fake calendar: busy, clear, all-day, empty, ask, denied, 24-hour) with the real scene renderer, light and
dark. Compared with Apple's references in cmux-design-references (`apple-widgets/web/hig-calendar-*`).

## Gaps

- The host has no `cmux.watch` signal source for the calendar yet: the widget reads with the op on its
  own 5-minute rhythm, and the daemon's cache shares the reads. A `system_calendar.events` signal with
  an EventKit change push would make it instant and drop the rhythm.
- The large size is a list per day, not Apple's hour grid with a now line: the scene DSL has no
  absolute placement for hour rows.
