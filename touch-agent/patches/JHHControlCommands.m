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
#include "JHHGeometryCache.h"
#include "JHHKeyboardCandidates.h"
#include "JHHCommittedText.h"
#include "JHHTextReceipt.h"
#include "JHHClipboardPolicy.h"
#import "XCUIDevice.h"
#import "XCTRunnerDaemonSession.h"
#import "FBRunLoopSpinner.h"
#import <CommonCrypto/CommonDigest.h>

@implementation JHHControlCommands
static NSString *JHHInstance;
static unsigned long long JHHLastSequence;
static JHHTransform JHHCoordinates;
static JHHGeometryCache JHHCoordinateCache;
static JHHTransform JHHKeyboardCoordinates;
static JHHGeometryCache JHHKeyboardCache;
static pid_t JHHComposingPID;
static BOOL JHHMayBeComposing;
static CGPoint JHHLastTapPoint;
static pid_t JHHLastTapPID;
static UIInterfaceOrientation JHHLastTapOrientation;
static double JHHLastTapTime;

static JHHCacheRect JHHCacheFrame(CGRect frame)
{
  return (JHHCacheRect){frame.origin.x,frame.origin.y,frame.size.width,frame.size.height};
}
static JHHGeometryKey JHHCurrentGeometryKey(XCUIApplication *app,UIInterfaceOrientation orientation)
{
  UIScreen *screen=UIScreen.mainScreen;
  return (JHHGeometryKey){app.processID,(int32_t)orientation,JHHCacheFrame(screen.bounds),
    JHHCacheFrame(screen.nativeBounds),screen.scale};
}

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
    [[[FBRoute POST:@"/jhh/v1/text"] withoutSession] respondWithTarget:self action:@selector(committedText:)],
    [[[FBRoute POST:@"/jhh/v1/clipboard/prepare"] withoutSession] respondWithTarget:self action:@selector(prepareClipboard:)],
    [[[FBRoute POST:@"/jhh/v1/clipboard/paste"] withoutSession] respondWithTarget:self action:@selector(pasteClipboard:)],
  ];
}

