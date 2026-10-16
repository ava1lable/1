from pathlib import Path
import shutil,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
class ClipboardTests(unittest.TestCase):
 def test_real_production_context_guard(self):
  cc=shutil.which('clang') or shutil.which('cc')
  if not cc:
   if sys.platform=='darwin':self.fail('Cloud compiler required')
   self.skipTest('Cloud compiler required')
  code='''#include "JHHClipboardPolicy.h"
#include <assert.h>
int main(void){
 assert(JHHClipboardFresh(30,10,20));assert(!JHHClipboardFresh(30.01,10,20));
 assert(!JHHClipboardFresh(9,10,20));assert(!JHHClipboardFresh(NAN,10,20));
 assert(JHHClipboardContext(1,1,1,1,1,1));
 for(int i=0;i<6;i++){bool f[6]={1,1,1,1,1,1};f[i]=0;assert(!JHHClipboardContext(f[0],f[1],f[2],f[3],f[4],f[5]));}
 JHHClipboardMenuTap p;
 assert(!JHHClipboardMenuTapPoints(0,0,100,812,530,50,520,&p));
 assert(!JHHClipboardMenuTapPoints(0,0,375,812,530,23,520,&p));
 assert(!JHHClipboardMenuTapPoints(0,0,375,812,530,150,528,&p));
 assert(!JHHClipboardMenuTapPoints(0,0,375,812,530,NAN,520,&p));
 assert(JHHClipboardMenuTapPoints(0,0,375,812,530,150,520,&p));
 for(int i=0;i<3;i++){assert(p.x[i]>0&&p.x[i]<375&&p.y[i]==520&&p.y[i]<530);}
 assert(p.x[0]<150&&p.x[1]==150&&p.x[2]>150);
 assert(JHHClipboardMenuTapPoints(0,0,812,375,220,330,200,&p));
 assert(JHHClipboardMenuTapPoints(10,20,375,812,550,160,540,&p));
 return 0;}'''
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp);(p/'test.c').write_text(code)
   subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'patches'),str(p/'test.c'),'-o',str(p/'test')],check=True)
   subprocess.run([str(p/'test')],check=True)
 def test_foreground_write_and_restore_without_reading_old_clipboard(self):
  s=(ROOT/'patches/JHHClipboard.m').read_text()
  self.assertLess(s.index('[runner activate]'),s.index('[pb setObjects:'))
  self.assertLess(s.index('[pb setObjects:'),s.index('current.string'))
  self.assertIn('@finally',s);self.assertIn('[restore activate]',s)
  self.assertIn('localOnly:YES',s)
  self.assertIn('expirationDate:',s)
  self.assertNotIn('NSLog',s);self.assertNotIn('setValue:',s)
 def test_one_use_ticket_before_paste_gesture(self):
  s=(ROOT/'patches/JHHClipboard.m').read_text();s=s[s.index('+ (id<FBResponsePayload>)pasteClipboard:'):]
  self.assertLess(s.index('JHHPreparedClipboard=nil'),s.index('initForTouchAtPoint:'))
  self.assertIn('JHHClipboardContext(',s);self.assertIn('finger<3',s)
  self.assertIn('JHHClipboardMenuTapPoints(',s)
  self.assertNotIn('app.buttons',s);self.assertIn('[paste tap]',s);self.assertNotIn('acceptWithError',s)
  self.assertNotIn('liftUpAtOffset:.65',s)
  self.assertIn('paste_menu_invoked_unverified',s)
 def test_delayed_foreground_and_user_interruption_policy(self):
  cc=shutil.which('clang') or shutil.which('cc')
  if not cc:
   if sys.platform=='darwin':self.fail('Cloud compiler required')
   self.skipTest('Cloud compiler required')
  code='''#include "JHHClipboardPolicy.h"
#include <assert.h>
int main(void){
 JHHForegroundWait w={10,0};
 assert(JHHClipboardForegroundStep(&w,10,0,1)==JHHForegroundPending);
 assert(JHHClipboardForegroundStep(&w,10.8,1,0)==JHHForegroundPending);
 assert(JHHClipboardForegroundStep(&w,10.88,1,0)==JHHForegroundReady);
 w=(JHHForegroundWait){20,0};
 assert(JHHClipboardForegroundStep(&w,20.1,1,0)==JHHForegroundPending);
 assert(JHHClipboardForegroundStep(&w,20.2,0,1)==JHHForegroundPending);
 assert(JHHClipboardForegroundStep(&w,20.3,1,0)==JHHForegroundPending);
 assert(JHHClipboardForegroundStep(&w,20.4,1,0)==JHHForegroundReady);
 w=(JHHForegroundWait){30,0};
 assert(JHHClipboardForegroundStep(&w,30.1,0,0)==JHHForegroundInterrupted);
 assert(JHHClipboardForegroundStep(&w,33.001,0,1)==JHHForegroundExpired);
 assert(JHHClipboardForegroundStep(&w,NAN,1,0)==JHHForegroundExpired);
 assert(JHHClipboardForegroundStep(&w,29.99,1,0)==JHHForegroundExpired);
 return 0;}'''
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp);(p/'test.c').write_text(code)
   subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'patches'),str(p/'test.c'),'-o',str(p/'test')],check=True)
   subprocess.run([str(p/'test')],check=True)
 def test_writer_waits_for_same_active_process_and_only_reads_own_write(self):
  s=(ROOT/'patches/JHHClipboard.m').read_text()
  self.assertIn('JHHClipboardWaitForApp(own,writerPID,bundle,YES)',s)
  self.assertIn('UIApplicationStateActive',s)
  self.assertIn('publishedChange==before||current.changeCount!=publishedChange',s)
  self.assertLess(s.index('publishedChange==before'),s.index('current.string'))
  self.assertIn('setObjects:@[text] localOnly:YES',s)
  self.assertIn('dateWithTimeIntervalSinceNow:600',s)
 def test_menu_action_requires_unique_enabled_system_item_and_has_no_fallback(self):
  s=(ROOT/'patches/JHHClipboard.m').read_text()
  for q in ('root.menuItems','root.menus.buttons','root.toolbars.buttons'):
   self.assertIn(q,s)
  self.assertIn('visible.count>1',s)
  self.assertIn('paste.enabled&&paste.hittable',s)
  self.assertNotIn('if(!textAvailable)',s)
  self.assertNotIn('!UIPasteboard.generalPasteboard.hasStrings',s)
  self.assertLess(s.index('if(!enabled)'),s.index('[paste tap]'))
  self.assertNotIn('app.buttons',s);self.assertNotIn('acceptWithError',s)
  self.assertNotIn('moveToPoint:',s);self.assertNotIn('JHHClipboardPastePinch',s)
if __name__=='__main__':unittest.main()
