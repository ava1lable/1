"""Execute the exact cache policy compiled into the phone, not a Python copy."""
from pathlib import Path
import shutil, subprocess, sys, tempfile, unittest
ROOT=Path(__file__).resolve().parents[1]

class GeometryCacheTests(unittest.TestCase):
    def test_production_cache_policy(self):
        cc=shutil.which('clang') or shutil.which('cc')
        if not cc:
            if sys.platform=='darwin':self.fail('Cloud C compiler required')
            self.skipTest('C compiler unavailable locally; mandatory in cloud build')
        code=r'''
#include "JHHGeometryCache.h"
#include <assert.h>
int main(void) {
 JHHGeometryKey k={101,1,{0,0,375,812},{0,0,1125,2436},3};
 JHHCacheRect frame={0,0,375,812};JHHGeometryCache c={0};
 assert(JHHGeometryCacheInspect(&c,k,0)==JHHCacheCold);
 assert(JHHGeometryCacheLearn(&c,k,frame,0));
 int anchors=1,validations=0;
 for(int i=1;i<600;i++) {
   double t=i*.1;JHHCachePlan p=JHHGeometryCacheInspect(&c,k,t);
   if(p==JHHCacheCheckFrame) { validations++;assert(JHHGeometryCacheValidate(&c,k,frame,t)); }
   else assert(p==JHHCacheHit);
 }
 // Crossing eleven old five-second expirations never rebuilds anchors.
 assert(anchors==1&&validations==11);
 assert(JHHGeometryCacheInspect(&c,k,60)==JHHCacheCheckFrame);
 assert(JHHGeometryCacheValidate(&c,k,frame,60));
 assert(JHHGeometryCacheInspect(&c,k,300)==JHHCachePeriodic);
 assert(!JHHGeometryCacheValidate(&c,k,frame,300));
 assert(JHHGeometryCacheLearn(&c,k,frame,60));
 JHHGeometryKey other=k;other.pid++;
 assert(JHHGeometryCacheInspect(&c,other,61)==JHHCacheStateChanged);
 other=k;other.orientation=3;assert(JHHGeometryCacheInspect(&c,other,61)==JHHCacheStateChanged);
 other=k;other.screen.width++;assert(JHHGeometryCacheInspect(&c,other,61)==JHHCacheStateChanged);
 other=k;other.nativeScreen.height++;assert(JHHGeometryCacheInspect(&c,other,61)==JHHCacheStateChanged);
 other=k;other.scale=2;assert(JHHGeometryCacheInspect(&c,other,61)==JHHCacheStateChanged);
 assert(JHHGeometryCacheInspect(&c,k,59)==JHHCacheClockChanged);
 assert(JHHGeometryCacheInspect(&c,k,NAN)==JHHCacheClockChanged);
 JHHCacheRect moved=frame;moved.y=20;
 assert(!JHHGeometryCacheValidate(&c,k,moved,61));
 assert(JHHGeometryCacheInspect(&c,k,61)==JHHCacheCold);
 assert(JHHGeometryCacheLearn(&c,k,frame,61));
 moved=frame;moved.height-=300;assert(!JHHGeometryCacheValidate(&c,k,moved,62));
 assert(JHHGeometryCacheLearn(&c,k,frame,62));
 moved=frame;moved.width=NAN;assert(!JHHGeometryCacheValidate(&c,k,moved,63));
 assert(!JHHGeometryCacheLearn(&c,k,moved,63));
 assert(!c.valid);
 other=k;other.pid=0;assert(!JHHGeometryCacheLearn(&c,other,frame,63));
 other=k;other.orientation=0;assert(!JHHGeometryCacheLearn(&c,other,frame,63));
 JHHGeometryCache phones[2]={{0},{0}};
 assert(JHHGeometryCacheLearn(&phones[0],k,frame,0));
 assert(JHHGeometryCacheLearn(&phones[1],k,frame,30));
 assert(JHHGeometryCacheInspect(&phones[0],k,301)==JHHCachePeriodic);
 assert(JHHGeometryCacheInspect(&phones[1],k,301)==JHHCacheCheckFrame);
 // Fresh keyboard-frame validation cannot extend the bounded five-minute calibration limit.
 assert(JHHGeometryCacheLearn(&c,k,frame,0));
 for(int i=1;i<600;i++)assert(JHHGeometryCacheValidate(&c,k,frame,i*.1));
 assert(JHHGeometryCacheInspect(&c,k,60)==JHHCacheCheckFrame);
 assert(JHHGeometryCacheInspect(&c,k,300)==JHHCachePeriodic);
 return 0;
}'''
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp);src=p/'cache.c';binary=p/'cache'
            src.write_text(code,encoding='utf-8')
            subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'patches'),str(src),'-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True)

    def test_frame_validation_keeps_existing_coordinate_basis(self):
        source=(ROOT/'patches/JHHControlCommands.m').read_text(encoding='utf-8')
        self.assertIn('CGRect frame=app.frame;',source)
        self.assertIn('JHHGeometryCacheValidate(&geometry->cache',source)
        self.assertIn('NSProcessInfo.processInfo.systemUptime',source)
        self.assertIn('origin.screenPoint',source)
        self.assertIn('JHHGeometryCacheValidate(&geometry->cache',source)
        self.assertIn('keyboard.fb_standardSnapshot',source)
        self.assertNotIn('started-JHHCoordinateTime < 5',source)

if __name__=='__main__':unittest.main()
