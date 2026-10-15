"""Compile and exercise the exact C transform used in the phone agent."""
from pathlib import Path
import shutil,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
class CoordinateTransformTests(unittest.TestCase):
    def test_production_transform(self):
        cc=shutil.which('clang') or shutil.which('cc')
        if not cc:
            if sys.platform=='darwin':self.fail('Cloud C compiler required')
            self.skipTest('C compiler unavailable locally; required on macOS build')
        program=r'''
#include "JHHCoordinateTransform.h"
#include <assert.h>
#define NEAR(a,b) assert(fabs((a)-(b))<0.0001)
int main(void) {
 JHHTransform t;JHHPoint p;
 assert(JHHTransformCreate((JHHPoint){10,20},(JHHPoint){197.5,20},(JHHPoint){10,426},&t));
 assert(JHHTransformMap(t,0,0,&p));NEAR(p.x,10);NEAR(p.y,20);
 assert(JHHTransformMap(t,.25,.75,&p));NEAR(p.x,103.75);NEAR(p.y,629);
 assert(JHHTransformCreate((JHHPoint){896,0},(JHHPoint){896,207},(JHHPoint){448,0},&t));
 assert(JHHTransformMap(t,.25,.75,&p));NEAR(p.x,224);NEAR(p.y,103.5);
 assert(JHHTransformCreate((JHHPoint){414,896},(JHHPoint){207,896},(JHHPoint){414,448},&t));
 assert(JHHTransformMap(t,.25,.75,&p));NEAR(p.x,310.5);NEAR(p.y,224);
 assert(JHHTransformCreate((JHHPoint){0,0},(JHHPoint){414,0},(JHHPoint){0,896},&t));
 assert(JHHTransformMap(t,.5,.5,&p));NEAR(p.x,414);NEAR(p.y,896);
 assert(JHHTransformMap(t,1,1,&p));assert(p.x<828&&p.y<1792);
 assert(!JHHTransformMap(t,NAN,.5,&p));assert(!JHHTransformMap(t,.5,INFINITY,&p));
 assert(!JHHTransformMap(t,-.01,.5,&p));assert(!JHHTransformMap(t,.5,1.01,&p));
 assert(!JHHTransformCreate((JHHPoint){0,0},(JHHPoint){1,1},(JHHPoint){2,2},&t));
 assert(!JHHTransformCreate((JHHPoint){NAN,0},(JHHPoint){1,0},(JHHPoint){0,1},&t));
 return 0;
}'''
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'check.c';binary=root/'check'
            source.write_text(program,encoding='utf-8')
            subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'patches'),str(source),'-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True)
