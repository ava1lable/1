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
