// SPDX-License-Identifier: BSD-3-Clause
#import "JHHControlCommands.h"
#import "FBRouteRequest.h"
#import "FBResponsePayload.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIElement+FBUtilities.h"
#import "FBXCElementSnapshot.h"
#import "XCUIApplication.h"
#import "XCUIApplication+FBQuiescence.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCSynthesizedEventRecord.h"
#import "XCPointerEventPath.h"
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include "JHHCoordinateTransform.h"
#include "JHHKeyboardMap.h"

@implementation JHHControlCommands
static NSString *JHHInstance;
static unsigned long long JHHLastSequence;
static JHHTransform JHHCoordinates;
static pid_t JHHCoordinatePID;
static UIInterfaceOrientation JHHCoordinateOrientation;
static CFAbsoluteTime JHHCoordinateTime;
static BOOL JHHHasCoordinates;
static JHHTransform JHHKeyboardCoordinates;
static pid_t JHHKeyboardPID;
static UIInterfaceOrientation JHHKeyboardOrientation;
static CGRect JHHKeyboardFrame;
static CFAbsoluteTime JHHKeyboardTime;
static BOOL JHHHasKeyboardCoordinates;

+ (void)initialize
{
  if (self == JHHControlCommands.class) JHHInstance = NSUUID.UUID.UUIDString;
}

+ (NSArray *)routes
{
  return @[
    [[[FBRoute GET:@"/jhh/v1/status"] withoutSession] respondWithTarget:self action:@selector(status:)],
    [[[FBRoute POST:@"/jhh/v1/gesture"] withoutSession] respondWithTarget:self action:@selector(gesture:)],
    [[[FBRoute POST:@"/jhh/v1/key"] withoutSession] respondWithTarget:self action:@selector(key:)],
    [[[FBRoute POST:@"/jhh/v1/keys"] withoutSession] respondWithTarget:self action:@selector(keys:)],
  ];
}

+ (id<FBResponsePayload>)status:(FBRouteRequest *)request
{
  return FBResponseWithObject(@{@"component":@"JHH-Touch-Agent", @"version":@"1.4.0", @"protocol":@1,
    @"instance":JHHInstance, @"ready":@YES, @"coordinateSpace":@"xctest-anchors-v1", @"features":@[@"tap", @"swipe", @"native-keyboard-v1", @"native-keyboard-batch-v1"]});
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
  if (landscape != [a[@"landscape"] boolValue])
    return [self rejected:@"orientation_changed"];

  // Use XCTest's own screenPoint basis, as upstream W3C synthesis does.
  // UIScreen bounds may differ from the application's XCTest coordinate
  // origin/scale. Cache only geometry, never an element or an input target.
  BOOL geometryCached = JHHHasCoordinates && JHHCoordinatePID == app.processID
    && JHHCoordinateOrientation == orientation && started-JHHCoordinateTime < 5;
  if (!geometryCached) {
    JHHHasCoordinates = NO;
    XCUICoordinate *origin = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
    CGPoint p0 = origin.screenPoint;
    CGPoint px = [app coordinateWithNormalizedOffset:CGVectorMake(0.5, 0)].screenPoint;
    CGPoint py = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0.5)].screenPoint;
    if (!JHHTransformCreate((JHHPoint){p0.x,p0.y}, (JHHPoint){px.x,px.y},
                            (JHHPoint){py.x,py.y}, &JHHCoordinates))
      return [self rejected:@"geometry_unavailable"];
    JHHCoordinatePID = app.processID; JHHCoordinateOrientation = orientation;
    JHHCoordinateTime = CFAbsoluteTimeGetCurrent(); JHHHasCoordinates = YES;
  }
  JHHPoint fromPoint, toPoint;
  if (!JHHTransformMap(JHHCoordinates, [a[@"x"] doubleValue], [a[@"y"] doubleValue], &fromPoint)
      || !JHHTransformMap(JHHCoordinates, [a[@"toX"] doubleValue], [a[@"toY"] doubleValue], &toPoint))
    return [self rejected:@"invalid_coordinate"];
  CGPoint from = CGPointMake(fromPoint.x,fromPoint.y), to = CGPointMake(toPoint.x,toPoint.y);
  double geometryMs = (CFAbsoluteTimeGetCurrent()-started)*1000-detectionMs;
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
    @"detectionMs":@(detectionMs), @"geometryMs":@(geometryMs), @"geometryCached":@(geometryCached),
    @"eventBuildMs":@(preflight - detectionMs - geometryMs), @"engine":@"xctest-anchors-v1",
    @"synthesisMs":@((CFAbsoluteTimeGetCurrent() - started) * 1000 - preflight)});
}
+ (XCUIElement *)keyboardKey:(XCUIElement *)keyboard aliases:(NSArray<NSString *> *)aliases
{
  NSPredicate *predicate = [NSPredicate predicateWithFormat:@"label IN %@ OR identifier IN %@", aliases, aliases];
  for (NSNumber *type in @[@(XCUIElementTypeKey), @(XCUIElementTypeButton)]) {
    NSArray<XCUIElement *> *keys = [[keyboard descendantsMatchingType:type.unsignedIntegerValue]
      matchingPredicate:predicate].allElementsBoundByIndex;
    XCUIElement *match = nil;
    for (XCUIElement *candidate in keys) {
      if (!candidate.hittable) continue;
      if (match != nil) return nil; // Never guess between ambiguous keyboard keys.
      match = candidate;
    }
    if (match != nil) return match;
  }
  return nil;
}

