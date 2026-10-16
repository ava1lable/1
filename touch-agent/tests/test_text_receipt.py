from pathlib import Path
import shutil,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
class TextReceiptTests(unittest.TestCase):
 def test_production_receipt_policy(self):
  cc=shutil.which('clang') or shutil.which('cc')
  if not cc:
   if sys.platform=='darwin':self.fail('Cloud C compiler required')
   self.skipTest('Cloud compiler required for production policy')
  code=r'''
#include "JHHTextReceipt.h"
#include <assert.h>
int main(void) {
 assert(!JHHTextCanDispatch(0,0));assert(JHHTextCanDispatch(1,0));assert(JHHTextCanDispatch(0,1));
 assert(JHHTextClassify(0,0,1,1,1,0)==JHHTextEventFailed); /* false BOOL, nil NSError */
 assert(JHHTextClassify(1,1,1,1,1,0)==JHHTextEventFailed);
 assert(JHHTextClassify(1,0,0,1,1,0)==JHHTextAppChanged);
 assert(JHHTextClassify(1,0,1,0,0,0)==JHHTextContextLost);
 assert(JHHTextClassify(1,0,1,0,1,0)==JHHTextDispatched); /* keyboard hidden but editing focus retained */
 assert(JHHTextClassify(1,0,1,1,0,0)==JHHTextDispatched); /* AX focus not observed, visible keyboard */
 assert(JHHTextClassify(1,0,1,0,0,1)==JHHTextDispatched); /* explicit Return may close keyboard */
 for(int s=0;s<2;s++)for(int e=0;e<2;e++)for(int a=0;a<2;a++)for(int k=0;k<2;k++)for(int f=0;f<2;f++) {
  JHHTextOutcome o=JHHTextClassify(s,e,a,k,f,0);
  if(o==JHHTextDispatched)assert(s&&!e&&a&&(k||f));
 }
 return 0;
}'''
  with tempfile.TemporaryDirectory() as t:
   p=Path(t);(p/'test.c').write_text(code)
   subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'patches'),str(p/'test.c'),'-o',str(p/'test')],check=True)
   subprocess.run([str(p/'test')],check=True)
 def test_callback_result_and_privacy(self):
  s=(ROOT/'patches/JHHControlCommands.m').read_text()
  self.assertIn('succeeded=result;failed=error!=nil',s)
  self.assertIn('@"insertionVerified":@NO',s)
  self.assertIn('beforePID>0&&afterApp.processID==beforePID',s)
  helper=s[s.index('static BOOL JHHTextKeyboardVisible'):s.index('+ (XCUIElement *)keyboardKey:')]
  for forbidden in ('.value','.label','.identifier','setValue:','UIPasteboard','NSLog'):self.assertNotIn(forbidden,helper)
  self.assertIn('seen++<4096',helper)
  self.assertEqual(helper.count('typeText:text atOffset'),1)
 def test_actual_foundation_json_boolean_wire_format(self):
  if sys.platform!='darwin':self.skipTest('Foundation JSON serialization requires macOS; mandatory in cloud')
  cc=shutil.which('clang');self.assertIsNotNone(cc)
  code=r'''
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include "JHHTextReceipt.h"
int main(int argc,const char **argv) { @autoreleasepool {
 JHHTextOutcome outcome=JHHTextDispatched;
 NSNumber *old=@(outcome==JHHTextDispatched);
 NSDictionary *values=@{@"originalAccepted":old,@"fixedAccepted":JHHTextAcceptedValue(outcome),
                       @"negative":JHHTextAcceptedValue(JHHTextEventFailed)};
 NSData *wire=[NSJSONSerialization dataWithJSONObject:values options:0 error:nil];
 NSDictionary *decoded=[NSJSONSerialization JSONObjectWithData:wire options:0 error:nil];
 assert(CFGetTypeID((__bridge CFTypeRef)decoded[@"originalAccepted"])!=CFBooleanGetTypeID());
 assert(CFGetTypeID((__bridge CFTypeRef)decoded[@"fixedAccepted"])==CFBooleanGetTypeID());
 assert(CFGetTypeID((__bridge CFTypeRef)decoded[@"negative"])==CFBooleanGetTypeID());
 assert([decoded[@"fixedAccepted"] boolValue]&&![decoded[@"negative"] boolValue]);
 assert([wire writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES]);
 } return 0; }
'''
  with tempfile.TemporaryDirectory() as t:
   p=Path(t);(p/'test.m').write_text(code)
   subprocess.run([cc,'-fobjc-arc','-framework','Foundation','-framework','CoreFoundation','-I',str(ROOT/'patches'),str(p/'test.m'),'-o',str(p/'test')],check=True)
   subprocess.run([str(p/'test'),str(ROOT/'json-codec-proof.json')],check=True)
  source=(ROOT/'patches/JHHControlCommands.m').read_text()
  self.assertIn('@"accepted":JHHTextAcceptedValue(outcome)',source)
  self.assertNotIn('@"accepted":@(outcome==',source)
if __name__=='__main__':unittest.main()
