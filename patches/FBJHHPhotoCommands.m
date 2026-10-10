// SPDX-License-Identifier: BSD-3-Clause
// MirrorGoodGood photo import extension. No album reads or image/body logging.
#import "FBJHHPhotoCommands.h"
#import "FBRouteRequest.h"
#import <Photos/Photos.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>

static const NSUInteger JHHMaxBytes = 64 * 1024 * 1024;
static const NSUInteger JHHChunkBytes = 256 * 1024;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *JHHJobs;
static NSURL *JHHDirectory;

static BOOL JHHHex(id value, NSUInteger length) {
  if (![value isKindOfClass:NSString.class] || [value length] != length) return NO;
  return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
static NSURL *JHHMeta(NSString *key) { return [JHHDirectory URLByAppendingPathComponent:[key stringByAppendingString:@".json"]]; }
static NSURL *JHHFile(NSDictionary *job) { return [JHHDirectory URLByAppendingPathComponent:[job[@"id"] stringByAppendingString:job[@"extension"]]]; }
static BOOL JHHPersist(NSDictionary *job) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:job options:0 error:nil];
  return data && [data writeToURL:JHHMeta(job[@"id"]) options:NSDataWritingAtomic error:nil];
}
static void JHHInitialize(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    JHHJobs = [NSMutableDictionary dictionary];
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    JHHDirectory = [support URLByAppendingPathComponent:@"MirrorGoodGood-Photos" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:JHHDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:JHHDirectory includingPropertiesForKeys:nil options:0 error:nil]) {
      if (![url.pathExtension isEqualToString:@"json"]) continue;
      NSDictionary *data = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] ?: NSData.data options:NSJSONReadingMutableContainers error:nil];
      if (![data isKindOfClass:NSDictionary.class] || !JHHHex(data[@"id"], 32) ||
          ![@[@".jpg", @".png", @".gif", @".heic"] containsObject:data[@"extension"]]) continue;
      NSMutableDictionary *job = [data mutableCopy];
      // A crash during the Photos transaction has an unknown outcome. Never repeat it.
      if ([@[@"saving", @"validating"] containsObject:job[@"state"]]) {
        job[@"state"] = @"unknown"; JHHPersist(job);
      }
      JHHJobs[job[@"id"]] = job;
    }
  });
}
static NSString *JHHAuthorization(void) {
  switch ([PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly]) {
    case PHAuthorizationStatusAuthorized: return @"authorized";
    case PHAuthorizationStatusNotDetermined: return @"notDetermined";
    case PHAuthorizationStatusRestricted: return @"restricted";
    case PHAuthorizationStatusLimited: return @"limited";
    default: return @"denied";
  }
}
static id<FBResponsePayload> JHHError(NSString *code) {
  return FBResponseWithObject(@{@"ok": @NO, @"code": code});
}
static NSDictionary *JHHSnapshot(NSDictionary *job) {
  return @{@"ok": @YES, @"uploadId": job[@"id"], @"state": job[@"state"],
           @"receivedBytes": job[@"received"], @"saved": @([job[@"state"] isEqualToString:@"saved"])};
}
static NSMutableDictionary *JHHLookup(FBRouteRequest *request) {
  JHHInitialize(); id key = request.parameters[@"uploadId"];
  return JHHHex(key, 32) ? JHHJobs[key] : nil;
}
static void JHHPrune(void) {
  NSTimeInterval now = NSDate.date.timeIntervalSince1970;
  for (NSString *key in JHHJobs.allKeys) {
    NSDictionary *job = JHHJobs[key]; NSString *state = job[@"state"];
    if ([@[@"saving", @"validating"] containsObject:state]) continue;
    NSTimeInterval age = now - [job[@"created"] doubleValue];
    BOOL incomplete = [@[@"uploading", @"ready"] containsObject:state];
    if (age > (incomplete ? 900 : 86400)) {
      [NSFileManager.defaultManager removeItemAtURL:JHHFile(job) error:nil];
      [NSFileManager.defaultManager removeItemAtURL:JHHMeta(key) error:nil];
      [JHHJobs removeObjectForKey:key];
    }
  }
}
static BOOL JHHValidImage(NSDictionary *job) {
  NSInputStream *stream = [NSInputStream inputStreamWithURL:JHHFile(job)];
  [stream open]; CC_SHA256_CTX context; CC_SHA256_Init(&context);
  uint8_t buffer[65536]; NSInteger count; NSUInteger total = 0;
  while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
    total += count; CC_SHA256_Update(&context, buffer, (CC_LONG)count);
  }
  [stream close]; if (count < 0 || total != [job[@"length"] unsignedIntegerValue]) return NO;
  uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
  NSMutableString *hash = [NSMutableString string];
  for (NSUInteger i = 0; i < sizeof(digest); i++) [hash appendFormat:@"%02x", digest[i]];
  if (![hash isEqualToString:job[@"sha256"]]) return NO;
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)JHHFile(job), NULL);
  if (!source) return NO;
  NSString *type = (__bridge NSString *)CGImageSourceGetType(source);
  BOOL valid = CGImageSourceGetCount(source) > 0 && [@[@"public.jpeg", @"public.png", @"com.compuserve.gif", @"public.heic", @"public.heif"] containsObject:type ?: @""];
  CFRelease(source); return valid;
}

