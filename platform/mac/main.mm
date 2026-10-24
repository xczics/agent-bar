// agent-bar for macOS: a non-activating, always-on-top NSPanel listing Claude
// Code sessions from ~/.claude/agent-status. All logic lives in core/; this
// file only does windowing, drawing, FSEvents and process launching.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <CoreServices/CoreServices.h>
#include <mach-o/dyld.h>
#include <sys/file.h>
#include <unistd.h>

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <sys/wait.h>

#include "agentbar/adapter.hpp"
#include "agentbar/config.hpp"
#include "agentbar/placement.hpp"
#include "agentbar/settings.hpp"
#include "agentbar/status.hpp"
#include "agentbar/store.hpp"

using namespace agentbar;

static NSString* const kActivateNotification = @"dev.agentbar.activate";
static NSString* const kLaunchAgentLabel = @"dev.agentbar.agent-bar";

static const CGFloat kWidth = 300;
static const CGFloat kTitleHeight = 30;
static const CGFloat kRowHeight = 42;
static const CGFloat kBottomPad = 6;
static const CGFloat kRadius = 10;
static const CGFloat kInset = 12;

// Compact (lights) view
static const CGFloat kLight = 14;
static const CGFloat kLightGap = 10;
static const CGFloat kCompactPad = 10;
static const CGFloat kTagHeight = 11;         // short name / status text line
static const CGFloat kTagCellWidth = 36;      // cell width when tags are shown
static const CGFloat kExpandButtonWidth = 16;

static const NSTimeInterval kDebounce = 0.1;
static const NSTimeInterval kTickInterval = 5;
static const NSTimeInterval kCleanupInterval = 600;

// ---------------------------------------------------------------- helpers

static NSColor* RGB(uint32_t c, CGFloat alpha = 1.0) {
  return [NSColor colorWithSRGBRed:((c >> 16) & 0xff) / 255.0
                             green:((c >> 8) & 0xff) / 255.0
                              blue:(c & 0xff) / 255.0
                             alpha:alpha];
}

// Text in a state colour: dark colours (e.g. the "off" green of idle) are
// lifted toward white so the label stays readable on the dark background.
static NSColor* TextColor(NSColor* c) {
  NSColor* rgb = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!rgb) return c;
  const CGFloat lum = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent;
  return lum < 0.45 ? [rgb blendedColorWithFraction:(0.45 - lum) / 0.45 * 0.6 ofColor:NSColor.whiteColor] : rgb;
}

// "Codex · " style prefix for sessions of agents other than Claude Code.
static std::string AgentPrefix(const Session& s) {
  if (s.agent.empty() || s.agent == kDefaultAdapter) return "";
  const Adapter* a = find_adapter(s.agent);
  return std::string(a ? a->display_name : s.agent.c_str()) + " · ";
}

static NSString* NS(const std::string& s) {
  NSString* r = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
  return r ? r : @"";
}

static std::string ExecutablePath() {
  char buf[PATH_MAX];
  uint32_t size = sizeof buf;
  if (_NSGetExecutablePath(buf, &size) != 0) return "";
  char real[PATH_MAX];
  return realpath(buf, real) ? std::string(real) : std::string(buf);
}

// AGENT_STATUS_DEBUG=1 appends timing lines to agent-status/bar.log.
static void DebugLog(const std::string& dir, const char* what) {
  static const bool enabled = [] {
    const char* v = std::getenv("AGENT_STATUS_DEBUG");
    return v && std::strcmp(v, "1") == 0;
  }();
  if (!enabled) return;
  if (FILE* f = std::fopen((dir + "/bar.log").c_str(), "a")) {
    std::fprintf(f, "%.3f %s\n", store::now_seconds(), what);
    std::fclose(f);
  }
}

static NSString* LaunchAgentPath() {
  return [NSHomeDirectory() stringByAppendingFormat:@"/Library/LaunchAgents/%@.plist", kLaunchAgentLabel];
}

static bool AutostartEnabled() {
  return [[NSFileManager defaultManager] fileExistsAtPath:LaunchAgentPath()];
}

// Login item via a per-user LaunchAgent; takes effect at next login.
static bool SetAutostart(bool on) {
  NSString* path = LaunchAgentPath();
  if (!on) {
    NSError* err = nil;
    return ![[NSFileManager defaultManager] fileExistsAtPath:path] ||
           [[NSFileManager defaultManager] removeItemAtPath:path error:&err];
  }
  [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  NSDictionary* plist = @{
    @"Label" : kLaunchAgentLabel,
    @"ProgramArguments" : @[ NS(ExecutablePath()) ],
    @"RunAtLoad" : @YES,
    @"ProcessType" : @"Interactive",
    @"LimitLoadToSessionType" : @"Aqua",
  };
  return [plist writeToURL:[NSURL fileURLWithPath:path] error:nil];
}

// Finds the VS Code CLI. GUI/launchd processes get a minimal PATH, so also
// try the usual install locations.
static NSString* FindCodeCLI() {
  NSMutableArray<NSString*>* candidates = [NSMutableArray array];
  NSString* path = NSProcessInfo.processInfo.environment[@"PATH"];
  if (!path) path = @"";
  for (NSString* dir in [path componentsSeparatedByString:@":"]) {
    if (dir.length) [candidates addObject:[dir stringByAppendingPathComponent:@"code"]];
  }
  [candidates addObjectsFromArray:@[
    @"/usr/local/bin/code", @"/opt/homebrew/bin/code",
    @"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
    [NSHomeDirectory() stringByAppendingPathComponent:
                           @"Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"],
  ]];
  for (NSString* c in candidates) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:c]) return c;
  }
  return nil;
}

// Runs `code <cwd>` with an argument array (no shell); falls back to
// `open -b com.microsoft.VSCode <cwd>` when the CLI is not installed.
static void OpenInVSCode(const std::string& cwd) {
  if (cwd.empty()) return;
  NSString* dir = NS(cwd);
  BOOL isDir = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return;
  NSTask* task = [[NSTask alloc] init];
  if (NSString* code = FindCodeCLI()) {
    task.executableURL = [NSURL fileURLWithPath:code];
    task.arguments = @[ dir ];
  } else {
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = @[ @"-b", @"com.microsoft.VSCode", dir ];
  }
  task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
  task.standardError = [NSFileHandle fileHandleWithNullDevice];
  [task launchAndReturnError:nil];
}

// ---------------------------------------------------------------- model

@class BarView;

@interface BarController : NSObject <NSMenuDelegate>
- (instancetype)initWithDir:(std::string)dir;
- (void)start;
- (BOOL)snapshotTo:(NSString*)path compact:(BOOL)compact;
- (BOOL)snapshotMenuBarTo:(NSString*)path;
- (void)bringToFront;
- (const std::vector<Session>&)sessions;
- (const BarConfig&)config;
- (BOOL)showsCompact;
- (void)clickedRow:(NSInteger)row clickCount:(NSInteger)count;
- (void)clickedLight:(NSInteger)index;
- (void)setExpanded:(BOOL)expanded;
- (void)windowDragged;
- (NSMenu*)contextMenu;
- (void)updateConfig:(void (^)(BarConfig& c))fn;
@end

@interface BarController (Settings)
// Implemented after SettingsController.
- (void)openSettings;
- (BOOL)snapshotSettingsTo:(NSString*)path;
@end

// ---------------------------------------------------------------- view

// Geometry of the compact (lights) view, in points. Each cell is
// [short name] / light / [short status], followed by an expand button.
struct CompactLayout {
  LightGrid grid;
  bool names = false;   // short project name above the light
  bool status = false;  // short status below the light
  CGFloat cellW = kLight, cellH = kLight, gapX = kLightGap, gapY = kLightGap;
  NSSize size;
  NSRect expandButton;

