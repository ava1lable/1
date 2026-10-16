// SPDX-License-Identifier: BSD-3-Clause
// Included in JHHControlCommands. USB-only, one-use preparation; never log text.
#include "JHHClipboardPolicy.h"
static NSMutableDictionary *JHHPreparedClipboard;
static unsigned long long JHHClipboardSequence(NSDictionary *a) {
 if(![a[@"instance"] isKindOfClass:NSString.class]||![a[@"instance"] isEqual:JHHInstance])return 0;
 if(![JHHControlCommands number:a[@"sequence"] min:1 max:9007199254740991.0]||floor([a[@"sequence"] doubleValue])!=[a[@"sequence"] doubleValue])return 0;
 unsigned long long s=[a[@"sequence"] unsignedLongLongValue];return s>JHHLastSequence?s:0;
}
static CGRect JHHClipboardKeyboardFrame(XCUIApplication *app) {
 @try { id<FBXCElementSnapshot> k=app.keyboards.firstMatch.fb_standardSnapshot;
  return k.children.count?k.frame:CGRectZero; } @catch(NSException *e){return CGRectZero;}
}
static id<FBResponsePayload> JHHClipboardReply(BOOL accepted,NSString *code,unsigned long long sequence,BOOL written,BOOL invoked) {
 return FBResponseWithObject(@{@"accepted":accepted?@YES:@NO,@"code":code,@"sequence":@(sequence),
  @"engine":@"clipboard-paste-v1",@"clipboardWritten":written?@YES:@NO,@"pasteInvoked":invoked?@YES:@NO,@"insertionVerified":@NO});
}
+ (id<FBResponsePayload>)prepareClipboard:(FBRouteRequest *)request {
 NSDictionary *a=request.arguments;unsigned long long sequence=JHHClipboardSequence(a);
 if(!sequence)return [self rejected:@"clipboard_stale_request"];
 NSString *text=a[@"text"];
 if(![text isKindOfClass:NSString.class]||text.length>4096)return [self rejected:@"invalid_text"];
 uint16_t units[4096];[text getCharacters:units range:NSMakeRange(0,text.length)];
 if(!JHHCommittedTextValid(units,text.length))return [self rejected:@"invalid_text"];
 XCUIApplication *target=XCUIApplication.fb_activeApplication;target.fb_shouldWaitForQuiescence=NO;
 pid_t pid=target.processID;UIInterfaceOrientation orientation=target.interfaceOrientation;
 CGRect keyboard=JHHClipboardKeyboardFrame(target);
 double now=NSProcessInfo.processInfo.systemUptime;
 // Require a fresh explicit click above the already visible keyboard. A click
 // made before the keyboard opened may now point into a key; never guess.
 if(pid<=0||pid!=JHHLastTapPID||orientation!=JHHLastTapOrientation||CGRectIsEmpty(keyboard)||
    !JHHClipboardFresh(now,JHHLastTapTime,120)||CGRectContainsPoint(CGRectInset(keyboard,-4,-4),JHHLastTapPoint))
  return JHHClipboardReply(NO,@"clipboard_target_required",sequence,NO,NO);
 NSString *bundle=target.bundleID,*own=NSBundle.mainBundle.bundleIdentifier;
 if(!bundle.length||!own.length||[bundle isEqual:own]||[bundle isEqual:@"com.apple.springboard"])
  return JHHClipboardReply(NO,@"clipboard_target_required",sequence,NO,NO);
 JHHLastSequence=sequence;JHHPreparedClipboard=nil;BOOL written=NO,restored=NO;
 NSInteger change=0;
 @try {
  XCUIApplication *runner=[[XCUIApplication alloc] initWithBundleIdentifier:own];runner.fb_shouldWaitForQuiescence=NO;
  [runner activate];
  if(![XCUIApplication.fb_activeApplication.bundleID isEqual:own])
   return JHHClipboardReply(NO,@"clipboard_foreground_failed",sequence,NO,NO);
  UIPasteboard *pb=UIPasteboard.generalPasteboard;
  [pb setItems:@[@{@"public.utf8-plain-text":text}] options:@{UIPasteboardOptionLocalOnly:@YES,
    UIPasteboardOptionExpirationDate:[NSDate dateWithTimeIntervalSinceNow:90]}];
  // Read back only our own newly written value while the runner is foreground.
  written=[pb.string isEqual:text];change=pb.changeCount;
 } @catch(NSException *exception) { written=NO; }
 @finally {
  // Restore only if the runner still owns foreground. Do not override a user's
  // intervening Home/app switch, launch a killed target, or choose another app.
  @try { if([XCUIApplication.fb_activeApplication.bundleID isEqual:own]&&target.state!=XCUIApplicationStateNotRunning){
    [target activate];restored=XCUIApplication.fb_activeApplication.processID==pid;
  }} @catch(NSException *exception) {restored=NO;}
 }
 if(!written||change<=0)return JHHClipboardReply(NO,@"clipboard_write_failed",sequence,NO,NO);
 if(!restored)return JHHClipboardReply(NO,@"clipboard_target_changed",sequence,YES,NO);
 NSString *ticket=NSUUID.UUID.UUIDString;
 JHHPreparedClipboard=[@{@"ticket":ticket,@"pid":@(pid),@"orientation":@(orientation),@"change":@(change),
  @"keyboard":[NSValue valueWithCGRect:keyboard],@"point":[NSValue valueWithCGPoint:JHHLastTapPoint],
  @"created":@(NSProcessInfo.processInfo.systemUptime)} mutableCopy];
 return FBResponseWithObject(@{@"accepted":@YES,@"sequence":@(sequence),@"engine":@"clipboard-paste-v1",
  @"clipboardWritten":@YES,@"targetRestored":@YES,@"ticket":ticket,@"insertionVerified":@NO});
}
+ (id<FBResponsePayload>)pasteClipboard:(FBRouteRequest *)request {
 NSDictionary *a=request.arguments;unsigned long long sequence=JHHClipboardSequence(a);
 if(!sequence)return [self rejected:@"clipboard_stale_request"];
 NSDictionary *prepared=JHHPreparedClipboard;JHHPreparedClipboard=nil;JHHLastSequence=sequence;
 if(!prepared||![a[@"ticket"] isKindOfClass:NSString.class]||![a[@"ticket"] isEqual:prepared[@"ticket"]])
  return JHHClipboardReply(NO,@"clipboard_ticket_invalid",sequence,NO,NO);
 XCUIApplication *app=XCUIApplication.fb_activeApplication;app.fb_shouldWaitForQuiescence=NO;
 CGRect keyboard=JHHClipboardKeyboardFrame(app),old=[prepared[@"keyboard"] CGRectValue];
 BOOL frameSame=!CGRectIsEmpty(keyboard)&&fabs(keyboard.origin.x-old.origin.x)<4&&fabs(keyboard.origin.y-old.origin.y)<4&&
  fabs(keyboard.size.width-old.size.width)<4&&fabs(keyboard.size.height-old.size.height)<4;
 BOOL clipboardSame=UIPasteboard.generalPasteboard.changeCount==[prepared[@"change"] integerValue];
 if(!JHHClipboardContext(app.processID==[prepared[@"pid"] intValue],app.interfaceOrientation==[prepared[@"orientation"] integerValue],
    !CGRectIsEmpty(keyboard),frameSame,clipboardSame,JHHClipboardFresh(NSProcessInfo.processInfo.systemUptime,[prepared[@"created"] doubleValue],20)))
  return JHHClipboardReply(NO,@"clipboard_context_changed",sequence,YES,NO);
 CGPoint point=[prepared[@"point"] CGPointValue];
 if(CGRectContainsPoint(CGRectInset(keyboard,-4,-4),point))return JHHClipboardReply(NO,@"clipboard_target_required",sequence,YES,NO);
 // One bounded long press on the last explicit input position; no field lookup
 // or value assignment. Only a real system menu's exact Paste item is tapped.
 XCSynthesizedEventRecord *event=[[XCSynthesizedEventRecord alloc] initWithName:@"JHH Paste Menu" interfaceOrientation:app.interfaceOrientation];
 XCPointerEventPath *path=[[XCPointerEventPath alloc] initForTouchAtPoint:point offset:0];
 [path liftUpAtOffset:.65];[event addPointerEventPath:path];BOOL hadError=NO;
 if(!JHHSynthesizeCommittedText(event,&hadError)||hadError)return JHHClipboardReply(NO,@"clipboard_menu_failed",sequence,YES,NO);
 NSArray *names=@[@"粘贴",@"貼上",@"粘貼",@"Paste"];
 NSPredicate *predicate=[NSPredicate predicateWithFormat:@"label IN %@",names];
 XCUIElement *paste=nil;NSUInteger matches=0;
 // The menu may animate briefly; only poll discovery, never repeat the press.
 double until=NSProcessInfo.processInfo.systemUptime+1.2;
 do {
  if(XCUIApplication.fb_activeApplication.processID!=[prepared[@"pid"] intValue]||!clipboardSame)
   return JHHClipboardReply(NO,@"clipboard_target_changed",sequence,YES,NO);
  matches=0;paste=nil;
  NSArray *items=[[app.menuItems matchingPredicate:predicate] allElementsBoundByIndex];
  if(!items.count)items=[[[app.menus descendantsMatchingType:XCUIElementTypeButton] matchingPredicate:predicate] allElementsBoundByIndex];
  for(XCUIElement *item in items)if(item.exists&&item.hittable){paste=item;matches++;}
  if(matches)break;
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
 } while(NSProcessInfo.processInfo.systemUptime<until);
 if(matches!=1)return JHHClipboardReply(NO,@"clipboard_menu_unavailable",sequence,YES,NO);
 if(UIPasteboard.generalPasteboard.changeCount!=[prepared[@"change"] integerValue]||XCUIApplication.fb_activeApplication.processID!=[prepared[@"pid"] intValue])
  return JHHClipboardReply(NO,@"clipboard_context_changed",sequence,YES,NO);
 [paste tap]; // Never tap Send/Return, accept a permission dialog or retry.
 JHHMayBeComposing=NO;
 return JHHClipboardReply(YES,@"paste_invoked_unverified",sequence,YES,YES);
}
