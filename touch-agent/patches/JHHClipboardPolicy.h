// SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include <stdbool.h>
#include <math.h>
static inline bool JHHClipboardFresh(double now,double when,double lifetime) {
 return isfinite(now)&&isfinite(when)&&now>=when&&now-when<=lifetime;
}
static inline bool JHHClipboardContext(bool sameApp,bool sameOrientation,bool keyboard,bool sameKeyboardFrame,bool sameClipboard,bool fresh) {
 return sameApp&&sameOrientation&&keyboard&&sameKeyboardFrame&&sameClipboard&&fresh;
}

typedef struct { double sx[3],sy[3],ex[3],ey[3]; } JHHClipboardPinch;
static inline bool JHHClipboardPastePinch(double width,double height,double usableHeight,JHHClipboardPinch *out) {
 if(!out||!isfinite(width)||!isfinite(height)||!isfinite(usableHeight)||width<180||height<180||usableHeight<160||usableHeight>height)return false;
 double r0=fmin(width,usableHeight)*.06,r1=fmin(width,usableHeight)*.22;
 const double dx[3]={0,.8660254037844386,-.8660254037844386},dy[3]={-1,.5,.5};
 for(int i=0;i<3;i++){
  out->sx[i]=(.5*width+dx[i]*r0)/width;out->sy[i]=(.5*usableHeight+dy[i]*r0)/height;
  out->ex[i]=(.5*width+dx[i]*r1)/width;out->ey[i]=(.5*usableHeight+dy[i]*r1)/height;
 }
 return true;
}
