// SPDX-License-Identifier: BSD-3-Clause
// Included in JHHControlCommands. USB-only, one-use preparation; never log text.
static NSMutableDictionary *JHHPreparedClipboard;
static NSDictionary *JHHClipboardWriteDiagnostics;
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
 NSMutableDictionary *reply=[@{@"accepted":accepted?@YES:@NO,@"code":code,@"sequence":@(sequence),
  @"engine":@"clipboard-paste-v1",@"clipboardWritten":written?@YES:@NO,@"pasteInvoked":invoked?@YES:@NO,@"insertionVerified":@NO} mutableCopy];
 [reply addEntriesFromDictionary:JHHClipboardWriteDiagnostics?:@{}];return FBResponseWithObject(reply);
}
static JHHForegroundResult JHHClipboardWaitForApp(NSString *expected,pid_t pid,NSString *previous,BOOL requireUIKitActive) {
 JHHForegroundWait wait={NSProcessInfo.processInfo.systemUptime,0};
 while(YES){
  @autoreleasepool {
   XCUIApplication *active=XCUIApplication.fb_activeApplication;
   NSString *bundle=active.bundleID;pid_t activePID=active.processID;
   BOOL axMatches=[bundle isEqual:expected]&&activePID>0&&(pid<=0||activePID==pid);
   BOOL localActive=!requireUIKitActive||UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
   BOOL matches=axMatches&&localActive;
   // A relaunched target with another PID is not the original editor.
   BOOL transition=(axMatches&&!localActive)||!bundle.length||activePID<=0||(![bundle isEqual:expected]&&([bundle isEqual:previous]||[bundle isEqual:@"com.apple.springboard"]));
   JHHForegroundResult result=JHHClipboardForegroundStep(&wait,NSProcessInfo.processInfo.systemUptime,matches,transition);
   if(result!=JHHForegroundPending)return result;
  }
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.08]];
 }
}
static id<FBResponsePayload> JHHClipboardPrepareFailure(NSString *code,unsigned long long sequence,BOOL written,BOOL runnerReady,BOOL attempted,BOOL restored,double restoreMs) {
 NSMutableDictionary *reply=[@{@"accepted":@NO,@"code":code,@"sequence":@(sequence),@"engine":@"clipboard-paste-v1",
  @"clipboardWritten":written?@YES:@NO,@"pasteInvoked":@NO,@"insertionVerified":@NO,
  @"runnerReady":runnerReady?@YES:@NO,@"restoreAttempted":attempted?@YES:@NO,@"targetRestored":restored?@YES:@NO,
  @"restoreWaitMs":@((NSInteger)fmax(0,restoreMs))} mutableCopy];
 [reply addEntriesFromDictionary:JHHClipboardWriteDiagnostics?:@{}];return FBResponseWithObject(reply);
}
+ (id<FBResponsePayload>)prepareClipboard:(FBRouteRequest *)request {
 NSDictionary *a=request.arguments;unsigned long long sequence=JHHClipboardSequence(a);
 if(!sequence)return [self rejected:@"clipboard_stale_request"];
 JHHClipboardWriteDiagnostics=nil;
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
 JHHLastSequence=sequence;JHHPreparedClipboard=nil;JHHClipboardWriteDiagnostics=nil;BOOL written=NO,restored=NO,runnerReady=NO,restoreAttempted=NO;
 NSString *failure=@"clipboard_foreground_failed";double restoreMs=0;
 NSInteger change=0;
 @try {
  XCUIApplication *runner=[[XCUIApplication alloc] initWithBundleIdentifier:own];runner.fb_shouldWaitForQuiescence=NO;
  [runner activate];
  pid_t writerPID=NSProcessInfo.processInfo.processIdentifier;
  runnerReady=JHHClipboardWaitForApp(own,writerPID,bundle,YES)==JHHForegroundReady;
  BOOL processMatches=XCUIApplication.fb_activeApplication.processID==writerPID;
  BOOL uiActive=UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
  JHHClipboardWriteDiagnostics=@{@"writerProcessMatches":processMatches?@YES:@NO,@"writerUIKitActive":uiActive?@YES:@NO};
  if(runnerReady){
   failure=@"clipboard_write_failed";
   UIPasteboard *pb=UIPasteboard.generalPasteboard;
   NSInteger before=pb.changeCount;
   // NSString supplies standard text representations through NSItemProviderWriting.
   // Keep Handoff disabled; allow ten minutes for deliberate manual verification.
   [pb setObjects:@[text] localOnly:YES expirationDate:[NSDate dateWithTimeIntervalSinceNow:600]];
   double publishUntil=NSProcessInfo.processInfo.systemUptime+1.0;
   while(pb.changeCount==before&&UIApplication.sharedApplication.applicationState==UIApplicationStateActive&&NSProcessInfo.processInfo.systemUptime<publishUntil)
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.08]];
   NSInteger publishedChange=pb.changeCount;
   change=publishedChange;
   double until=NSProcessInfo.processInfo.systemUptime+1.5;unsigned stable=0;
   BOOL hasStrings=NO,standardText=NO;
   do {
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive||XCUIApplication.fb_activeApplication.processID!=writerPID)break;
    UIPasteboard *current=UIPasteboard.generalPasteboard;
    if(publishedChange==before||current.changeCount!=publishedChange)break;
    hasStrings=current.hasStrings;
    standardText=[current containsPasteboardTypes:@[@"public.utf8-plain-text",@"public.plain-text",@"public.text"]];
    // Only our newly written text is read, never the previous clipboard.
    BOOL same=hasStrings&&standardText&&[current.string isEqual:text];
    stable=same?stable+1:0;change=current.changeCount;
    if(stable>=2){written=YES;break;}
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
   }while(NSProcessInfo.processInfo.systemUptime<until);
   NSMutableDictionary *diagnostics=[JHHClipboardWriteDiagnostics mutableCopy];
   [diagnostics addEntriesFromDictionary:@{@"clipboardHasStrings":hasStrings?@YES:@NO,@"clipboardStandardText":standardText?@YES:@NO,@"clipboardChangeAdvanced":change!=before?@YES:@NO}];
   JHHClipboardWriteDiagnostics=diagnostics;
  }
 } @catch(NSException *exception) { written=NO; }
 @finally {
  // Restore only if the runner still owns foreground. Do not override a user's
  // intervening Home/app switch, launch a killed target, or choose another app.
  @try {
   XCUIApplication *active=XCUIApplication.fb_activeApplication;
   if([active.bundleID isEqual:bundle]&&active.processID==pid){
    JHHForegroundResult result=JHHClipboardWaitForApp(bundle,pid,own,NO);restored=result==JHHForegroundReady;
    if(!restored)failure=result==JHHForegroundInterrupted?@"clipboard_restore_interrupted":@"clipboard_restore_timeout";
   }else if([active.bundleID isEqual:own]){
    // A fresh bundle-bound application can be activated reliably; the original
    // WDA active-app object is an AX process proxy. Never launch a stopped app.
    XCUIApplication *restore=[[XCUIApplication alloc] initWithBundleIdentifier:bundle];
    restore.fb_shouldWaitForQuiescence=NO;
    if(restore.running&&restore.processID==pid){
     restoreAttempted=YES;double begin=NSProcessInfo.processInfo.systemUptime;
     [restore activate];
     JHHForegroundResult result=JHHClipboardWaitForApp(bundle,pid,own,NO);
     restoreMs=(NSProcessInfo.processInfo.systemUptime-begin)*1000;
     restored=result==JHHForegroundReady;
     if(!restored)failure=result==JHHForegroundInterrupted?@"clipboard_restore_interrupted":@"clipboard_restore_timeout";
    }else failure=@"clipboard_target_changed";
   }else failure=@"clipboard_restore_interrupted";
  } @catch(NSException *exception) {restored=NO;failure=@"clipboard_restore_failed";}
 }
 if(!written||change<=0)return JHHClipboardPrepareFailure(runnerReady?@"clipboard_write_failed":@"clipboard_foreground_failed",sequence,NO,runnerReady,restoreAttempted,restored,restoreMs);
 if(!restored)return JHHClipboardPrepareFailure(failure,sequence,YES,runnerReady,restoreAttempted,NO,restoreMs);
 NSString *ticket=NSUUID.UUID.UUIDString;
 JHHPreparedClipboard=[@{@"ticket":ticket,@"pid":@(pid),@"orientation":@(orientation),@"change":@(change),
  @"keyboard":[NSValue valueWithCGRect:keyboard],@"point":[NSValue valueWithCGPoint:JHHLastTapPoint],
  @"created":@(NSProcessInfo.processInfo.systemUptime),@"diagnostics":JHHClipboardWriteDiagnostics?:@{}} mutableCopy];
 NSMutableDictionary *reply=[@{@"accepted":@YES,@"sequence":@(sequence),@"engine":@"clipboard-paste-v1",
  @"clipboardWritten":@YES,@"targetRestored":@YES,@"ticket":ticket,@"insertionVerified":@NO,
  @"runnerReady":@YES,@"restoreAttempted":restoreAttempted?@YES:@NO,@"restoreWaitMs":@((NSInteger)fmax(0,restoreMs))} mutableCopy];
 [reply addEntriesFromDictionary:JHHClipboardWriteDiagnostics?:@{}];return FBResponseWithObject(reply);
}
static void JHHClipboardMenuDiagnostics(BOOL available,BOOL found,BOOL enabled,BOOL gesture) {
 NSMutableDictionary *d=[(JHHClipboardWriteDiagnostics?:@{}) mutableCopy];
 [d addEntriesFromDictionary:@{@"backgroundClipboardTextObserved":available?@YES:@NO,@"pasteMenuFound":found?@YES:@NO,
  @"pasteMenuEnabled":enabled?@YES:@NO,@"menuGestureDispatched":gesture?@YES:@NO}];JHHClipboardWriteDiagnostics=d;
}
static XCUIElement *JHHClipboardFindPasteMenu(XCUIApplication *root,CGRect bounds,BOOL *ambiguous) {
 NSPredicate *label=[NSPredicate predicateWithFormat:@"label IN %@",@[@"Paste",@"粘贴",@"黏贴"]];
 // Search only menu items or menu/toolbar buttons, never chat or Send buttons.
 NSArray<XCUIElementQuery *> *queries=@[[root.menuItems matchingPredicate:label],
  [root.menus.buttons matchingPredicate:label],[root.toolbars.buttons matchingPredicate:label]];
 for(XCUIElementQuery *query in queries){
  NSArray<XCUIElement *> *all=query.allElementsBoundByIndex;
  if(all.count>8){*ambiguous=YES;return nil;}
  NSMutableArray<XCUIElement *> *visible=[NSMutableArray array];
  for(XCUIElement *item in all){
   CGRect frame=item.frame;
   if(!item.exists||CGRectIsEmpty(frame)||!CGRectIntersectsRect(frame,bounds))continue;
   if(item.enabled&&!item.hittable)continue;
   [visible addObject:item];
  }
  if(visible.count>1){*ambiguous=YES;return nil;}
  if(visible.count==1)return visible.firstObject;
 }
 return nil;
}
+ (id<FBResponsePayload>)pasteClipboard:(FBRouteRequest *)request {
 NSDictionary *a=request.arguments;unsigned long long sequence=JHHClipboardSequence(a);
 if(!sequence)return [self rejected:@"clipboard_stale_request"];
 NSDictionary *prepared=JHHPreparedClipboard;JHHPreparedClipboard=nil;JHHLastSequence=sequence;
 JHHClipboardWriteDiagnostics=prepared[@"diagnostics"];
 if(!prepared||![a[@"ticket"] isKindOfClass:NSString.class]||![a[@"ticket"] isEqual:prepared[@"ticket"]])
  return JHHClipboardReply(NO,@"clipboard_ticket_invalid",sequence,NO,NO);
 XCUIApplication *app=XCUIApplication.fb_activeApplication;app.fb_shouldWaitForQuiescence=NO;
 CGRect keyboard=CGRectZero,old=[prepared[@"keyboard"] CGRectValue];BOOL frameSame=NO;
 double keyboardUntil=NSProcessInfo.processInfo.systemUptime+1.8;
 do {
  if(XCUIApplication.fb_activeApplication.processID!=[prepared[@"pid"] intValue])break;
  keyboard=JHHClipboardKeyboardFrame(app);
  frameSame=!CGRectIsEmpty(keyboard)&&fabs(keyboard.origin.x-old.origin.x)<4&&fabs(keyboard.origin.y-old.origin.y)<4&&
   fabs(keyboard.size.width-old.size.width)<4&&fabs(keyboard.size.height-old.size.height)<4;
  if(frameSame)break;
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
 }while(NSProcessInfo.processInfo.systemUptime<keyboardUntil);
 BOOL clipboardSame=UIPasteboard.generalPasteboard.changeCount==[prepared[@"change"] integerValue];
 BOOL textAvailable=UIPasteboard.generalPasteboard.hasStrings&&[UIPasteboard.generalPasteboard containsPasteboardTypes:@[@"public.utf8-plain-text",@"public.plain-text",@"public.text"]];
 JHHClipboardMenuDiagnostics(textAvailable,NO,NO,NO);
 // Background pasteboard metadata may be hidden by iOS. Never reject on it;
 // the foreground app's actual enabled system Paste item is the action gate.
 if(!frameSame&&app.processID==[prepared[@"pid"] intValue]&&clipboardSame&&app.interfaceOrientation==[prepared[@"orientation"] integerValue])
  return JHHClipboardReply(NO,@"clipboard_refocus_required",sequence,YES,NO);
 if(!JHHClipboardContext(app.processID==[prepared[@"pid"] intValue],app.interfaceOrientation==[prepared[@"orientation"] integerValue],
    !CGRectIsEmpty(keyboard),frameSame,clipboardSame,JHHClipboardFresh(NSProcessInfo.processInfo.systemUptime,[prepared[@"created"] doubleValue],20)))
  return JHHClipboardReply(NO,@"clipboard_context_changed",sequence,YES,NO);
 CGPoint point=[prepared[@"point"] CGPointValue];
 if(CGRectContainsPoint(CGRectInset(keyboard,-4,-4),point))return JHHClipboardReply(NO,@"clipboard_target_required",sequence,YES,NO);
 // Display the system editing toolbar at the user's actual editor click, then
 // require one visible enabled Paste item. No long press or fallback gesture.
 CGRect appFrame=app.frame;JHHClipboardMenuTap points;
 if(!JHHClipboardMenuTapPoints(appFrame.origin.x,appFrame.origin.y,appFrame.size.width,appFrame.size.height,
      CGRectGetMinY(keyboard),point.x,point.y,&points))
  return JHHClipboardReply(NO,@"clipboard_geometry_unavailable",sequence,YES,NO);
 XCSynthesizedEventRecord *event=[[XCSynthesizedEventRecord alloc] initWithName:@"JHH System Editing Toolbar" interfaceOrientation:app.interfaceOrientation];
 for(int finger=0;finger<3;finger++){
  XCPointerEventPath *path=[[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(points.x[finger],points.y[finger]) offset:0];
  [path liftUpAtOffset:.15];[event addPointerEventPath:path];
 }
 if(UIPasteboard.generalPasteboard.changeCount!=[prepared[@"change"] integerValue]||XCUIApplication.fb_activeApplication.processID!=[prepared[@"pid"] intValue]||app.interfaceOrientation!=[prepared[@"orientation"] integerValue])
  return JHHClipboardReply(NO,@"clipboard_context_changed",sequence,YES,NO);
 BOOL hadError=NO;
 if(!JHHSynthesizeCommittedText(event,&hadError)||hadError)return JHHClipboardReply(NO,@"clipboard_gesture_failed",sequence,YES,NO);
 JHHClipboardMenuDiagnostics(textAvailable,NO,NO,YES);
 XCUIElement *paste=nil;BOOL ambiguous=NO;double until=NSProcessInfo.processInfo.systemUptime+2.0;
 do {
  if(XCUIApplication.fb_activeApplication.processID!=[prepared[@"pid"] intValue])return JHHClipboardReply(NO,@"clipboard_context_changed",sequence,YES,NO);
  if(app.alerts.firstMatch.exists||XCUIApplication.fb_systemApplication.alerts.firstMatch.exists)return JHHClipboardReply(NO,@"clipboard_system_alert",sequence,YES,NO);
  @try {
   paste=JHHClipboardFindPasteMenu(app,appFrame,&ambiguous);
   if(!paste&&!ambiguous)paste=JHHClipboardFindPasteMenu(XCUIApplication.fb_systemApplication,appFrame,&ambiguous);
  } @catch(NSException *exception){return JHHClipboardReply(NO,@"clipboard_menu_unavailable",sequence,YES,NO);}
  if(paste||ambiguous)break;
  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.12]];
 }while(NSProcessInfo.processInfo.systemUptime<until);
 if(ambiguous)return JHHClipboardReply(NO,@"clipboard_menu_ambiguous",sequence,YES,NO);
 if(!paste)return JHHClipboardReply(NO,@"clipboard_menu_unavailable",sequence,YES,NO);
 BOOL enabled=paste.enabled&&paste.hittable;JHHClipboardMenuDiagnostics(textAvailable,YES,enabled,YES);
 if(!enabled)return JHHClipboardReply(NO,@"clipboard_paste_disabled",sequence,YES,NO);
 if(UIPasteboard.generalPasteboard.changeCount!=[prepared[@"change"] integerValue]||XCUIApplication.fb_activeApplication.processID!=[prepared[@"pid"] intValue]||app.interfaceOrientation!=[prepared[@"orientation"] integerValue]||!JHHClipboardFresh(NSProcessInfo.processInfo.systemUptime,[prepared[@"created"] doubleValue],20))
  return JHHClipboardReply(NO,@"clipboard_context_changed",sequence,YES,NO);
 @try {[paste tap];if(app.alerts.firstMatch.exists||XCUIApplication.fb_systemApplication.alerts.firstMatch.exists)return JHHClipboardReply(NO,@"clipboard_system_alert",sequence,YES,YES);} @catch(NSException *exception){return JHHClipboardReply(NO,@"clipboard_paste_unconfirmed",sequence,YES,YES);}
 JHHMayBeComposing=NO;
 return JHHClipboardReply(YES,@"paste_menu_invoked_unverified",sequence,YES,YES);
}
