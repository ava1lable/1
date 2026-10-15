// SPDX-License-Identifier: BSD-3-Clause
#import "JHHControlCommands.h"
#import "FBRouteRequest.h"
#import "FBResponsePayload.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIApplication+FBQuiescence.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCSynthesizedEventRecord.h"
#import "XCPointerEventPath.h"
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
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
  return FBResponseWithObject(@{@"component":@"JHH-Touch-Agent", @"version":@"1.1.0", @"protocol":@1,
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
  UIInterfaceOrientation orientation = app.interfaceOrientation;
  double detectionMs = (CFAbsoluteTimeGetCurrent() - started) * 1000;
  if (orientation == UIInterfaceOrientationUnknown) return [self rejected:@"orientation_unavailable"];
  BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
  CGSize natural = UIScreen.mainScreen.fixedCoordinateSpace.bounds.size;
  CGSize size = landscape ? CGSizeMake(fmax(natural.width, natural.height), fmin(natural.width, natural.height))
                          : CGSizeMake(fmin(natural.width, natural.height), fmax(natural.width, natural.height));
  if (!isfinite(size.width) || !isfinite(size.height) || size.width < 1 || size.height < 1)
    return [self rejected:@"screen_unavailable"];
  if (landscape != [a[@"landscape"] boolValue])
    return [self rejected:@"orientation_changed"];

  // Use oriented screen points directly. Resolving app.frame and three
  // XCUICoordinates invokes accessibility snapshots on each gesture. The
  // event record carries interface orientation, including upside-down/right.
  CGPoint from = CGPointMake(fmin([a[@"x"] doubleValue], 0.999999) * size.width,
                             fmin([a[@"y"] doubleValue], 0.999999) * size.height);
  CGPoint to = CGPointMake(fmin([a[@"toX"] doubleValue], 0.999999) * size.width,
                           fmin([a[@"toY"] doubleValue], 0.999999) * size.height);
  XCSynthesizedEventRecord *event = [[XCSynthesizedEventRecord alloc] initWithName:@"JHH Touch"
                                                                         interfaceOrientation:orientation];
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:from offset:0];
  if ([kind isEqual:@"tap"]) {
    [path liftUpAtOffset:0.045];
  } else {
    // Manual remote interaction needs a short, bounded swipe. Do not replay
    // the entire desktop hold time as a second long gesture on the phone.
    double duration = fmax(0.08, fmin(0.35, [a[@"duration"] doubleValue]));
    NSUInteger steps = MAX(2, (NSUInteger)ceil(duration * 60));
    for (NSUInteger i = 1; i <= steps; i++) {
      double fraction = (double)i / steps;
      [path moveToPoint:CGPointMake(from.x + (to.x - from.x) * fraction,
                                   from.y + (to.y - from.y) * fraction)
              atOffset:0.015 + duration * fraction];
    }
    [path liftUpAtOffset:0.015 + duration];
  }
  [event addPointerEventPath:path];
  double preflight = (CFAbsoluteTimeGetCurrent() - started) * 1000;
  // Consume before synthesis. An exception/USB timeout must never cause replay.
  JHHLastSequence = sequence;
  NSError *error = nil;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:event error:&error])
    return [self rejected:@"synthesis_failed"];
  return FBResponseWithObject(@{@"accepted":@YES, @"sequence":@(sequence), @"preflightMs":@(preflight),
    @"detectionMs":@(detectionMs), @"eventBuildMs":@(preflight - detectionMs), @"engine":@"screen-event-v1",
    @"synthesisMs":@((CFAbsoluteTimeGetCurrent() - started) * 1000 - preflight)});
}
@end
