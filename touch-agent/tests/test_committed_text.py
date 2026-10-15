from pathlib import Path
import shutil,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
class CommittedTextTests(unittest.TestCase):
    def test_production_unicode_commit_validation(self):
        cc=shutil.which('clang') or shutil.which('cc')
        if not cc:
            if sys.platform=='darwin':self.fail('Cloud C compiler required')
            self.skipTest('C compiler unavailable locally; mandatory in cloud build')
        code=r'''
#include "JHHCommittedText.h"
#include <assert.h>
int main(void) {
 uint16_t good[]={0x4e2d,0x6587,0xd83d,0xde42,'a','b','c'};
 assert(JHHCommittedTextValid(good,7));
 uint16_t emoji[]={0xd83d,0xdc69,0x200d,0xd83d,0xdcbb,0xfe0f};
 assert(JHHCommittedTextValid(emoji,6));
 assert(!JHHCommittedTextValid(good,0));assert(!JHHCommittedTextValid(0,1));
 uint16_t half[]={0xd83d};assert(!JHHCommittedTextValid(half,1));
 uint16_t low[]={0xde42};assert(!JHHCommittedTextValid(low,1));
 uint16_t badPair[]={0xd83d,'a'};assert(!JHHCommittedTextValid(badPair,2));
 for(unsigned i=0;i<32;i++){uint16_t control=(uint16_t)i;assert(!JHHCommittedTextValid(&control,1));}
 uint16_t special[]={0xe007};assert(!JHHCommittedTextValid(special,1));
 uint16_t newline[]={0x2028};assert(!JHHCommittedTextValid(newline,1));
 uint16_t large[4097];for(unsigned i=0;i<4097;i++)large[i]='a';
 assert(JHHCommittedTextValid(large,4096));assert(!JHHCommittedTextValid(large,4097));
 return 0;
}'''
        with tempfile.TemporaryDirectory() as temp:
            r=Path(temp);src=r/'text.c';binary=r/'text';src.write_text(code,encoding='utf-8')
            subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'patches'),str(src),'-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True)
    def test_committed_event_redacts_text_and_never_searches_input_field(self):
        s=(ROOT/'patches/JHHControlCommands.m').read_text(encoding='utf-8')
        text=s[s.index('+ (id<FBResponsePayload>)committedText:'):s.index('+ (XCUIElement *)keyboardKey:')]
        self.assertIn('shouldRedact:YES',text)
        self.assertIn('initForTextInput',text)
        self.assertIn('initWithName:@"JHH Committed Input"',text)
        self.assertLess(text.index('JHHLastSequence=sequence'),text.index('synthesizeEventWithRecord'))
        for word in ('textFields','textViews','setValue:','UIPasteboard','FBTypeText('):self.assertNotIn(word,text)
        self.assertIn('isText==isEditing',text)
if __name__=='__main__':unittest.main()
