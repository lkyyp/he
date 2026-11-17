"""Integration contract and design model, not real notify/SDK/device execution."""
from pathlib import Path
import sys,subprocess,tempfile,shutil,os,plistlib
r=Path(__file__).resolve().parent

def model():
 root=plistlib.loads((r/'AxsHeadsetBridgePrefs/Resources/AxsHeadsetBridgeRoot.plist').read_bytes())
 items={x['key']:x for x in root['items'] if 'key' in x}
 assert items['selectedApp']['validValues']==['cloud','kuwo'] and items['enabled']['default'] is False
 assert any(x.get('label')=='弹窗时限' for x in root['items'])
 # A selection epoch change revokes old capability; the existing connection is rebaselined.
 cases=0
 for selected in ['cloud','kuwo']:
  for enabled in [False,True]:
   for request_target in ['cloud','kuwo']:
    for matches_epoch in [False,True]:
     for live in [False,True]:
      authorized=enabled and request_target==selected and matches_epoch and live
      if not enabled or request_target!=selected or not matches_epoch or not live:assert not authorized
      cases+=1
 # Candidate and committed capabilities are distinct: a switch/ABA cannot revive the old one.
 schedules=0
 for engine in ['cloud','kuwo']:
  for stage in ['before_consume','after_consume']:
   for change in ['none','challenge','new_session','new_lease','off','target','epoch_ABA','expired','disconnect','read_failure','zero_challenge']:
    session,lease,epoch,challenge=7,(7,123),11,101
    candidate=(session,challenge);expected_lease=lease;expected_epoch=epoch
    consumed=0;handled=0;plays=0
    if stage=='after_consume':consumed=session
    enabled=True;selected=engine;route=True;now=100;read=True
    if change=='challenge':challenge=102
    elif change=='new_session':session=8;lease=(8,123)
    elif change=='new_lease':lease=(7,124)
    elif change=='off':enabled=False
    elif change=='target':selected='kuwo' if engine=='cloud' else 'cloud'
    elif change=='epoch_ABA':epoch=13
    elif change=='expired':now=123
    elif change=='disconnect':route=False;lease=(0,0)
    elif change=='read_failure':read=False
    elif change=='zero_challenge':challenge=0
    request_ok=bool(challenge) and session==candidate[0] and (engine=='kuwo' or challenge==candidate[1])
    valid=read and request_ok and lease==expected_lease and epoch==expected_epoch and enabled and selected==engine and route and now<lease[1]
    if valid:
     if stage=='before_consume':consumed=session
     handled=session;plays+=1
    expect=change=='none' or (change=='challenge' and engine=='kuwo')
    assert plays==int(expect),(engine,stage,change)
    # Deliver another copy: neither a false result nor an exception refunds consumed.
    if consumed!=session and handled!=session and valid:plays+=1
    assert plays<=1
    if stage=='after_consume':assert consumed==candidate[0]
    schedules+=1
 assert schedules==44
 # Existing Cloud keeps its challenge policy; Kuwo accepts only same-session rotations.
 cloud=(r/'Sources/AxsHeadsetBridgeCloudPlayback.m').read_text()
 kuwa=(r/'Sources/AxsHeadsetBridgeKuwoMusic.m').read_text()
 kuwo=(r/'Sources/AxsHeadsetBridgeKuwoPlayback.m').read_text()
 assert 'finalRequest != requestState' in cloud
 assert 'currentRequest != requestState' not in kuwa
 assert '(uint32_t)(currentRequest >> 32) != (uint32_t)(requestState >> 32)' in kuwa
 assert 'notify_get_state(t, &playbackRequest)' in kuwa
 assert '(uint32_t)(playbackRequest >> 32) != (uint32_t)(requestState >> 32)' in kuwa
 assert 'playbackRequest)' in kuwa[kuwa.index('music.ack_sent'):kuwa.index('NSNotificationCenter *center')]
 assert '(uint32_t)(finalRequest >> 32) != session' in kuwo
 assert 'finalLease != lease' in cloud and 'finalLease != lease' in kuwo
 assert 'consumed == nonce' in cloud and 'consumed == nonce' in kuwo
 assert cloud.count('((void (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"playCurrentSong"))')==1
 assert kuwo.count('((BOOL (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(@"play"))')==1
 for engine in ['cloud','kuwo']:
  sb=(r/('Sources/AxsHeadsetBridge'+('Cloud' if engine=='cloud' else 'Kuwo')+'SpringBoard.m')).read_text()
  assert '+ 23.0' in sb and '3 * NSEC_PER_SEC' in sb and '@[@1, @3, @6, @10, @16]' in sb
  assert 'ObservedEpoch != epoch' in sb and 'audio_device_set_changed' in sb
 assert 'now + 6.0' in (r/'Sources/AxsHeadsetBridgeKuwoBackground.m').read_text()
 assert 'out[@"audio_status_revision"]=@1;' in (r/'Sources/AxsHeadsetBridgeAudioStatus.m').read_text() or 'row[@"audio_status_revision"]=@1;' in (r/'Sources/AxsHeadsetBridgeAudioStatus.m').read_text()
 print('PASS',cases,'selection/epoch cases +',schedules,'consume/cancel/duplicate schedules; current selectors, one Play, original Cloud vs frozen Kuwo challenge rules, 23s/6s preserved.')
 print('Design abstraction only; does not prove concurrent cross-process cancellation or readiness.')