  NSRect cell(int i) const {
    const int col = i % kLightsPerRow, row = i / kLightsPerRow;
    return NSMakeRect(kCompactPad + col * (cellW + gapX), kCompactPad + row * (cellH + gapY), cellW, cellH);
  }
  NSRect light(int i) const {
    NSRect c = cell(i);
    return NSMakeRect(NSMidX(c) - kLight / 2, c.origin.y + (names ? kTagHeight + 2 : 0), kLight, kLight);
  }
  NSRect nameRect(int i) const {
    NSRect c = cell(i);
    return NSMakeRect(c.origin.x - 3, c.origin.y - 1, c.size.width + 6, kTagHeight + 1);
  }
  NSRect statusRect(int i) const {
    NSRect c = cell(i);
    return NSMakeRect(c.origin.x - 3, NSMaxY(light(i)) + 2.5, c.size.width + 6, kTagHeight + 1);
  }
};

static CompactLayout MakeCompactLayout(size_t sessions, const BarConfig& cfg) {
  CompactLayout l;
  l.grid = light_grid(sessions);
  l.names = cfg.show_names && sessions > 0;
  l.status = cfg.show_status && sessions > 0;
  if (l.names || l.status) {
    l.cellW = kTagCellWidth;
    l.gapX = 4;
    l.gapY = 6;
  }
  l.cellH = kLight + (l.names ? kTagHeight + 2 : 0) + (l.status ? kTagHeight + 3.5 : 0);
  const int cols = std::max(l.grid.cols, 1), rows = std::max(l.grid.rows, 1);  // empty: one dim light
  const CGFloat gridW = cols * l.cellW + (cols - 1) * l.gapX;
  const CGFloat gridH = rows * l.cellH + (rows - 1) * l.gapY;
  const CGFloat buttonH = std::min<CGFloat>(gridH, 22);
  l.expandButton =
      NSMakeRect(kCompactPad + gridW + 8, kCompactPad + (gridH - buttonH) / 2, kExpandButtonWidth, buttonH);
  l.size = NSMakeSize(NSMaxX(l.expandButton) + 6, 2 * kCompactPad + gridH);
  return l;
}

static NSSize ExpandedSize(size_t sessions) {
  return NSMakeSize(kWidth, kTitleHeight + (sessions == 0 ? 1 : sessions) * kRowHeight + kBottomPad);
}

@interface BarView : NSView <NSViewToolTipOwner>
@property(nonatomic, weak) BarController* controller;
@property(nonatomic) NSInteger hover;  // row (expanded) or light index (compact); -1 = none
- (void)layoutChanged;
@end

@implementation BarView {
  NSTrackingArea* _tracking;
  NSMutableArray<CALayer*>* _pulses;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_tracking) [self removeTrackingArea:_tracking];
  _tracking = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                   NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:_tracking];
}

// ---- hit testing

- (NSInteger)rowAtPoint:(NSPoint)p {
  if (p.y < kTitleHeight) return -1;
  NSInteger row = (NSInteger)((p.y - kTitleHeight) / kRowHeight);
  return row < (NSInteger)self.controller.sessions.size() ? row : -1;
}

// Light index under p, kOverflowCell for the "+N" cell, kExpandButton, or -1
// for background.
static const NSInteger kOverflowCell = -2;
static const NSInteger kExpandButton = -3;
- (NSInteger)lightAtPoint:(NSPoint)p {
  CompactLayout l = [self compactLayout];
  for (int i = 0; i < l.grid.lights; ++i) {
    if (NSPointInRect(p, NSInsetRect(l.cell(i), -2, -3))) return i;
  }
  if (l.grid.overflow > 0 && NSPointInRect(p, NSInsetRect(l.cell(l.grid.lights), -2, -3))) return kOverflowCell;
  if (NSPointInRect(p, NSInsetRect(l.expandButton, -3, -3))) return kExpandButton;
  return -1;
}

- (CompactLayout)compactLayout {
  return MakeCompactLayout(self.controller.sessions.size(), self.controller.config);
}

- (NSRect)collapseButtonRect {
  return NSMakeRect(kWidth - kInset - 30, 7, 30, 16);
}

- (void)updateHover:(NSInteger)h {
  if (h == self.hover) return;
  self.hover = h;
  self.needsDisplay = YES;
}

- (void)mouseMoved:(NSEvent*)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  [self updateHover:self.controller.showsCompact ? [self lightAtPoint:p] : [self rowAtPoint:p]];
}
- (void)mouseExited:(NSEvent*)e { [self updateHover:-1]; }

// Moves the window while the mouse is dragged. Returns YES when the mouse went
// up without moving, i.e. the gesture was a click.
- (BOOL)trackClickOrDrag:(NSEvent*)down {
  NSWindow* w = self.window;
  const NSPoint start = [NSEvent mouseLocation];
  const NSPoint origin = w.frame.origin;
  BOOL dragging = NO;
  while (true) {
    NSEvent* e = [w nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
    const NSPoint now = [NSEvent mouseLocation];
    const CGFloat dx = now.x - start.x, dy = now.y - start.y;
    if (!dragging && (fabs(dx) > 3 || fabs(dy) > 3)) dragging = YES;
    if (dragging) [w setFrameOrigin:NSMakePoint(origin.x + dx, origin.y + dy)];
    if (e.type == NSEventTypeLeftMouseUp) break;
  }
  if (dragging) [self.controller windowDragged];
  return !dragging;
}

// Anywhere on the window can be dragged: a press that moves more than a few
// points moves the window; only a press released in place counts as a click.
- (void)mouseDown:(NSEvent*)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  BarController* c = self.controller;
  if (![self trackClickOrDrag:e]) return;  // it was a drag

  if (c.showsCompact) {
    NSInteger light = [self lightAtPoint:p];
    if (light >= 0) {
      [c clickedLight:light];
    } else {
      [c setExpanded:YES];  // expand button, "+N" or background
    }
    return;
  }
  if (p.y < kTitleHeight) {
    if (c.config.compact && NSPointInRect(p, [self collapseButtonRect])) [c setExpanded:NO];
    return;
  }
  NSInteger row = [self rowAtPoint:p];
  if (row >= 0) [c clickedRow:row clickCount:e.clickCount];
}

- (NSMenu*)menuForEvent:(NSEvent*)e { return [self.controller contextMenu]; }

// ---- tooltips (compact mode: project, status, detail)

- (NSString*)view:(NSView*)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)p userData:(void*)data {
  NSInteger i = (NSInteger)(intptr_t)data;
  const auto& sessions = self.controller.sessions;
  if (i < 0 || i >= (NSInteger)sessions.size()) return @"";
  const Session& s = sessions[i];
  const double now = store::now_seconds();
  std::string text = AgentPrefix(s) + s.project + "  " + status_text(s, now, self.controller.config.stale_after_seconds());
  if (!s.detail.empty()) text += "\n" + display_detail(s.detail);
  return NS(text);
}

// Rebuilds tooltips and the animated pulse layers after sessions or mode change.
- (void)layoutChanged {
  [self removeAllToolTips];
  for (CALayer* l in _pulses) [l removeFromSuperlayer];
  [_pulses removeAllObjects];
  if (!self.controller.showsCompact) return;
  if (!_pulses) _pulses = [NSMutableArray array];

  const auto& sessions = self.controller.sessions;
  const double now = store::now_seconds();
  const double stale = self.controller.config.stale_after_seconds();
  CompactLayout l = [self compactLayout];
  for (int i = 0; i < l.grid.lights; ++i) {
    [self addToolTipRect:NSInsetRect(l.cell(i), -2, -3) owner:self userData:(void*)(intptr_t)i];
    const Session& s = sessions[i];
    if (!s.unread || !self.layer) continue;
    const DisplayState d = display_state(s, now, stale);
    [_pulses addObject:[self addPulseAt:l.light(i) color:RGB(self.controller.config.color(d)) fast:d == DisplayState::Waiting]];
  }
}

// A ring that expands and fades out, repeating. Core Animation runs it in the
// render server, so it costs the app no CPU while idle.
- (CALayer*)addPulseAt:(NSRect)cell color:(NSColor*)color fast:(BOOL)fast {
  CALayer* ring = [CALayer layer];
  NSRect r = cell;
  if (!self.layer.geometryFlipped) r.origin.y = self.bounds.size.height - NSMaxY(cell);
  ring.frame = NSRectToCGRect(r);
  ring.cornerRadius = kLight / 2;
  ring.borderWidth = 1.5;
  ring.borderColor = color.CGColor;
  ring.opacity = 0;
  ring.contentsScale = self.window ? self.window.backingScaleFactor : 2;

  CABasicAnimation* scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
  scale.fromValue = @1.0;
  scale.toValue = @1.9;
  CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
  fade.fromValue = @0.9;
  fade.toValue = @0.0;
  CAAnimationGroup* group = [CAAnimationGroup animation];
  group.animations = @[ scale, fade ];
  group.duration = fast ? 1.1 : 2.2;
  group.repeatCount = HUGE_VALF;
  group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
  [ring addAnimation:group forKey:@"pulse"];
  [self.layer addSublayer:ring];
  return ring;
}

