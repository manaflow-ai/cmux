import json,socket,sys
def rpc(m,p=None,sock="/tmp/cmux-debug-density-helium-fix-shots-v4.sock"):
    c=socket.socket(socket.AF_UNIX); c.settimeout(60); c.connect(sock)
    c.sendall((json.dumps({"id":1,"method":m,"params":p or {}})+"\n").encode()); b=b""
    while not b.endswith(b"\n"):
        x=c.recv(1<<20)
        if not x: break
        b+=x
    return json.loads(b)
if __name__=="__main__":
    print(json.dumps(rpc(sys.argv[1], json.loads(sys.argv[2]) if len(sys.argv)>2 else {}))[:1500])
