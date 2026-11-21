# Leo weather: the live sky, animated

`local/leo-weather` (the Leo collection) draws the weather where you are on the New Tab page, in a
pane and in a sidebar section. Rain, snow and stars are `Particles`, the sun spins and glows,
clouds float, the sky's gradient follows the hour, and the next 12 hours are bars that spring to new
values. cmux runs every motion; the code only declares it.

```sh
cmux ext dev examples/extensions/leo-weather
cmux settings set tabs.newTabApp local/leo-weather   # the New Tab page
```

Settings > Apps > Leo weather: Place (or the opt-in Approximate location from my IP address, off by
default, its own `net:get.geojs.io` scope), Units, Look (`sky`, `card`, `minimal`) and Preview a sky
(sun, rain, snow, storm, night without the network). Open-Meteo is read every 15 minutes, no key.
Edit `src/main.ts` for the looks, `src/sky.ts` for the sky, `src/weather.ts` for the data.
