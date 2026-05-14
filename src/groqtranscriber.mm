#include "groqtranscriber.h"
#import <Foundation/Foundation.h>

static NSString *const kGroqAPIKeyDefault = @"GroqAPIKey";
static NSString *const kGroqEndpoint = @"https://api.groq.com/openai/v1/audio/transcriptions";

GroqTranscriber::GroqTranscriber()
{
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    m_session = (__bridge_retained void *)session;

    // Load API key from NSUserDefaults
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:kGroqAPIKeyDefault];
    if (key.length > 0) {
        m_apiKey = [key UTF8String];
    }
}

GroqTranscriber::~GroqTranscriber()
{
    if (m_session) {
        NSURLSession *session = (__bridge_transfer NSURLSession *)m_session;
        [session invalidateAndCancel];
        m_session = nullptr;
    }
}

bool GroqTranscriber::isReady() const
{
    return !m_apiKey.empty();
}

void GroqTranscriber::transcribe(const std::string& wavFilePath)
{
    if (m_apiKey.empty()) {
        if (onTranscriptionError) onTranscriptionError(wavFilePath, "No Groq API key configured");
        return;
    }

    NSString *nsPath = [NSString stringWithUTF8String:wavFilePath.c_str()];
    NSData *wavData = [NSData dataWithContentsOfFile:nsPath];
    if (!wavData || wavData.length == 0) {
        if (onTranscriptionError) onTranscriptionError(wavFilePath, "Failed to read WAV file");
        return;
    }

    // Build multipart form-data
    NSString *boundary = [[NSUUID UUID] UUIDString];
    NSMutableData *body = [NSMutableData data];

    // "file" field
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary]
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n"
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Type: audio/wav\r\n\r\n"
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:wavData];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // "model" field
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary]
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"model\"\r\n\r\n"
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"whisper-large-v3\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // "response_format" field
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary]
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"response_format\"\r\n\r\n"
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"json\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // "language" field
    [body appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary]
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"Content-Disposition: form-data; name=\"language\"\r\n\r\n"
                      dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:[@"vi\r\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // Closing boundary
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary]
                      dataUsingEncoding:NSUTF8StringEncoding]];

    // Build request
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kGroqEndpoint]];
    request.HTTPMethod = @"POST";
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
   forHTTPHeaderField:@"Content-Type"];
    NSString *apiKey = [NSString stringWithUTF8String:m_apiKey.c_str()];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
   forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = body;

    std::string wavPath = wavFilePath;  // capture per-request so concurrent calls don't collide

    NSURLSession *session = (__bridge NSURLSession *)m_session;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                NSString *errMsg = [NSString stringWithFormat:@"[groq_network_error] %@",
                                    error.localizedDescription];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (onTranscriptionError) onTranscriptionError(wavPath, [errMsg UTF8String]);
                });
                return;
            }

            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            if (httpResp.statusCode == 429) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (onTranscriptionError) onTranscriptionError(wavPath, "[groq_rate_limit] Rate limited by Groq API");
                });
                return;
            }

            if (httpResp.statusCode != 200) {
                NSString *bodyStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
                NSString *errMsg = [NSString stringWithFormat:@"[groq_api_error] HTTP %ld: %@",
                                    (long)httpResp.statusCode, bodyStr];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (onTranscriptionError) onTranscriptionError(wavPath, [errMsg UTF8String]);
                });
                return;
            }

            // Parse JSON response
            NSError *jsonErr = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (jsonErr || !json[@"text"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (onTranscriptionError) onTranscriptionError(wavPath, "[groq_api_error] Failed to parse response");
                });
                return;
            }

            NSString *text = json[@"text"];
            NSString *trimmed = [text stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            std::string result = [trimmed UTF8String];
            NSLog(@"Groq transcription result: %s", result.c_str());

            dispatch_async(dispatch_get_main_queue(), ^{
                if (onTranscriptionComplete) onTranscriptionComplete(wavPath, result);
            });
        }];

    [task resume];
}
