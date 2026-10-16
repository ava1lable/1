// SPDX-License-Identifier: BSD-3-Clause
#ifndef JHH_GEOMETRY_BANK_H
#define JHH_GEOMETRY_BANK_H
#include "JHHGeometryCache.h"
#include "JHHCoordinateTransform.h"
typedef struct { JHHGeometryCache cache;JHHTransform transform;double lastUsed; } JHHGeometryEntry;
typedef struct { JHHGeometryEntry entries[4];int active; } JHHGeometryBank;
static inline JHHGeometryEntry *JHHGeometryBankSelect(JHHGeometryBank *bank,JHHGeometryKey key,double now,int *changed) {
 if(!bank||!JHHGeometryKeyValid(key)||!isfinite(now)||now<0)return 0;
 int slot=-1;
 for(int i=0;i<4;i++)if(bank->entries[i].cache.valid&&JHHGeometryKeyEqual(bank->entries[i].cache.key,key)){slot=i;break;}
 if(slot<0) {
  slot=0;
  for(int i=0;i<4;i++) {
   if(!bank->entries[i].cache.valid){slot=i;break;}
   if(bank->entries[i].lastUsed<bank->entries[slot].lastUsed)slot=i;
  }
  bank->entries[slot].cache.valid=0;
 }
 if(changed)*changed=slot!=bank->active;
 bank->active=slot;bank->entries[slot].lastUsed=now;return &bank->entries[slot];
}
#endif
