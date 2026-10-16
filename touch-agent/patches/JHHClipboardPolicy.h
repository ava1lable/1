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
typedef enum { JHHForegroundPending=0,JHHForegroundReady=1,JHHForegroundInterrupted=2,JHHForegroundExpired=3 } JHHForegroundResult;
typedef struct { double started; unsigned stable; } JHHForegroundWait;
// AX can acknowledge an activation after activate has returned. Require two
// consecutive observations; only observe during transitions, never activate again.
static inline JHHForegroundResult JHHClipboardForegroundStep(JHHForegroundWait *wait,double now,bool expected,bool allowedTransition) {
 if(!wait||!JHHClipboardFresh(now,wait->started,3.0))return JHHForegroundExpired;
 if(!expected&&!allowedTransition)return JHHForegroundInterrupted;
 wait->stable=expected?wait->stable+1:0;
 return wait->stable>=2?JHHForegroundReady:JHHForegroundPending;
}

typedef struct { double x[3],y[3]; } JHHClipboardMenuTap;
// Three stationary touches at the user's last editor click. Never pinch in the
// chat list, long-press, relocate the caret, or touch inside the keyboard.
static inline bool JHHClipboardMenuTapPoints(double left,double top,double width,double height,double keyboardTop,double x,double y,JHHClipboardMenuTap *out) {
 if(!out||!isfinite(left)||!isfinite(top)||!isfinite(width)||!isfinite(height)||!isfinite(keyboardTop)||!isfinite(x)||!isfinite(y)||
    width<120||height<120||keyboardTop<top+40||keyboardTop>top+height||x<left+24||x>left+width-24||y<top+8||y>keyboardTop-6)return false;
 for(int i=0;i<3;i++){out->x[i]=x+(i-1)*22;out->y[i]=y;}
 return true;
}