+ (id<FBResponsePayload>)status:(FBRouteRequest *)request
{
  return FBResponseWithObject(@{@"component":@"JHH-Touch-Agent", @"version":@"1.10.2", @"protocol":@1,
    @"instance":JHHInstance, @"ready":@YES, @"coordinateSpace":@"xctest-anchors-v1", @"features":@[@"tap", @"swipe", @"native-keyboard-v1", @"native-keyboard-batch-v1", @"geometry-cache-v1", @"native-candidate-numbers-v1", @"keyboard-standard-snapshot-v1", @"committed-text-v1", @"text-receipt-v1", @"clipboard-paste-v1", @"clipboard-foreground-settle-v1", @"clipboard-standard-writer-v1", @"clipboard-system-menu-v1", @"photo-upload-v1"]});
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
  double cacheNow=NSProcessInfo.processInfo.systemUptime;
  JHHGeometryKey geometryKey=JHHCurrentGeometryKey(app,orientation);
  JHHCachePlan cachePlan=JHHGeometryCacheInspect(&JHHCoordinateCache,geometryKey,cacheNow);
  NSString *cacheReason=[NSString stringWithUTF8String:JHHGeometryCacheReason(cachePlan)];
  BOOL geometryCached=cachePlan==JHHCacheHit;
  double validationMs=0,anchorMs=0;
  if(cachePlan==JHHCacheCheckFrame) {
    CFAbsoluteTime validationStarted=CFAbsoluteTimeGetCurrent();
    CGRect frame=app.frame;
    geometryCached=JHHGeometryCacheValidate(&JHHCoordinateCache,geometryKey,JHHCacheFrame(frame),
      NSProcessInfo.processInfo.systemUptime);
    validationMs=(CFAbsoluteTimeGetCurrent()-validationStarted)*1000;
    if(!geometryCached)cacheReason=@"frame_changed";
  }
  if(!geometryCached) {
    JHHCoordinateCache.valid=0;
    CFAbsoluteTime anchorStarted=CFAbsoluteTimeGetCurrent();
    XCUICoordinate *origin = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
    CGPoint p0 = origin.screenPoint;
    CGPoint px = [app coordinateWithNormalizedOffset:CGVectorMake(0.5, 0)].screenPoint;
    CGPoint py = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0.5)].screenPoint;
    if (!JHHTransformCreate((JHHPoint){p0.x,p0.y}, (JHHPoint){px.x,px.y},
                            (JHHPoint){py.x,py.y}, &JHHCoordinates))
      return [self rejected:@"geometry_unavailable"];
    // The just-resolved anchor snapshot supplies the validation baseline;
    // reading its frame does not issue another remote XCTest request.
    id<FBXCElementSnapshot> root=app.fb_cachedSnapshot;
    CGRect frame=root ? root.frame : app.frame;
    if(!JHHGeometryCacheLearn(&JHHCoordinateCache,geometryKey,JHHCacheFrame(frame),
        NSProcessInfo.processInfo.systemUptime))return [self rejected:@"geometry_unavailable"];
    anchorMs=(CFAbsoluteTimeGetCurrent()-anchorStarted)*1000;
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
  JHHMayBeComposing=NO; // A screen gesture changes the editing/candidate context.
  NSError *error = nil;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:event error:&error])
    return [self rejected:@"synthesis_failed"];
  if ([kind isEqualToString:@"tap"]) { JHHLastTapPoint=CGPointMake(from.x,from.y); JHHLastTapPID=app.processID; JHHLastTapOrientation=orientation; JHHLastTapTime=NSProcessInfo.processInfo.systemUptime; }
  return FBResponseWithObject(@{@"accepted":@YES, @"sequence":@(sequence), @"preflightMs":@(preflight),
    @"detectionMs":@(detectionMs), @"geometryMs":@(geometryMs), @"geometryCached":@(geometryCached),
    @"geometryValidationMs":@(validationMs), @"anchorResolutionMs":@(anchorMs), @"geometryCacheReason":cacheReason,
    @"eventBuildMs":@(preflight - detectionMs - geometryMs), @"engine":@"xctest-anchors-v1",
    @"synthesisMs":@((CFAbsoluteTimeGetCurrent() - started) * 1000 - preflight)});
}
// Read only focus flags and geometry; never read/log labels, values or text.
static BOOL JHHTextKeyboardVisible(XCUIApplication *app) {
 @try { id<FBXCElementSnapshot> k=app.keyboards.firstMatch.fb_standardSnapshot;
  return !CGRectIsEmpty(k.frame)&&k.children.count>0; }
 @catch(NSException *exception) { return NO; }
}
static BOOL JHHTextFocusObserved(XCUIApplication *app) {
 @try {
  id<FBXCElementSnapshot> root=app.fb_standardSnapshot;
  NSMutableArray *pending=[NSMutableArray arrayWithObject:root];NSUInteger seen=0;
  while(pending.count&&seen++<4096) {
   id<FBXCElementSnapshot> node=pending.lastObject;[pending removeLastObject];
   if(node.hasKeyboardFocus)return YES;
   for(id child in node.children)if(pending.count<4096)[pending addObject:child];
  }
 } @catch(NSException *exception) { }
 return NO; // Not observed is not proof of no focus in a custom accessibility tree.
}
static NSString *JHHTextAppToken(XCUIApplication *app) {
 NSString *bundle=app.bundleID ?: @"unknown";NSData *data=[bundle dataUsingEncoding:NSUTF8StringEncoding];
 unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
 return [NSString stringWithFormat:@"app#%02x%02x%02x%02x%02x",digest[0],digest[1],digest[2],digest[3],digest[4]];
}
static BOOL JHHSynthesizeCommittedText(XCSynthesizedEventRecord *event,BOOL *hadError) {
 __block BOOL succeeded=NO;__block BOOL failed=NO;
 [FBRunLoopSpinner spinUntilCompletion:^(void(^completion)(void)) {
  [[XCUIDevice.sharedDevice eventSynthesizer] synthesizeEvent:event completion:(id)^(BOOL result,NSError *error) {
   succeeded=result;failed=error!=nil;completion();
  }];
 }];
 if(hadError)*hadError=failed;
 return succeeded;
}
// Same redacted event mechanism, now with explicit execution and context receipts.
+ (id<FBResponsePayload>)committedText:(FBRouteRequest *)request
{
  NSDictionary *a=request.arguments;
  if(![a[@"instance"] isKindOfClass:NSString.class]||![a[@"instance"] isEqual:JHHInstance])return [self rejected:@"agent_restarted"];
  if(![self number:a[@"sequence"] min:1 max:9007199254740991.0]||floor([a[@"sequence"] doubleValue])!=[a[@"sequence"] doubleValue])return [self rejected:@"invalid_sequence"];
  unsigned long long sequence=[a[@"sequence"] unsignedLongLongValue];
  if(sequence<=JHHLastSequence)return [self rejected:@"duplicate_or_stale"];
  BOOL isText=a[@"text"]!=nil,isEditing=a[@"editingKey"]!=nil;
  if(isText==isEditing)return [self rejected:@"invalid_text"];
  NSString *text=nil,*editing=nil;
  if(isText) {
    text=a[@"text"];
    if(![text isKindOfClass:NSString.class]||text.length>4096)return [self rejected:@"invalid_text"];
    uint16_t units[4096];[text getCharacters:units range:NSMakeRange(0,text.length)];
    if(!JHHCommittedTextValid(units,text.length))return [self rejected:@"invalid_text"];
  } else {
    if(![self number:a[@"editingKey"] min:0 max:255]||floor([a[@"editingKey"] doubleValue])!=[a[@"editingKey"] doubleValue])return [self rejected:@"unsupported_editing_key"];
    switch([a[@"editingKey"] unsignedIntValue]) {
      case 8:editing=XCUIKeyboardKeyDelete;break;
      case 9:editing=XCUIKeyboardKeyTab;break;
      case 13:editing=XCUIKeyboardKeyReturn;break;
      case 37:editing=XCUIKeyboardKeyLeftArrow;break;
      case 38:editing=XCUIKeyboardKeyUpArrow;break;
      case 39:editing=XCUIKeyboardKeyRightArrow;break;
      case 40:editing=XCUIKeyboardKeyDownArrow;break;
      case 46:editing=XCUIKeyboardKeyForwardDelete;break;
      default:return [self rejected:@"unsupported_editing_key"];
    }
  }
  CFAbsoluteTime started=CFAbsoluteTimeGetCurrent();
  XCUIApplication *app=XCUIApplication.fb_activeApplication;app.fb_shouldWaitForQuiescence=NO;
  UIInterfaceOrientation orientation=app.interfaceOrientation;
  if(orientation==UIInterfaceOrientationUnknown)return [self rejected:@"orientation_unavailable"];
  pid_t beforePID=app.processID;
  BOOL keyboardBefore=JHHTextKeyboardVisible(app),focusBefore=JHHTextFocusObserved(app);
  NSString *appToken=JHHTextAppToken(app);
  if(!JHHTextCanDispatch(keyboardBefore,focusBefore))
    return FBResponseWithObject(@{@"accepted":@NO,@"code":@"keyboard_not_visible",@"sequence":@(sequence),
      @"keyboardBefore":@(keyboardBefore),@"focusBefore":@(focusBefore),@"appToken":appToken,@"executionAttempted":@NO});
  double preflight=(CFAbsoluteTimeGetCurrent()-started)*1000;
  XCPointerEventPath *path=[[XCPointerEventPath alloc] initForTextInput];
  if(![path respondsToSelector:@selector(typeText:atOffset:typingSpeed:shouldRedact:)]||
     ![path respondsToSelector:@selector(typeKey:modifiers:atOffset:)])return [self rejected:@"text_input_unavailable"];
  if(isText)[path typeText:text atOffset:0 typingSpeed:60 shouldRedact:YES];
  else [path typeKey:editing modifiers:0 atOffset:0];
  XCSynthesizedEventRecord *event=[[XCSynthesizedEventRecord alloc] initWithName:@"JHH Committed Input" interfaceOrientation:orientation];
  [event addPointerEventPath:path];
  JHHLastSequence=sequence;JHHMayBeComposing=NO;
  BOOL hadError=NO;
  BOOL eventSucceeded=JHHSynthesizeCommittedText(event,&hadError);
  double synthesis=(CFAbsoluteTimeGetCurrent()-started)*1000-preflight;
  XCUIApplication *afterApp=XCUIApplication.fb_activeApplication;afterApp.fb_shouldWaitForQuiescence=NO;
  BOOL sameApp=beforePID>0&&afterApp.processID==beforePID;
  BOOL keyboardAfter=JHHTextKeyboardVisible(afterApp),focusAfter=JHHTextFocusObserved(afterApp);
  JHHTextOutcome outcome=JHHTextClassify(eventSucceeded,hadError,sameApp,keyboardAfter,focusAfter,isEditing);
  NSString *code=outcome==JHHTextEventFailed?@"text_event_failed":outcome==JHHTextAppChanged?@"text_app_changed":
    outcome==JHHTextContextLost?@"text_context_lost":@"event_dispatched_unverified";
  return FBResponseWithObject(@{@"accepted":JHHTextAcceptedValue(outcome),@"code":code,@"sequence":@(sequence),@"engine":@"committed-text-v1",
    @"receiptVersion":@1,@"executionAttempted":@YES,@"eventSucceeded":@(eventSucceeded),@"hadError":@(hadError),
    @"sameApp":@(sameApp),@"appToken":appToken,@"keyboardBefore":@(keyboardBefore),@"focusBefore":@(focusBefore),
    @"keyboardAfter":@(keyboardAfter),@"focusAfter":@(focusAfter),@"insertionVerified":@NO,
    @"preflightMs":@(preflight),@"synthesisMs":@(synthesis),@"postflightMs":@((CFAbsoluteTimeGetCurrent()-started)*1000-preflight-synthesis),
    @"characters":@(isText?text.length:0),@"editing":@(isEditing)});
}

