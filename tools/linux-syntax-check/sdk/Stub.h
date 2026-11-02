// Minimal stand-ins for the Apple SDK, only for `clang -fsyntax-only` on Linux.
#pragma once
#pragma clang system_header
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <unistd.h>

typedef signed char BOOL;
#define YES ((BOOL)1)
#define NO ((BOOL)0)
#define nil nullptr
#define Nil ((Class)0)
#define NS_ASSUME_NONNULL_BEGIN
#define NS_ASSUME_NONNULL_END
typedef long NSInteger;
typedef unsigned long NSUInteger;
typedef double NSTimeInterval;
typedef double CGFloat;
typedef unsigned char UInt8;
typedef unsigned short UInt16;
typedef unsigned int UInt32;
typedef int SInt32;
typedef long long SInt64;
typedef unsigned long long UInt64;
typedef int32_t OSStatus;
typedef UInt16 UniChar;
enum { noErr = 0 };
#ifndef MAX
#define MAX(a,b) ((a) > (b) ? (a) : (b))
#define MIN(a,b) ((a) < (b) ? (a) : (b))
#endif

// ---- CoreFoundation
typedef const void *CFTypeRef;
typedef const struct __CFAllocator *CFAllocatorRef;
typedef const struct __CFString *CFStringRef;
typedef const struct __CFURL *CFURLRef;
typedef const struct __CFDictionary *CFDictionaryRef;
typedef struct __CFMachPort *CFMachPortRef;
typedef struct __CFRunLoop *CFRunLoopRef;
typedef struct __CFRunLoopSource *CFRunLoopSourceRef;
typedef long CFIndex;
extern const CFAllocatorRef kCFAllocatorDefault;
extern const CFStringRef kCFRunLoopCommonModes;
#ifdef __cplusplus
extern "C" {
#endif
CFTypeRef CFRetain(CFTypeRef);
void CFRelease(CFTypeRef);
CFRunLoopSourceRef CFMachPortCreateRunLoopSource(CFAllocatorRef, CFMachPortRef, CFIndex);
void CFMachPortInvalidate(CFMachPortRef);
CFRunLoopRef CFRunLoopGetCurrent(void);
CFRunLoopRef CFRunLoopGetMain(void);
void CFRunLoopAddSource(CFRunLoopRef, CFRunLoopSourceRef, CFStringRef);
void CFRunLoopRemoveSource(CFRunLoopRef, CFRunLoopSourceRef, CFStringRef);
void CFRunLoopRun(void);
void CFRunLoopStop(CFRunLoopRef);
void CFRunLoopWakeUp(CFRunLoopRef);
#ifdef __cplusplus
}
#endif

// ---- pthread QoS (macOS)
typedef enum { QOS_CLASS_USER_INTERACTIVE = 0x21, QOS_CLASS_USER_INITIATED = 0x19 } qos_class_t;
#ifdef __cplusplus
extern "C" {
#endif
int pthread_set_qos_class_self_np(qos_class_t, int);
int mac_pthread_setname_np(const char *);
#ifdef __cplusplus
}
#endif

// ---- ObjC base
@protocol NSObject
@end
@protocol NSCopying
@end
@interface NSObject <NSObject>
+ (instancetype)alloc;
- (instancetype)init;
+ (instancetype)new;
+ (Class)class;
- (BOOL)isKindOfClass:(Class)c;
- (id)copy;
- (id)mutableCopy;
@end

