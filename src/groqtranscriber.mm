#include "groqtranscriber.h"
#import <Foundation/Foundation.h>

static NSString *const kGroqAPIKeyDefault = @"GroqAPIKey";
static NSString *const kGroqEndpoint = @"https://api.groq.com/openai/v1/audio/transcriptions";
static NSString *const kGroqModel = @"whisper-large-v3";
static NSString *const kGroqLanguage = @"vi";

// Bounds for one attempt. Measured on this machine (Sep 2026): a healthy request takes
// ~1 s, p90 ~6 s; the long waits were uploads crawling at 20-90 KB/s. The idle timeout
// catches a stalled socket, the total timeout caps a crawling transfer. One retry, then
// the controller falls back or gives up and keeps the audio file.
static const NSTimeInterval kIdleTimeout = 20.0;
static const NSTimeInterval kTotalTimeout = 45.0;
static const int kMaxAttempts = 2;
static const NSTimeInterval kRetryDelay = 2.0;

static NSTimeInterval monotonicNow() { return [NSProcessInfo processInfo].systemUptime; }
static std::string cstr(NSString *s) { const char *c = [s UTF8String]; return c ? c : ""; }

// Per-task bookkeeping, keyed by NSURLSessionTask.taskIdentifier.
@interface GroqRequest : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) int attempt;
@property (nonatomic, strong) NSMutableData *body;
@property (nonatomic, assign) int lastPercent;
@property (nonatomic, assign) NSTimeInterval startedAt;
@end

@implementation GroqRequest
@end

typedef void (^GroqProgressBlock)(NSString *path, NSString *status);
typedef void (^GroqFinishedBlock)(NSString *path, int attempt, NSTimeInterval elapsed,
                                  NSData *body, NSHTTPURLResponse *response, NSError *error);

@interface GroqSessionDelegate : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, GroqRequest *> *requests;
@property (nonatomic, copy) GroqProgressBlock onProgress;
@property (nonatomic, copy) GroqFinishedBlock onFinished;
- (void)track:(NSURLSessionTask *)task path:(NSString *)path attempt:(int)attempt;
@end

@implementation GroqSessionDelegate

- (instancetype)init {
    if ((self = [super init])) {
        _requests = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)track:(NSURLSessionTask *)task path:(NSString *)path attempt:(int)attempt {
    GroqRequest *req = [[GroqRequest alloc] init];
    req.path = path;
    req.attempt = attempt;
    req.body = [NSMutableData data];
    req.lastPercent = -1;
    req.startedAt = monotonicNow();
    @synchronized (self) { self.requests[@(task.taskIdentifier)] = req; }
}

- (GroqRequest *)requestForTask:(NSURLSessionTask *)task {
    @synchronized (self) { return self.requests[@(task.taskIdentifier)]; }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    (void)session; (void)bytesSent;
    GroqRequest *req = [self requestForTask:task];
    if (!req || totalBytesExpectedToSend <= 0) return;
    int pct = (int)((totalBytesSent * 100) / totalBytesExpectedToSend);
    if (pct == req.lastPercent) return;
    req.lastPercent = pct;
    NSString *status = pct >= 100 ? @"Waiting for Groq"
                                  : [NSString stringWithFormat:@"Uploading %d%%", pct];
    if (self.onProgress) self.onProgress(req.path, status);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    [[self requestForTask:dataTask].body appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    GroqRequest *req = nil;
    @synchronized (self) {
        req = self.requests[@(task.taskIdentifier)];
        [self.requests removeObjectForKey:@(task.taskIdentifier)];
    }
    if (!req) return;
    NSTimeInterval elapsed = monotonicNow() - req.startedAt;
    NSHTTPURLResponse *http = [task.response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)task.response : nil;
    if (self.onFinished) self.onFinished(req.path, req.attempt, elapsed, req.body, http, error);
}

@end

// ---

static void appendField(NSMutableData *body, NSString *boundary, NSString *name, NSString *value)
{
    NSString *part = [NSString stringWithFormat:
        @"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", boundary, name, value];
    [body appendData:[part dataUsingEncoding:NSUTF8StringEncoding]];
}

GroqTranscriber::GroqTranscriber()
{
    // Load API key from NSUserDefaults
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:kGroqAPIKeyDefault];
    if (key.length > 0) {
        m_apiKey = [key UTF8String];
    }

    // Delegate callbacks arrive on a background queue; everything is converted to plain
    // values and hopped to the main queue so the C++ side never touches ObjC objects
    // off-main.
    GroqSessionDelegate *delegate = [[GroqSessionDelegate alloc] init];
    delegate.onProgress = ^(NSString *path, NSString *status) {
        std::string p = cstr(path), s = cstr(status);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (onStatus) onStatus(p, s);
        });
    };
    delegate.onFinished = ^(NSString *path, int attempt, NSTimeInterval elapsed,
                            NSData *body, NSHTTPURLResponse *response, NSError *error) {
        std::string p = cstr(path);
        long errorCode = error ? (long)error.code : 0;
        std::string errorText = error ? cstr(error.localizedDescription) : "";
        long status = response ? (long)response.statusCode : 0;
        std::string responseBody = cstr([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]);
        dispatch_async(dispatch_get_main_queue(), ^{
            completeRequest(p, attempt, elapsed, errorCode, errorText, status, responseBody);
        });
    };

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = kIdleTimeout;
    config.timeoutIntervalForResource = kTotalTimeout;
    config.waitsForConnectivity = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                          delegate:delegate
                                                     delegateQueue:nil];

    m_delegate = (__bridge_retained void *)delegate;
    m_session = (__bridge_retained void *)session;
}

