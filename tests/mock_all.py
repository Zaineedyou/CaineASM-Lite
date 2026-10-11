import socket, ssl, struct, sys, threading, time, json, base64, hashlib, os
PORT=int(sys.argv[1]); BOT="900"; LOCK=threading.Lock()
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain('cert.pem','key.pem')
EVENTS=[]   # (kind, data)
def ev(k,d):
    with LOCK:
        EVENTS.append((k,d)); print("EV",k,json.dumps(d)[:200],flush=True)
        open('/tmp/ev.jsonl','a').write(json.dumps({"k":k,"d":d})+"\n")
def frame(op,payload,fin=True):
    n=len(payload); b0=(0x80 if fin else 0)|op
    h=struct.pack('!BB',b0,n) if n<126 else struct.pack('!BBH',b0,126,n) if n<65536 else struct.pack('!BBQ',b0,127,n)
    return h+payload
def readn(c,n):
    d=b''
    while len(d)<n:
        x=c.recv(n-len(d))
        if not x: raise EOFError
        d+=x
    return d
def readframe(c):
    b0,b1=readn(c,2); n=b1&0x7f
    if n==126: n=struct.unpack('!H',readn(c,2))[0]
    elif n==127: n=struct.unpack('!Q',readn(c,8))[0]
    m=readn(c,4); d=bytearray(readn(c,n))
    for i in range(n): d[i]^=m[i%4]
    return b0&15,bytes(d)
GROQ_CALLS=[0]; RATE_DONE=[False]
def groq_reply(req):
    msgs=req["messages"]; last=msgs[-1]["content"]
    if isinstance(last,list): last=" ".join(p.get("text","") for p in last if p["type"]=="text")
    if "RATE" in last and not RATE_DONE[0]:
        RATE_DONE[0]=True; return 429,{"error":{"message":"rate limited"}}
    if "LONG" in last:
        txt=("Baris panjang 😀 \"quote\" \\ backslash\n"*90)
    elif "EMPTY" in last: return 200,{"choices":[{"message":{"role":"assistant","content":None}}]}
    elif "FAIL" in last: return 400,{"error":{"message":"bad request"}}
    else: txt="Balasan untuk: "+last[:60]
    return 200,{"choices":[{"index":0,"message":{"role":"assistant","content":txt,"reasoning":"hidden"},"finish_reason":"stop"}]}