// ---- dispatch (ObjC objects under ARC, like the real SDK)
@protocol OS_dispatch_object <NSObject> @end
@protocol OS_dispatch_queue <OS_dispatch_object> @end
@protocol OS_dispatch_source <OS_dispatch_object> @end
@protocol OS_dispatch_semaphore <OS_dispatch_object> @end
@protocol OS_dispatch_queue_attr <OS_dispatch_object> @end
typedef NSObject<OS_dispatch_queue> *dispatch_queue_t;
typedef NSObject<OS_dispatch_source> *dispatch_source_t;
typedef NSObject<OS_dispatch_semaphore> *dispatch_semaphore_t;
typedef NSObject<OS_dispatch_queue_attr> *dispatch_queue_attr_t;
typedef void (^dispatch_block_t)(void);
typedef uint64_t dispatch_time_t;
typedef long dispatch_once_t;
typedef const struct dispatch_source_type_s *dispatch_source_type_t;
extern const struct dispatch_source_type_s _dispatch_source_type_timer;
#define DISPATCH_SOURCE_TYPE_TIMER (&_dispatch_source_type_timer)
#define DISPATCH_TIME_NOW (0ull)
#define DISPATCH_TIME_FOREVER (~0ull)
#define NSEC_PER_SEC 1000000000ull
#define NSEC_PER_MSEC 1000000ull
#define DISPATCH_QUEUE_SERIAL ((dispatch_queue_attr_t)0)
#define DISPATCH_QUEUE_PRIORITY_DEFAULT 0
#ifdef __cplusplus
extern "C" {
#endif
dispatch_queue_t dispatch_get_main_queue(void);
dispatch_queue_t dispatch_get_global_queue(long, unsigned long);
dispatch_queue_t dispatch_queue_create(const char *, dispatch_queue_attr_t);
dispatch_queue_attr_t dispatch_queue_attr_make_with_qos_class(dispatch_queue_attr_t, qos_class_t, int);
void dispatch_async(dispatch_queue_t, dispatch_block_t);
void dispatch_sync(dispatch_queue_t, dispatch_block_t);
void dispatch_after(dispatch_time_t, dispatch_queue_t, dispatch_block_t);
void dispatch_once(dispatch_once_t *, dispatch_block_t);
dispatch_time_t dispatch_time(dispatch_time_t, int64_t);
dispatch_source_t dispatch_source_create(dispatch_source_type_t, uintptr_t, uintptr_t, dispatch_queue_t);
void dispatch_source_set_timer(dispatch_source_t, dispatch_time_t, uint64_t, uint64_t);
void dispatch_source_set_event_handler(dispatch_source_t, dispatch_block_t);
void dispatch_source_cancel(dispatch_source_t);
void dispatch_resume(id);
dispatch_semaphore_t dispatch_semaphore_create(long);
long dispatch_semaphore_signal(dispatch_semaphore_t);
long dispatch_semaphore_wait(dispatch_semaphore_t, dispatch_time_t);
#ifdef __cplusplus
}
#endif

// ---- Foundation
typedef struct _NSRange { NSUInteger location; NSUInteger length; } NSRange;
static inline NSRange NSMakeRange(NSUInteger l, NSUInteger n) { NSRange r = { l, n }; return r; }
typedef enum { NSOrderedAscending = -1, NSOrderedSame = 0, NSOrderedDescending = 1 } NSComparisonResult;
typedef NSUInteger NSStringEncoding;
enum { NSUTF8StringEncoding = 4 };
typedef enum { NSCachesDirectory = 13, NSApplicationSupportDirectory = 14 } NSSearchPathDirectory;
typedef enum { NSUserDomainMask = 1 } NSSearchPathDomainMask;

@class NSString, NSArray, NSDictionary, NSData, NSURL, NSError, NSDate, NSNumber, NSCharacterSet;

@interface NSNumber : NSObject
+ (NSNumber *)numberWithInt:(int)v;
+ (NSNumber *)numberWithLong:(long)v;
+ (NSNumber *)numberWithUnsignedInt:(unsigned)v;
+ (NSNumber *)numberWithUnsignedLong:(unsigned long)v;
+ (NSNumber *)numberWithUnsignedLongLong:(unsigned long long)v;
+ (NSNumber *)numberWithLongLong:(long long)v;
+ (NSNumber *)numberWithDouble:(double)v;
+ (NSNumber *)numberWithBool:(BOOL)v;
+ (NSNumber *)numberWithInteger:(NSInteger)v;
+ (NSNumber *)numberWithUnsignedInteger:(NSUInteger)v;
@end

@interface NSValue : NSObject
+ (NSValue *)valueWithPointer:(const void *)p;
@property (readonly) void *pointerValue;
@end

@interface NSString : NSObject <NSCopying>
+ (instancetype)stringWithUTF8String:(const char *)s;
+ (instancetype)stringWithFormat:(NSString *)fmt, ...;
- (instancetype)initWithData:(NSData *)d encoding:(NSStringEncoding)e;
@property (readonly) const char *UTF8String;
@property (readonly) NSUInteger length;
@property (readonly, copy) NSString *lowercaseString;
@property (readonly, copy) NSString *lastPathComponent;
@property (readonly, copy) NSString *pathExtension;
@property (readonly, copy) NSString *stringByDeletingPathExtension;
@property (readonly, copy) NSString *stringByExpandingTildeInPath;
@property (readonly, getter=isAbsolutePath) BOOL absolutePath;
- (BOOL)isEqualToString:(NSString *)s;
- (NSString *)stringByAppendingPathComponent:(NSString *)s;
- (NSString *)stringByAppendingPathExtension:(NSString *)s;
- (NSString *)stringByAppendingString:(NSString *)s;
- (NSString *)stringByTrimmingCharactersInSet:(NSCharacterSet *)set;
- (NSString *)substringWithRange:(NSRange)r;
- (NSString *)substringFromIndex:(NSUInteger)i;
- (NSComparisonResult)caseInsensitiveCompare:(NSString *)s;
- (void)getCharacters:(UniChar *)buf range:(NSRange)r;
- (NSData *)dataUsingEncoding:(NSStringEncoding)e;
- (BOOL)writeToFile:(NSString *)p atomically:(BOOL)a encoding:(NSStringEncoding)e error:(NSError **)err;
@end
@interface NSMutableString : NSString @end

