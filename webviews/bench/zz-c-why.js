window.__probe = () => {
  const m = window.__zzWhy || {};
  return Object.fromEntries(Object.entries(m).sort((a, b) => b[1] - a[1]).slice(0, 40));
};
