"""Two isolated RouterOS REST fixtures; never contacts a real router."""
import copy, http.server, json, os, pathlib, subprocess, tempfile, threading, unittest
BIN=str(pathlib.Path(__file__).resolve().parents[1]/'target/debug/wgtun')
KEYS=['AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=','AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=']
class Router:
    def __init__(self,key):
        self.writes=[]; self.mode='ok'; self.key=key
        self.rows={'/rest/interface/wireguard':[{'name':'wg-test','public-key':key,'disabled':'false','private-key':'SECRET'}],'/rest/ip/address':[{'.id':'*1','interface':'ether-mgmt','address':'127.0.0.1/8','disabled':'false'}],'/rest/interface/wireguard/peers':[]}
        router=self
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def response(self,status,body):
                self.send_response(status); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(json.dumps(body).encode())
            def do_GET(self):
                path=self.path.split('?')[0]
                # Deliberately return secrets/metrics too; executor must project public fields.
                self.response(200,router.rows.get(path,[]))
            def write(self):
                body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or '{}')
                router.writes.append((self.command,self.path,body))
                if router.mode=='reject': return self.response(400,{'message':'rejected'})
                path=self.path; menu=path if self.command=='PUT' else path.rsplit('/',1)[0]
                if router.mode!='ignore':
                    if self.command=='PUT': router.rows[menu].append({'.id':'*'+format(len(router.rows[menu])+10,'X'),**body})
                    elif self.command=='PATCH': next(x for x in router.rows[menu] if x['.id']==path.rsplit('/',1)[1]).update(body)
                    else: router.rows[menu]=[x for x in router.rows[menu] if x['.id']!=path.rsplit('/',1)[1]]
                if router.mode=='drop': self.close_connection=True; return
                self.response(200,body)
            do_PUT=write; do_PATCH=write; do_DELETE=write
        self.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        threading.Thread(target=self.server.serve_forever,daemon=True).start()
    def stop(self): self.server.shutdown(); self.server.server_close()
