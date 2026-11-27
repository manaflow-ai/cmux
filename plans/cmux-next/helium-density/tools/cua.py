import json,socket,sys,os
S=os.path.expanduser("~/Library/Application Support/cmux/agent-capture/run/cua.sock")
def call(name,args):
    s=socket.socket(socket.AF_UNIX); s.settimeout(90); s.connect(S)
    s.sendall((json.dumps({"method":"call","name":name,"args":args})+"\n").encode())
    b=b""
    while not b.endswith(b"\n"):
        c=s.recv(1<<20)
        if not c: break
        b+=c
    return json.loads(b)
if __name__=="__main__":
    r=call(sys.argv[1], json.loads(sys.argv[2]) if len(sys.argv)>2 else {})
    sc=(r.get("result") or {}).get("structuredContent")
    print(json.dumps(sc if sc is not None else r))
