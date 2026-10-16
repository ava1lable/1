// SPDX-License-Identifier: BSD-3-Clause
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

@interface JHHEventCompletion : NSObject
@property(nonatomic,strong) NSLock *lock;
@property(nonatomic,assign) BOOL completed, succeeded;
@property(nonatomic,strong) NSError *error;
@property(nonatomic,assign) double callbackAt;
@property(nonatomic,assign) CFRunLoopRef loop;
@property(nonatomic,assign) CFRunLoopSourceRef source;
@end
@implementation JHHEventCompletion
- (void)dealloc { if(_source)CFRelease(_source);if(_loop)CFRelease(_loop); }
@end
static void JHHCompletionWake(void *info) { (void)info; }

// Production waiter and macOS Foundation tests share this exact implementation.
// Only a real completion can report success. The source wakes the owning loop;
// the 10 ms slice also services main-thread XCTest callbacks without 100 ms polling.
static BOOL JHHWaitForEvent(void (^submit)(void (^done)(BOOL,NSError *)),double timeout,
                           NSDictionary **metrics,NSError **error) {
 double started=NSProcessInfo.processInfo.systemUptime;
 JHHEventCompletion *state=[JHHEventCompletion new];state.lock=[NSLock new];
 state.loop=(CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
 CFRunLoopSourceContext context={0};context.perform=JHHCompletionWake;
 state.source=CFRunLoopSourceCreate(kCFAllocatorDefault,0,&context);
 CFRunLoopAddSource(state.loop,state.source,kCFRunLoopDefaultMode);
 @try {
  submit(^(BOOL succeeded,NSError *failure) {
   [state.lock lock];
   if(!state.completed) {
    state.succeeded=succeeded;state.error=failure;state.callbackAt=NSProcessInfo.processInfo.systemUptime;state.completed=YES;
    CFRunLoopSourceSignal(state.source);CFRunLoopWakeUp(state.loop);
   }
   [state.lock unlock];
  });
 } @catch(NSException *exception) {
  [state.lock lock];state.error=[NSError errorWithDomain:@"JHHEvent" code:2 userInfo:nil];state.completed=YES;state.callbackAt=NSProcessInfo.processInfo.systemUptime;[state.lock unlock];
 }
 unsigned polls=0;BOOL complete=NO,succeeded=NO;NSError *failure=nil;double callbackAt=0;
 while(YES) {
  [state.lock lock];complete=state.completed;succeeded=state.succeeded;failure=state.error;callbackAt=state.callbackAt;[state.lock unlock];
  double now=NSProcessInfo.processInfo.systemUptime;
  if(complete||now-started>=timeout)break;
  polls++;CFRunLoopRunInMode(kCFRunLoopDefaultMode,fmin(.010,fmax(0,timeout-(now-started))),true);
 }
 double finished=NSProcessInfo.processInfo.systemUptime;
 CFRunLoopRemoveSource(state.loop,state.source,kCFRunLoopDefaultMode);
 CFRunLoopSourceInvalidate(state.source);
 if(!complete)failure=[NSError errorWithDomain:@"JHHEvent" code:1 userInfo:nil];
 if(error)*error=failure;
 if(metrics)*metrics=@{@"callbackMs":@(complete?fmax(0,(callbackAt-started)*1000):0),
   @"completionWaitMs":@(complete?fmax(0,(finished-callbackAt)*1000):0),@"completionPolls":@(polls),
   @"completionTimedOut":complete?@NO:@YES};
 return complete&&succeeded&&failure==nil;
}
