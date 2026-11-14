import json,sys,time
sys.path.insert(0,'/Users/cmux/density-helium')
import rpc as R
sock=sys.argv[1]; out=sys.argv[2]; win=sys.argv[3]
def call(m,p=None): return R.rpc(m,p,sock)
paths={"appearance.background":"laurence-mckinley","appearance.backgroundOpacity":0.85,"appearance.backgroundBlur":"none","appearance.theme":"Monokai Classic","appearance.metrics.titlebarHeight":31,"appearance.metrics.chromeFontSize":12,"appearance.density":"cozy"}
saved={p:call("settings.get",{"path":p}) for p in paths}
try:
    for p,v in paths.items(): print(p, str(call("settings.set",{"path":p,"value":v}))[:120])
    time.sleep(3)
    for mode,theme in [("dark","Monokai Classic"),("light","Catppuccin Latte")]:
        call("settings.set",{"path":"appearance.theme","value":theme}); time.sleep(3)
        r=call("debug.window_snapshot",{"window":win,"path":f"{out}-{mode}.png"}); print(mode, str(r)[:100])
finally:
    for p,before in saved.items():
        res=before.get("result") or {}
        if res.get("value") is not None: call("settings.set",{"path":p,"value":res["value"]})
        else: call("settings.unset",{"path":p})
    print("restored")
