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
    formatDate: () => formatDate,
    formatTime: () => formatTime,
    renderClock: () => renderClock
  });
  var DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  var MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  var pad = (n) => String(n).padStart(2, "0");
  function systemTwelveHour() {
    try {
      return new Intl.DateTimeFormat(cmux.app.locale || undefined, { hour: "numeric" }).resolvedOptions().hour12 === true;
    } catch {
      return false;
    }
  }
  function formatTime(at, settings, twelveByDefault = systemTwelveHour()) {
    const twelve = settings.hourCycle === "12h" || settings.hourCycle !== "24h" && twelveByDefault;
    const minutes = pad(at.getMinutes()) + (settings.showSeconds ? `:${pad(at.getSeconds())}` : "");
    if (!twelve)
      return `${pad(at.getHours())}:${minutes}`;
    const hour = at.getHours() % 12 || 12;
    return `${hour}:${minutes} ${at.getHours() < 12 ? "AM" : "PM"}`;
  }
  function formatDate(at) {
    return `${DAYS[at.getDay()]}, ${MONTHS[at.getMonth()]} ${at.getDate()}`;
  }
  function renderClock() {
    const settings = () => cmux.app.settings();
    const [now, setNow] = signal(Date.now());
    const [date, setDate] = signal(formatDate(new Date(now())));
    const tick = () => {
      const at = Date.now();
      setNow(at);
      setDate(formatDate(new Date(at)));
    };
    cmux.timer.every(1000, tick);
    const twelve = systemTwelveHour();
    return VStack({ spacing: 0, alignment: "leading" }, [
      Text(() => formatTime(new Date(now()), settings(), twelve)).font("title2").weight("semibold").monospaced(),
      Text(date).font("caption").secondary()
    ]);
  }
  globalThis.__cmuxAppExports = { ...exports_main };
})();
