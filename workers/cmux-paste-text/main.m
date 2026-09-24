#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString * const kWorkerMode = @"--cmux-plain-text-paste-worker";
static NSString * const kWorkingDirectoryArgument = @"--cmux-paste-preparation-working-directory";
static NSString * const kWorkingDirectoryPrefix = @"cmux-paste-preparation-";
static NSString * const kRequestFilename = @"request.json";
static NSString * const kResponseFilename = @"response.json";
static NSString * const kPayloadFilename = @"text-payload.txt";
static NSString * const kUTF8PlainTextType = @"public.utf8-plain-text";
static const NSUInteger kMaximumTextByteCount = 16 * 1024 * 1024;
static const int kIneligibleStatus = 73;
// Retained for this one-shot process. The parent owns reaping; neither source
// closes stdin before process exit. Supervision must run while a provider blocks.
static dispatch_source_t gParentSource;
static dispatch_source_t gDeadlineSource;

static NSString *workingDirectoryPath(NSArray<NSString *> *arguments) {
    NSUInteger index = [arguments indexOfObject:kWorkingDirectoryArgument];
    if (index == NSNotFound || index + 1 >= arguments.count) {
        return nil;
    }
    return [arguments[index + 1] stringByStandardizingPath];
}

static BOOL isSafeWorkingDirectory(NSString *path) {
    NSString *temporaryDirectory = [NSTemporaryDirectory() stringByStandardizingPath];
    NSString *parent = [path stringByDeletingLastPathComponent];
    NSString *name = [path lastPathComponent];
    if (![path hasPrefix:@"/"] || ![parent isEqualToString:temporaryDirectory] ||
        ![name hasPrefix:kWorkingDirectoryPrefix]) {
        return NO;
    }

    NSString *identifier = [name substringFromIndex:kWorkingDirectoryPrefix.length];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    BOOL isDirectory = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];
    struct stat metadata = {0};
    BOOL isSymlink = lstat(path.fileSystemRepresentation, &metadata) == 0 && S_ISLNK(metadata.st_mode);
    return uuid != nil && exists && isDirectory && !isSymlink &&
        metadata.st_uid == getuid() && (metadata.st_mode & 0777) == 0700;
}

static void terminateWorker(NSString *workingDirectory, int status) {
    [[NSFileManager defaultManager] removeItemAtPath:workingDirectory error:nil];
    _exit(status);
}

static void installSupervisor(NSString *workingDirectory) {
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    gParentSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ,
        STDIN_FILENO,
        0,
        queue
    );
    if (gParentSource == nil) {
        terminateWorker(workingDirectory, 71);
    }
    dispatch_source_set_event_handler(gParentSource, ^{
        char byte = 0;
        ssize_t count = read(STDIN_FILENO, &byte, sizeof(byte));
        if (count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) {
            terminateWorker(workingDirectory, 125);
        }
    });
    dispatch_resume(gParentSource);

    gDeadlineSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        queue
    );
    if (gDeadlineSource == nil) {
        terminateWorker(workingDirectory, 71);
    }
    dispatch_source_set_timer(
        gDeadlineSource,
        dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
        DISPATCH_TIME_FOREVER,
        100 * NSEC_PER_MSEC
    );
    dispatch_source_set_event_handler(gDeadlineSource, ^{
        terminateWorker(workingDirectory, 124);
    });
    dispatch_resume(gDeadlineSource);
}

static BOOL isImageType(NSString *typeIdentifier) {
    if ([typeIdentifier isEqualToString:NSPasteboardTypeTIFF] ||
        [typeIdentifier isEqualToString:NSPasteboardTypePNG]) {
        return YES;
    }
    UTType *type = [UTType typeWithIdentifier:typeIdentifier];
    return type != nil && [type conformsToType:UTTypeImage];
}

static BOOL isPlainTextType(NSString *typeIdentifier) {
    if ([typeIdentifier isEqualToString:NSPasteboardTypeString] ||
        [typeIdentifier isEqualToString:kUTF8PlainTextType]) {
        return YES;
    }
    if ([typeIdentifier isEqualToString:NSPasteboardTypeHTML] ||
        [typeIdentifier isEqualToString:NSPasteboardTypeRTF] ||
        [typeIdentifier isEqualToString:NSPasteboardTypeRTFD] ||
        [typeIdentifier isEqualToString:NSPasteboardTypeFileURL] ||
        [typeIdentifier isEqualToString:NSPasteboardTypeURL] ||
        isImageType(typeIdentifier)) {
        return NO;
    }
    UTType *type = [UTType typeWithIdentifier:typeIdentifier];
    return type != nil && [type conformsToType:UTTypePlainText];
}

static BOOL hasDisallowedType(NSString *typeIdentifier) {
    if ([typeIdentifier isEqualToString:NSPasteboardTypeFileURL] ||
        [typeIdentifier isEqualToString:NSPasteboardTypeURL] ||
        [typeIdentifier isEqualToString:@"NSFilenamesPboardType"] ||
        [typeIdentifier isEqualToString:@"com.apple.pasteboard.promised-file-url"] ||
        isImageType(typeIdentifier)) {
        return YES;
    }
    return NO;
}