class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.path=pathlib.Path(self.tmp.name)
        self.hub=Router(KEYS[0]); self.site=Router(KEYS[1]); self.env={**os.environ,'WGTUN_CONFIG':str(self.path/'config.toml'),'WGTUN_TEST_HUB_PASSWORD':'password','WGTUN_TEST_SITE_PASSWORD':'password'}
        config=''
        for name,r in [('test-hub',self.hub),('test-site',self.site)]:
            config+=f'[profiles.{name}]\nurl="http://127.0.0.1:{r.server.server_port}"\nusername="test"\nmanagement_interface="ether-mgmt"\nindependent_path_verified=true\n'
        (self.path/'config.toml').write_text(config)
        plan={'version':1,'tag':'WGTUN:TEST','hub':{'profile':'test-hub','interface':'wg-test','address':'10.0.0.1/30','listen_port':51820,'public_key':KEYS[0],'allowed_addresses':[]},'site':{'profile':'test-site','interface':'wg-test','address':'10.0.0.2/30','endpoint':'hub.example:51820','public_key':KEYS[1],'keepalive_seconds':25,'lan_networks':['192.168.88.0/24'],'allowed_addresses':[]}}
        (self.path/'site.yaml').write_text(json.dumps(plan)); self.number=0
    def tearDown(self): self.hub.stop(); self.site.stop(); self.tmp.cleanup()
    def cli(self,*args):
        p=subprocess.run([BIN,'--json',*map(str,args)],env=self.env,capture_output=True,text=True,timeout=20)
        return json.loads(p.stdout)
    def preview(self):
        self.number+=1; self.preview_path=self.path/f'preview{self.number}.json'
        result=self.cli('preview','--file',self.path/'site.yaml','--out',self.preview_path)
        self.assertTrue(result['ok'],result); self.preview_data=result['data']; return result['data']
    def apply(self,operation='00000000-0000-4000-8000-000000000001'):
        return self.cli('apply','--preview',self.preview_path,'--confirm',self.preview_data['confirm_hash'],'--operation-id',operation)
    def test_success_then_unchanged_and_stale(self):
        self.preview(); result=self.apply(); self.assertTrue(result['ok'],result); self.assertEqual(result['data']['overall'],'applied')
        self.assertEqual(self.site.writes[1][2]['endpoint-port'],'51820')
        self.assertEqual(self.apply()['error']['code'],'state_changed')
        self.preview(); result=self.apply('00000000-0000-4000-8000-000000000002'); self.assertEqual(result['data']['overall'],'applied')
        self.assertEqual(result['data']['devices']['hub']['result'],'unchanged'); self.assertEqual(len(self.hub.writes),2)
        self.assertNotIn('SECRET',self.preview_path.read_text())
    def test_drift_blocks_all_writes(self):
        self.preview(); self.hub.rows['/rest/interface/wireguard'][0]['public-key']=KEYS[1]
        self.assertEqual(self.apply()['error']['code'],'state_changed'); self.assertFalse(self.hub.writes+self.site.writes)
    def test_metrics_ignored(self):
        self.preview(); self.hub.rows['/rest/interface/wireguard'][0]['rx']='999'
        self.assertEqual(self.apply()['data']['overall'],'applied')
    def test_unowned_collision(self):
        self.hub.rows['/rest/ip/address'].append({'.id':'*2','interface':'wg-test','address':'10.0.0.1/30','comment':'manual'})
        self.assertTrue(self.preview()['conflicts']); self.assertEqual(self.apply()['error']['code'],'conflict'); self.assertFalse(self.hub.writes)
    def test_interface_key_conflict(self):
        self.site.rows['/rest/interface/wireguard'][0]['public-key']=KEYS[0]
        self.preview(); self.assertEqual(self.apply()['error']['code'],'conflict')
    def test_unknown_stops_site(self):
        self.preview(); self.hub.mode='drop'; result=self.apply()['data']; self.assertEqual(result['overall'],'unknown'); self.assertFalse(self.site.writes)
        self.assertEqual(result['devices']['hub']['operations'][-1]['outcome'],'unknown')
        self.assertTrue(list(self.path.glob('*.before.json')))
    def test_verify_failure_stops_site(self):
        self.preview(); self.hub.mode='ignore'; result=self.apply()['data']; self.assertNotEqual(result['overall'],'applied'); self.assertFalse(result['devices']['hub']['verification']['ok']); self.assertFalse(self.site.writes)
    def test_partial(self):
        self.preview(); self.site.mode='reject'; result=self.apply()['data']; self.assertEqual(result['overall'],'partial')
    def test_independent_path_required(self):
        self.hub.rows['/rest/ip/address'][0]['interface']='wg-test'; self.preview(); self.assertEqual(self.apply()['error']['code'],'no_independent_path'); self.assertFalse(self.hub.writes)
    def test_tampered_operations(self):
        self.preview(); v=json.loads(self.preview_path.read_text()); v['operations'][1]['address']='10.9.9.1/30'; self.preview_path.write_text(json.dumps(v)); self.assertEqual(self.apply()['error']['code'],'state_changed')
    def test_update_and_duplicate_cleanup(self):
        self.preview(); self.apply(); self.hub.rows['/rest/ip/address'].append({'.id':'*F','interface':'wg-test','address':'10.0.0.5/30','comment':'WGTUN:TEST:address'})
        self.hub.rows['/rest/interface/wireguard/peers'][0]['persistent-keepalive']='10s'
        self.preview(); self.assertEqual(self.apply('00000000-0000-4000-8000-000000000003')['data']['overall'],'applied')
        self.assertTrue(any(x[0]=='DELETE' for x in self.hub.writes)); self.assertTrue(any(x[0]=='PATCH' for x in self.hub.writes)); self.assertEqual(len(self.hub.rows['/rest/ip/address']),2)
    def test_consumed_unchanged_preview_cannot_execute_again(self):
        self.preview(); self.apply(); self.preview()
        self.assertEqual(self.apply('00000000-0000-4000-8000-000000000002')['data']['overall'],'applied')
        self.assertEqual(self.apply('00000000-0000-4000-8000-000000000003')['error']['code'],'preview_consumed')
    def test_tag_on_another_interface_is_a_conflict(self):
        self.hub.rows['/rest/ip/address'].append({'.id':'*F','interface':'other','address':'10.9.0.1/30','comment':'WGTUN:TEST:address'})
        self.preview(); self.assertEqual(self.apply()['error']['code'],'conflict'); self.assertFalse(self.hub.writes)
    def test_config_identity_change_blocks_apply(self):
        self.preview(); path=self.path/'config.toml'; path.write_text(path.read_text().replace('username="test"','username="other"'))
        self.assertEqual(self.apply()['error']['code'],'state_changed'); self.assertFalse(self.hub.writes)
    def test_cli_lock_covers_two_previews_same_target(self):
        import fcntl,hashlib
        self.preview(); url=f'http://127.0.0.1:{self.hub.server.server_port}'
        directory=self.path/'apply-locks'; directory.mkdir(exist_ok=True)
        lock=directory/hashlib.sha256(json.dumps(url,separators=(',',':')).encode()).hexdigest()
        with lock.open('w') as file:
            fcntl.flock(file,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertEqual(self.apply()['error']['code'],'resource_busy'); self.assertFalse(self.hub.writes)
    def test_report_hash_matches_canonical_json(self):
        import hashlib
        self.preview(); r=self.apply()['data']; digest=r.pop('report_hash')
        self.assertEqual(digest,hashlib.sha256(json.dumps(r,sort_keys=True,separators=(',',':')).encode()).hexdigest())
    def test_rsc_uses_model_and_correct_public_key(self):
        out=self.path/'rsc'; self.assertTrue(self.cli('plan','render','--file',self.path/'site.yaml','--out',out)['ok']); text=(out/'hub.rsc').read_text(); self.assertIn(KEYS[0],text); self.assertIn(KEYS[1],text); self.assertIn('interface="wg-test" comment="WGTUN:TEST:peer"',text)
if __name__=='__main__':
    import sys
    if '--serve' in sys.argv:
        fixture=Tests('test_partial'); fixture.setUp()
        try:
            print(json.dumps({'directory':str(fixture.path)}),flush=True)
            input()
        finally: fixture.tearDown()
    else: unittest.main()
