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
    return request_object({'text':text})

def request_object(data):
    s,h=connect(); assert b'101 Switching' in h,h
    send(s,json.dumps(data, ensure_ascii=False))
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
    assert request('Hello')[-1]['translation']=='訳:Hello'
    assert 'error' in request('x'*2001)[-1]
    print('PASS protocol and input bounds')
    s,h=connect(); send(s,b'{"text":',final=False); send(s,b'"Hello"}',opcode=0)
    assert json.loads(receive(s)[1])['translation']=='訳:Hello'; s.close()
    print('PASS fragmented message')
    s,h=connect(); send(s,b'ping',opcode=9); assert receive(s)==(10,b'ping'); s.close()
    s,h=connect(); send(s,b'{"text":"Hi"}',masked=False); assert receive(s)[0]==8; s.close()
    print('PASS ping and unmasked rejection')
    replies=request('slow'); assert replies[0]['working'] is True; assert replies[-1]['translation']=='訳:slow'
    print('PASS heartbeat and response')

    assert request('Hello')[-1]['server']=={'platform':'macos','appVersion':'0.3.0','protocolVersion':1,'capabilities':['options','glossaries','context']}
    for version in [1, 2]:
        s,h=connect(); send(s,json.dumps({'text':'Hello','protocolVersion':version}))
        reply=json.loads(receive(s)[1]); s.close()
        assert ('translation' in reply) if version==1 else ('error' in reply)
    print('PASS server identity and protocol negotiation')

    # Metadata must not require text, load a model, or join the translation queue.
    before=request_object({'action':'metadata','protocolVersion':1})[-1]
    assert before['modelId']=='test-mlx-model'
    assert len(before['languages'])==53
    assert before['glossaries']==[{'id':'test-glossary','name':'Software','count':1}]
    assert before['glossaryRevision']=='test-revision' and before['glossaryError']==''
    after=request_object({'action':'metadata'})[-1]
    assert before['translateCount']==after['translateCount']
    print('PASS metadata without translation')
    options={'text':'options','from':'en','to':'ja','style':'plain','glossaryId':'test-glossary','context':'Software manual','protocolVersion':1}
    reply=request_object(options)[-1]
    assert json.loads(reply['translation'])=={'source':'en','target':'ja','style':'plain','glossaryID':'test-glossary','context':'Software manual'}
    defaults=json.loads(request_object({'text':'options'})[-1]['translation'])
    assert defaults=={'source':'','target':'ja','style':'polite','glossaryID':'','context':''}
    blank=json.loads(request_object({'text':'options','style':'','from':'','glossaryId':''})[-1]['translation'])
    assert blank['style']=='' and blank['source']=='' and blank['glossaryID']==''
    print('PASS explicit options and legacy defaults')
    invalid=[[],None,{'action':'other'},{'action':True},{'text':' '},{'text':2},
             {'text':'Hello','to':'xx'},{'text':'Hello','from':'xx'},{'text':'Hello','from':'ja'},
             {'text':'Hello','style':'other'},{'text':'Hello','glossaryId':'missing'},
             {'text':'Hello','context':'x'*1201},{'text':'Hello','context':'😀'*601},
             {'text':'😀'*1001},{'text':'<|plamo:tag|>input'},
             {'text':'Hello','context':'<|plamo:tag|>context'}]
    for field in ['from','to','style','glossaryId','context']:
        for value in [1,True,[],{},None]: invalid.append({'text':'Hello',field:value})
    for version in [True,False,1.5,1.0,0,2,'1',None,[],{}]:
        invalid.append({'text':'Hello','protocolVersion':version})
        invalid.append({'action':'metadata','protocolVersion':version})
    for value in invalid:
        reply=request_object(value)[-1]
        assert 'error' in reply,(value,reply)
        assert reply['server']['capabilities']==['options','glossaries','context']
    assert 'translation' in request_object({'text':'😀'*1000,'context':'😀'*600})[-1]
    print('PASS malformed fields, strict protocol and UTF-16 limits')
    s=socket.create_connection(('127.0.0.1',47832),timeout=10)
    s.sendall(b'GET /translate HTTP/1.1\r\nHost: 127.0.0.1:47832\r\n\r\n')
    assert b'403' in s.recv(256);s.close()
    print('PASS plain HTTP connectivity probe returns 403')