model()
if '--model-only' in sys.argv:raise SystemExit(0)
with tempfile.TemporaryDirectory() as tmp:
 dest=Path(tmp)/'project'
 shutil.copytree(r,dest,ignore=shutil.ignore_patterns('.git','__pycache__','theos-roothide','.theos'))
 p=dest/'theos-roothide/CODE_OF_CONDUCT.md';p.parent.mkdir();p.write_text('external toolchain fixture')
 p=dest/'theos-roothide/sdks/iPhoneOS16.5.sdk/usr/include/mock.h';p.parent.mkdir(parents=True);p.write_text('fixture only, not an SDK')
 workflow=(dest/'.github/workflows/build.yml').read_text()
 step=workflow[workflow.index('      - name: Set Fixed Package Version'):workflow.index('      - name: Checkout Theos')]
 command='\n'.join(x[10:] for x in step.split('        run: |\n',1)[1].splitlines() if x.strip())+'\n'
 subprocess.run(['sh','-eu','-c',command],cwd=dest,env=dict(os.environ,GITHUB_OUTPUT=str(dest/'theos-roothide/output')),check=True)
 def check(ok,quick=True):
  cmd=[sys.executable,'-B',str(dest/'validate_merge.py')]
  if quick:cmd.append('--quick')
  p=subprocess.run(cmd,capture_output=True,text=True)
  assert (p.returncode==0)==ok,(p.stdout,p.stderr)
 check(True,False)
 for name in ['Sources/AxsHeadsetBridgeCloudPlayback.m','Sources/AxsHeadsetBridgeKuwoPlayback.m','Sources/AxsHeadsetBridgeGate.m','Sources/AxsHeadsetBridgeAudioStatus.m','Sources/AxsHeadsetCardTimerController.m','Hooks/AxsHeadsetBridgeMain.xm','control','Makefile']:
  p=dest/name;data=p.read_bytes();p.write_bytes(data+b'\n// undeclared mutation\n');check(False);p.write_bytes(data)
 for name in ['Sources/unapproved.m','Sources/theos-roothide/unapproved.m','theos-roothide-similar/unapproved.m']:
  p=dest/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('bad');check(False);p.unlink()
 print('PASS actual fixed-version CI shell, root toolchain/SDK directory fixtures, full source validation, 11 unapproved source/metadata/file cases rejected.')
 print('NOT actual GitHub run or Apple SDK/Theos build; fixtures do not compile code.')