@implementation FBJHHPhotoCommands
+ (NSArray *)routes {
  return @[
    [[FBRoute GET:@"/wda/jhh/photos/status"].withoutSession respondWithTarget:self action:@selector(status:)],
    [[FBRoute POST:@"/wda/jhh/photos/authorize"].withoutSession respondWithTarget:self action:@selector(authorize:)],
    [[FBRoute POST:@"/wda/jhh/photos/uploads"].withoutSession respondWithTarget:self action:@selector(begin:)],
    [[FBRoute POST:@"/wda/jhh/photos/uploads/:uploadId/chunk"].withoutSession respondWithTarget:self action:@selector(chunk:)],
    [[FBRoute POST:@"/wda/jhh/photos/uploads/:uploadId/commit"].withoutSession respondWithTarget:self action:@selector(commit:)],
    [[FBRoute GET:@"/wda/jhh/photos/uploads/:uploadId"].withoutSession respondWithTarget:self action:@selector(job:)],
    [[FBRoute POST:@"/wda/jhh/photos/uploads/:uploadId/cancel"].withoutSession respondWithTarget:self action:@selector(cancel:)],
  ];
}
+ (id<FBResponsePayload>)status:(FBRouteRequest *)request {
  JHHInitialize(); JHHPrune();
  return FBResponseWithObject(@{@"ok": @YES, @"apiVersion": @1, @"component": @"MirrorGoodGood-WDA-Photos",
    @"authorization": JHHAuthorization(), @"maxFileBytes": @(JHHMaxBytes), @"chunkBytes": @(JHHChunkBytes), @"saveAcknowledgements": @YES});
}
+ (id<FBResponsePayload>)authorize:(FBRouteRequest *)request {
  if ([JHHAuthorization() isEqualToString:@"notDetermined"]) {
    // User must approve the iOS prompt; this component never taps Allow itself.
    dispatch_async(dispatch_get_main_queue(), ^{
      [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {}];
    });
  }
  return [self status:request];
}
+ (id<FBResponsePayload>)begin:(FBRouteRequest *)request {
  JHHInitialize(); JHHPrune(); NSDictionary *args = request.arguments;
  NSString *key = args[@"uploadId"]; id length = args[@"length"];
  if (!JHHHex(key, 32) || !JHHHex(args[@"sha256"], 64) || ![length isKindOfClass:NSNumber.class] ||
      [length doubleValue] != [length unsignedIntegerValue] || [length unsignedIntegerValue] == 0 ||
      [length unsignedIntegerValue] > JHHMaxBytes || ![@[@".jpg", @".png", @".gif", @".heic"] containsObject:args[@"extension"]]) return JHHError(@"invalid_file");
  if (![JHHAuthorization() isEqualToString:@"authorized"]) return JHHError(@"photo_permission");
  NSMutableDictionary *existing = JHHJobs[key];
  if (existing) {
    if (![existing[@"sha256"] isEqual:args[@"sha256"]] || ![existing[@"length"] isEqual:length] || ![existing[@"extension"] isEqual:args[@"extension"]]) return JHHError(@"upload_conflict");
    return FBResponseWithObject(JHHSnapshot(existing));
  }
  for (NSDictionary *job in JHHJobs.allValues) if ([@[@"uploading", @"ready", @"validating", @"saving"] containsObject:job[@"state"]]) return JHHError(@"busy");
  if (JHHJobs.count >= 512) return JHHError(@"receipt_limit");
  NSMutableDictionary *job = [@{@"id": key, @"length": length, @"extension": args[@"extension"], @"sha256": args[@"sha256"],
    @"received": @0, @"state": @"uploading", @"created": @(NSDate.date.timeIntervalSince1970)} mutableCopy];
  if (![NSData.data writeToURL:JHHFile(job) options:NSDataWritingAtomic error:nil] || !JHHPersist(job)) return JHHError(@"storage_error");
  JHHJobs[key] = job; return FBResponseWithObject(JHHSnapshot(job));
}
+ (id<FBResponsePayload>)chunk:(FBRouteRequest *)request {
  NSMutableDictionary *job = JHHLookup(request); NSDictionary *args = request.arguments;
  if (!job || ![job[@"state"] isEqualToString:@"uploading"]) return JHHError(@"upload_state");
  if (![args[@"offset"] isKindOfClass:NSNumber.class] || ![args[@"offset"] isEqual:job[@"received"]] ||
      ![args[@"data"] isKindOfClass:NSString.class] || [args[@"data"] length] > (JHHChunkBytes + 2) / 3 * 4) return JHHError(@"chunk_order");
  NSData *data = [[NSData alloc] initWithBase64EncodedString:args[@"data"] options:0];
  NSUInteger total = [job[@"received"] unsignedIntegerValue] + data.length;
  if (!data.length || data.length > JHHChunkBytes || total > [job[@"length"] unsignedIntegerValue]) return JHHError(@"chunk_size");
  @try {
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:JHHFile(job).path];
    if (!file) return JHHError(@"storage_error");
    [file seekToEndOfFile]; [file writeData:data]; [file synchronizeFile]; [file closeFile];
  } @catch (NSException *exception) { job[@"state"] = @"failed"; JHHPersist(job); return JHHError(@"storage_error"); }
  job[@"received"] = @(total); if (total == [job[@"length"] unsignedIntegerValue]) job[@"state"] = @"ready";
  if (!JHHPersist(job)) return JHHError(@"storage_error");
  return FBResponseWithObject(JHHSnapshot(job));
}
+ (id<FBResponsePayload>)commit:(FBRouteRequest *)request {
  NSMutableDictionary *job = JHHLookup(request);
  if (!job) return JHHError(@"upload_missing");
  if ([@[@"saved", @"saving", @"validating", @"unknown"] containsObject:job[@"state"]]) return FBResponseWithObject(JHHSnapshot(job));
  if (![job[@"state"] isEqualToString:@"ready"]) return JHHError(@"upload_incomplete");
  if (![JHHAuthorization() isEqualToString:@"authorized"]) return JHHError(@"photo_permission");
  job[@"state"] = @"validating"; if (!JHHPersist(job)) { job[@"state"] = @"failed"; return JHHError(@"storage_error"); }
  NSDictionary *snapshot = [job copy];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    BOOL valid = JHHValidImage(snapshot);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!valid) { job[@"state"] = @"failed"; JHHPersist(job); return; }
      job[@"state"] = @"saving";
      if (!JHHPersist(job)) { job[@"state"] = @"failed"; return; }
      [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
        PHAssetCreationRequest *creation = [PHAssetCreationRequest creationRequestForAsset];
        [creation addResourceWithType:PHAssetResourceTypePhoto fileURL:JHHFile(snapshot) options:nil];
      } completionHandler:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
          job[@"state"] = success ? @"saved" : @"failed";
          if (!JHHPersist(job)) job[@"state"] = @"unknown";
          [NSFileManager.defaultManager removeItemAtURL:JHHFile(snapshot) error:nil];
        });
      }];
    });
  });
  return FBResponseWithObject(JHHSnapshot(job));
}
+ (id<FBResponsePayload>)job:(FBRouteRequest *)request {
  NSDictionary *job = JHHLookup(request); return job ? FBResponseWithObject(JHHSnapshot(job)) : JHHError(@"upload_missing");
}
+ (id<FBResponsePayload>)cancel:(FBRouteRequest *)request {
  NSMutableDictionary *job = JHHLookup(request); if (!job) return JHHError(@"upload_missing");
  if (![@[@"uploading", @"ready"] containsObject:job[@"state"]]) return FBResponseWithObject(JHHSnapshot(job));
  [NSFileManager.defaultManager removeItemAtURL:JHHFile(job) error:nil];
  job[@"state"] = @"cancelled"; JHHPersist(job); return FBResponseWithObject(JHHSnapshot(job));
}
@end
