#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_var.h>
#import <dispatch/dispatch.h>
#import <math.h>

static const NSInteger kNetSpeedLabelTag = 0x4E535053;
static __weak UILabel *gNetSpeedLabel;
static dispatch_source_t gSampleTimer;
static dispatch_queue_t gSampleQueue;
static uint64_t gPreviousReceived, gPreviousSent, gPreviousTimestamp;
static double gSmoothedDownload, gSmoothedUpload;

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
	if (container == nil) container = statusBar;
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

@interface _UIStatusBarForegroundView : UIView
@end

%hook UIStatusBar_Modern

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachToStatusBar(self);
}

%end

%hook UIStatusBarWindow

- (void)setStatusBar:(id)statusBar {
	%orig;
	NetSpeedAttachToStatusBar((UIView *)statusBar);
}

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachToStatusBar(self);
}

%end

%hook _UIStatusBarForegroundView

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachToStatusBar(self);
}

%end

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application {
	%orig;
	NetSpeedStartSampling();
}

%end
