// SPDX-License-Identifier: BSD-3-Clause
#ifndef JHH_COMMITTED_TEXT_H
#define JHH_COMMITTED_TEXT_H
#include <stddef.h>
#include <stdint.h>
// Text is a commit, never an implicit editing command. Editing keys use an
// explicit operation so candidate confirmation cannot submit a chat message.
static inline int JHHCommittedTextValid(const uint16_t *s,size_t length) {
  if(!s||!length||length>4096)return 0;
  for(size_t i=0;i<length;i++) {
    uint16_t c=s[i];
    if(c<32||(c>=127&&c<=159)||c==0x2028||c==0x2029||(c>=0xe000&&c<=0xe05d))return 0;
    if(c>=0xd800&&c<=0xdbff) {
      if(++i==length||s[i]<0xdc00||s[i]>0xdfff)return 0;
    } else if(c>=0xdc00&&c<=0xdfff)return 0;
  }
  return 1;
}
#endif
