import socket, base64, os, struct, json, sys
ORIGIN = 'chrome-extension://oefekpcnnmijlldkpeplijencgdnakbb'
def connect(origin=ORIGIN, path='/translate'):
    s=socket.create_connection(('127.0.0.1',47832),timeout=25)
    key=base64.b64encode(os.urandom(16)).decode()
    s.sendall((f'GET {path} HTTP/1.1\r\nHost: 127.0.0.1:47832\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nOrigin: {origin}\r\n\r\n').encode())
    header=b''
    while not header.endswith(b'\r\n\r\n'):
        chunk=s.recv(1)
        if not chunk: break
        header+=chunk
    return s,header

def send(s, data, opcode=1, final=True, masked=True):
    if isinstance(data,str): data=data.encode()
    mask=os.urandom(4)
    prefix=bytes([(128 if final else 0)|opcode])
    n=len(data)
    prefix+=bytes([(128 if masked else 0)|(n if n<126 else 126)])
    if n>=126: prefix+=struct.pack('!H',n)
    s.sendall(prefix+(mask if masked else b'')+bytes(b^mask[i%4] if masked else b for i,b in enumerate(data)))
def receive(s):
    def exact(n):
        data=b''
        while len(data)<n:
            part=s.recv(n-len(data))
            if not part: raise EOFError()
            data+=part
        return data
    a,b=exact(2); n=b&127
    if n==126:n=struct.unpack('!H',exact(2))[0]
    if n==127:n=struct.unpack('!Q',exact(8))[0]
    return a&15,exact(n)
def request(text):
    s,h=connect(); assert b'101 Switching' in h,h
    send(s,json.dumps({'text':text}))
    replies=[]
    while True:
        opcode,payload=receive(s)
        if opcode==1:
            reply=json.loads(payload); replies.append(reply)
            if not reply.get('working'): break
    s.close(); return replies

if __name__=='__main__':
    for origin,path,status in [('https://evil.example','/translate',b'403'),(ORIGIN,'/wrong',b'404'),('', '/translate',b'403')]:
        s,h=connect(origin,path); assert status in h,h; s.close()
    print('PASS origin/path rejection')
    assert request('Hello')[-1]=={'translation':'訳:Hello'}
    assert 'error' in request('x'*2001)[-1]
    print('PASS protocol and input bounds')
    s,h=connect(); send(s,b'{"text":',final=False); send(s,b'"Hello"}',opcode=0)
    assert json.loads(receive(s)[1])=={'translation':'訳:Hello'}; s.close()
    print('PASS fragmented message')
    s,h=connect(); send(s,b'ping',opcode=9); assert receive(s)==(10,b'ping'); s.close()
    s,h=connect(); send(s,b'{"text":"Hi"}',masked=False); assert receive(s)[0]==8; s.close()
    print('PASS ping and unmasked rejection')
    replies=request('slow'); assert replies[0]=={'working':True}; assert replies[-1]=={'translation':'訳:slow'}
    print('PASS heartbeat and response')