// ---- drawing

static void DrawText(NSString* s, NSRect r, NSFont* font, NSColor* color, NSTextAlignment align) {
  NSMutableParagraphStyle* ps = [[NSMutableParagraphStyle alloc] init];
  ps.lineBreakMode = NSLineBreakByTruncatingTail;
  ps.alignment = align;
  [s drawWithRect:r
          options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
       attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : color,
                    NSParagraphStyleAttributeName : ps}
          context:nil];
}

static CGFloat TextWidth(NSString* s, NSFont* font) {
  return ceil([s sizeWithAttributes:@{NSFontAttributeName : font}].width);
}

// A glowing glass bead: soft outer glow, radial gradient with a highlight.
static void DrawLight(NSRect r, NSColor* color, BOOL glow, BOOL hollow) {
  NSBezierPath* circle = [NSBezierPath bezierPathWithOvalInRect:r];
  if (hollow) {
    [color setStroke];
    circle.lineWidth = 1.5;
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, 0.75, 0.75)] stroke];
    return;
  }
  [NSGraphicsContext saveGraphicsState];
  if (glow) {
    NSShadow* shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [color colorWithAlphaComponent:0.85];
    shadow.shadowBlurRadius = 7;
    shadow.shadowOffset = NSZeroSize;
    [shadow set];
  }
  [color setFill];
  [circle fill];
  [NSGraphicsContext restoreGraphicsState];
  NSColor* light = [color blendedColorWithFraction:0.55 ofColor:[NSColor whiteColor]];
  NSColor* dark = [color blendedColorWithFraction:0.25 ofColor:[NSColor blackColor]];
  NSGradient* g = [[NSGradient alloc] initWithColorsAndLocations:light, 0.0, color, 0.55, dark, 1.0, nil];
  [g drawInBezierPath:circle relativeCenterPosition:NSMakePoint(-0.35, 0.35)];
}

- (void)drawBackgroundRadius:(CGFloat)radius {
  [[NSColor clearColor] set];
  NSRectFill(self.bounds);
  [RGB(0x1e1f24, 0.93) setFill];
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:radius yRadius:radius] fill];
}

- (void)drawRect:(NSRect)dirty {
  if (self.controller.showsCompact) {
    [self drawCompact];
  } else {
    [self drawExpanded];
  }
}

- (void)drawCompact {
  const auto& sessions = self.controller.sessions;
  const double now = store::now_seconds();
  const double stale = self.controller.config.stale_after_seconds();
  CompactLayout l = [self compactLayout];
  const BOOL pill = l.grid.rows <= 1 && !l.names && !l.status;
  [self drawBackgroundRadius:pill ? self.bounds.size.height / 2 : 12];
  [self drawExpandButton:l.expandButton hovered:self.hover == kExpandButton];

  if (sessions.empty()) {
    DrawLight(l.light(0), RGB(0x8b8d98, 0.6), NO, YES);
    return;
  }
  NSFont* nameFont = [NSFont systemFontOfSize:9 weight:NSFontWeightMedium];
  NSFont* nameBold = [NSFont systemFontOfSize:9 weight:NSFontWeightBold];
  NSFont* statusFont = [NSFont systemFontOfSize:9];
  for (int i = 0; i < l.grid.lights; ++i) {
    const Session& s = sessions[i];
    const DisplayState d = display_state(s, now, stale);
    NSColor* color = RGB(self.controller.config.color(d));
    NSRect r = l.light(i);
    if (i == self.hover) r = NSInsetRect(r, -1.5, -1.5);
    const BOOL active = d != DisplayState::Idle && d != DisplayState::Stale;
    DrawLight(r, color, active, NO);
    if (s.unread) {  // static marker; the animated ring sits on top of it
      [[NSColor colorWithWhite:1 alpha:0.9] setStroke];
      NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, -2.5, -2.5)];
      ring.lineWidth = 1;
      [ring stroke];
    }
    if (l.names) {
      DrawText(NS(short_name(s.project)), l.nameRect(i), s.unread ? nameBold : nameFont,
               RGB(0xedeef0, s.unread ? 1.0 : 0.75), NSTextAlignmentCenter);
    }
    if (l.status) {
      DrawText(NS(display_short_label(d)), l.statusRect(i), statusFont, TextColor(color), NSTextAlignmentCenter);
    }
  }
  if (l.grid.overflow > 0) {
    NSRect r = l.light(l.grid.lights);
    NSString* more = [NSString stringWithFormat:@"+%d", l.grid.overflow];
    DrawText(more, NSMakeRect(r.origin.x - 10, r.origin.y + 0.5, r.size.width + 20, r.size.height),
             [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold], RGB(0xb0b4ba), NSTextAlignmentCenter);
  }
}

// Rounded button with a downward chevron: "show the full list".
- (void)drawExpandButton:(NSRect)r hovered:(BOOL)hovered {
  [RGB(0xffffff, hovered ? 0.16 : 0.08) setFill];
  [[NSBezierPath bezierPathWithRoundedRect:r xRadius:5 yRadius:5] fill];
  NSBezierPath* chevron = [NSBezierPath bezierPath];
  const CGFloat cx = NSMidX(r), cy = NSMidY(r);
  [chevron moveToPoint:NSMakePoint(cx - 3.5, cy - 1.5)];
  [chevron lineToPoint:NSMakePoint(cx, cy + 2)];
  [chevron lineToPoint:NSMakePoint(cx + 3.5, cy - 1.5)];
  chevron.lineWidth = 1.5;
  chevron.lineCapStyle = NSLineCapStyleRound;
  chevron.lineJoinStyle = NSLineJoinStyleRound;
  [RGB(0xd0d3d8, hovered ? 1.0 : 0.8) setStroke];
  [chevron stroke];
}