GroqTranscriber::~GroqTranscriber()
{
    if (m_delegate) {
        // The blocks capture `this`; drop them before the session is torn down.
        GroqSessionDelegate *delegate = (__bridge_transfer GroqSessionDelegate *)m_delegate;
        m_delegate = nullptr;
        delegate.onProgress = nil;
        delegate.onFinished = nil;
    }
    if (m_session) {
        NSURLSession *session = (__bridge_transfer NSURLSession *)m_session;
        m_session = nullptr;
        [session invalidateAndCancel];
    }
}

bool GroqTranscriber::isReady() const
{
    return !m_apiKey.empty();
}

void GroqTranscriber::transcribe(const std::string& audioFilePath)
{
    if (m_apiKey.empty()) {
        if (onTranscriptionError) onTranscriptionError(audioFilePath, "[groq_api_error] No Groq API key configured");
        return;
    }
    startRequest(audioFilePath, 1);
}

void GroqTranscriber::startRequest(const std::string& path, int attempt)
{
    NSString *nsPath = [NSString stringWithUTF8String:path.c_str()];
    NSData *audio = nsPath ? [NSData dataWithContentsOfFile:nsPath] : nil;
    if (audio.length == 0) {
        if (onTranscriptionError) onTranscriptionError(path, "[groq_api_error] Failed to read audio file");
        return;
    }

    NSString *ext = nsPath.pathExtension.lowercaseString;
    if (ext.length == 0) ext = @"wav";
    NSString *mime = @"application/octet-stream";
    if ([ext isEqualToString:@"flac"]) mime = @"audio/flac";
    else if ([ext isEqualToString:@"wav"]) mime = @"audio/wav";
    else if ([ext isEqualToString:@"m4a"]) mime = @"audio/mp4";

    // Build multipart form-data
    NSString *boundary = [[NSUUID UUID] UUIDString];
    NSMutableData *body = [NSMutableData dataWithCapacity:audio.length + 1024];
    NSString *fileHeader = [NSString stringWithFormat:
        @"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.%@\"\r\n"
        @"Content-Type: %@\r\n\r\n", boundary, ext, mime];
    [body appendData:[fileHeader dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:audio];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    appendField(body, boundary, @"model", kGroqModel);
    appendField(body, boundary, @"response_format", @"json");
    appendField(body, boundary, @"language", kGroqLanguage);
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary]
                      dataUsingEncoding:NSUTF8StringEncoding]];

    // Build request (body goes through uploadTask so didSendBodyData reports progress)
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kGroqEndpoint]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = kIdleTimeout;
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
   forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %s", m_apiKey.c_str()]
   forHTTPHeaderField:@"Authorization"];

    NSURLSession *session = (__bridge NSURLSession *)m_session;
    GroqSessionDelegate *delegate = (__bridge GroqSessionDelegate *)m_delegate;
    NSURLSessionUploadTask *task = [session uploadTaskWithRequest:request fromData:body];
    [delegate track:task path:nsPath attempt:attempt];

    NSLog(@"Groq request: %lu bytes (%@), attempt %d/%d, timeouts idle %.0fs total %.0fs",
          (unsigned long)body.length, ext, attempt, kMaxAttempts, kIdleTimeout, kTotalTimeout);
    if (onStatus) onStatus(path, attempt > 1 ? "Retrying upload" : "Uploading");
    [task resume];
}

void GroqTranscriber::completeRequest(const std::string& path, int attempt, double elapsed,
                                      long errorCode, const std::string& errorText,
                                      long httpStatus, const std::string& responseBody)
{
    if (errorCode != 0) {
        std::string msg;
        if (errorCode == NSURLErrorTimedOut) {
            msg = cstr([NSString stringWithFormat:@"[groq_network_error] Timed out after %.0fs", elapsed]);
        } else {
            msg = "[groq_network_error] " + errorText;
        }
        handleFailure(path, attempt, msg, errorCode != NSURLErrorCancelled);
        return;
    }

    if (httpStatus == 429) {
        handleFailure(path, attempt, "[groq_rate_limit] Rate limited by Groq API", true);
        return;
    }
    if (httpStatus >= 500) {
        handleFailure(path, attempt, "[groq_server_error] HTTP " + std::to_string(httpStatus) + ": " + responseBody, true);
        return;
    }
    if (httpStatus != 200) {
        handleFailure(path, attempt, "[groq_api_error] HTTP " + std::to_string(httpStatus) + ": " + responseBody, false);
        return;
    }

    // Parse JSON response
    NSData *data = [NSData dataWithBytes:responseBody.data() length:responseBody.size()];
    NSError *jsonErr = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
    NSString *text = [json isKindOfClass:[NSDictionary class]] ? json[@"text"] : nil;
    if (jsonErr || ![text isKindOfClass:[NSString class]]) {
        handleFailure(path, attempt, "[groq_api_error] Failed to parse response", false);
        return;
    }

    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSLog(@"Groq transcription result (%.1fs, attempt %d): %@", elapsed, attempt, trimmed);
    if (onTranscriptionComplete) onTranscriptionComplete(path, cstr(trimmed));
}

void GroqTranscriber::handleFailure(const std::string& path, int attempt, const std::string& error, bool retryable)
{
    if (retryable && attempt < kMaxAttempts) {
        NSLog(@"Groq attempt %d/%d failed: %s. Retrying in %.0fs", attempt, kMaxAttempts, error.c_str(), kRetryDelay);
        if (onStatus) onStatus(path, "Retrying");
        std::string p = path;
        int next = attempt + 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetryDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            startRequest(p, next);
        });
        return;
    }
    if (onTranscriptionError) onTranscriptionError(path, error);
}