// Emit the same Codable envelope as TerminalPastePreparationWorker. Both
// workers use the existing validator, byte cap and file-ownership boundary.
static void writeResponse(NSString *workingDirectory, BOOL hasText) {
    NSDictionary *response = hasText ? @{
        @"textPayload": @{
            @"destination": @{ @"terminal": @{} },
            @"filename": kPayloadFilename
        },
        @"ownedTemporaryImageNames": @[]
    } : @{
        @"result": @{ @"terminal": @{ @"_0": @{ @"reject": @{} } } },
        @"ownedTemporaryImageNames": @[]
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    if (data == nil) {
        terminateWorker(workingDirectory, 74);
    }
    NSString *path = [workingDirectory stringByAppendingPathComponent:kResponseFilename];
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil] || chmod(path.fileSystemRepresentation, 0600) != 0) {
        terminateWorker(workingDirectory, 74);
    }
}

static int runWorker(NSArray<NSString *> *arguments) {
    NSString *workingDirectory = workingDirectoryPath(arguments);
    if (workingDirectory == nil || !isSafeWorkingDirectory(workingDirectory)) {
        return 64;
    }
    installSupervisor(workingDirectory);

    NSString *requestPath = [workingDirectory stringByAppendingPathComponent:kRequestFilename];
    NSData *requestData = [NSData dataWithContentsOfFile:requestPath options:NSDataReadingMappedIfSafe error:nil];
    NSDictionary *request = requestData == nil ? nil : [NSJSONSerialization JSONObjectWithData:requestData options:0 error:nil];
    NSDictionary *pasteboardRequest = [request isKindOfClass:NSDictionary.class] ? request[@"pasteboard"] : nil;
    NSString *pasteboardName = [pasteboardRequest isKindOfClass:NSDictionary.class] ? pasteboardRequest[@"pasteboardName"] : nil;
    NSNumber *expectedChangeCount = [pasteboardRequest isKindOfClass:NSDictionary.class] ? pasteboardRequest[@"changeCount"] : nil;
    if (![pasteboardName isKindOfClass:NSString.class] || ![expectedChangeCount isKindOfClass:NSNumber.class]) {
        return 65;
    }

    if (![request[@"mode"] isKindOfClass:NSDictionary.class] ||
        request[@"mode"][@"paste"] == nil ||
        ![request[@"destination"] isKindOfClass:NSDictionary.class] ||
        request[@"destination"][@"terminal"] == nil ||
        request[@"snapshotMaximumByteCount"] != nil) {
        return kIneligibleStatus;
    }

    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithName:pasteboardName];
    if (pasteboard == nil || pasteboard.changeCount != expectedChangeCount.integerValue) {
        writeResponse(workingDirectory, NO);
        return 0;
    }

    NSArray<NSPasteboardType> *types = pasteboard.types ?: @[];
    BOOL hasPlainText = NO;
    BOOL hasDisallowedPayload = NO;
    for (NSPasteboardType type in types) {
        hasPlainText = hasPlainText || isPlainTextType(type);
        hasDisallowedPayload = hasDisallowedPayload || hasDisallowedType(type);
    }
    if (!hasPlainText || hasDisallowedPayload) {
        return kIneligibleStatus;
    }

    NSMutableArray<NSPasteboardType> *preferredTypes = [NSMutableArray arrayWithObject:kUTF8PlainTextType];
    if (![preferredTypes containsObject:NSPasteboardTypeString]) {
        [preferredTypes addObject:NSPasteboardTypeString];
    }
    [preferredTypes addObjectsFromArray:types];
    NSString *text = nil;
    for (NSPasteboardType type in preferredTypes) {
        if (![types containsObject:type] || !isPlainTextType(type)) {
            continue;
        }
        NSString *candidate = [pasteboard stringForType:type];
        if (candidate.length > 0) {
            text = candidate;
            break;
        }
    }
    if (pasteboard.changeCount != expectedChangeCount.integerValue) {
        writeResponse(workingDirectory, NO);
        return 0;
    }
    if (text == nil) {
        writeResponse(workingDirectory, NO);
        return 0;
    }

    NSData *payload = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (payload == nil || payload.length > kMaximumTextByteCount) {
        return 74;
    }
    NSString *payloadPath = [workingDirectory stringByAppendingPathComponent:kPayloadFilename];
    if (![payload writeToFile:payloadPath options:NSDataWritingAtomic error:nil] || chmod(payloadPath.fileSystemRepresentation, 0600) != 0) {
        return 74;
    }
    writeResponse(workingDirectory, YES);
    return 0;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithCapacity:(NSUInteger)argc];
        for (int index = 0; index < argc; index++) {
            [arguments addObject:[NSString stringWithUTF8String:argv[index]] ?: @""];
        }
        if (![arguments containsObject:kWorkerMode]) {
            return 64;
        }
        return runWorker(arguments);
    }
}
