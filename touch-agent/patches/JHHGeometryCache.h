// SPDX-License-Identifier: BSD-3-Clause
#ifndef JHH_GEOMETRY_CACHE_H
#define JHH_GEOMETRY_CACHE_H
#include <math.h>
#include <stdint.h>
typedef struct { double x,y,width,height; } JHHCacheRect;
typedef struct {
  int32_t pid,orientation;
  JHHCacheRect screen,nativeScreen;
  double scale;
} JHHGeometryKey;
typedef struct {
  int valid;
  JHHGeometryKey key;
  JHHCacheRect frame;
  double learnedAt,checkedAt;
} JHHGeometryCache;
typedef enum {
  JHHCacheCold, JHHCacheStateChanged, JHHCacheClockChanged,
  JHHCachePeriodic, JHHCacheCheckFrame, JHHCacheHit
} JHHCachePlan;
static inline int JHHCacheRectValid(JHHCacheRect r) {
  return isfinite(r.x)&&isfinite(r.y)&&isfinite(r.width)&&isfinite(r.height)&&r.width>0&&r.height>0;
}
static inline int JHHCacheRectEqual(JHHCacheRect a,JHHCacheRect b) {
  return a.x==b.x&&a.y==b.y&&a.width==b.width&&a.height==b.height;
}
static inline int JHHGeometryKeyValid(JHHGeometryKey k) {
  return k.pid>0&&k.orientation>=1&&k.orientation<=4&&isfinite(k.scale)&&k.scale>0
    &&JHHCacheRectValid(k.screen)&&JHHCacheRectValid(k.nativeScreen);
}
static inline int JHHGeometryKeyEqual(JHHGeometryKey a,JHHGeometryKey b) {
  return a.pid==b.pid&&a.orientation==b.orientation&&a.scale==b.scale
    &&JHHCacheRectEqual(a.screen,b.screen)&&JHHCacheRectEqual(a.nativeScreen,b.nativeScreen);
}
// Monotonic seconds. Cheap state is checked on every request. A single root
// frame is validated every five seconds; full XCTest anchors at a bounded five-minute safety limit.
static inline JHHCachePlan JHHGeometryCacheInspect(const JHHGeometryCache *c,JHHGeometryKey k,double now) {
  if(!c||!c->valid)return JHHCacheCold;
  if(!JHHGeometryKeyValid(k)||!JHHGeometryKeyEqual(c->key,k))return JHHCacheStateChanged;
  if(!isfinite(now)||now<c->learnedAt||now<c->checkedAt)return JHHCacheClockChanged;
  if(now-c->learnedAt>=300)return JHHCachePeriodic;
  return now-c->checkedAt>=5 ? JHHCacheCheckFrame : JHHCacheHit;
}
static inline int JHHGeometryCacheLearn(JHHGeometryCache *c,JHHGeometryKey k,JHHCacheRect frame,double now) {
  if(!c)return 0;
  c->valid=0;
  if(!JHHGeometryKeyValid(k)||!JHHCacheRectValid(frame)||!isfinite(now)||now<0)return 0;
  *c=(JHHGeometryCache){1,k,frame,now,now};return 1;
}
static inline int JHHGeometryCacheValidate(JHHGeometryCache *c,JHHGeometryKey k,JHHCacheRect frame,double now) {
  if(!c||!c->valid)return 0;
  JHHCachePlan p=JHHGeometryCacheInspect(c,k,now);
  if((p!=JHHCacheHit&&p!=JHHCacheCheckFrame)||!JHHCacheRectValid(frame)||!JHHCacheRectEqual(c->frame,frame)) {
    c->valid=0;return 0;
  }
  c->checkedAt=now;return 1;
}
static inline const char *JHHGeometryCacheReason(JHHCachePlan p) {
  switch(p) {
    case JHHCacheCold:return "cold";
    case JHHCacheStateChanged:return "state_changed";
    case JHHCacheClockChanged:return "clock_changed";
    case JHHCachePeriodic:return "periodic_calibration";
    case JHHCacheCheckFrame:return "frame_validation";
    default:return "hit";
  }
}
#endif