- (void)drawExpanded {
  const auto& sessions = self.controller.sessions;
  const double now = store::now_seconds();
  const double stale = self.controller.config.stale_after_seconds();
  NSColor* white = RGB(0xedeef0);
  NSColor* gray = RGB(0x8b8d98);
  [self drawBackgroundRadius:kRadius];

  // Title: "Agents  N 运行  M 未读", plus "收起" when compact mode is on.
  NSFont* titleFont = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
  NSFont* small = [NSFont systemFontOfSize:11];
  std::string title = title_text(sessions, now, stale);
  NSString* rest = NS(title.substr(std::strlen("Agents")));
  DrawText(@"Agents", NSMakeRect(kInset, 8, 60, 16), titleFont, white, NSTextAlignmentLeft);
  DrawText(rest, NSMakeRect(kInset + TextWidth(@"Agents", titleFont), 9, kWidth - 2 * kInset - 80, 16), small,
           gray, NSTextAlignmentLeft);
  if (self.controller.config.compact) {
    DrawText(@"收起", [self collapseButtonRect], small, RGB(0xb0b4ba), NSTextAlignmentRight);
  }
  [RGB(0xffffff, 0.08) setFill];
  NSRectFillUsingOperation(NSMakeRect(kInset, kTitleHeight - 1, kWidth - 2 * kInset, 1),
                           NSCompositingOperationSourceOver);

  if (sessions.empty()) {
    DrawText(@"暂无会话", NSMakeRect(kInset, kTitleHeight + 13, kWidth - 2 * kInset, 16), small, gray,
             NSTextAlignmentCenter);
    return;
  }

  NSFont* nameFont = [NSFont systemFontOfSize:13];
  NSFont* nameBold = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  NSFont* badgeFont = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
  for (size_t i = 0; i < sessions.size(); ++i) {
    const Session& s = sessions[i];
    const CGFloat y = kTitleHeight + i * kRowHeight;
    const DisplayState d = display_state(s, now, stale);
    NSColor* color = RGB(self.controller.config.color(d));

    if ((NSInteger)i == self.hover) {
      [RGB(0xffffff, 0.06) setFill];
      [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(4, y + 1, kWidth - 8, kRowHeight - 2)
                                       xRadius:6
                                       yRadius:6] fill];
    }

    // Rows without detail center their single line.
    const CGFloat line = s.detail.empty() ? y + 12 : y + 4;
    DrawLight(NSMakeRect(kInset, line + 5, 9, 9), color, NO, NO);

    // Right side, laid out right-to-left: badge, then "状态 · 时长".
    CGFloat right = kWidth - kInset;
    if (s.unread) {
      NSRect badge = NSMakeRect(right - 20, line + 2, 20, 15);
      [RGB(0x0090ff) setFill];
      [[NSBezierPath bezierPathWithRoundedRect:badge xRadius:4 yRadius:4] fill];
      DrawText(@"新", NSMakeRect(badge.origin.x, line + 3, 20, 13), badgeFont, [NSColor whiteColor],
               NSTextAlignmentCenter);
      right -= 26;
    }
    NSString* status = NS(status_text(s, now, stale));
    CGFloat statusW = TextWidth(status, small);
    DrawText(status, NSMakeRect(right - statusW, line + 2, statusW, 15), small, TextColor(color),
             NSTextAlignmentRight);
    right -= statusW + 8;

    const CGFloat textX = kInset + 16;
    DrawText(NS(AgentPrefix(s) + s.project), NSMakeRect(textX, line, right - textX, 17), s.unread ? nameBold : nameFont, white,
             NSTextAlignmentLeft);
    if (!s.detail.empty()) {
      DrawText(NS(display_detail(s.detail)), NSMakeRect(textX, y + 22, kWidth - kInset - textX, 15), small,
               gray, NSTextAlignmentLeft);
    }
  }
}

@end

// ---------------------------------------------------------------- menu bar

// The menu-bar lights: up to kMenuBarLights dots, the last becoming "+N" when
// there are more. Unread dots get a ring in the menu bar's text colour (drawn
// lazily, so it follows the light/dark menu bar).
static const int kMenuBarLights = 8;

static NSImage* MenuBarImage(const std::vector<Session>& sessions, const BarConfig& cfg, double now) {
  const LightGrid g = light_grid(sessions.size(), kMenuBarLights, 1);
  const CGFloat dot = 9, gap = 4, h = 16;
  const int cells = std::max(g.cols, 1);
  const CGFloat w = cells * dot + (cells - 1) * gap + (g.overflow > 0 ? 16 : 0) + 2;
  std::vector<std::pair<uint32_t, bool>> dots;  // colour, unread
  for (int i = 0; i < g.lights; ++i) {
    dots.emplace_back(cfg.color(display_state(sessions[i], now, cfg.stale_after_seconds())), sessions[i].unread);
  }
  const int overflow = g.overflow;
  NSImage* image = [NSImage imageWithSize:NSMakeSize(w, h)
                                  flipped:NO
                           drawingHandler:^BOOL(NSRect) {
                             if (dots.empty()) {
                               DrawLight(NSMakeRect(1, (h - dot) / 2, dot, dot), NSColor.secondaryLabelColor, NO, YES);
                               return YES;
                             }
                             for (size_t i = 0; i < dots.size(); ++i) {
                               NSRect r = NSMakeRect(1 + i * (dot + gap), (h - dot) / 2, dot, dot);
                               DrawLight(r, RGB(dots[i].first), NO, NO);
                               if (dots[i].second) {
                                 [NSColor.labelColor setStroke];
                                 NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, -1.5, -1.5)];
                                 ring.lineWidth = 1;
                                 [ring stroke];
                               }
                             }
                             if (overflow > 0) {
                               NSString* more = [NSString stringWithFormat:@"+%d", overflow];
                               NSRect r = NSMakeRect(1 + dots.size() * (dot + gap) - 2, 1, dot + 12, h - 2);
                               DrawText(more, r, [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                                        NSColor.labelColor, NSTextAlignmentLeft);
                             }
                             return YES;
                           }];
  [image setTemplate:NO];
  return image;
}

// ---------------------------------------------------------------- controller

static void FSEventsCallback(ConstFSEventStreamRef, void* info, size_t, void*,
                             const FSEventStreamEventFlags*, const FSEventStreamEventId*);

@class SettingsController;

@implementation BarController {
  SettingsController* _settings;
  std::string _dir;
  BarConfig _config;
  std::vector<Session> _sessions;
  std::string _signature;  // last scanned content, to skip redundant redraws
  std::string _clockText;  // last drawn clock-dependent text
  BOOL _expanded;          // temporarily showing the full list while compact mode is on
  NSStatusItem* _statusItem;  // menu-bar lights (when show_menubar)
  NSPanel* _panel;
  BarView* _view;
  FSEventStreamRef _stream;
  NSTimer* _tick;
  NSTimer* _cleanup;
  BOOL _rescanPending;
}

- (instancetype)initWithDir:(std::string)dir {
  if ((self = [super init])) {
    _dir = std::move(dir);
    if (auto text = store::read_file(_dir + "/bar.ini")) _config = parse_bar_ini(*text);
  }
  return self;
}

- (const std::vector<Session>&)sessions { return _sessions; }
- (const BarConfig&)config { return _config; }
- (BOOL)showsCompact { return _config.compact && !_expanded; }

- (NSSize)contentSize {
  return self.showsCompact ? MakeCompactLayout(_sessions.size(), _config).size : ExpandedSize(_sessions.size());
}

- (void)start {
  _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, kWidth, 100)
                                      styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                        backing:NSBackingStoreBuffered
                                          defer:NO];
  _panel.level = NSFloatingWindowLevel;
  [self applySpacesBehavior];
  _panel.floatingPanel = YES;
  _panel.hidesOnDeactivate = NO;
  _panel.becomesKeyOnlyIfNeeded = YES;
  _panel.opaque = NO;
  _panel.backgroundColor = [NSColor clearColor];
  _panel.hasShadow = YES;
  _panel.releasedWhenClosed = NO;

  _view = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 100)];
  _view.controller = self;
  _view.hover = -1;
  _view.wantsLayer = YES;
  _panel.contentView = _view;

  [self discover];
  [self rescan:YES];
  [self placeInitially];
  [self applyPlacement];
  [_view layoutChanged];
  {
    NSRect f = _panel.frame;
    char line[160];
    std::snprintf(line, sizeof line, "started visible=%d frame=%.0f,%.0f,%.0fx%.0f compact=%d", _panel.isVisible,
                  f.origin.x, f.origin.y, f.size.width, f.size.height, (int)self.showsCompact);
    DebugLog(_dir, line);
  }

  [self startWatching];
  _tick = [NSTimer scheduledTimerWithTimeInterval:kTickInterval
                                           target:self
                                         selector:@selector(onTick)
                                         userInfo:nil
                                          repeats:YES];
  _tick.tolerance = 1.0;
  _cleanup = [NSTimer scheduledTimerWithTimeInterval:kCleanupInterval
                                              target:self
                                            selector:@selector(onCleanup)
                                            userInfo:nil
                                             repeats:YES];
  _cleanup.tolerance = 30;
  [self onCleanup];

  [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                      selector:@selector(bringToFront)
                                                          name:kActivateNotification
                                                        object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(screensChanged:)
                                               name:NSApplicationDidChangeScreenParametersNotification
                                             object:nil];
}

- (void)bringToFront {
  if (!_config.show_floating) return;
  [self ensureOnScreen];
  [_panel orderFrontRegardless];
}

// ---- placement: floating window and/or menu bar

