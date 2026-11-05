/*
MIT License

Copyright (c) 2011-Present 0xFA709394

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
 */

#import "IUAPerfSampler.h"
#import "IUALogger.h"
#import <mach/mach.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

// 前向声明（实现位于文件底部）
static NSDictionary *IUASummaryOfNumbers(NSArray<NSNumber *> *numbers);

#pragma mark - mach 采样工具

/// 进程累计 CPU 时间（user+system，秒）
static double IUAProcessCPUTime(void) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;
    if (task_threads(mach_task_self(), &threads, &threadCount) != KERN_SUCCESS) {
        return -1;
    }
    double total = 0;
    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        thread_basic_info_data_t info;
        mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&info, &count) == KERN_SUCCESS) {
            if (!(info.flags & TH_FLAGS_IDLE)) {
                total += info.user_time.seconds + info.user_time.microseconds / 1e6;
                total += info.system_time.seconds + info.system_time.microseconds / 1e6;
            }
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, threadCount * sizeof(thread_act_t));
    return total;
}

/// 全系统 CPU 占用率（0~100*N核）
static double IUASystemCPUPercent(void) {
    static host_cpu_load_info_data_t previous = {0};
    static double previousWall = 0;
    host_cpu_load_info_data_t current;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&current, &count) != KERN_SUCCESS) {
        return -1;
    }
    double now = CACurrentMediaTime();
    double result = -1;
    if (previousWall > 0 && now > previousWall) {
        double dTotal = (current.cpu_ticks[CPU_STATE_USER] + current.cpu_ticks[CPU_STATE_SYSTEM] +
                         current.cpu_ticks[CPU_STATE_NICE] - previous.cpu_ticks[CPU_STATE_USER] -
                         previous.cpu_ticks[CPU_STATE_SYSTEM] - previous.cpu_ticks[CPU_STATE_NICE]);
        double dIdlePlus = (current.cpu_ticks[CPU_STATE_IDLE] - previous.cpu_ticks[CPU_STATE_IDLE]);
        double dAll = dTotal + dIdlePlus;
        if (dAll > 0) {
            result = dTotal / dAll * 100.0;
        }
    }
    previous = current;
    previousWall = now;
    return result;
}

/// 进程内存（物理足迹 / 驻留），字节
static BOOL IUAProcessMemoryBytes(double *physFootprint, double *resident) {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &count) != KERN_SUCCESS) {
        return NO;
    }
    if (physFootprint) *physFootprint = (double)vmInfo.phys_footprint;
    if (resident) *resident = (double)vmInfo.resident_size;
    return YES;
}

static double IUALogicalCpuCount(void) {
    return MAX((double)[NSProcessInfo processInfo].activeProcessorCount, 1.0);
}

#pragma mark - FPS 计数（CADisplayLink）

@interface IUAFPSCounter : NSObject
@property (nonatomic, assign) NSInteger currentFps;   // 最近一秒帧数
- (void)start;
- (void)stop;
@end

@implementation IUAFPSCounter {
    CADisplayLink *_displayLink;
    NSInteger _framesInWindow;
    CFTimeInterval _windowStart;
}

- (void)start {
    if (_displayLink) {
        return;
    }
    _framesInWindow = 0;
    _windowStart = CACurrentMediaTime();
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)tick:(CADisplayLink *)link {
    _framesInWindow += 1;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _windowStart >= 1.0) {
        self.currentFps = _framesInWindow;
        _framesInWindow = 0;
        _windowStart = now;
    }
}

- (void)stop {
    [_displayLink invalidate];
    _displayLink = nil;
}

@end

#pragma mark - IUAPerfSampler

@interface IUAPerfSampler ()
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, id> *> *timeline;
@property (nonatomic, assign) double lastCPUTime;
@property (nonatomic, assign) double lastWallTime;
@property (nonatomic, strong) IUAFPSCounter *fpsCounter;
@end

@implementation IUAPerfSampler

+ (instancetype)shared {
    static IUAPerfSampler *sampler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sampler = [[self alloc] init];
    });
    return sampler;
}

- (BOOL)isSampling {
    return self.timer != nil && self.timer.valid;
}

- (BOOL)startSamplingWithInterval:(NSTimeInterval)interval {
    if (self.isSampling) {
        return NO;
    }
    interval = MIN(MAX(interval, 0.1), 5.0);
    self.timeline = [NSMutableArray array];
    self.lastCPUTime = IUAProcessCPUTime();
    self.lastWallTime = CACurrentMediaTime();
    self.fpsCounter = [[IUAFPSCounter alloc] init];
    [self.fpsCounter start];

    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                  repeats:YES
                                                block:^(NSTimer * _Nonnull timer) {
        [weakSelf takeSample];
    }];
    [self takeSample];
    IUALogInfo(@"性能采样开始（周期 %.1fs）", interval);
    return YES;
}