@interface NSCharacterSet : NSObject
+ (NSCharacterSet *)whitespaceAndNewlineCharacterSet;
+ (NSCharacterSet *)whitespaceCharacterSet;
+ (NSCharacterSet *)punctuationCharacterSet;
@end
@interface NSMutableCharacterSet : NSCharacterSet
+ (NSMutableCharacterSet *)whitespaceAndNewlineCharacterSet;
- (void)formUnionWithCharacterSet:(NSCharacterSet *)s;
@end

@interface NSArray<ObjectType> : NSObject
+ (instancetype)arrayWithObjects:(const ObjectType [])objects count:(NSUInteger)cnt;
@property (readonly) NSUInteger count;
@property (readonly) ObjectType firstObject;
@property (readonly) ObjectType lastObject;
- (ObjectType)objectAtIndexedSubscript:(NSUInteger)i;
- (NSString *)componentsJoinedByString:(NSString *)s;
- (NSUInteger)countByEnumeratingWithState:(void *)state objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len;
@end
@interface NSMutableArray<ObjectType> : NSArray<ObjectType>
+ (instancetype)array;
+ (instancetype)arrayWithCapacity:(NSUInteger)n;
- (void)addObject:(ObjectType)o;
@end

@interface NSDictionary<KeyType, ObjectType> : NSObject
+ (instancetype)dictionaryWithObjects:(const ObjectType [])objects forKeys:(const KeyType [])keys count:(NSUInteger)cnt;
- (ObjectType)objectForKeyedSubscript:(KeyType)key;
- (NSString *)fileType;
- (NSDate *)fileModificationDate;
- (unsigned long long)fileSize;
@end
@interface NSMutableDictionary<KeyType, ObjectType> : NSDictionary<KeyType, ObjectType>
+ (instancetype)dictionary;
- (void)setObject:(ObjectType)o forKeyedSubscript:(KeyType)k;
- (void)removeObjectForKey:(KeyType)k;
@end

@interface NSData : NSObject
+ (instancetype)dataWithContentsOfFile:(NSString *)p;
+ (instancetype)dataWithBytes:(const void *)b length:(NSUInteger)n;
@property (readonly) NSUInteger length;
@end
@interface NSMutableData : NSData
+ (instancetype)data;
+ (instancetype)dataWithCapacity:(NSUInteger)n;
- (void)appendData:(NSData *)d;
@end

@interface NSError : NSObject
@property (readonly) NSInteger code;
@property (readonly, copy) NSString *localizedDescription;
@end

@interface NSDate : NSObject
+ (instancetype)date;
+ (instancetype)dateWithTimeIntervalSinceNow:(NSTimeInterval)t;
- (NSComparisonResult)compare:(NSDate *)d;
- (NSTimeInterval)timeIntervalSinceDate:(NSDate *)d;
@end
@interface NSDateInterval : NSObject
@property (readonly) NSTimeInterval duration;
@end
@interface NSDateFormatter : NSObject
@property (copy) NSString *dateFormat;
- (NSString *)stringFromDate:(NSDate *)d;
@end

@interface NSURL : NSObject
+ (instancetype)fileURLWithPath:(NSString *)p;
+ (instancetype)URLWithString:(NSString *)s;
@property (readonly, copy) NSString *path;
@end

@interface NSUUID : NSObject
+ (instancetype)UUID;
@property (readonly, copy) NSString *UUIDString;
@end

@interface NSProcessInfo : NSObject
+ (NSProcessInfo *)processInfo;
@property (readonly) NSTimeInterval systemUptime;
@end

@interface NSUserDefaults : NSObject
+ (NSUserDefaults *)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)k;
- (NSInteger)integerForKey:(NSString *)k;
- (NSString *)stringForKey:(NSString *)k;
- (void)setBool:(BOOL)v forKey:(NSString *)k;
@end

extern NSString *const NSFileTypeRegular;
@interface NSFileManager : NSObject
+ (NSFileManager *)defaultManager;
- (BOOL)fileExistsAtPath:(NSString *)p;
- (BOOL)removeItemAtPath:(NSString *)p error:(NSError **)e;
- (BOOL)moveItemAtPath:(NSString *)a toPath:(NSString *)b error:(NSError **)e;
- (BOOL)createDirectoryAtPath:(NSString *)p withIntermediateDirectories:(BOOL)i attributes:(NSDictionary *)a error:(NSError **)e;
- (NSArray<NSString *> *)contentsOfDirectoryAtPath:(NSString *)p error:(NSError **)e;
- (NSDictionary *)attributesOfItemAtPath:(NSString *)p error:(NSError **)e;
@end

