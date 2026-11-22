# Widgets

Four widgets you add to the sidebar, each a card in the sizes system widgets come in. None of them
is in the app by default: you add the ones you want, and right-click a card to change its size.

| Widget | Small | Medium | Large | Reads |
| --- | --- | --- | --- | --- |
| [Clock](../widget-clock) | The weekday, the time, the date | Three cities beside the time | Six cities with their day and distance | Nothing: cmux's own time zone data |
| [Weather](../widget-weather) | The place, the temperature, the sky, today's high and low | The next six hours | The next six hours and six days | Open-Meteo, no account or key (`net:` scopes) |
| [Calendar](../widget-calendar) | The date over your next event | The date beside your next three events | This month over your next five events | The calendars on this Mac (`system_calendar:read`); macOS asks once, from the card's button |
| [To-do](../widget-todo) | How many are left and the first three | Four items and a field to add one | Ten items, the field, and the ticked ones with Clear | Nothing: the list is kept on this Mac (`storage:local`) |

## Add them

From the root of this repository, with cmux open:

```sh
examples/extensions/widgets/install.sh                  # all four
examples/extensions/widgets/install.sh weather todo     # only the ones you name
examples/extensions/widgets/install.sh remove           # take them all off
```

Or one at a time: `cmux ext dev examples/extensions/widget-weather`. Each shows its install card
once, listing what it may read or reach and why. The weather's network access and the calendar's
access are off until you turn them on in Settings > Apps; until then the card says so.

## Change them

- Size: right-click the card and pick Small, Medium or Large, or set Size in Settings > Apps.
- Clock: the cities (time zone names such as Europe/London) and a 12-hour clock.
- Weather: the place (or type it in the card) and Celsius or Fahrenheit.
- Calendar: 12-hour times.
- To-do: click an item's circle to tick it; right-click an item to edit, remove or move it to the top.

Every card draws theme tones only, so a theme or look recolors them all at once. Each one is a
short `src/main.ts` on the public SDK: copy one to make your own.
