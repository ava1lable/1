from pathlib import Path
import shutil,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
class LatencyTests(unittest.TestCase):
 def test_production_geometry_bank(self):
  cc=shutil.which('clang') or shutil.which('cc')
  if not cc:self.skipTest('C compiler required in cloud')
  code=r'''
#include "JHHGeometryBank.h"
#include <assert.h>
int main(void){
 JHHGeometryBank b={0};int switched=0;
 JHHGeometryKey k={1,1,{0,0,375,812},{0,0,1125,2436},3};JHHCacheRect f={0,0,375,812};
 JHHGeometryEntry *a=JHHGeometryBankSelect(&b,k,0,&switched);assert(a);
 assert(JHHGeometryCacheLearn(&a->cache,k,f,0));a->transform.origin.x=77;
 JHHGeometryKey next=k;next.pid=2;
 JHHGeometryEntry *c=JHHGeometryBankSelect(&b,next,1,&switched);assert(c!=a&&switched);
 assert(JHHGeometryCacheLearn(&c->cache,next,f,1));
 assert(JHHGeometryBankSelect(&b,k,2,&switched)==a&&switched&&a->transform.origin.x==77);
 assert(JHHGeometryCacheValidate(&a->cache,k,f,2));
 for(int i=3;i<=5;i++){next.pid=i;c=JHHGeometryBankSelect(&b,next,i,&switched);assert(JHHGeometryCacheLearn(&c->cache,next,f,i));}
 assert(JHHGeometryBankSelect(&b,k,6,&switched)==a&&a->cache.valid);
 next.pid=2;c=JHHGeometryBankSelect(&b,next,7,&switched);assert(!c->cache.valid);
 next=k;next.orientation=3;c=JHHGeometryBankSelect(&b,next,8,&switched);assert(!c->cache.valid);
 assert(!JHHGeometryBankSelect(&b,k,NAN,0));
 assert(!JHHGeometryBankSelect(0,k,1,0));
 return 0;
}'''
  with tempfile.TemporaryDirectory() as temp:
   d=Path(temp);p=d/'bank.c';p.write_text(code)
   subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'patches'),str(p),'-o',str(d/'bank')],check=True)
   subprocess.run([str(d/'bank')],check=True)
 def test_actual_foundation_completion_waiter(self):
  if sys.platform!='darwin':self.skipTest('Actual Foundation check runs on macOS cloud')
  code=r'''
#import "JHHEventSynthesis.m"
#include <assert.h>
int main(void){@autoreleasepool{
 NSDictionary *m=nil;NSError *e=nil;
 BOOL ok=JHHWaitForEvent(^(void(^done)(BOOL,NSError*)){
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_MSEC),dispatch_get_global_queue(0,0),^{done(YES,nil);});
 },1,&m,&e);
 assert(ok&&!e&&![m[@"completionTimedOut"] boolValue]);
 assert([m[@"callbackMs"] doubleValue]>0&&[m[@"completionWaitMs"] doubleValue]<100);
 ok=JHHWaitForEvent(^(void(^done)(BOOL,NSError*)){done(NO,nil);},.1,&m,&e);assert(!ok);
 ok=JHHWaitForEvent(^(void(^done)(BOOL,NSError*)){done(YES,[NSError errorWithDomain:@"test" code:1 userInfo:nil]);},.1,&m,&e);assert(!ok&&e);
 ok=JHHWaitForEvent(^(void(^done)(BOOL,NSError*)){@throw [NSException exceptionWithName:@"test" reason:nil userInfo:nil];},.1,&m,&e);assert(!ok&&e);
 __block void(^late)(BOOL,NSError*)=nil;
 ok=JHHWaitForEvent(^(void(^done)(BOOL,NSError*)){late=[done copy];},.025,&m,&e);
 assert(!ok&&e&&[m[@"completionTimedOut"] boolValue]);late(YES,nil);late=nil;
 ok=JHHWaitForEvent(^(void(^done)(BOOL,NSError*)){done(YES,nil);done(NO,nil);},.1,&m,&e);assert(ok&&!e);
 // A callback on the owning main queue must be serviced, not deadlocked.
 ok=JHHWaitForEvent(^(void(^done)(BOOL,NSError*)){
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_MSEC),dispatch_get_main_queue(),^{done(YES,nil);});
 },1,&m,&e);assert(ok&&!e);
}}
'''
  with tempfile.TemporaryDirectory() as temp:
   d=Path(temp);p=d/'completion.m';p.write_text(code)
   subprocess.run(['clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-I',str(ROOT/'patches'),str(p),'-framework','Foundation','-framework','CoreFoundation','-o',str(d/'completion')],check=True)
   subprocess.run([str(d/'completion')],check=True)
 def test_native_layout_and_receipt_contracts(self):
  s=(ROOT/'patches/JHHControlCommands.m').read_text()
  slow=s[s.index('+ (id<FBResponsePayload>)keyArguments:'):s.index('+ (id<FBXCElementSnapshot>)snapshotKey:')]
  for remote in ('keyboard.exists','keyboardKey:','[key tap]','[layoutKey tap]','.hittable'):self.assertNotIn(remote,slow)
  self.assertIn('current.processID!=pid',slow)
  self.assertIn('current.interfaceOrientation!=orientation',slow)
  self.assertIn('snapshot=keyboard.fb_standardSnapshot',slow)
  self.assertIn('JHHLastSequence = sequence;',slow)
  self.assertIn('keyboardBefore?NO:JHHTextFocusObserved',s)
  self.assertIn('low-latency-completion-v1',s)
