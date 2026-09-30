export default [
  {
    id: "smoke.title-click",
    members: ["aside:Page.title", "chatgpt:Tab.title"],
    path: "/diff/lab.html",
    code: `await $P.locator("#action").click();
return { title: await $P.title(), status: await $P.locator("#status").innerText(), trusted: $LOG.filter((r) => r[1] === "action").map((r) => [r[0], r[2]]) };`,
    chatgpt: `await $P.locator("#action").click();
return { title: await t.title(), status: await $P.locator("#status").innerText(), trusted: $LOG.filter((r) => r[1] === "action").map((r) => [r[0], r[2]]) };`,
  },
];
