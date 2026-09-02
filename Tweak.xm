#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_var.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import <stdarg.h>
#import <unistd.h>
#import <objc/runtime.h>

static const NSInteger kNetSpeedLabelTag = 0x4E535053;
static NSObject *gLogLock;
static BOOL gDidLogRuntime;
static BOOL gDidLogAttach;
static BOOL gDidLogMissingForeground;
static BOOL gDidLogHierarchy;
static BOOL gDidLogStatusBarClasses;
static __weak UILabel *gNetSpeedLabel;
static dispatch_source_t gSampleTimer;
static dispatch_queue_t gSampleQueue;
static uint64_t gPreviousReceived, gPreviousSent, gPreviousTimestamp;
static double gSmoothedDownload, gSmoothedUpload;

static void NetSpeedLog(NSString *format, ...) {
	va_list arguments;
	va_start(arguments, format);
	NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);
	NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
	@synchronized (gLogLock) {
		NSString *path = @"/var/mobile/NetSpeedStatus.log";
		NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
		if (handle == nil) {
			[line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
		} else {
			[handle seekToEndOfFile];
			[handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
			[handle closeFile];
		}
	}
}

static uint64_t NetSpeedNow(void) {
	return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000000000.0);
}

static void NetSpeedReadCounters(uint64_t *received, uint64_t *sent) {
	*received = 0;
	*sent = 0;
	struct ifaddrs *interfaces = NULL;
	if (getifaddrs(&interfaces) != 0 || interfaces == NULL) return;

	NSMutableSet<NSString *> *countedInterfaces = [NSMutableSet set];
	for (struct ifaddrs *current = interfaces; current != NULL; current = current->ifa_next) {
		if (current->ifa_name == NULL || current->ifa_addr == NULL || current->ifa_data == NULL) continue;
		if ((current->ifa_flags & IFF_LOOPBACK) != 0) continue;
		NSString *name = [NSString stringWithUTF8String:current->ifa_name];
		if (!([name isEqualToString:@"en0"] || [name hasPrefix:@"pdp_ip"])) continue;
		if ([countedInterfaces containsObject:name]) continue;
		[countedInterfaces addObject:name];

		struct if_data *data = (struct if_data *)current->ifa_data;
		uint64_t rx = (uint64_t)data->ifi_ibytes, tx = (uint64_t)data->ifi_obytes;
		*received = UINT64_MAX - *received < rx ? UINT64_MAX : *received + rx;
		*sent = UINT64_MAX - *sent < tx ? UINT64_MAX : *sent + tx;
	}
	freeifaddrs(interfaces);
}

static NSString *NetSpeedFormat(double bytesPerSecond) {
	if (!isfinite(bytesPerSecond) || bytesPerSecond < 0.0) bytesPerSecond = 0.0;
	if (bytesPerSecond >= 1024.0 * 1024.0) return [NSString stringWithFormat:@"%.1fM/s", bytesPerSecond / (1024.0 * 1024.0)];
	if (bytesPerSecond >= 1024.0) return [NSString stringWithFormat:@"%.1fK/s", bytesPerSecond / 1024.0];
	return [NSString stringWithFormat:@"%.0fB/s", bytesPerSecond];
}

static UIView *NetSpeedFindForegroundView(UIView *root) {
	Class foregroundClass = NSClassFromString(@"_UIStatusBarForegroundView");
	if (foregroundClass != Nil && [root isKindOfClass:foregroundClass]) return root;
	for (UIView *subview in [root.subviews reverseObjectEnumerator]) {
		UIView *result = NetSpeedFindForegroundView(subview);
		if (result != nil) return result;
	}
	return nil;
}

static void NetSpeedLogViewTree(UIView *view, NSUInteger depth) {
	if (view == nil || depth > 3) return;
	NetSpeedLog(@"tree[%lu]: %@ frame=%@ bounds=%@ subviews=%lu", (unsigned long)depth, NSStringFromClass(view.class), NSStringFromCGRect(view.frame), NSStringFromCGRect(view.bounds), (unsigned long)view.subviews.count);
	for (UIView *subview in view.subviews) NetSpeedLogViewTree(subview, depth + 1);
}

static void NetSpeedLogObjectIvars(id object) {
	if (object == nil) return;
	for (Class cls = object_getClass(object); cls != Nil && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
		unsigned int count = 0;
		Ivar *ivars = class_copyIvarList(cls, &count);
		for (unsigned int index = 0; index < count; index++) {
			Ivar ivar = ivars[index];
			const char *type = ivar_getTypeEncoding(ivar);
			const char *name = ivar_getName(ivar);
			if (type != NULL && type[0] == '@') {
				id value = object_getIvar(object, ivar);
				NetSpeedLog(@"ivar: %@ %s=%@", NSStringFromClass(cls), name, value ? NSStringFromClass([value class]) : @"nil");
			} else {
				NetSpeedLog(@"ivar: %@ %s type=%s", NSStringFromClass(cls), name, type ?: "?");
			}
		}
		free(ivars);
	}
}

