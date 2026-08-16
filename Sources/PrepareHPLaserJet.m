#import <Cocoa/Cocoa.h>

static NSString *const QueueName = @"HP_LaserJet_1020";
static NSString *const PrinterProductName = @"HP LaserJet 1020";
static NSString *const FirmwarePath = @"/usr/local/share/foo2zjs/firmware/sihp1020.dl";

@interface CommandResult : NSObject
@property(nonatomic) int status;
@property(nonatomic, copy) NSString *output;
@end

@implementation CommandResult
@end

static CommandResult *RunCommand(NSString *executable, NSArray<NSString *> *arguments) {
    CommandResult *result = [CommandResult new];
    NSTask *task = [NSTask new];
    NSPipe *pipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        result.status = -1;
        result.output = error.localizedDescription ?: @"Unknown command error";
        return result;
    }

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    result.status = task.terminationStatus;
    result.output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return result;
}

static void ShowAlert(NSString *title, NSString *message, NSAlertStyle style) {
    [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApplication.sharedApplication activateIgnoringOtherApps:YES];

    NSAlert *alert = [NSAlert new];
    alert.alertStyle = style;
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

static BOOL PrinterIsConnected(void) {
    CommandResult *result = RunCommand(@"/usr/sbin/ioreg", @[@"-p", @"IOUSB", @"-l", @"-w0"]);
    NSString *needle = [NSString stringWithFormat:@"\"USB Product Name\" = \"%@\"", PrinterProductName];
    return result.status == 0 && [result.output containsString:needle];
}

static BOOL QueueExists(void) {
    return RunCommand(@"/usr/bin/lpstat", @[@"-p", QueueName]).status == 0;
}

static NSString *ReadinessProblem(void) {
    if (!PrinterIsConnected()) {
        return @"Switch on the printer, connect its USB cable, wait a few seconds, and open this app again.";
    }
    if (!QueueExists()) {
        return @"The HP_LaserJet_1020 printer queue is not configured. Add it in System Settings → Printers & Scanners, then try again.";
    }
    if (![NSFileManager.defaultManager isReadableFileAtPath:FirmwarePath]) {
        return @"The LaserJet 1020 firmware file is missing. Reinstall the printer driver before trying again.";
    }
    return nil;
}

static NSString *ExtractJobID(NSString *submission) {
    NSString *marker = @"request id is ";
    NSRange markerRange = [submission rangeOfString:marker];
    if (markerRange.location == NSNotFound) return nil;

    NSString *remaining = [submission substringFromIndex:NSMaxRange(markerRange)];
    NSArray<NSString *> *parts = [remaining componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *part in parts) {
        if (part.length > 0) return part;
    }
    return nil;
}

static void PreparePrinter(void) {
    NSString *problem = ReadinessProblem();
    if (problem) {
        ShowAlert(@"HP LaserJet 1020 is not ready", problem, NSAlertStyleWarning);
        return;
    }

    CommandResult *submission = RunCommand(@"/usr/bin/lp", @[@"-d", QueueName, @"-o", @"raw", FirmwarePath]);
    if (submission.status != 0) {
        NSString *message = [submission.output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        ShowAlert(@"Firmware upload could not start", message, NSAlertStyleCritical);
        return;
    }

    NSString *jobID = ExtractJobID(submission.output);
    if (!jobID) {
        ShowAlert(@"Printer preparation started", @"Firmware was submitted. Wait a few seconds, then print normally.", NSAlertStyleInformational);
        return;
    }

    for (NSInteger attempt = 0; attempt < 30; attempt++) {
        [NSThread sleepForTimeInterval:1.0];
        CommandResult *pending = RunCommand(@"/usr/bin/lpstat", @[@"-W", @"not-completed", @"-o", QueueName]);
        if (![pending.output containsString:jobID]) {
            ShowAlert(@"Printer ready", @"Firmware was loaded successfully. Your HP LaserJet 1020 is ready to print.", NSAlertStyleInformational);
            return;
        }
    }

    ShowAlert(
        @"Firmware upload is taking longer than expected",
        @"The job was accepted but did not complete within 30 seconds. Check that the printer is switched on and connected.",
        NSAlertStyleWarning
    );
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
            NSString *problem = ReadinessProblem();
            if (problem) {
                fprintf(stderr, "Self-test failed: %s\n", problem.UTF8String);
                return 1;
            }
            printf("Self-test passed: USB printer, CUPS queue, and firmware file are ready.\n");
            return 0;
        }

        [NSApplication sharedApplication];
        PreparePrinter();
    }
    return 0;
}