- (void)applyPlacement {
  if (_config.show_floating) {
    [_panel orderFrontRegardless];
  } else {
    [_panel orderOut:nil];
  }
  if (_config.show_menubar && !_statusItem) {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSMenu* menu = [[NSMenu alloc] init];
    menu.delegate = self;  // rebuilt in menuNeedsUpdate: each time it opens
    menu.autoenablesItems = NO;
    _statusItem.menu = menu;
    _statusItem.button.imagePosition = NSImageOnly;
  } else if (!_config.show_menubar && _statusItem) {
    [NSStatusBar.systemStatusBar removeStatusItem:_statusItem];
    _statusItem = nil;
  }
  [self updateStatusItem];
  char line[96];
  std::snprintf(line, sizeof line, "placement floating=%d menubar=%d", (int)_config.show_floating,
                (int)(_statusItem != nil));
  DebugLog(_dir, line);
}

- (void)updateStatusItem {
  if (!_statusItem) return;
  _statusItem.button.image = MenuBarImage(_sessions, _config, store::now_seconds());
  _statusItem.button.toolTip = NS(title_text(_sessions, store::now_seconds(), _config.stale_after_seconds()));
}

- (void)placeFloating {
  [self updateConfig:^(BarConfig& c) {
    c.show_floating = true;
    c.show_menubar = false;
  }];
}

- (void)placeMenuBar {
  [self updateConfig:^(BarConfig& c) {
    c.show_floating = false;
    c.show_menubar = true;
  }];
}

// "放在：桌面浮窗 / 菜单栏" radio items, shared by both menus.
- (void)addPlacementItems:(NSMenu*)menu {
  NSMenuItem* header = [menu addItemWithTitle:@"放在" action:nil keyEquivalent:@""];
  header.enabled = NO;
  NSMenuItem* floating = [menu addItemWithTitle:@"桌面浮窗" action:@selector(placeFloating) keyEquivalent:@""];
  floating.target = self;
  floating.indentationLevel = 1;
  floating.state = _config.show_floating ? NSControlStateValueOn : NSControlStateValueOff;
  NSMenuItem* bar = [menu addItemWithTitle:@"菜单栏" action:@selector(placeMenuBar) keyEquivalent:@""];
  bar.target = self;
  bar.indentationLevel = 1;
  bar.state = _config.show_menubar ? NSControlStateValueOn : NSControlStateValueOff;
}

// The menu-bar menu: one row per session (click = mark read + open VS Code),
// then the common actions.
- (void)menuNeedsUpdate:(NSMenu*)menu {
  [menu removeAllItems];
  const double now = store::now_seconds();
  const double stale = _config.stale_after_seconds();
  NSMenuItem* title = [menu addItemWithTitle:NS(title_text(_sessions, now, stale)) action:nil keyEquivalent:@""];
  title.enabled = NO;
  if (_sessions.empty()) {
    NSMenuItem* none = [menu addItemWithTitle:@"暂无会话" action:nil keyEquivalent:@""];
    none.enabled = NO;
  }
  for (const Session& s : _sessions) {
    const DisplayState d = display_state(s, now, stale);
    NSColor* color = RGB(_config.color(d));
    NSMutableAttributedString* text = [[NSMutableAttributedString alloc] init];
    NSFont* nameFont = s.unread ? [NSFont boldSystemFontOfSize:13] : [NSFont menuFontOfSize:13];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:NS(AgentPrefix(s) + s.project)
                                                                 attributes:@{NSFontAttributeName : nameFont}]];
    [text appendAttributedString:[[NSAttributedString alloc]
                                     initWithString:[@"   " stringByAppendingString:NS(status_text(s, now, stale))]
                                         attributes:@{
                                           NSFontAttributeName : [NSFont menuFontOfSize:11],
                                           NSForegroundColorAttributeName : TextColor(color)
                                         }]];
    if (!s.detail.empty()) {
      [text appendAttributedString:[[NSAttributedString alloc]
                                       initWithString:[@"\n" stringByAppendingString:NS(display_detail(s.detail))]
                                           attributes:@{
                                             NSFontAttributeName : [NSFont menuFontOfSize:11],
                                             NSForegroundColorAttributeName : NSColor.secondaryLabelColor
                                           }]];
    }
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:NS(s.project) action:@selector(openSessionItem:)
                                           keyEquivalent:@""];
    item.attributedTitle = text;
    item.target = self;
    item.representedObject = NS(s.id);
    item.image = [NSImage imageWithSize:NSMakeSize(12, 12)
                                flipped:NO
                         drawingHandler:^BOOL(NSRect r) {
                           DrawLight(NSInsetRect(r, 1, 1), color, NO, NO);
                           return YES;
                         }];
    [menu addItem:item];
  }
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"全部标为已读" action:@selector(markAllRead) keyEquivalent:@""].target = self;
  [menu addItemWithTitle:@"清理空闲/无响应记录" action:@selector(cleanIdle) keyEquivalent:@""].target = self;
  [menu addItem:[NSMenuItem separatorItem]];
  [self addPlacementItems:menu];
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"设置…" action:@selector(openSettings) keyEquivalent:@""].target = self;
  [menu addItemWithTitle:@"退出" action:@selector(quit) keyEquivalent:@""].target = self;
}

- (void)openSessionItem:(NSMenuItem*)item {
  const std::string id = [(NSString*)item.representedObject UTF8String];
  for (const Session& s : _sessions) {
    if (s.id != id) continue;
    if (store::mark_read(_dir, s.id)) [self rescan:NO];
    OpenInVSCode(s.cwd);
    return;
  }
}

- (BOOL)snapshotMenuBarTo:(NSString*)path {
  [self rescan:YES];
  NSImage* image = MenuBarImage(_sessions, _config, store::now_seconds());
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:nullptr pixelsWide:(NSInteger)(image.size.width * 2)
                    pixelsHigh:(NSInteger)(image.size.height * 2) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                      isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  rep.size = image.size;
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  [[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] performAsCurrentDrawingAppearance:^{
    [[NSColor colorWithWhite:0.15 alpha:1] setFill];  // dark menu bar backdrop
    NSRectFill(NSMakeRect(0, 0, image.size.width, image.size.height));
    [image drawInRect:NSMakeRect(0, 0, image.size.width, image.size.height)];
  }];
  [NSGraphicsContext restoreGraphicsState];
  return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

// Renders the view off-screen at 2x into a PNG (docs and visual checks; needs
// no screen-recording permission). Animations are not captured.
- (BOOL)snapshotTo:(NSString*)path compact:(BOOL)compact {
  _config.compact = compact;
  [self rescan:YES];
  NSSize size = [self contentSize];
  _view = [[BarView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
  _view.controller = self;
  _view.hover = -1;
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:nullptr pixelsWide:(NSInteger)(size.width * 2) pixelsHigh:(NSInteger)(size.height * 2)
                 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  rep.size = size;
  [_view cacheDisplayInRect:_view.bounds toBitmapImageRep:rep];
  NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return [png writeToFile:path atomically:YES];
}

// all_spaces: on every desktop and fixed in Mission Control (not draggable
// there). Otherwise a normal window of one desktop that Mission Control can
// move between desktops. Both float over full-screen apps.
- (void)applySpacesBehavior {
  NSWindowCollectionBehavior b = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
  b |= _config.all_spaces ? (NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary)
                          : NSWindowCollectionBehaviorManaged;
  _panel.collectionBehavior = b;
}

// ---- layout & persistence

static ScreenRect ToRect(NSRect r) { return {r.origin.x, r.origin.y, r.size.width, r.size.height}; }

static std::vector<ScreenRect> ScreenFrames() {
  std::vector<ScreenRect> out;
  for (NSScreen* screen in NSScreen.screens) out.push_back(ToRect(screen.frame));
  return out;
}

// Puts the window at its saved position if that is on an attached screen,
// else at the top-right of the main screen (see core/placement.hpp).
- (void)placeInitially {
  NSSize size = [self contentSize];
  NSScreen* main = NSScreen.screens.firstObject ? NSScreen.screens.firstObject : NSScreen.mainScreen;
  ScreenRect r = place_window(_config, size.width, size.height, ScreenFrames(), ToRect(main.visibleFrame));
  [_panel setFrame:NSMakeRect(r.x, r.y, r.w, r.h) display:YES];
}

// Displays were plugged in or out (or resolution changed). Re-place the window:
// it leaves a display that went away, and returns to its saved spot when that
// display comes back. The saved position itself is only written on drag.
- (void)screensChanged:(NSNotification*)n {
  [self placeInitially];
  [_panel invalidateShadow];
  DebugLog(_dir, "screens changed, window re-placed");
}

- (void)ensureOnScreen {
  if (!frame_on_screen(ToRect(_panel.frame), ScreenFrames())) [self placeInitially];
}

// Resizes to fit the content. The top edge stays put; horizontally the window
// grows away from the nearer screen edge and is kept on screen.
- (void)resizeToFit {
  NSRect f = _panel.frame;
  NSSize size = [self contentSize];
  if (NSEqualSizes(f.size, size)) return;
  NSScreen* screen = _panel.screen ? _panel.screen : NSScreen.mainScreen;
  NSRect vis = screen.visibleFrame;
  CGFloat x = (NSMidX(f) > NSMidX(vis)) ? NSMaxX(f) - size.width : f.origin.x;
  x = std::max(NSMinX(vis), std::min(x, NSMaxX(vis) - size.width));
  CGFloat top = NSMaxY(f);
  [_panel setFrame:NSMakeRect(x, top - size.height, size.width, size.height) display:YES];
  [_panel invalidateShadow];
}

- (void)saveConfig {
  store::write_file_atomic(_dir + "/bar.ini", format_bar_ini(_config));
}

- (void)windowDragged {
  NSRect f = _panel.frame;
  _config.has_position = true;
  _config.x = f.origin.x;
  _config.top = NSMaxY(f);
  [self saveConfig];
}

- (void)relayout {
  [self updateStatusItem];
  [self resizeToFit];
  _view.needsDisplay = YES;
  [_view displayIfNeeded];
  [_view layoutChanged];
  _clockText = [self clockText];
}

- (void)setExpanded:(BOOL)expanded {
  if (_expanded == expanded) return;
  _expanded = expanded;
  _view.hover = -1;
  [self relayout];
}

// ---- data

- (void)rescan:(BOOL)force {
  std::vector<Session> sessions = store::scan(_dir);
  const double now = store::now_seconds();
  sort_sessions(sessions, now, _config.stale_after_seconds());
  std::string sig;
  for (const auto& s : sessions) {
    sig += s.id + '\x1f' + s.project + '\x1f' + s.state + '\x1f' + s.detail + '\x1f' +
           (s.unread ? "1" : "0") + '\x1f' + std::to_string(s.since) + '\x1f' + std::to_string(s.updated) +
           '\x1e';
  }
  // No debug log here: bar.log lives in the watched directory, so logging an
  // unchanged rescan would trigger the next one.
  if (!force && sig == _signature) return;
  _signature = std::move(sig);
  _sessions = std::move(sessions);
  if (_panel) [self relayout];
  DebugLog(_dir, "redraw");
}

- (void)scheduleRescan {
  if (_rescanPending) return;
  _rescanPending = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDebounce * NSEC_PER_SEC)), dispatch_get_main_queue(),
                 ^{
                   self->_rescanPending = NO;
                   [self rescan:NO];
                 });
}

