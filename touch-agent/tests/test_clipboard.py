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
 JHHClipboardPinch p;
 assert(!JHHClipboardPastePinch(100,800,400,&p));assert(!JHHClipboardPastePinch(375,812,50,&p));
 assert(!JHHClipboardPastePinch(375,812,900,&p));assert(!JHHClipboardPastePinch(NAN,812,400,&p));
 assert(JHHClipboardPastePinch(375,812,450,&p));
 for(int i=0;i<3;i++){assert(p.sx[i]>0&&p.sx[i]<1&&p.ex[i]>0&&p.ex[i]<1);assert(p.sy[i]>0&&p.ey[i]>0&&p.sy[i]<450.0/812&&p.ey[i]<450.0/812);}
 assert(p.ey[0]<p.sy[0]&&p.ex[1]>p.sx[1]&&p.ex[2]<p.sx[2]);
 return 0;}'''
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp);(p/'test.c').write_text(code)
   subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'patches'),str(p/'test.c'),'-o',str(p/'test')],check=True)
   subprocess.run([str(p/'test')],check=True)
 def test_foreground_write_and_restore_without_reading_old_clipboard(self):
  s=(ROOT/'patches/JHHClipboard.m').read_text()
  self.assertLess(s.index('[runner activate]'),s.index('[pb setItems:'))
  self.assertLess(s.index('[pb setItems:'),s.index('pb.string'))
  self.assertIn('@finally',s);self.assertIn('[target activate]',s)
  self.assertIn('UIPasteboardOptionLocalOnly:@YES',s)
  self.assertIn('UIPasteboardOptionExpirationDate',s)
  self.assertNotIn('NSLog',s);self.assertNotIn('setValue:',s)
 def test_one_use_ticket_before_paste_gesture(self):
  s=(ROOT/'patches/JHHClipboard.m').read_text();s=s[s.index('+ (id<FBResponsePayload>)pasteClipboard:'):]
  self.assertLess(s.index('JHHPreparedClipboard=nil'),s.index('initForTouchAtPoint:'))
  self.assertIn('JHHClipboardContext(',s);self.assertIn('finger<3',s)
  self.assertIn('JHHClipboardPastePinch(',s)
  self.assertNotIn('app.buttons',s);self.assertNotIn('[paste tap]',s);self.assertNotIn('acceptWithError',s)
  self.assertNotIn('liftUpAtOffset:.65',s)
  self.assertIn('paste_gesture_invoked_unverified',s)
if __name__=='__main__':unittest.main()