#include "JHHClipboard.m"

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
  NSMutableDictionary *a=[request.arguments mutableCopy];
  a[@"keys"]=@[@{@"usage":a[@"usage"]?:NSNull.null,@"modifiers":a[@"modifiers"]?:NSNull.null}];
  return [self keysArguments:a];
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
  JHHComposingPID=app.processID;
  if(usage>=4&&usage<=29)JHHMayBeComposing=YES;else if(usage!=42)JHHMayBeComposing=NO;
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

+ (NSArray<id<FBXCElementSnapshot>> *)visibleChineseCandidates:(id<FBXCElementSnapshot>)snapshot
{
  NSMutableArray<id<FBXCElementSnapshot>> *all=[NSMutableArray new];
  __block double firstLetterY=INFINITY;
  NSSet *functions=[NSSet setWithArray:@[@"完成",@"发送",@"搜索",@"前往",@"下一项",@"下一步",@"空格",@"换行",@"删除",@"退格",@"粘贴",@"拷贝",@"复制",@"撤销",@"重做",@"自动填充",@"扫描文本",@"表情",@"符号",@"拼音",@"手写",@"候选词",@"候選字",@"候选字",@"展开候选",@"收起候选"]];
  [snapshot enumerateDescendantsUsingBlock:^(id<FBXCElementSnapshot> node) {
    NSString *label=node.label?:@"";
    if(node.elementType==XCUIElementTypeKey && label.length==1) {
      unichar c=[label characterAtIndex:0];
      if((c>='a'&&c<='z')||(c>='A'&&c<='Z'))firstLetterY=fmin(firstLetterY,CGRectGetMinY(node.frame));
    }
    if(node.elementType==XCUIElementTypeKey||node.elementType==XCUIElementTypeButton
        ||node.elementType==XCUIElementTypeCell||node.elementType==XCUIElementTypeStaticText) {
      if(all.count<256)[all addObject:node];
    }
  }];
  JHHCandidate candidates[256];
  for(NSUInteger i=0;i<all.count;i++) {
    id<FBXCElementSnapshot> node=all[i];NSString *label=node.label?:@"";
    BOOL han=NO;
    for(NSUInteger j=0;j<label.length;j++) {
      unsigned cp=[label characterAtIndex:j];
      if(cp>=0xd800&&cp<=0xdbff&&j+1<label.length) {
        unsigned low=[label characterAtIndex:j+1];
        if(low>=0xdc00&&low<=0xdfff){cp=0x10000+((cp-0xd800)<<10)+(low-0xdc00);j++;}
      }
      if(JHHIsHan(cp)){han=YES;break;}
    }
    NSString *identifier=node.identifier.lowercaseString?:@"";
    BOOL explicit=[identifier containsString:@"candidate"]||[identifier containsString:@"候选"]||[identifier containsString:@"候選"];
    candidates[i]=(JHHCandidate){JHHCacheFrame(node.frame),node.enabled,han,[functions containsObject:label],explicit};
  }
  size_t indexes[64];size_t count=JHHVisibleCandidates(candidates,all.count,JHHCacheFrame(snapshot.frame),firstLetterY,indexes,64);
  NSMutableArray *result=[NSMutableArray new];
  for(size_t i=0;i<count;i++)[result addObject:all[indexes[i]]];
  return result;
}

