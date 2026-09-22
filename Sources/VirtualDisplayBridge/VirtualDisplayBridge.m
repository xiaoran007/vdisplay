#import "VirtualDisplayBridge.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <stdio.h>

// Private interface declarations informed by Chromium and DeskPad.
// Pinned revisions and licenses: THIRD_PARTY_NOTICES.md.
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int serialNumber;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(nonatomic, readonly) unsigned int displayID;
@end

static void Fail(char *error, size_t capacity, NSString *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message.UTF8String);
}

bool VDCheckAPI(char *error, size_t capacity) {
    NSDictionary<NSString *, NSArray<NSString *> *> *requirements = @{
        @"CGVirtualDisplayDescriptor": @[@"init", @"setQueue:", @"setName:", @"setMaxPixelsWide:",
            @"setMaxPixelsHigh:", @"setSizeInMillimeters:", @"setVendorID:", @"setProductID:",
            @"setSerialNum:", @"setRedPrimary:", @"setGreenPrimary:", @"setBluePrimary:", @"setWhitePoint:"],
        @"CGVirtualDisplaySettings": @[@"init", @"setModes:", @"setHiDPI:"],
        @"CGVirtualDisplayMode": @[@"initWithWidth:height:refreshRate:"],
        @"CGVirtualDisplay": @[@"initWithDescriptor:", @"applySettings:", @"displayID"]
    };
    for (NSString *name in requirements) {
        Class cls = NSClassFromString(name);
        if (!cls) { Fail(error, capacity, [@"Missing private API class: " stringByAppendingString:name]); return false; }
        for (NSString *selector in requirements[name]) {
            if (![cls instancesRespondToSelector:NSSelectorFromString(selector)]) {
                Fail(error, capacity, [NSString stringWithFormat:@"Missing private API: %@ %@", name, selector]);
                return false;
            }
        }
    }
    return true;
}

void *VDCreate(CFStringRef name, uint32_t width, uint32_t height, uint32_t scale,
               double refresh, uint32_t serial, char *error, size_t capacity) {
    @autoreleasepool {
    if (!VDCheckAPI(error, capacity)) return NULL;
    if (!name || !width || !height || (scale != 1 && scale != 2) || width % scale || height % scale
        || refresh != 60 || !serial) {
        Fail(error, capacity, @"Invalid display configuration."); return NULL;
    }
    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    descriptor.name = (__bridge NSString *)name;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / (96.0 * scale), height * 25.4 / (96.0 * scale));
    descriptor.vendorID = 0x7664;
    descriptor.productID = 1;
    descriptor.serialNum = serial;
    // Newer OS versions expose a second serial property; keep both consistent.
    if ([descriptor respondsToSelector:@selector(setSerialNumber:)]) descriptor.serialNumber = serial;
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display) { Fail(error, capacity, @"CGVirtualDisplay rejected the descriptor."); return NULL; }
    CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:width / scale height:height / scale refreshRate:refresh];
    if (!mode) { Fail(error, capacity, @"CGVirtualDisplayMode rejected the mode."); return NULL; }
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = scale == 2;
    settings.modes = @[mode];
    if (![display applySettings:settings] || !display.displayID) {
        Fail(error, capacity, @"CGVirtualDisplay failed to apply settings."); return NULL;
    }
    return (__bridge_retained void *)display;
    }
}
uint32_t VDDisplayID(void *handle) { return [(__bridge CGVirtualDisplay *)handle displayID]; }
void VDRelease(void *handle) {
    @autoreleasepool {
        if (handle) CFRelease(handle);
    }
}