static void NetSpeedLogStatusBarHierarchy(UIView *statusBar) {
	if (gDidLogHierarchy || statusBar == nil) return;
	gDidLogHierarchy = YES;
	NetSpeedLog(@"hierarchy begin: object=%@ frame=%@ bounds=%@", NSStringFromClass(statusBar.class), NSStringFromCGRect(statusBar.frame), NSStringFromCGRect(statusBar.bounds));
	NetSpeedLogObjectIvars(statusBar);
	NetSpeedLogViewTree(statusBar, 0);
	UIResponder *responder = statusBar.nextResponder;
	for (NSUInteger index = 0; responder != nil && index < 8; index++) {
		NetSpeedLog(@"responder[%lu]: %@", (unsigned long)index, NSStringFromClass(responder.class));
		responder = responder.nextResponder;
	}
	NetSpeedLog(@"hierarchy end");
}

static void NetSpeedLayoutLabel(UIView *container, UILabel *label) {
	CGRect bounds = container.bounds;
	CGFloat width = MIN(190.0, MAX(150.0, bounds.size.width * 0.18));
	CGFloat height = MIN(20.0, MAX(17.0, bounds.size.height - 2.0));
	label.frame = CGRectMake((bounds.size.width - width) / 2.0, (bounds.size.height - height) / 2.0, width, height);
}

static void NetSpeedAttachToStatusBar(UIView *statusBar) {
	if (statusBar == nil) return;
	UIView *container = NetSpeedFindForegroundView(statusBar);
	// Some iPadOS builds do not expose the foreground container with the same
	// private class name. The native status-bar window is the safe fallback.
	if (container == nil) {
		if (!gDidLogMissingForeground) {
			NetSpeedLog(@"foreground view not found; statusBar=%@ bounds=%@ subviews=%lu", NSStringFromClass(statusBar.class), NSStringFromCGRect(statusBar.bounds), (unsigned long)statusBar.subviews.count);
			gDidLogMissingForeground = YES;
		}
		return;
	}
	UILabel *label = (UILabel *)[container viewWithTag:kNetSpeedLabelTag];
	if (label == nil) {
		label = [[UILabel alloc] initWithFrame:CGRectZero];
		label.tag = kNetSpeedLabelTag;
		label.font = [UIFont monospacedDigitSystemFontOfSize:9.0 weight:UIFontWeightMedium];
		label.textColor = UIColor.labelColor;
		label.textAlignment = NSTextAlignmentCenter;
		label.adjustsFontSizeToFitWidth = YES;
		label.minimumScaleFactor = 0.65;
		label.userInteractionEnabled = NO;
		label.text = @"↓ 0B/s  ↑ 0B/s";
		label.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
			UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
		[container addSubview:label];
	}
	gNetSpeedLabel = label;
	[container bringSubviewToFront:label];
	NetSpeedLayoutLabel(container, label);
	if (!gDidLogAttach) {
		NetSpeedLog(@"attached label: statusBar=%@ container=%@ bounds=%@ labelFrame=%@", NSStringFromClass(statusBar.class), NSStringFromClass(container.class), NSStringFromCGRect(container.bounds), NSStringFromCGRect(label.frame));
		gDidLogAttach = YES;
	}
}

static void NetSpeedLogRuntimeState(void) {
	if (gDidLogRuntime) return;
	gDidLogRuntime = YES;
	NetSpeedLog(@"runtime: pid=%d UIStatusBar_Modern=%@ UIStatusBarWindow=%@ _UIStatusBar=%@ UIStatusBar_Base=%@ _UIStatusBarForegroundView=%@", getpid(), NSClassFromString(@"UIStatusBar_Modern") ? @"YES" : @"NO", NSClassFromString(@"UIStatusBarWindow") ? @"YES" : @"NO", NSClassFromString(@"_UIStatusBar") ? @"YES" : @"NO", NSClassFromString(@"UIStatusBar_Base") ? @"YES" : @"NO", NSClassFromString(@"_UIStatusBarForegroundView") ? @"YES" : @"NO");
	if (!gDidLogStatusBarClasses) {
		gDidLogStatusBarClasses = YES;
		int classCount = objc_getClassList(NULL, 0);
		Class *classes = classCount > 0 ? (__unsafe_unretained Class *)calloc((size_t)classCount, sizeof(Class)) : NULL;
		if (classes != NULL) {
			objc_getClassList(classes, classCount);
			for (int index = 0; index < classCount; index++) {
				NSString *name = NSStringFromClass(classes[index]);
				if ([name rangeOfString:@"StatusBar" options:NSCaseInsensitiveSearch].location != NSNotFound) {
					NetSpeedLog(@"runtime class: %@", name);
				}
			}
			free(classes);
		}
	}
	// SpringBoard on iPadOS 18 can keep its system windows outside the scene
	// collection, so use KVC for UIApplication's private window list here.
	id windows = [UIApplication.sharedApplication valueForKey:@"windows"];
	NetSpeedLog(@"application windows=%@ count=%lu", NSStringFromClass([windows class]), (unsigned long)[windows count]);
	for (UIWindow *window in windows) {
		NetSpeedLog(@"window: class=%@ level=%.1f hidden=%@ bounds=%@ root=%@ subviews=%lu", NSStringFromClass(window.class), window.windowLevel, window.hidden ? @"YES" : @"NO", NSStringFromCGRect(window.bounds), NSStringFromClass(window.rootViewController.class), (unsigned long)window.subviews.count);
	}
}

