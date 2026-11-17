"""Frozen-baseline integration checks. NOT a Theos compile or device test."""
from pathlib import Path
import hashlib,json,zipfile,io,os,re,plistlib,tempfile,subprocess,sys
r=Path(__file__).resolve().parent
sha=lambda data:hashlib.sha256(data).hexdigest()
provenance=(r/'merge-provenance.json').read_bytes()
assert sha(provenance)=='ef600d467df6dc97f82a5a0e86056cc9ddaaaa4e7285bc6a318f68ac365c8265', 'Approved merge provenance changed'
proof=json.loads(provenance)
assert proof['revision']==2
with zipfile.ZipFile(r/'merge-baselines.zip') as archive:
 basebytes=archive.read('netease-card-previous-reference-source.zip')
 kuwobytes=archive.read('alex-kuwo-audiostatus-5.8.8.1-source.zip')
assert sha(basebytes)==proof['base_sha256']=='f7cf520654de5d7ce78274d38fa056c30d175a9784686beaaa60469a75940ec5'
assert sha(kuwobytes)==proof['kuwo_sha256']=='1f1d2dad2380cbfdaaa57ea15a75771c04ab672d4826d56c1b99b7b64c9e5334'
base=zipfile.ZipFile(io.BytesIO(basebytes));kuwo=zipfile.ZipFile(io.BytesIO(kuwobytes))
assert len(base.namelist())==99 and len(kuwo.namelist())==46
mapping=[['AlexKuwoProbe','AxsHeadsetBridge'],['alex_kuwoprobe','axs_headsetbridge'],['com.alex.kuwoprobe','com.axs.headsetbridge']]
assert proof['namespace_mapping']==mapping
def remap(text):
 for old,new in mapping:text=text.replace(old,new)
 return text
keep_root={'README.md','source-manifest.json','card-source-manifest.json','tweak.json'}
excluded={n for n in base.namelist() if '/' not in n and Path(n).suffix in {'.py','.json','.md'} and n not in keep_root}
excluded.add('Headers/AxsHeadsetBridgePrivate.h')
assert set(proof['archived_files'])==excluded and len(excluded)==41
assert base.read('Headers/AxsHeadsetBridgePrivate.h').decode().strip().endswith('// Declare only private interfaces confirmed on the target iOS version.')
for name in excluded:assert not (r/name).exists(),('Archived file accidentally left active',name)
expected={n:base.read(n) for n in base.namelist() if n not in excluded}
kwfiles=[n for n in kuwo.namelist() if n.startswith('Sources/AlexKuwoProbeKuwo') or n in ['Sources/AlexKuwoProbeAudioStatus.h','Sources/AlexKuwoProbeAudioStatus.m']]
assert proof['kuwo_files']==kwfiles and len(kwfiles)==15
for n in kwfiles:expected[remap(n)]=remap(kuwo.read(n).decode()).encode()
presentation={
 'Sources/AxsHeadsetBridgeKuwoLog.m':[['/Library/Logs/AxsHeadsetBridge-springboard.jsonl','/Library/Logs/HeadsetBridge-springboard.jsonl'],['Documents/AxsHeadsetBridge-music.jsonl','Documents/HeadsetBridge-music.jsonl']],
 'Sources/AxsHeadsetBridgeKuwoProcess.m':[['/Library/Logs/AxsHeadsetBridge-kuwo-system-runtime.json','/Library/Logs/HeadsetBridge-kuwo-system-runtime.json']]}
assert proof['kuwo_presentation_patches']==presentation
for name,changes in presentation.items():
 text=expected[name].decode()
 for old,new in changes:
  assert text.count(old)==1
  text=text.replace(old,new,1)
 expected[name]=text.encode()
cleanup={
 'Sources/AxsHeadsetBridgeCloudRuntime.h':[['void axs_headsetbridge_cloud_inventory(void);\n','']],
 'Sources/AxsHeadsetBridgeKuwoRuntime.h':[['void axs_headsetbridge_kuwo_inventory(void);\n','']]}
assert proof['declaration_cleanup']==cleanup
for name,changes in cleanup.items():
 text=expected[name].decode()
 for old,new in changes:
  assert text.count(old)==1
  text=text.replace(old,new,1)
 expected[name]=text.encode()
patches=proof['wiring_patches']
assert set(patches)=={'Hooks/AxsHeadsetBridgeMain.xm','Makefile','source-manifest.json','control','build.sh'}
for name,changes in patches.items():
 text=expected[name].decode()
 for old,new in changes:
  assert old and text.count(old)==1,('Patch anchor must be unique',name)
  text=text.replace(old,new,1)
 expected[name]=text.encode()
# README is integration documentation; no old code/test hash is loosened.
for name,data in expected.items():
 if name!='README.md':assert (r/name).read_bytes()==data,('Unapproved integration difference',name)