#ifdef __cplusplus
extern "C" {
#endif
void NSLog(NSString *fmt, ...) __attribute__((format(__NSString__, 1, 2)));
NSArray<NSString *> *NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory, NSSearchPathDomainMask, BOOL);
#ifdef __cplusplus
}
#endif

typedef enum { NSRegularExpressionCaseInsensitive = 1 } NSRegularExpressionOptions;
@interface NSTextCheckingResult : NSObject
- (NSRange)rangeAtIndex:(NSUInteger)i;
@end
@interface NSRegularExpression : NSObject
+ (NSString *)escapedPatternForString:(NSString *)s;
+ (instancetype)regularExpressionWithPattern:(NSString *)p options:(NSRegularExpressionOptions)o error:(NSError **)e;
- (NSArray<NSTextCheckingResult *> *)matchesInString:(NSString *)s options:(NSUInteger)o range:(NSRange)r;
@end

@interface NSJSONSerialization : NSObject
+ (id)JSONObjectWithData:(NSData *)d options:(NSUInteger)o error:(NSError **)e;
@end

// ---- NSURLSession
enum { NSURLErrorCancelled = -999, NSURLErrorTimedOut = -1001 };
@interface NSURLRequest : NSObject
@property (readonly, copy) NSString *HTTPMethod;
@end
@interface NSMutableURLRequest : NSURLRequest
+ (instancetype)requestWithURL:(NSURL *)u;
@property (copy) NSString *HTTPMethod;
@property NSTimeInterval timeoutInterval;
- (void)setValue:(NSString *)v forHTTPHeaderField:(NSString *)f;
@end
@interface NSURLResponse : NSObject @end
@interface NSHTTPURLResponse : NSURLResponse
@property (readonly) NSInteger statusCode;
@end
typedef enum { NSURLSessionTaskStateRunning = 0, NSURLSessionTaskStateSuspended = 1,
               NSURLSessionTaskStateCanceling = 2, NSURLSessionTaskStateCompleted = 3 } NSURLSessionTaskState;
@interface NSURLSessionTask : NSObject
@property (readonly) NSUInteger taskIdentifier;
@property (readonly, copy) NSURLRequest *originalRequest;
@property (readonly, copy) NSURLResponse *response;
@property (readonly) NSURLSessionTaskState state;
- (void)resume;
- (void)cancel;
@end
@interface NSURLSessionDataTask : NSURLSessionTask @end
@interface NSURLSessionUploadTask : NSURLSessionDataTask @end
@interface NSURLSessionDownloadTask : NSURLSessionTask @end
@interface NSURLSessionTaskTransactionMetrics : NSObject
@property (copy, readonly) NSDate *fetchStartDate;
@property (copy, readonly) NSDate *domainLookupStartDate;
@property (copy, readonly) NSDate *domainLookupEndDate;
@property (copy, readonly) NSDate *connectStartDate;
@property (copy, readonly) NSDate *secureConnectionStartDate;
@property (copy, readonly) NSDate *secureConnectionEndDate;
@property (copy, readonly) NSDate *connectEndDate;
@property (copy, readonly) NSDate *requestStartDate;
@property (copy, readonly) NSDate *requestEndDate;
@property (copy, readonly) NSDate *responseStartDate;
@property (copy, readonly) NSDate *responseEndDate;
@property (copy, readonly) NSString *networkProtocolName;
@property (assign, readonly, getter=isReusedConnection) BOOL reusedConnection;
@property (readonly) int64_t countOfRequestBodyBytesSent;
@end
@interface NSURLSessionTaskMetrics : NSObject
@property (copy, readonly) NSArray<NSURLSessionTaskTransactionMetrics *> *transactionMetrics;
@property (copy, readonly) NSDateInterval *taskInterval;
@end
@interface NSURLSessionConfiguration : NSObject
+ (NSURLSessionConfiguration *)defaultSessionConfiguration;
@property NSTimeInterval timeoutIntervalForRequest;
@property NSTimeInterval timeoutIntervalForResource;
@property BOOL waitsForConnectivity;
@end
@class NSURLSession;
@protocol NSURLSessionDelegate <NSObject> @end
@protocol NSURLSessionTaskDelegate <NSURLSessionDelegate> @end
@protocol NSURLSessionDataDelegate <NSURLSessionTaskDelegate> @end
@protocol NSURLSessionDownloadDelegate <NSURLSessionTaskDelegate> @end
@class NSOperationQueue;
@interface NSURLSession : NSObject
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)c delegate:(id<NSURLSessionDelegate>)d delegateQueue:(NSOperationQueue *)q;
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)r fromData:(NSData *)d;
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)r;
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)u;
- (void)invalidateAndCancel;
@end