static void NetSpeedStartSampling(void) {
	if (gSampleTimer != nil) return;
	gSampleQueue = dispatch_queue_create("com.example.netspeedstatus.sampling", DISPATCH_QUEUE_SERIAL);
	gSampleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gSampleQueue);
	dispatch_source_set_timer(gSampleTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(gSampleTimer, ^{
		uint64_t received = 0, sent = 0, now = NetSpeedNow();
		NetSpeedReadCounters(&received, &sent);
		if (gPreviousTimestamp != 0 && now > gPreviousTimestamp && received >= gPreviousReceived && sent >= gPreviousSent) {
			double interval = (double)(now - gPreviousTimestamp) / 1000000000.0;
			double download = (double)(received - gPreviousReceived) / interval;
			double upload = (double)(sent - gPreviousSent) / interval;
			gSmoothedDownload = gSmoothedDownload == 0.0 ? download : gSmoothedDownload * 0.7 + download * 0.3;
			gSmoothedUpload = gSmoothedUpload == 0.0 ? upload : gSmoothedUpload * 0.7 + upload * 0.3;
		}
		gPreviousReceived = received;
		gPreviousSent = sent;
		gPreviousTimestamp = now;
		NSString *text = [NSString stringWithFormat:@"↓ %@  ↑ %@", NetSpeedFormat(gSmoothedDownload), NetSpeedFormat(gSmoothedUpload)];
		dispatch_async(dispatch_get_main_queue(), ^{
			gNetSpeedLabel.text = text;
		});
	});
	dispatch_resume(gSampleTimer);
}

@interface UIStatusBar_Modern : UIWindow
@end

@interface UIStatusBarWindow : UIWindow
@end

@interface SBStatusBarWindow : UIWindow
@end

@interface _UIStatusBarForegroundView : UIView
@end

@interface _UIStatusBar : UIView
@end

@interface UIStatusBar_Base : UIView
@end

@interface UIWindow (NetSpeedStatusBarHook)
@end

%hook UIStatusBar_Modern

- (void)layoutSubviews {
	%orig;
	NetSpeedLogRuntimeState();
	NetSpeedLogStatusBarHierarchy(self);
	NetSpeedAttachToStatusBar(self);
}

%end

%hook UIStatusBarWindow

- (void)setStatusBar:(id)statusBar {
	%orig;
	NetSpeedLog(@"UIStatusBarWindow setStatusBar: %@", NSStringFromClass([statusBar class]));
	NetSpeedAttachToStatusBar((UIView *)statusBar);
}

- (void)layoutSubviews {
	%orig;
	NetSpeedLogRuntimeState();
	NetSpeedLogStatusBarHierarchy(self);
	NetSpeedAttachToStatusBar(self);
}

%end

%hook SBStatusBarWindow

- (void)layoutSubviews {
	%orig;
	NetSpeedLogRuntimeState();
	NetSpeedLogStatusBarHierarchy(self);
	NetSpeedAttachToStatusBar(self);
	// iPadOS creates the status-bar content asynchronously after the window
	// itself has laid out, so retry once after the current layout transaction.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
		NetSpeedLogStatusBarHierarchy(self);
		NetSpeedAttachToStatusBar(self);
	});
}

%end

%hook _UIStatusBarForegroundView

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachToStatusBar(self);
}

%end

%hook _UIStatusBar

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachToStatusBar(self);
}

%end

%hook UIStatusBar_Base

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachToStatusBar(self);
}

%end

// iPadOS 18 may use a private UIWindow subclass whose concrete name differs
// between builds. Discover it through the common UIWindow layout path.
%hook UIWindow

- (void)layoutSubviews {
	%orig;
	NSString *className = NSStringFromClass(self.class);
	if ([className rangeOfString:@"StatusBar" options:NSCaseInsensitiveSearch].location != NSNotFound) {
		NetSpeedAttachToStatusBar(self);
	}
}

%end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application {
	%orig;
	NetSpeedLog(@"SpringBoard launched; bundle=%@", NSBundle.mainBundle.bundleIdentifier);
	NetSpeedStartSampling();
}

%end

%ctor {
	gLogLock = [NSObject new];
	NetSpeedLog(@"loaded; bundle=%@", NSBundle.mainBundle.bundleIdentifier);
}
