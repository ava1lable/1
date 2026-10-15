// SPDX-License-Identifier: BSD-3-Clause
#ifndef JHH_COORDINATE_TRANSFORM_H
#define JHH_COORDINATE_TRANSFORM_H
#include <math.h>
typedef struct { double x, y; } JHHPoint;
typedef struct { JHHPoint origin, horizontal, vertical; } JHHTransform;
static inline int JHHTransformCreate(JHHPoint origin, JHHPoint halfX, JHHPoint halfY, JHHTransform *out) {
  if (!out || !isfinite(origin.x) || !isfinite(origin.y) || !isfinite(halfX.x) || !isfinite(halfX.y)
      || !isfinite(halfY.x) || !isfinite(halfY.y)) return 0;
  JHHTransform t = {origin, {2 * (halfX.x-origin.x), 2 * (halfX.y-origin.y)},
                           {2 * (halfY.x-origin.x), 2 * (halfY.y-origin.y)}};
  double determinant = t.horizontal.x*t.vertical.y-t.horizontal.y*t.vertical.x;
  if (!isfinite(determinant) || fabs(determinant)<0.000001) return 0;
  *out=t; return 1;
}
static inline int JHHTransformMap(JHHTransform t, double x, double y, JHHPoint *out) {
  if (!out || !isfinite(x) || !isfinite(y) || x<0 || x>1 || y<0 || y>1) return 0;
  x=fmin(x,0.999999); y=fmin(y,0.999999);
  JHHPoint p={t.origin.x+t.horizontal.x*x+t.vertical.x*y,
              t.origin.y+t.horizontal.y*x+t.vertical.y*y};
  if (!isfinite(p.x) || !isfinite(p.y)) return 0;
  *out=p; return 1;
}
#endif
