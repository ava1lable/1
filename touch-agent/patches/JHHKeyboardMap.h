// SPDX-License-Identifier: BSD-3-Clause
// USB keyboard-page usages -> keys on an iPhone's own full keyboard.
#ifndef JHH_KEYBOARD_MAP_H
#define JHH_KEYBOARD_MAP_H
static inline int JHHKeyboardCharacter(unsigned usage, int shifted) {
  if (usage >= 4 && usage <= 29) return (shifted ? 'A' : 'a') + usage - 4;
  if (usage >= 30 && usage <= 39) return (shifted ? "!@#$%^&*()" : "1234567890")[usage-30];
  switch (usage) {
    case 44: return ' ';
    case 45: return shifted ? '_' : '-'; case 46: return shifted ? '+' : '=';
    case 47: return shifted ? '{' : '['; case 48: return shifted ? '}' : ']';
    case 49: return shifted ? '|' : '\\'; case 51: return shifted ? ':' : ';';
    case 52: return shifted ? '"' : '\''; case 53: return shifted ? '~' : '`';
    case 54: return shifted ? '<' : ','; case 55: return shifted ? '>' : '.';
    case 56: return shifted ? '?' : '/';
    case 84: return '/'; case 85: return '*'; case 86: return '-'; case 87: return '+';
    case 89: case 90: case 91: case 92: case 93: case 94: case 95: case 96: case 97: return '1'+usage-89;
    case 98: return '0'; case 99: return '.';
    default: return 0;
  }
}
#endif
