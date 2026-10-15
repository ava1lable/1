// SPDX-License-Identifier: BSD-3-Clause
#ifndef JHH_KEYBOARD_CANDIDATES_H
#define JHH_KEYBOARD_CANDIDATES_H
#include "JHHGeometryCache.h"
#include <stddef.h>
typedef struct { JHHCacheRect frame; int enabled,han,functionKey,explicitCandidate; } JHHCandidate;
static inline int JHHKeyboardCandidateNumber(unsigned usage,unsigned modifiers) {
  if(modifiers)return 0;
  if(usage>=30&&usage<=38)return (int)usage-29;
  if(usage>=89&&usage<=97)return (int)usage-88;
  return 0; // Zero and shifted symbols retain ordinary keyboard semantics.
}
static inline int JHHIsHan(unsigned cp) {
  return (cp>=0x3400&&cp<=0x4dbf)||(cp>=0x4e00&&cp<=0x9fff)
    ||(cp>=0xf900&&cp<=0xfaff)||(cp>=0x20000&&cp<=0x3134f);
}
static inline int JHHRectContains(JHHCacheRect a,double x,double y) {
  return x>=a.x&&x<=a.x+a.width&&y>=a.y&&y<=a.y+a.height;
}
static inline int JHHCandidateOverlaps(JHHCacheRect a,JHHCacheRect b) {
  double w=fmax(0,fmin(a.x+a.width,b.x+b.width)-fmax(a.x,b.x));
  double h=fmax(0,fmin(a.y+a.height,b.y+b.height)-fmax(a.y,b.y));
  return w*h>=.8*fmin(a.width*a.height,b.width*b.height);
}
// Inputs are from ONE fresh keyboard snapshot. No label or target persists
// between requests. Return unique visible top-row candidates, left to right.
static inline size_t JHHVisibleCandidates(const JHHCandidate *nodes,size_t count,
    JHHCacheRect keyboard,double firstLetterY,size_t *out,size_t capacity) {
  if(!nodes||!out||!capacity||!JHHCacheRectValid(keyboard)||!isfinite(firstLetterY)
      ||firstLetterY<=keyboard.y||firstLetterY>=keyboard.y+keyboard.height)return 0;
  size_t used=0;
  for(size_t i=0;i<count;i++) {
    JHHCandidate n=nodes[i];JHHCacheRect f=n.frame;
    double cx=f.x+f.width/2,cy=f.y+f.height/2;
    if(!n.enabled||!n.han||n.functionKey||!JHHCacheRectValid(f)
       ||f.width>keyboard.width*.65||f.height>keyboard.height*.25
       ||cy>=firstLetterY||!JHHRectContains(keyboard,cx,cy))continue;
    size_t duplicate=used;
    for(size_t j=0;j<used;j++)if(JHHCandidateOverlaps(f,nodes[out[j]].frame)){duplicate=j;break;}
    if(duplicate<used) { if(n.explicitCandidate&&!nodes[out[duplicate]].explicitCandidate)out[duplicate]=i;continue; }
    // Overflow must reject, never silently change the ordinal of a key.
    if(used==capacity)return 0;
    out[used++]=i;
  }
  if(!used)return 0;
  double top=nodes[out[0]].frame.y;
  for(size_t i=1;i<used;i++)top=fmin(top,nodes[out[i]].frame.y);
  size_t row=0;
  for(size_t i=0;i<used;i++) {
    JHHCacheRect f=nodes[out[i]].frame;
    if(fabs(f.y-top)<=fmax(4,f.height*.5))out[row++]=out[i];
  }
  for(size_t i=1;i<row;i++) {
    size_t value=out[i],j=i;
    while(j>0&&nodes[out[j-1]].frame.x>nodes[value].frame.x){out[j]=out[j-1];j--;}
    out[j]=value;
  }
  return row;
}
#endif
