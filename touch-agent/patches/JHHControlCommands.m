// SPDX-License-Identifier: BSD-3-Clause
#import "JHHControlCommands.h"
#import "FBRouteRequest.h"
#import "FBResponsePayload.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIApplication+FBQuiescence.h"
#import <XCTest/XCTest.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

@implementation JHHControlCommands
static NSString *JHHInstance;
static unsigned long long JHHLastSequence;

+ (void)initialize
{
  if (self == JHHControlCommands.class) JHHInstance = NSUUID.UUID.UUIDString;
}

+ (NSArray *)routes
{
  return @[
    [[[FBRoute GET:@"/jhh/v1/status"] withoutSession] respondWithTarget:self action:@selector(status:)],
    [[[FBRoute POST:@"/jhh/v1/gesture"] withoutSession] respondWithTarget:self action:@selector(gesture:)],
  ];
}

+ (id<FBResponsePayload>)status:(FBRouteRequest *)request
{
  return FBResponseWithObject(@{@"component":@"JHH-Touch-Agent", @"version":@"1.0.0", @"protocol":@1,
    @"instance":JHHInstance, @"ready":@YES, @"features":@[@"tap", @"swipe"]});
}

+ (id<FBResponsePayload>)rejected:(NSString *)code
{
  return FBResponseWithObject(@{@"accepted":@NO, @"code":code});
}

+ (BOOL)number:(id)value min:(double)minimum max:(double)maximum
{
  return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()
    && isfinite([value doubleValue]) && [value doubleValue] >= minimum && [value doubleValue] <= maximum;
}

+ (id<FBResponsePayload>)gesture:(FBRouteRequest *)request
{
  // RoutingHTTPServer dispatches every route on the main queue, so sequence
  // validation and consumption are atomic with respect to other requests.
  NSDictionary *a = request.arguments;
  if (![a[@"instance"] isKindOfClass:NSString.class] || ![a[@"instance"] isEqual:JHHInstance])
    return [self rejected:@"agent_restarted"];
  if (![self number:a[@"sequence"] min:1 max:9007199254740991.0] ||
      floor([a[@"sequence"] doubleValue]) != [a[@"sequence"] doubleValue])
    return [self rejected:@"invalid_sequence"];
  unsigned long long sequence = [a[@"sequence"] unsignedLongLongValue];
  if (sequence <= JHHLastSequence) return [self rejected:@"duplicate_or_stale"];
  NSString *kind = a[@"kind"];
  if (![kind isKindOfClass:NSString.class] || ![@[@"tap", @"swipe"] containsObject:kind])
    return [self rejected:@"unsupported_gesture"];
  for (NSString *key in @[@"x", @"y", @"toX", @"toY"])
    if (![self number:a[key] min:0 max:1]) return [self rejected:@"invalid_coordinate"];
  if (![a[@"landscape"] isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)a[@"landscape"]) != CFBooleanGetTypeID())
    return [self rejected:@"invalid_orientation"];
  if (![self number:a[@"duration"] min:0.08 max:2]) return [self rejected:@"invalid_duration"];

  CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  app.fb_shouldWaitForQuiescence = NO;
  CGRect frame = app.frame;
  if (!isfinite(frame.size.width) || !isfinite(frame.size.height) || frame.size.width < 1 || frame.size.height < 1)
    return [self rejected:@"screen_unavailable"];
  if ((frame.size.width > frame.size.height) != [a[@"landscape"] boolValue])
    return [self rejected:@"orientation_changed"];

  // Anchor to the active application's full frame. Do not search the element
  // tree or find an input field. Coordinates arrive normalized to the actual
  // displayed video rectangle, excluding desktop letterbox margins.
  XCUICoordinate *origin = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
  double x = fmin([a[@"x"] doubleValue], 0.999999) * frame.size.width;
  double y = fmin([a[@"y"] doubleValue], 0.999999) * frame.size.height;
  double tx = fmin([a[@"toX"] doubleValue], 0.999999) * frame.size.width;
  double ty = fmin([a[@"toY"] doubleValue], 0.999999) * frame.size.height;
  XCUICoordinate *from = [origin coordinateWithOffset:CGVectorMake(x, y)];
  XCUICoordinate *to = [origin coordinateWithOffset:CGVectorMake(tx, ty)];
  double preflight = (CFAbsoluteTimeGetCurrent() - started) * 1000;
  // Consume before synthesis. An exception/USB timeout must never cause replay.
  JHHLastSequence = sequence;
  if ([kind isEqual:@"tap"]) {
    [from tap];
  } else {
    CGFloat velocity = fmax(50, fmin(5000, hypot(tx - x, ty - y) / [a[@"duration"] doubleValue]));
    [from pressForDuration:0.03 thenDragToCoordinate:to withVelocity:velocity thenHoldForDuration:0];
  }
  return FBResponseWithObject(@{@"accepted":@YES, @"sequence":@(sequence), @"preflightMs":@(preflight),
    @"synthesisMs":@((CFAbsoluteTimeGetCurrent() - started) * 1000 - preflight)});
}
@end
