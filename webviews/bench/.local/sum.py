import json,sys
for line in open(sys.argv[1]):
    if line.startswith("FIRST_LOAD_JSON "):
        j=json.loads(line[len("FIRST_LOAD_JSON "):])
        for k,v in j.items():
            if isinstance(v,dict) and "median" in v:
                m=v["median"]
                print("MODE", k, json.dumps({x:m.get(x) for x in ["firstContentMs","finalFirstPaintMs","shiftFrames","layoutShift","blankAfterContent"]}), "gone", json.dumps(v.get("gone")))