- (void)takeSample {
    double cpuTime = IUAProcessCPUTime();
    double wall = CACurrentMediaTime();
    double cpuPercent = -1;
    if (cpuTime >= 0 && self.lastCPUTime >= 0 && wall > self.lastWallTime) {
        cpuPercent = (cpuTime - self.lastCPUTime) / (wall - self.lastWallTime) * 100.0;
    }
    self.lastCPUTime = cpuTime;
    self.lastWallTime = wall;

    double phys = 0, resident = 0;
    IUAProcessMemoryBytes(&phys, &resident);

    NSDictionary *point = @{
        @"t" : @(round(wall * 1000) / 1000),
        @"cpu" : @(round(cpuPercent * 10) / 10),
        @"cpuSystem" : @(round(IUASystemCPUPercent() * 10) / 10),
        @"physMB" : @(round(phys / 1048576.0 * 10) / 10),
        @"fps" : @(self.fpsCounter.currentFps),
    };
    [self.timeline addObject:point];
    if (self.timeline.count > 600) {
        [self.timeline removeObjectAtIndex:0];
    }
}

- (nullable NSDictionary<NSString *, id> *)stopSampling {
    if (!self.isSampling) {
        return nil;
    }
    [self.timer invalidate];
    self.timer = nil;
    [self.fpsCounter stop];

    NSArray *timeline = [self.timeline copy];
    if (timeline.count == 0) {
        return @{};
    }

    double duration = ([timeline.lastObject[@"t"] doubleValue] - [timeline.firstObject[@"t"] doubleValue]);

    // CPU / FPS / 内存分位统计
    NSMutableArray<NSNumber *> *cpuArr = [NSMutableArray array];
    NSMutableArray<NSNumber *> *sysArr = [NSMutableArray array];
    NSMutableArray<NSNumber *> *physArr = [NSMutableArray array];
    NSMutableArray<NSNumber *> *fpsArr = [NSMutableArray array];
    for (NSDictionary *p in timeline) {
        // -1 表示该点无有效差值基线（首个采样点），不参与统计
        if ([p[@"cpu"] doubleValue] >= 0) [cpuArr addObject:p[@"cpu"]];
        if ([p[@"cpuSystem"] doubleValue] >= 0) [sysArr addObject:p[@"cpuSystem"]];
        [physArr addObject:p[@"physMB"]];
        NSInteger fps = [p[@"fps"] integerValue];
        if (fps > 0) {
            [fpsArr addObject:p[@"fps"]]; // 0 表示该窗口无帧（后台），不参与统计
        }
    }

    NSDictionary *stats = @{
        @"duration" : @(round(duration * 10) / 10),
        @"sampleCount" : @(timeline.count),
        // 无有效样本时返回 null（而非空字典），避免下游把 {} 当作有效统计
        @"cpuPercent" : cpuArr.count ? IUASummaryOfNumbers(cpuArr) : [NSNull null],
        @"cpuSystemPercent" : sysArr.count ? IUASummaryOfNumbers(sysArr) : [NSNull null],
        @"memoryMB" : IUASummaryOfNumbers(physArr),
        @"fps" : fpsArr.count ? IUASummaryOfNumbers(fpsArr) : [NSNull null],
        @"timeline" : timeline,
    };
    IUALogInfo(@"性能采样结束：%lu 点，%.1fs", (unsigned long)timeline.count, duration);
    return stats;
}

#pragma mark - 即时采样

+ (NSDictionary<NSString *, id> *)instantSample {
    double phys = 0, resident = 0;
    IUAProcessMemoryBytes(&phys, &resident);
    static double lastCPUTime = -1;
    static double lastWall = 0;
    double cpuTime = IUAProcessCPUTime();
    double wall = CACurrentMediaTime();
    double cpuPercent = -1;
    if (lastCPUTime >= 0 && cpuTime >= 0 && wall > lastWall) {
        cpuPercent = (cpuTime - lastCPUTime) / (wall - lastWall) * 100.0;
    }
    lastCPUTime = cpuTime;
    lastWall = wall;
    return @{
        @"cpuPercent" : @(round(cpuPercent * 10) / 10),
        @"cpuCoreCount" : @(IUALogicalCpuCount()),
        @"physFootprintMB" : @(round(phys / 1048576.0 * 10) / 10),
        @"residentMB" : @(round(resident / 1048576.0 * 10) / 10),
        @"timestamp" : @(round(NSDate.date.timeIntervalSince1970 * 1000)),
    };
}

@end

#pragma mark - 统计工具

static NSDictionary *IUASummaryOfNumbers(NSArray<NSNumber *> *numbers) {
    if (numbers.count == 0) {
        return @{};
    }
    NSArray<NSNumber *> *sorted = [numbers sortedArrayUsingSelector:@selector(compare:)];
    double sum = 0;
    for (NSNumber *n in sorted) {
        sum += [n doubleValue];
    }
    NSUInteger p95Index = (NSUInteger)floor(sorted.count * 0.95);
    if (p95Index >= sorted.count) {
        p95Index = sorted.count - 1;
    }
    return @{
        @"min" : @([sorted.firstObject doubleValue]),
        @"avg" : @(round(sum / sorted.count * 10) / 10),
        @"max" : @([sorted.lastObject doubleValue]),
        @"p95" : @([sorted[p95Index] doubleValue]),
    };
}