+ (id<FBResponsePayload>)key:(FBRouteRequest *)request
{
  return [self keyArguments:request.arguments];
}

+ (NSArray<NSString *> *)keyAliases:(unsigned)usage modifiers:(unsigned)modifiers
{
  int character = JHHKeyboardCharacter(usage, (modifiers & 0x22U) != 0);
  NSArray<NSString *> *aliases;
  if (usage == 40 || usage == 88)
    aliases = @[@"return", @"Return", @"换行", @"完成", @"发送", @"搜索", @"前往", @"下一项", @"下一步", @"go", @"Go", @"Done", @"Send", @"Search", @"Next", @"Join"];
  else if (usage == 42) aliases = @[@"delete", @"Delete", @"删除", @"退格"];
  else if (usage == 44) aliases = @[@"space", @"Space", @"空格", @"空白", @"spacebar"];
  else if (character) {
    NSString *value = [NSString stringWithFormat:@"%c", character];
    // With no desktop Shift, preserve the phone's automatic capitalization.
    aliases = usage >= 4 && usage <= 29 && modifiers == 0 ? @[value, value.uppercaseString] : @[value];
  } else return nil;

  return aliases;
}

+ (id<FBResponsePayload>)keyArguments:(NSDictionary *)a
{
  if (![a[@"instance"] isKindOfClass:NSString.class] || ![a[@"instance"] isEqual:JHHInstance])
    return [self rejected:@"agent_restarted"];
  if (![self number:a[@"sequence"] min:1 max:9007199254740991.0] ||
      floor([a[@"sequence"] doubleValue]) != [a[@"sequence"] doubleValue])
    return [self rejected:@"invalid_sequence"];
  unsigned long long sequence = [a[@"sequence"] unsignedLongLongValue];
  if (sequence <= JHHLastSequence) return [self rejected:@"duplicate_or_stale"];
  if (![self number:a[@"usage"] min:4 max:99] || floor([a[@"usage"] doubleValue]) != [a[@"usage"] doubleValue] ||
      ![self number:a[@"modifiers"] min:0 max:255] || floor([a[@"modifiers"] doubleValue]) != [a[@"modifiers"] doubleValue])
    return [self rejected:@"invalid_key"];
  unsigned usage = [a[@"usage"] unsignedIntValue], modifiers = [a[@"modifiers"] unsignedIntValue];
  // Shift is interpreted as a requested on-screen key, never as a held HID key.
  if (modifiers & ~0x22U) return [self rejected:@"unsupported_modifiers"];
  int character = JHHKeyboardCharacter(usage, (modifiers & 0x22U) != 0);
  NSArray<NSString *> *aliases = [self keyAliases:usage modifiers:modifiers];
  if (aliases == nil) return [self rejected:@"unsupported_key"];

  CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  app.fb_shouldWaitForQuiescence = NO;
  XCUIElement *keyboard = app.keyboards.firstMatch;
  if (!keyboard.exists) return [self rejected:@"keyboard_not_visible"];
  XCUIElement *key = [self keyboardKey:keyboard aliases:aliases];
  // Consume BEFORE any keyboard-layout tap. An uncertain response is never replayed.
  JHHLastSequence = sequence;
  if (key == nil && character && character != ' ') {
    NSArray<NSArray<NSString *> *> *switchGroups = usage >= 4 && usage <= 29
      ? @[@[@"ABC", @"letters", @"字母", @"拼音"], @[@"shift", @"Shift", @"大写"]]
      : @[@[@"123", @"numbers", @"Number", @"数字"], @[@"#+=", @"symbols", @"符号"]];
    for (NSArray<NSString *> *switches in switchGroups) {
      if (key != nil) break;
      // Do not change case for ordinary letters: respect the phone keyboard.
      if (usage >= 4 && usage <= 29 && modifiers == 0 && [switches containsObject:@"shift"]) break;
      XCUIElement *layoutKey = [self keyboardKey:keyboard aliases:switches];
      if (layoutKey == nil) continue;
      [layoutKey tap];
      keyboard = app.keyboards.firstMatch;
      key = [self keyboardKey:keyboard aliases:aliases];
    }
  }
  if (key == nil) return [self rejected:@"key_unavailable"];
  double detectionMs = (CFAbsoluteTimeGetCurrent()-started)*1000;
  // Tap only a key inside the active system keyboard. No input-field search,
  // setValue, typeText, clipboard injection or implicit return/submit.
  [key tap];
  return FBResponseWithObject(@{@"accepted":@YES, @"sequence":@(sequence), @"engine":@"native-keyboard-v1",
    @"detectionMs":@(detectionMs), @"executionMs":@((CFAbsoluteTimeGetCurrent()-started)*1000-detectionMs)});
}

