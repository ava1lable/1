from pathlib import Path
import shutil, subprocess, tempfile, unittest

ROOT=Path(__file__).resolve().parents[1]

class NativeKeyboardMap(unittest.TestCase):
    def test_production_keyboard_map(self):
        compiler=shutil.which('cc') or shutil.which('clang')
        if not compiler: self.skipTest('No local C compiler; mandatory in macOS build')
        with tempfile.TemporaryDirectory() as temp:
            source=Path(temp)/'keys.c'; exe=Path(temp)/'keys'
            source.write_text('''#include <assert.h>
#include "JHHKeyboardMap.h"
int main(void) {
 for(unsigned i=4;i<=29;i++) { assert(JHHKeyboardCharacter(i,0)=='a'+(int)i-4); assert(JHHKeyboardCharacter(i,1)=='A'+(int)i-4); }
 for(unsigned i=30;i<=39;i++) { assert(JHHKeyboardCharacter(i,0)=="1234567890"[i-30]); assert(JHHKeyboardCharacter(i,1)=="!@#$%^&*()"[i-30]); }
 assert(JHHKeyboardCharacter(44,0)==' '); assert(JHHKeyboardCharacter(52,1)=='"');
 assert(JHHKeyboardCharacter(49,0)=='\\\\'); assert(JHHKeyboardCharacter(89,0)=='1');
 assert(JHHKeyboardCharacter(97,0)=='9'); assert(JHHKeyboardCharacter(98,0)=='0');
 assert(JHHKeyboardCharacter(40,0)==0); assert(JHHKeyboardCharacter(224,0)==0);
 return 0;
}''',encoding='utf-8')
            subprocess.run([compiler,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'patches'),str(source),'-o',str(exe)],check=True)
            subprocess.run([str(exe)],check=True)

    def test_native_route_never_sets_input_value(self):
        source=(ROOT/'patches/JHHControlCommands.m').read_text(encoding='utf-8')
        key=source[source.index('+ (id<FBResponsePayload>)key:'):]
        for forbidden in ('typeText:', 'setValue:', 'textFields', 'textViews', 'UIPasteboard'):
            self.assertNotIn(forbidden,key)
        self.assertIn('app.keyboards.firstMatch',key)
        self.assertLess(key.index('JHHLastSequence = sequence;'),key.index('[layoutKey tap]'))
        self.assertLess(key.index('JHHLastSequence = sequence;'),key.index('[key tap]'))

    def test_fast_batch_uses_single_snapshot_and_raw_event(self):
        source=(ROOT/'patches/JHHControlCommands.m').read_text(encoding='utf-8')
        fast=source[source.index('+ (id<FBResponsePayload>)keys:'):]
        self.assertEqual(fast.count('keyboard.fb_customSnapshot'),1)
        self.assertNotIn('[key tap]',fast)
        self.assertNotIn('keyboard.exists',fast)
        self.assertNotIn('.hittable',fast)
        self.assertIn('keys.count > 8',fast)
        self.assertIn('keys.count > 1 && (usage < 4 || usage > 29 || modifiers != 0)',fast)
        self.assertLess(fast.index('JHHLastSequence = sequence;'),fast.index('[FBXCTestDaemonsProxy synthesizeEventWithRecord:'))
        self.assertIn('JHHGeometryCacheValidate(&JHHKeyboardCache',fast)