- (void)startWatching {
  FSEventStreamContext ctx = {0, (__bridge void*)self, nullptr, nullptr, nullptr};
  CFArrayRef paths = (__bridge CFArrayRef) @[ NS(_dir) ];
  _stream = FSEventStreamCreate(nullptr, &FSEventsCallback, &ctx, paths, kFSEventStreamEventIdSinceNow, 0.05,
                                kFSEventStreamCreateFlagNoDefer);
  if (!_stream) return;
  FSEventStreamSetDispatchQueue(_stream, dispatch_get_main_queue());
  FSEventStreamStart(_stream);
}

// Everything on screen that depends on the clock rather than on file content.
// In compact mode only colours (stale) and order are visible.
- (std::string)clockText {
  const double now = store::now_seconds();
  const double stale = _config.stale_after_seconds();
  std::string out;
  if (self.showsCompact) {
    for (const auto& s : _sessions) out += s.id + std::to_string(display_rank(display_state(s, now, stale)));
    return out;
  }
  out = title_text(_sessions, now, stale);
  for (const auto& s : _sessions) out += '\x1e' + s.id + status_text(s, now, stale);
  return out;
}

- (void)onTick {
  // Elapsed times ("3m") and the stale flag change with the clock. Redraw only
  // when the visible result changed, so idle sessions cost ~one redraw a minute
  // (expanded) or nothing at all (compact).
  if (_sessions.empty()) return;
  sort_sessions(_sessions, store::now_seconds(), _config.stale_after_seconds());
  std::string text = [self clockText];
  if (text == _clockText) return;
  _clockText = std::move(text);
  _view.needsDisplay = YES;
  [_view layoutChanged];
  [self updateStatusItem];
  DebugLog(_dir, "tick redraw");
}

- (void)onCleanup {
  int changed = store::cleanup_expired(_dir, store::now_seconds(), _config.expire_after_seconds());
  changed += [self discover];
  if (changed > 0) [self scheduleRescan];
}

// Picks up running sessions that have not sent a hook event yet (started
// before the hooks were installed, or quiet since this bar started).
- (int)discover {
  int n = store::discover_sessions(_dir, store::claude_sessions_dir(), store::now_seconds());
  if (n > 0) {
    char line[64];
    std::snprintf(line, sizeof line, "discovered %d session(s)", n);
    DebugLog(_dir, line);
  }
  return n;
}

// ---- interaction

- (void)clickedRow:(NSInteger)row clickCount:(NSInteger)count {
  if (row < 0 || row >= (NSInteger)_sessions.size()) return;
  Session s = _sessions[row];
  if (store::mark_read(_dir, s.id)) [self rescan:NO];
  if (count >= 2) OpenInVSCode(s.cwd);
}

- (void)clickedLight:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)_sessions.size()) return;
  Session s = _sessions[index];
  if (store::mark_read(_dir, s.id)) [self rescan:NO];
  OpenInVSCode(s.cwd);
}

- (NSMenu*)contextMenu {
  NSMenu* menu = [[NSMenu alloc] init];
  menu.autoenablesItems = NO;
  if (_config.compact) {
    [menu addItemWithTitle:_expanded ? @"收起" : @"展开列表" action:@selector(toggleExpanded) keyEquivalent:@""]
        .target = self;
  }
  [menu addItemWithTitle:@"全部标为已读" action:@selector(markAllRead) keyEquivalent:@""].target = self;
  [menu addItemWithTitle:@"清理空闲/无响应记录" action:@selector(cleanIdle) keyEquivalent:@""].target = self;
  [menu addItem:[NSMenuItem separatorItem]];
  [self addPlacementItems:menu];
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* compact = [menu addItemWithTitle:@"紧凑模式" action:@selector(toggleCompact) keyEquivalent:@""];
  compact.target = self;
  compact.state = _config.compact ? NSControlStateValueOn : NSControlStateValueOff;
  NSMenuItem* names = [menu addItemWithTitle:@"灯上显示简称" action:@selector(toggleNames) keyEquivalent:@""];
  names.target = self;
  names.state = _config.show_names ? NSControlStateValueOn : NSControlStateValueOff;
  names.enabled = _config.compact;
  names.indentationLevel = 1;
  NSMenuItem* status = [menu addItemWithTitle:@"灯下显示状态" action:@selector(toggleStatus) keyEquivalent:@""];
  status.target = self;
  status.state = _config.show_status ? NSControlStateValueOn : NSControlStateValueOff;
  status.enabled = _config.compact;
  status.indentationLevel = 1;
  NSMenuItem* spaces = [menu addItemWithTitle:@"在所有桌面显示" action:@selector(toggleSpaces) keyEquivalent:@""];
  spaces.target = self;
  spaces.state = _config.all_spaces ? NSControlStateValueOn : NSControlStateValueOff;
  NSMenuItem* autostart = [menu addItemWithTitle:@"开机自启" action:@selector(toggleAutostart) keyEquivalent:@""];
  autostart.target = self;
  autostart.state = AutostartEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItemWithTitle:@"设置…" action:@selector(openSettings) keyEquivalent:@""].target = self;
  NSMenuItem* version = [menu addItemWithTitle:@"agent-bar " AGENTBAR_VERSION action:nil keyEquivalent:@""];
  version.enabled = NO;
  [menu addItemWithTitle:@"退出" action:@selector(quit) keyEquivalent:@""].target = self;
  return menu;
}

