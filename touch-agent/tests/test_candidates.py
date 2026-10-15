from pathlib import Path
import shutil,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
class CandidateTests(unittest.TestCase):
    def test_production_candidate_order_filter_and_digit_mapping(self):
        cc=shutil.which('clang') or shutil.which('cc')
        if not cc:
            if sys.platform=='darwin':self.fail('Cloud C compiler required')
            self.skipTest('C compiler unavailable locally; mandatory in cloud build')
        source=r'''
#include "JHHKeyboardCandidates.h"
#include <assert.h>
int main(void) {
 for(unsigned i=30;i<=38;i++)assert(JHHKeyboardCandidateNumber(i,0)==(int)i-29);
 for(unsigned i=89;i<=97;i++)assert(JHHKeyboardCandidateNumber(i,0)==(int)i-88);
 assert(!JHHKeyboardCandidateNumber(39,0));assert(!JHHKeyboardCandidateNumber(98,0));
 assert(!JHHKeyboardCandidateNumber(30,2));assert(!JHHKeyboardCandidateNumber(30,1));
 assert(JHHIsHan(0x4f60));assert(JHHIsHan(0x20000));assert(!JHHIsHan('a'));
 JHHCacheRect keyboard={0,500,375,300};size_t indexes[64];
 JHHCandidate nodes[]={
  {{200,510,80,35},1,1,0,1}, // third, intentionally unordered
  {{10,510,80,35},1,1,0,1},  // first
  {{100,510,80,35},1,1,0,1}, // second
  {{30,515,40,25},1,1,0,0},  // duplicate static text inside first cell
  {{0,510,375,40},1,1,0,1},  // whole toolbar container
  {{285,510,70,35},1,1,1,0}, // Chinese function button, not candidate
  {{10,600,35,40},1,1,0,1},  // ordinary key row
  {{390,510,80,35},1,1,0,1}, // outside visible frame
  {{285,510,70,35},0,1,0,1}, // disabled
  {{285,510,70,35},1,0,0,1}, // English suggestion
  {{10,560,80,25},1,1,0,1}   // a different row
 };
 size_t n=JHHVisibleCandidates(nodes,sizeof(nodes)/sizeof(nodes[0]),keyboard,590,indexes,64);
 assert(n==3);assert(indexes[0]==1&&indexes[1]==2&&indexes[2]==0);
 assert(!JHHVisibleCandidates(nodes,11,keyboard,590,indexes,1));
 assert(!JHHVisibleCandidates(nodes,11,keyboard,INFINITY,indexes,64));
 assert(!JHHVisibleCandidates(nodes,11,keyboard,500,indexes,64));
 JHHCandidate english[]={{{10,510,80,35},1,0,0,1}};
 assert(!JHHVisibleCandidates(english,1,keyboard,590,indexes,64));
 return 0;
}'''
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);p=root/'candidates.c';binary=root/'candidates'
            p.write_text(source,encoding='utf-8')
            subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'patches'),str(p),'-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True)

    def test_candidate_is_a_fresh_single_key_barrier_not_text_assignment(self):
        s=(ROOT/'patches/JHHControlCommands.m').read_text(encoding='utf-8')
        self.assertIn('keys.count==1',s)
        self.assertIn('visibleChineseCandidates:snapshot',s)
        self.assertIn('candidateIndex>candidates.count',s)
        self.assertIn('JHHMayBeComposing=NO',s)
        self.assertIn('JHHComposingPID!=app.processID',s)
        self.assertNotIn('typeText:',s)
        self.assertNotIn('setValue:',s)
        self.assertNotIn('UIPasteboard',s)
        self.assertIn('keyboard.fb_standardSnapshot',s)
        self.assertIn('index++*0.045',s)
        self.assertIn('offset+0.035',s)

if __name__=='__main__':unittest.main()
