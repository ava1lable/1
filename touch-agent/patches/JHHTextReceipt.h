// SPDX-License-Identifier: BSD-3-Clause
#ifndef JHH_TEXT_RECEIPT_H
#define JHH_TEXT_RECEIPT_H
#include <stdbool.h>
typedef enum { JHHTextDispatched=0, JHHTextEventFailed, JHHTextAppChanged, JHHTextContextLost } JHHTextOutcome;
static inline bool JHHTextCanDispatch(bool keyboard,bool focus) { return keyboard || focus; }
static inline JHHTextOutcome JHHTextClassify(bool succeeded,bool error,bool sameApp,bool keyboardAfter,bool focusAfter,bool editing) {
 if (!succeeded || error) return JHHTextEventFailed;
 if (!sameApp) return JHHTextAppChanged;
 if (!editing && !keyboardAfter && !focusAfter) return JHHTextContextLost;
 return JHHTextDispatched;
}
#endif