def http(c,first):
    buf=first
    while True:
        while b'\r\n\r\n' not in buf:
            x=c.recv(65536)
            if not x: return
            buf+=x
        head,_,rest=buf.partition(b'\r\n\r\n')
        lines=head.decode().split('\r\n'); meth,path,_=lines[0].split(' ',2)
        hd={l.split(':',1)[0].lower():l.split(':',1)[1].strip() for l in lines[1:] if ':' in l}
        n=int(hd.get('content-length','0'))
        while len(rest)<n: rest+=c.recv(65536)
        body,buf=rest[:n],rest[n:]
        status,out=200,b'{}'
        if path.startswith('/openai/v1/chat/completions'):
            req=json.loads(body); ev("groq",{"auth":hd.get('authorization'),"model":req["model"],"extra":{k:v for k,v in req.items() if k not in("messages","model")},"msgs":req["messages"]})
            status,o=groq_reply(req); out=json.dumps(o).encode()
        elif path.endswith('/typing'): status,out=204,b''; ev("typing",{"path":path,"ua":hd.get('user-agent'),"auth":hd.get('authorization')})
        elif '/messages' in path and meth=='POST':
            j=json.loads(body); ev("post",{"path":path,"json":j}); out=b'{"id":"5000"}'
        elif '/messages' in path and meth=='GET':
            ev("getmsgs",{"path":path})
            out=json.dumps([{"id":"3","content":"third msg","author":{"username":"carol","bot":False}},{"id":"2","content":"bot noise","author":{"username":"botty","bot":True}},{"id":"1","content":"first \"msg\"","author":{"username":"alice","bot":False}},{"id":"0","content":"","author":{"username":"empty","bot":False}}]).encode()
        elif path.startswith('/api/v10/guilds/'):
            ev("getguild",{"path":path})
            gid=path.rsplit('/',1)[1]
            out=json.dumps({"id":gid,"owner_id":"OWNER1","roles":[{"id":gid,"permissions":"1024"},{"id":"R_ADMIN","permissions":"8"},{"id":"R_MOD","permissions":"2"}]}).encode()
        resp=(f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {len(out)}\r\n\r\n").encode()+out
        c.sendall(resp)
def msg(id,content,uid="U1",uname="alice",guild="G1",bot=False,extra=None,nick=None,roles=None):
    d={"id":id,"channel_id":"C1","content":content,"author":{"id":uid,"username":uname,"bot":bot},"mentions":[],"mention_everyone":False,"attachments":[]}
    if guild: d["guild_id"]=guild; d["member"]={"nick":nick,"roles":roles or []}
    if extra: d.update(extra)
    return {"op":0,"s":None,"t":"MESSAGE_CREATE","d":d}
SEQ=[0]
def send(c,obj):
    SEQ[0]+=1
    if obj.get("op")==0: obj["s"]=SEQ[0]
    c.sendall(frame(1,json.dumps(obj,separators=(',',':'),ensure_ascii=False).encode()))
CONN=[0]
def ws(c,req):
    CONN[0]+=1; n=CONN[0]
    key=[l for l in req.decode().split('\r\n') if l.lower().startswith('sec-websocket-key')][0].split(': ')[1]
    acc=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    ev("ws_open",{"n":n,"req":req.decode().split('\r\n')[0]})
    c.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n'%acc).encode())
    c.sendall(frame(1,json.dumps({"op":10,"d":{"heartbeat_interval":1500}}).encode()))
    stop=threading.Event()
    def reader():
        try:
            while not stop.is_set():
                op,d=readframe(c)
                if op==1:
                    j=json.loads(d); ev("ws_in",{"n":n,**{k:(j[k] if k!='d' or j['op']!=2 and j['op']!=6 else j['d']) for k in j}})
                    if j["op"]==1: c.sendall(frame(1,b'{"op":11}'))
                elif op==8: ev("ws_close_rx",{"n":n}); break
        except Exception as e: ev("ws_reader_end",{"n":n,"e":str(e)})
        stop.set()
    t=threading.Thread(target=reader,daemon=True); t.start()
    time.sleep(0.5)
    if n==1:
        send(c,{"op":0,"t":"READY","d":{"v":10,"user":{"id":BOT,"username":"CaineTest"},"session_id":"SESS1","resume_gateway_url":f"wss://localhost:{PORT}"}})
        time.sleep(0.3)
        script=[
          (msg("M1","Caine halo",nick=None),1.0),
          (msg("M0","ngobrol biasa tanpa trigger",uid="U9",uname="x"),0.3),
          (msg("MB","Caine bot",uid="B1",bot=True),0.3),
          (msg("M2","caine apa kabar hari ini?",nick="Alice Nick"),2.5),
          (msg("M3",f"<@{BOT}> tolong LONG",uid="U2",uname="bob",extra={"mentions":[{"id":BOT,"username":"CaineTest"}]}),2.5),
          (msg("M4","balas tanpa prefix",uid="U3",uname="carl",extra={"type":19,"referenced_message":{"id":"x","author":{"id":BOT}}}),2.5),
          (msg("M5","Caine liat ini",uid="U4",uname="dina",extra={"attachments":[{"content_type":"image/png","url":"https://cdn.example/a.png?x=1&y=2"}]}),2.5),
          (msg("M6","Caine summarize 5",uid="U5",uname="eva"),2.5),
          (msg("M7","Caine setmodel gpt20b",uid="OWNER1",uname="own",roles=[]),2.5),
          (msg("M8","Caine setmodel",uid="U6",uname="admin",roles=["R_ADMIN"]),2.5),
          (msg("M9","Caine setpersona kamu bajak laut",uid="U7",uname="rando",roles=["R_MOD"]),2.5),
          (msg("M10","Caine sethistory 50",uid="OWNER1",uname="own"),2.5),
          (msg("M11","Caine sethistory 3",uid="OWNER1",uname="own"),2.5),
          (msg("M12","Caine setpersona kamu bajak laut \"arrr\"",uid="OWNER1",uname="own"),2.5),
          (msg("M13","Caine RATE test",uid="U8",uname="gina"),4.5),
          (msg("M14","Caine EMPTY",uid="U10",uname="hal"),2.5),
          (msg("M15","Caine FAIL",uid="U11",uname="ian"),2.5),
          (msg("M16","Caine help",uid="U12",uname="jo"),2.5),
          (msg("M17","Caine reset",uid="U1",uname="alice"),2.5),
          (msg("M18","Caine halo di DM",uid="U13",uname="kim",guild=None),2.5),
          (msg("M19","Caine setmodel gpt20b",uid="U13",uname="kim",guild=None),2.5),
        ]
        for m,delay in script:
            if stop.is_set(): return
            send(c,m); time.sleep(delay)
        time.sleep(2)
        ev("server_closing_4000",{})
        c.sendall(frame(8,struct.pack('!H',4000)+b'test'))
        time.sleep(1)
    elif n>=3:
        time.sleep(1); ev("sending_4004",{})
        c.sendall(frame(8,struct.pack('!H',4004)+b'Authentication failed')); time.sleep(1)
    else:
        time.sleep(0.5)
        send(c,{"op":0,"t":"RESUMED","d":{}})
        send(c,msg("R1","Caine setelah resume",uid="U1",uname="alice"))
        time.sleep(3)
        # force an invalid session -> expect identify again
        c.sendall(frame(1,json.dumps({"op":9,"d":False}).encode()))
        time.sleep(4)
        ev("done",{})
def conn(raw):
    try:
        c=ctx.wrap_socket(raw,server_side=True)
        first=b''
        while b'\r\n\r\n' not in first: first+=c.recv(65536)
        if b'Upgrade: websocket' in first: ws(c,first.split(b'\r\n\r\n')[0])
        else: http(c,first)
    except Exception as e: print("conn err",type(e).__name__,e,flush=True)
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',PORT)); s.listen(50)
while True:
    r,_=s.accept(); threading.Thread(target=conn,args=(r,),daemon=True).start()