+ (id<FBXCElementSnapshot>)snapshotKey:(id<FBXCElementSnapshot>)keyboard aliases:(NSArray<NSString *> *)aliases
{
  // Traverse this request's single keyboard snapshot. These are in-memory
  // attributes, not one remote exists/hittable/frame query per candidate key.
  for (NSNumber *type in @[@(XCUIElementTypeKey), @(XCUIElementTypeButton)]) {
    __block id<FBXCElementSnapshot> match = nil;
    __block BOOL ambiguous = NO;
    [keyboard enumerateDescendantsUsingBlock:^(id<FBXCElementSnapshot> node) {
      if (node.elementType != type.unsignedIntegerValue || !node.enabled || CGRectIsEmpty(node.frame)) return;
      if (![aliases containsObject:node.label] && ![aliases containsObject:node.identifier]) return;
      CGPoint center = CGPointMake(CGRectGetMidX(node.frame),CGRectGetMidY(node.frame));
      if (!CGRectContainsPoint(keyboard.frame,center)) return;
      if (match != nil) ambiguous = YES;
      match = node;
    }];
    if (ambiguous) return nil;
    if (match != nil) return match;
  }
  return nil;
}

+ (id<FBResponsePayload>)keys:(FBRouteRequest *)request
{
  NSDictionary *a = request.arguments;
  if (![a[@"instance"] isKindOfClass:NSString.class] || ![a[@"instance"] isEqual:JHHInstance])
    return [self rejected:@"agent_restarted"];
  if (![self number:a[@"sequence"] min:1 max:9007199254740991.0] ||
      floor([a[@"sequence"] doubleValue]) != [a[@"sequence"] doubleValue])
    return [self rejected:@"invalid_sequence"];
  unsigned long long sequence = [a[@"sequence"] unsignedLongLongValue];
  if (sequence <= JHHLastSequence) return [self rejected:@"duplicate_or_stale"];
  NSArray *keys = a[@"keys"];
  if (![keys isKindOfClass:NSArray.class] || keys.count < 1 || keys.count > 8)
    return [self rejected:@"invalid_key"];
  for (id item in keys) {
    if (![item isKindOfClass:NSDictionary.class] ||
        ![self number:item[@"usage"] min:4 max:99] || floor([item[@"usage"] doubleValue]) != [item[@"usage"] doubleValue] ||
        ![self number:item[@"modifiers"] min:0 max:255] || floor([item[@"modifiers"] doubleValue]) != [item[@"modifiers"] doubleValue])
      return [self rejected:@"invalid_key"];
    unsigned usage = [item[@"usage"] unsignedIntValue], modifiers = [item[@"modifiers"] unsignedIntValue];
    if (modifiers & ~0x22U) return [self rejected:@"unsupported_modifiers"];
    // Never batch space, deletion, return, symbols or case/layout changes.
    if (keys.count > 1 && (usage < 4 || usage > 29 || modifiers != 0))
      return [self rejected:@"invalid_key"];
    if ([self keyAliases:usage modifiers:modifiers] == nil) return [self rejected:@"unsupported_key"];
  }
  CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  XCUIApplication *app = XCUIApplication.fb_activeApplication;
  app.fb_shouldWaitForQuiescence = NO;
  UIInterfaceOrientation orientation = app.interfaceOrientation;
  if (orientation == UIInterfaceOrientationUnknown) return [self rejected:@"orientation_unavailable"];
  XCUIElement *keyboard = app.keyboards.firstMatch;
  id<FBXCElementSnapshot> snapshot;
  @try { snapshot = keyboard.fb_customSnapshot; }
  @catch (NSException *exception) { return [self rejected:@"keyboard_not_visible"]; }
  CGRect frame = snapshot.frame;
  if (CGRectIsEmpty(frame) || snapshot.children.count == 0) return [self rejected:@"keyboard_not_visible"];
  NSMutableArray *nodes = [NSMutableArray new];
  for (NSDictionary *item in keys) {
    id<FBXCElementSnapshot> node = [self snapshotKey:snapshot
      aliases:[self keyAliases:[item[@"usage"] unsignedIntValue] modifiers:[item[@"modifiers"] unsignedIntValue]]];
    if (node == nil) {
      if (keys.count == 1) {
        // Layout switching is an explicit single-key slow path, before any fast
        // event was submitted. Never retry an uncertain synthesized key batch.
        NSMutableDictionary *single = [a mutableCopy];
        [single addEntriesFromDictionary:keys.firstObject];
        return [self keyArguments:single];
      }
      return [self rejected:@"key_unavailable"];
    }
    [nodes addObject:node];
  }
  double snapshotMs = (CFAbsoluteTimeGetCurrent()-started)*1000;
  BOOL geometryCached = JHHHasKeyboardCoordinates && JHHKeyboardPID == app.processID
    && JHHKeyboardOrientation == orientation && CGRectEqualToRect(JHHKeyboardFrame,frame)
    && started-JHHKeyboardTime < 5;
  if (!geometryCached) {
    JHHHasKeyboardCoordinates = NO;
    CGPoint p0 = [keyboard coordinateWithNormalizedOffset:CGVectorMake(0,0)].screenPoint;
    CGPoint px = [keyboard coordinateWithNormalizedOffset:CGVectorMake(0.5,0)].screenPoint;
    CGPoint py = [keyboard coordinateWithNormalizedOffset:CGVectorMake(0,0.5)].screenPoint;
    if (!JHHTransformCreate((JHHPoint){p0.x,p0.y},(JHHPoint){px.x,px.y},(JHHPoint){py.x,py.y},&JHHKeyboardCoordinates))
      return [self rejected:@"geometry_unavailable"];
    JHHKeyboardFrame=frame; JHHKeyboardPID=app.processID; JHHKeyboardOrientation=orientation;
    JHHKeyboardTime=started; JHHHasKeyboardCoordinates=YES;
  }
  XCSynthesizedEventRecord *event = [[XCSynthesizedEventRecord alloc] initWithName:@"JHH Keyboard"
    interfaceOrientation:orientation];
  NSUInteger index=0;
  for (id<FBXCElementSnapshot> node in nodes) {
    double x=(CGRectGetMidX(node.frame)-frame.origin.x)/frame.size.width;
    double y=(CGRectGetMidY(node.frame)-frame.origin.y)/frame.size.height;
    JHHPoint point;
    if (!JHHTransformMap(JHHKeyboardCoordinates,x,y,&point)) return [self rejected:@"geometry_unavailable"];
    // Sequential complete taps, matching upstream W3C's separate pointer paths.
    double offset=index++*0.06;
    XCPointerEventPath *path=[[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(point.x,point.y) offset:offset];
    [path liftUpAtOffset:offset+0.035];
    [event addPointerEventPath:path];
  }
  double preflightMs=(CFAbsoluteTimeGetCurrent()-started)*1000;
  JHHLastSequence = sequence;
  NSError *error=nil;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:event error:&error]) return [self rejected:@"synthesis_failed"];
  return FBResponseWithObject(@{@"accepted":@YES,@"sequence":@(sequence),@"keyCount":@(keys.count),
    @"engine":@"native-keyboard-batch-v1",@"snapshotMs":@(snapshotMs),@"geometryCached":@(geometryCached),
    @"geometryMs":@(preflightMs-snapshotMs),@"synthesisMs":@((CFAbsoluteTimeGetCurrent()-started)*1000-preflightMs)});
}

@end
