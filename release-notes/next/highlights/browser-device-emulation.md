title: Emulate phones, tablets and foldables in the browser
action: browserDevice | Emulate device

Emulate Device… in the browser's Tools menu (or the palette) shows every device of Chrome's device toolbar, grouped as Chrome groups them, and newer devices that Chrome does not list yet. In a Chromium tab the page gets the device's viewport, pixel ratio, user agent, client hints, touch and mobile layout, as in Chrome's device mode. A WebKit tab gets the viewport, pixel ratio and user agent. Choose an orientation or the unfolded screen of a foldable from the same menu.

Agents and scripts use the same list: `cmux browser devices list`, `cmux tab <tab> emulate --device "iPhone 16 Pro"`, and `cmux browser devices add` for your own devices in Chrome's device format.