- (void)toggleExpanded {
  [self setExpanded:!_expanded];
}

- (void)toggleCompact {
  _config.compact = !_config.compact;
  _expanded = NO;
  [self saveConfig];
  [self relayout];
}

- (void)updateConfig:(void (^)(BarConfig& c))fn {
  fn(_config);
  [self saveConfig];
  [self applySpacesBehavior];
  [self applyPlacement];
  _signature.clear();  // thresholds can change the order
  [self rescan:YES];
  [self relayout];
}

- (void)toggleSpaces {
  [self updateConfig:^(BarConfig& c) { c.all_spaces = !c.all_spaces; }];
}

- (void)toggleNames {
  _config.show_names = !_config.show_names;
  [self saveConfig];
  [self relayout];
}

- (void)toggleStatus {
  _config.show_status = !_config.show_status;
  [self saveConfig];
  [self relayout];
}

- (void)markAllRead {
  if (store::mark_all_read(_dir) > 0) [self rescan:NO];
}

- (void)cleanIdle {
  if (store::cleanup_idle_and_stale(_dir, store::now_seconds(), _config.stale_after_seconds()) > 0)
    [self rescan:NO];
}

- (void)toggleAutostart {
  SetAutostart(!AutostartEnabled());
}

- (void)quit {
  [NSApp terminate:nil];
}

@end

static void FSEventsCallback(ConstFSEventStreamRef, void* info, size_t, void*, const FSEventStreamEventFlags*,
                             const FSEventStreamEventId*) {
  [(__bridge BarController*)info scheduleRescan];
}

// ---------------------------------------------------------------- settings window

static uint32_t ToRGB(NSColor* color) {
  NSColor* c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!c) return 0;
  auto ch = [](CGFloat v) { return (uint32_t)std::lround(std::clamp(v, 0.0, 1.0) * 255); };
  return (ch(c.redComponent) << 16) | (ch(c.greenComponent) << 8) | ch(c.blueComponent);
}

@interface SettingsController : NSObject <NSWindowDelegate>
- (instancetype)initWithBar:(BarController*)bar;
- (void)show;
- (NSView*)contentForSnapshot;
@end

@implementation SettingsController {
  __weak BarController* _bar;
  NSWindow* _window;
  NSMutableArray<NSColorWell*>* _wells;
  NSButton *_compact, *_names, *_status, *_spaces, *_autostart;
  NSTextField* _stale;
}

- (instancetype)initWithBar:(BarController*)bar {
  if ((self = [super init])) _bar = bar;
  return self;
}

static NSTextField* Label(NSString* text) {
  NSTextField* f = [NSTextField labelWithString:text];
  f.alignment = NSTextAlignmentRight;
  return f;
}

static NSTextField* Header(NSString* text) {
  NSTextField* f = [NSTextField labelWithString:text];
  f.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
  return f;
}

- (NSButton*)checkbox:(NSString*)title action:(SEL)action {
  NSButton* b = [NSButton checkboxWithTitle:title target:self action:action];
  return b;
}