+ (id<FBResponsePayload>)keys:(FBRouteRequest *)request
{
  return [self keysArguments:request.arguments];
}

+ (id<FBResponsePayload>)keysArguments:(NSDictionary *)a
{
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
  @try { snapshot = keyboard.fb_standardSnapshot; }
  @catch (NSException *exception) { return [self rejected:@"keyboard_not_visible"]; }
  CGRect frame = snapshot.frame;
  if (CGRectIsEmpty(frame) || snapshot.children.count == 0) return [self rejected:@"keyboard_not_visible"];
  if(JHHComposingPID!=app.processID){JHHComposingPID=app.processID;JHHMayBeComposing=NO;}
  NSMutableArray *nodes = [NSMutableArray new];
  BOOL selectingCandidate=NO;
  unsigned candidateIndex=0;
  NSDictionary *single=keys.count==1 ? keys.firstObject : nil;
  if(single && JHHMayBeComposing) {
    candidateIndex=JHHKeyboardCandidateNumber([single[@"usage"] unsignedIntValue],[single[@"modifiers"] unsignedIntValue]);
    if(candidateIndex) {
      NSArray *candidates=[self visibleChineseCandidates:snapshot];
      if(candidates.count) {
        if(candidateIndex>candidates.count)return [self rejected:@"candidate_unavailable"];
        [nodes addObject:candidates[candidateIndex-1]];selectingCandidate=YES;
      }
    }
  }
  for (NSDictionary *item in selectingCandidate ? @[] : keys) {
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
  JHHGeometryKey geometryKey=JHHCurrentGeometryKey(app,orientation);
  double cacheNow=NSProcessInfo.processInfo.systemUptime;
  JHHCachePlan cachePlan=JHHGeometryCacheInspect(&JHHKeyboardCache,geometryKey,cacheNow);
  // This batch already has a fresh keyboard snapshot. Validate its frame every
  // time; never cache key targets or the candidate/layout snapshot.
  BOOL geometryCached=(cachePlan==JHHCacheHit||cachePlan==JHHCacheCheckFrame)
    && JHHGeometryCacheValidate(&JHHKeyboardCache,geometryKey,JHHCacheFrame(frame),cacheNow);
  NSString *cacheReason=[NSString stringWithUTF8String:JHHGeometryCacheReason(cachePlan)];
  if(!geometryCached && (cachePlan==JHHCacheHit||cachePlan==JHHCacheCheckFrame))cacheReason=@"frame_changed";
  double anchorMs=0;
  if(!geometryCached) {
    JHHKeyboardCache.valid=0;
    CFAbsoluteTime anchorStarted=CFAbsoluteTimeGetCurrent();
    CGPoint p0 = [keyboard coordinateWithNormalizedOffset:CGVectorMake(0,0)].screenPoint;
    CGPoint px = [keyboard coordinateWithNormalizedOffset:CGVectorMake(0.5,0)].screenPoint;
    CGPoint py = [keyboard coordinateWithNormalizedOffset:CGVectorMake(0,0.5)].screenPoint;
    if (!JHHTransformCreate((JHHPoint){p0.x,p0.y},(JHHPoint){px.x,px.y},(JHHPoint){py.x,py.y},&JHHKeyboardCoordinates))
      return [self rejected:@"geometry_unavailable"];
    if(!JHHGeometryCacheLearn(&JHHKeyboardCache,geometryKey,JHHCacheFrame(frame),
        NSProcessInfo.processInfo.systemUptime))return [self rejected:@"geometry_unavailable"];
    anchorMs=(CFAbsoluteTimeGetCurrent()-anchorStarted)*1000;
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
    double offset=index++*0.045;
    XCPointerEventPath *path=[[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(point.x,point.y) offset:offset];
    [path liftUpAtOffset:offset+0.035];
    [event addPointerEventPath:path];
  }
  double preflightMs=(CFAbsoluteTimeGetCurrent()-started)*1000;
  JHHLastSequence = sequence;
  NSError *error=nil;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:event error:&error]) { JHHMayBeComposing=NO; return [self rejected:@"synthesis_failed"]; }
  unsigned lastUsage=[keys.lastObject[@"usage"] unsignedIntValue];
  if(selectingCandidate)JHHMayBeComposing=NO;
  else if(lastUsage>=4&&lastUsage<=29)JHHMayBeComposing=YES;
  else if(lastUsage!=42)JHHMayBeComposing=NO;
  return FBResponseWithObject(@{@"accepted":@YES,@"sequence":@(sequence),@"keyCount":@(keys.count),
    @"keyAction":selectingCandidate ? @"candidate" : @"key",@"candidateIndex":@(selectingCandidate?candidateIndex:0),
    @"snapshotEngine":@"standard",@"keyIntervalMs":@45,
    @"engine":@"native-keyboard-batch-v1",@"snapshotMs":@(snapshotMs),@"geometryCached":@(geometryCached),
    @"anchorResolutionMs":@(anchorMs),@"geometryCacheReason":cacheReason,
    @"geometryMs":@(preflightMs-snapshotMs),@"synthesisMs":@((CFAbsoluteTimeGetCurrent()-started)*1000-preflightMs)});
}

@end
