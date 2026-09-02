#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_var.h>
#import <dispatch/dispatch.h>
#import <math.h>

static __weak UILabel *gNetSpeedLabel;
static dispatch_source_t gSampleTimer;
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
		uint64_t rx = (uint64_t)data->ifi_ibytes;
		uint64_t tx = (uint64_t)data->ifi_obytes;
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

static void NetSpeedLayoutLabel(UIView *container, UILabel *label) {
	CGRect bounds = container.bounds;
	CGFloat width = MIN(190.0, MAX(150.0, bounds.size.width * 0.18));
	CGFloat height = MIN(20.0, MAX(17.0, bounds.size.height - 2.0));
	label.frame = CGRectMake(MAX(4.0, bounds.size.width - width - 8.0), (bounds.size.height - height) / 2.0, width, height);
}

static void NetSpeedAttachLabel(UIView *container) {
	if (container == nil || container.bounds.size.width <= 0.0 || container.bounds.size.height <= 0.0) return;
	UILabel *label = (UILabel *)[container viewWithTag:0x4E535053];
	if (label == nil) {
		label = [[UILabel alloc] initWithFrame:CGRectZero];
		label.tag = 0x4E535053;
		label.font = [UIFont monospacedDigitSystemFontOfSize:9.0 weight:UIFontWeightMedium];
		label.textColor = UIColor.labelColor;
		label.textAlignment = NSTextAlignmentRight;
		label.adjustsFontSizeToFitWidth = YES;
		label.minimumScaleFactor = 0.65;
		label.userInteractionEnabled = NO;
		label.hidden = YES;
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
	dispatch_queue_t queue = dispatch_queue_create("com.example.netspeedstatus.sampling", DISPATCH_QUEUE_SERIAL);
	gSampleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
	dispatch_source_set_timer(gSampleTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
	dispatch_source_set_event_handler(gSampleTimer, ^{
		uint64_t received = 0, sent = 0, now = NetSpeedNow();
		double currentDownload = 0.0, currentUpload = 0.0;
		NetSpeedReadCounters(&received, &sent);
		if (gPreviousTimestamp != 0 && now > gPreviousTimestamp && received >= gPreviousReceived && sent >= gPreviousSent) {
			double interval = (double)(now - gPreviousTimestamp) / 1000000000.0;
			currentDownload = (double)(received - gPreviousReceived) / interval;
			currentUpload = (double)(sent - gPreviousSent) / interval;
			gSmoothedDownload = gSmoothedDownload == 0.0 ? currentDownload : gSmoothedDownload * 0.7 + currentDownload * 0.3;
			gSmoothedUpload = gSmoothedUpload == 0.0 ? currentUpload : gSmoothedUpload * 0.7 + currentUpload * 0.3;
		}
		gPreviousReceived = received;
		gPreviousSent = sent;
		gPreviousTimestamp = now;

		NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:2];
		if (currentDownload > 0.0) [parts addObject:[NSString stringWithFormat:@"↓ %@", NetSpeedFormat(gSmoothedDownload)]];
		if (currentUpload > 0.0) [parts addObject:[NSString stringWithFormat:@"↑ %@", NetSpeedFormat(gSmoothedUpload)]];
		NSString *text = [parts componentsJoinedByString:@"  "];
		dispatch_async(dispatch_get_main_queue(), ^{
			gNetSpeedLabel.hidden = parts.count == 0;
			if (parts.count > 0) gNetSpeedLabel.text = text;
		});
	});
	dispatch_resume(gSampleTimer);
}

@interface STUIStatusBarForegroundView : UIView
@end

@interface UIStatusBarForegroundView : UIView
@end

@interface _UIStatusBarForegroundView : UIView
@end

%group NetSpeedSTUIStatusBar

%hook STUIStatusBarForegroundView

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachLabel(self);
}

%end

%end

%group NetSpeedUIStatusBar

%hook UIStatusBarForegroundView

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachLabel(self);
}

%end

%end

%group NetSpeedUnderscoreStatusBar

%hook _UIStatusBarForegroundView

- (void)layoutSubviews {
	%orig;
	NetSpeedAttachLabel(self);
}

%end

%end

%group NetSpeedCore

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application {
	%orig;
	NetSpeedStartSampling();
}

%end

%end

%ctor {
	%init(NetSpeedCore);
	if (NSClassFromString(@"STUIStatusBarForegroundView") != Nil) %init(NetSpeedSTUIStatusBar);
	if (NSClassFromString(@"UIStatusBarForegroundView") != Nil) %init(NetSpeedUIStatusBar);
	if (NSClassFromString(@"_UIStatusBarForegroundView") != Nil) %init(NetSpeedUnderscoreStatusBar);
}