- (void)build {
  _wells = [NSMutableArray array];
  NSMutableArray<NSArray<NSView*>*>* rows = [NSMutableArray array];
  [rows addObject:@[ Header(@"颜色"), [NSGridCell emptyContentView] ]];
  for (DisplayState d : kAllDisplayStates) {
    NSColorWell* well = [NSColorWell colorWellWithStyle:NSColorWellStyleMinimal];
    well.tag = static_cast<NSInteger>(d);
    well.target = self;
    well.action = @selector(colorChanged:);
    [well.widthAnchor constraintEqualToConstant:44].active = YES;
    [_wells addObject:well];
    [rows addObject:@[ Label(NS(display_label(d))), well ]];
  }
  NSButton* reset = [NSButton buttonWithTitle:@"恢复默认颜色" target:self action:@selector(resetColors)];
  [rows addObject:@[ [NSGridCell emptyContentView], reset ]];

  [rows addObject:@[ Header(@"显示"), [NSGridCell emptyContentView] ]];
  _compact = [self checkbox:@"紧凑模式（只显示灯）" action:@selector(togglesChanged)];
  _names = [self checkbox:@"灯上显示简称" action:@selector(togglesChanged)];
  _status = [self checkbox:@"灯下显示状态" action:@selector(togglesChanged)];
  [rows addObject:@[ [NSGridCell emptyContentView], _compact ]];
  [rows addObject:@[ [NSGridCell emptyContentView], _names ]];
  [rows addObject:@[ [NSGridCell emptyContentView], _status ]];
  _spaces = [self checkbox:@"在所有桌面显示（关闭后可在调度中心拖到别的桌面）" action:@selector(togglesChanged)];
  [rows addObject:@[ [NSGridCell emptyContentView], _spaces ]];

  [rows addObject:@[ Header(@"其他"), [NSGridCell emptyContentView] ]];
  _stale = [NSTextField textFieldWithString:@""];
  NSNumberFormatter* fmt = [[NSNumberFormatter alloc] init];
  fmt.minimum = @1;
  fmt.maximum = @1440;
  fmt.maximumFractionDigits = 0;
  _stale.formatter = fmt;
  _stale.target = self;
  _stale.action = @selector(staleChanged);
  [_stale.widthAnchor constraintEqualToConstant:60].active = YES;
  [rows addObject:@[ Label(@"无响应阈值（分钟）"), _stale ]];
  _autostart = [self checkbox:@"开机自启" action:@selector(autostartChanged)];
  [rows addObject:@[ [NSGridCell emptyContentView], _autostart ]];

  NSGridView* grid = [NSGridView gridViewWithViews:rows];
  grid.rowSpacing = 8;
  grid.columnSpacing = 12;
  grid.translatesAutoresizingMaskIntoConstraints = NO;
  [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  for (NSInteger i = 0; i < grid.numberOfRows; ++i) [grid rowAtIndex:i].yPlacement = NSGridCellPlacementCenter;

  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 340, 420)
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  _window.title = @"agent-bar 设置";
  _window.releasedWhenClosed = NO;
  _window.delegate = self;
  NSView* content = _window.contentView;
  [content addSubview:grid];
  [NSLayoutConstraint activateConstraints:@[
    [grid.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
    [grid.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-20],
    [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
    [grid.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
  ]];
}

- (void)sync {
  const BarConfig& c = _bar.config;
  for (NSColorWell* well in _wells) well.color = RGB(c.color(static_cast<DisplayState>(well.tag)));
  _compact.state = c.compact ? NSControlStateValueOn : NSControlStateValueOff;
  _names.state = c.show_names ? NSControlStateValueOn : NSControlStateValueOff;
  _status.state = c.show_status ? NSControlStateValueOn : NSControlStateValueOff;
  _names.enabled = _status.enabled = c.compact;
  _spaces.state = c.all_spaces ? NSControlStateValueOn : NSControlStateValueOff;
  _stale.integerValue = (NSInteger)std::lround(c.stale_minutes);
  _autostart.state = AutostartEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
}

- (NSView*)contentForSnapshot {
  if (!_window) [self build];
  [self sync];
  [_window layoutIfNeeded];
  return _window.contentView;
}

- (void)show {
  if (!_window) {
    [self build];
    [_window center];
  }
  [self sync];
  // An accessory app must activate itself for the window and colour panel to take focus.
  [NSApp activateIgnoringOtherApps:YES];
  [_window makeKeyAndOrderFront:nil];
}

- (void)colorChanged:(NSColorWell*)well {
  const uint32_t rgb = ToRGB(well.color);
  const auto d = static_cast<DisplayState>(well.tag);
  [_bar updateConfig:^(BarConfig& c) { c.set_color(d, rgb); }];
}

- (void)resetColors {
  [_bar updateConfig:^(BarConfig& c) {
    for (DisplayState d : kAllDisplayStates) c.set_color(d, default_color(d));
  }];
  [NSColorPanel.sharedColorPanel orderOut:nil];
  [self sync];
}

- (void)togglesChanged {
  const bool compact = _compact.state == NSControlStateValueOn;
  const bool names = _names.state == NSControlStateValueOn;
  const bool status = _status.state == NSControlStateValueOn;
  const bool spaces = _spaces.state == NSControlStateValueOn;
  [_bar updateConfig:^(BarConfig& c) {
    c.compact = compact;
    c.show_names = names;
    c.show_status = status;
    c.all_spaces = spaces;
  }];
  [self sync];
}

- (void)staleChanged {
  const double minutes = std::max<NSInteger>(1, _stale.integerValue);
  [_bar updateConfig:^(BarConfig& c) { c.stale_minutes = minutes; }];
}

- (void)autostartChanged {
  SetAutostart(_autostart.state == NSControlStateValueOn);
  [self sync];
}

- (void)windowWillClose:(NSNotification*)n {
  [NSColorPanel.sharedColorPanel orderOut:nil];
}

@end

@implementation BarController (Settings)
- (void)openSettings {
  if (!_settings) _settings = [[SettingsController alloc] initWithBar:self];
  [_settings show];
}

- (BOOL)snapshotSettingsTo:(NSString*)path {
  _settings = [[SettingsController alloc] initWithBar:self];
  NSView* v = [_settings contentForSnapshot];
  NSBitmapImageRep* rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
  [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
  return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
@end

// ---------------------------------------------------------------- main

static int PrintList(const std::string& dir) {
  auto sessions = store::scan(dir);
  const double now = store::now_seconds();
  BarConfig cfg;
  if (auto text = store::read_file(dir + "/bar.ini")) cfg = parse_bar_ini(*text);
  sort_sessions(sessions, now, cfg.stale_after_seconds());
  std::printf("%s\n", title_text(sessions, now, cfg.stale_after_seconds()).c_str());
  for (const auto& s : sessions) {
    std::printf("%s %-24s %s  %s\n", s.unread ? "*" : " ", (AgentPrefix(s) + s.project).c_str(),
                status_text(s, now, cfg.stale_after_seconds()).c_str(), display_detail(s.detail).c_str());
  }
  return 0;
}

static int Usage();

// True when some agent-bar holds the single-instance lock.
static bool BarRunning(const std::string& dir) {
  int fd = open((dir + "/bar.lock").c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) return false;
  const bool running = flock(fd, LOCK_EX | LOCK_NB) != 0;
  close(fd);  // releases our probe lock if we got it
  return running;
}

// Starts agent-bar fully detached (double fork + setsid), so it outlives the
// agent's shell that ran `agent-bar attach`.
static bool SpawnDetachedBar() {
  const std::string exe = ExecutablePath();
  pid_t pid = fork();
  if (pid < 0) return false;
  if (pid == 0) {
    setsid();
    if (fork() != 0) _exit(0);
    int null = open("/dev/null", O_RDWR);
    dup2(null, 0);
    dup2(null, 1);
    dup2(null, 2);
    execl(exe.c_str(), exe.c_str(), (char*)nullptr);
    _exit(127);
  }
  int status = 0;
  waitpid(pid, &status, 0);
  return true;
}

// `agent-bar attach`: registers the Claude Code session this command runs in
// (found through the process tree), checks the hooks and makes sure the bar
// is running. Meant to be run by an agent on the user's behalf.
static int Attach(const std::string& dir, int argc, char** argv) {
  RegisteredSession r;
  for (int i = 2; i + 1 < argc; i += 2) {
    if (std::strcmp(argv[i], "--session-id") == 0) r.session_id = argv[i + 1];
    else if (std::strcmp(argv[i], "--cwd") == 0) r.cwd = argv[i + 1];
    else return Usage();
  }
  if (r.session_id.empty()) {
    auto found = store::find_session_for_process(store::claude_sessions_dir(), (long)getpid());
    if (!found) {
      std::fprintf(stderr,
                   "error: not running inside a Claude Code session (no ancestor process in %s).\n"
                   "Run this from the agent's shell, or pass --session-id <id> --cwd <dir>.\n",
                   store::claude_sessions_dir().c_str());
      return 1;
    }
    r = *found;
  } else if (!is_valid_session_id(r.session_id)) {
    std::fprintf(stderr, "error: invalid session id\n");
    return 1;
  }

  const double now = store::now_seconds();
  const bool added = store::register_session(dir, r, now);
  std::string state = "?";
  if (auto doc = store::read_json(store::session_path(dir, r.session_id))) {
    if (auto s = session_from_json(*doc, r.session_id)) state = display_label(display_state(*s, now, 600));
  }
  std::printf("session   %s (%s)\n", r.session_id.c_str(), r.cwd.c_str());
  std::printf("status    %s, shown as \"%s\"\n", added ? "registered now" : "already on the bar", state.c_str());

  const char* home = std::getenv("HOME");
  const std::string settings_path = std::string(home && *home ? home : NSHomeDirectory().UTF8String) +
                                    "/.claude/settings.json";
  bool hooks_ok = false;
  if (auto text = store::read_file(settings_path)) {
    json settings = json::parse(*text, nullptr, false);
    hooks_ok = !settings.is_discarded() && hooks_complete(settings);
  }
  if (hooks_ok) {
    std::printf("hooks     installed in %s\n", settings_path.c_str());
  } else {
    std::printf("hooks     MISSING in %s: the light will not update. Run install.sh from the release.\n",
                settings_path.c_str());
  }

  if (BarRunning(dir)) {
    std::printf("agent-bar running\n");
  } else {
    std::printf("agent-bar %s\n", SpawnDetachedBar() ? "started" : "could not be started");
  }
  return hooks_ok ? 0 : 2;
}

static int Usage() {
  std::fprintf(stderr,
               "agent-bar %s — floating status window for Claude Code sessions\n"
               "  agent-bar                    run the window (single instance)\n"
               "  agent-bar --list             print sessions and exit\n"
               "  agent-bar attach [--session-id <id> --cwd <dir>]\n"
               "                               put the Claude Code session this runs in on the bar\n"
               "  agent-bar --snapshot <png> [compact|expanded|settings|menubar]\n"
               "                               render the window to a PNG and exit\n"
               "  agent-bar --autostart on|off start at login\n"
               "  agent-bar --version\n",
               AGENTBAR_VERSION);
  return 64;
}

int main(int argc, char** argv) {
  @autoreleasepool {
    const std::string dir = store::status_dir();
    if (argc > 1) {
      std::string a = argv[1];
      if (a == "--version") {
        std::printf("agent-bar %s\n", AGENTBAR_VERSION);
        return 0;
      }
      if (a == "--list") return PrintList(dir);
      if (a == "attach") return Attach(dir, argc, argv);
      if (a == "--snapshot" && argc > 2) {
        BarController* c = [[BarController alloc] initWithDir:dir];
        if (argc > 3 && std::strcmp(argv[3], "settings") == 0) return [c snapshotSettingsTo:@(argv[2])] ? 0 : 1;
        if (argc > 3 && std::strcmp(argv[3], "menubar") == 0) return [c snapshotMenuBarTo:@(argv[2])] ? 0 : 1;
        BOOL compact = !(argc > 3 && std::strcmp(argv[3], "expanded") == 0);
        return [c snapshotTo:@(argv[2]) compact:compact] ? 0 : 1;
      }
      if (a == "--autostart" && argc > 2) {
        bool on = std::strcmp(argv[2], "on") == 0;
        if (!on && std::strcmp(argv[2], "off") != 0) return Usage();
        if (!SetAutostart(on)) return 1;
        std::printf("autostart %s\n", on ? "enabled" : "disabled");
        return 0;
      }
      return Usage();
    }

    store::ensure_dir(dir);
    // Single instance: hold an flock for the process lifetime.
    int lockfd = open((dir + "/bar.lock").c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (lockfd < 0 || flock(lockfd, LOCK_EX | LOCK_NB) != 0) {
      [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kActivateNotification
                                                                     object:nil
                                                                   userInfo:nil
                                                         deliverImmediately:YES];
      return 0;
    }

    NSApplication* app = [NSApplication sharedApplication];
    app.activationPolicy = NSApplicationActivationPolicyAccessory;  // no Dock icon (LSUIElement)
    BarController* controller = [[BarController alloc] initWithDir:dir];
    [controller start];
    [app run];
  }
  return 0;
}
