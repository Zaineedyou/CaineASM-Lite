import socket, ssl, struct, sys, threading, os, hashlib, base64
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain('cert.pem','key.pem')
def frame(op, payload, fin=True):
    b0 = (0x80 if fin else 0) | op; n=len(payload)
    if n<126: h=struct.pack('!BB',b0,n)
    elif n<65536: h=struct.pack('!BBH',b0,126,n)
    else: h=struct.pack('!BBQ',b0,127,n)
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
    assert b1&0x80, "client frame not masked"
    if n==126: n=struct.unpack('!H',readn(c,2))[0]
    elif n==127: n=struct.unpack('!Q',readn(c,8))[0]
    m=readn(c,4); d=bytearray(readn(c,n))
    for i in range(n): d[i]^=m[i%4]
    return b0&15,bytes(d)
def handle(c):
    req=b''
    while b'\r\n\r\n' not in req: req+=c.recv(4096)
    print("REQ:",req.decode().replace('\r\n',' | '),flush=True)
    key=[l for l in req.decode().split('\r\n') if l.lower().startswith('sec-websocket-key')][0].split(': ')[1]
    acc=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    # send 101 and hello in one write to test leftover bytes
    c.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n'%acc).encode()+frame(1,b'{"op":10,"d":{"heartbeat_interval":45000}}'))
    op,d=readframe(c); print("GOT",op,d,flush=True)
    c.sendall(frame(1,b'echo:'+d))
    big=os.urandom(0)+b'A'*70000
    c.sendall(frame(1,b'B'*10,fin=False)+frame(9,b'ping!')+frame(0,b'C'*5,fin=False)+frame(0,b'D'*3))
    op,d=readframe(c); print("GOT pong",op,d,flush=True)
    c.sendall(frame(1,big))
    op,d=readframe(c); print("GOT big-echo-trigger",op,len(d),flush=True)
    big2=b'Z'*3000000
    c.sendall(frame(1,big2))
    op,d=readframe(c); print("GOT big client frame",op,len(d),flush=True)
    c.sendall(frame(8,struct.pack('!H',4004)+b'Authentication failed'))
    try: print("client close echo",readframe(c),flush=True)
    except Exception as e: print("no echo",e)
    c.close()
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',int(sys.argv[1]))); s.listen(5)
while True:
    cs,_=s.accept()
    try: handle(ctx.wrap_socket(cs,server_side=True))
    except Exception as e: print("ERR",e,flush=True)