infra={'merge-baselines.zip','merge-provenance.json','validate_merge.py','test_merge.py','MERGE-REVIEW.md'}
for directory,dirs,files in os.walk(r,followlinks=False):
 current=Path(directory)
 dirs[:]=[d for d in dirs if d not in {'.git','__pycache__'} and not(current==r and d=='theos-roothide')]
 for filename in files:
  name=(current/filename).relative_to(r).as_posix()
  assert name in expected or name in infra,('Unexpected project file',name)
# Functional integration anchors are checked on the CURRENT merged files.
make=(r/'Makefile').read_text();joined=make.replace('\\\n',' ')
manifest=json.loads((r/'source-manifest.json').read_text())
assert re.findall(r'^AxsHeadsetBridge_FILES\s*=\s*(.*)$',joined,re.M)[0].split()==manifest
assert len(manifest)==18 and len(set(manifest))==len(manifest)
assert 'AudioToolbox' in make and 'TWEAK_NAME = AxsHeadsetBridge AxsHeadsetBridgeCard' in make
card_manifest=json.loads((r/'card-source-manifest.json').read_text())
assert re.findall(r'^AxsHeadsetBridgeCard_FILES\s*=\s*(.*)$',joined,re.M)[0].split()==card_manifest
assert len(card_manifest)==4 and not set(manifest)&set(card_manifest)
pref_sources=sorted((r/'AxsHeadsetBridgePrefs').glob('*.m'))
compile_files=[r/name for name in manifest+card_manifest]+pref_sources
assert len(compile_files)==25
for source in compile_files:
 assert source.is_file(),source
 for header in re.findall(r'#import "([^"]+)"',source.read_text()):
  assert (source.parent/header).is_file() or (r/'Sources'/header).is_file(),(source,header)
assert '-I./Headers' not in make
for script in ['build.sh','collect-logs.sh']:subprocess.run(['sh','-n',str(r/script)],check=True)
entry=(r/'Hooks/AxsHeadsetBridgeMain.xm').read_text()
kuwo_start='if ([bundle isEqual:@"com.yeelion.kwplayer"]) {\n                axs_headsetbridge_audioStatusStart();\n                axs_headsetbridge_kuwo_flowTraceStart();\n                axs_headsetbridge_kuwo_diagnosticsStart();\n            }'
assert entry.count(kuwo_start)==1
assert entry.count('axs_headsetbridge_audioStatusStart();')==1
assert entry.count('axs_headsetbridge_cloud_startMusic();')==entry.count('axs_headsetbridge_kuwo_startMusic();')==1
assert 'integration_revision":@2' in entry
assert '#import "AxsHeadsetBridgeAudioStatus.h"' in entry
assert 'extern "C"' in (r/'Sources/AxsHeadsetBridgeAudioStatus.h').read_text()
for name in ['Sources/AxsHeadsetBridgeCloudMusic.m','Sources/AxsHeadsetBridgeCloudPlayback.m','Sources/AxsHeadsetBridgeGate.m','Sources/AxsHeadsetBridgePreferences.h']:
 assert (r/name).read_bytes()==base.read(name),('Original Cloud/shared policy changed',name)
code='\n'.join((r/name).read_text() for name in manifest)
for bad in ['MixWithOthers','mixWithOthers','startup_request_read','AlexKuwoProbe','alex_kuwoprobe','com.alex.kuwoprobe','setActive:YES']:
 assert bad not in code,bad
assert 'com.alex.kuwoprobe' in (r/'control').read_text().split('Conflicts: ',1)[1].split(', ')
assert set(plistlib.loads((r/'AxsHeadsetBridge.plist').read_bytes())['Filter']['Bundles'])=={'com.apple.springboard','com.netease.cloudmusic','com.yeelion.kwplayer'}
assert set(plistlib.loads((r/'AxsHeadsetBridgeCard.plist').read_bytes())['Filter']['Bundles'])=={'com.apple.springboard','com.apple.SharingViewService'}
subprocess.run([sys.executable,'-B',str(r/'test_merge.py'),'--model-only'],check=True)
if '--quick' not in sys.argv:
 # Restore each input from its immutable archive and run its unchanged full checks.
 with tempfile.TemporaryDirectory() as tmp:
  for label,z,validator in [('base',base,'validate_branding.py'),('kuwo',kuwo,'validate_audio_status.py')]:
   dest=Path(tmp)/label;z.extractall(dest)
   subprocess.run([sys.executable,'-B',str(dest/validator)],check=True)
 print('PASS both archived input projects: complete original validator suites passed.')
print('PASS current integration: original Cloud/Card/UI/shared Gate preserved; frozen Kuwo mapping + exact log-path fixes; five approved wiring files; archived legacy duplicates removed.')
print('NOT TESTED Apple SDK/Theos compile/link, install, shared-config behavior on device, audible playback or cold-start recovery.')
