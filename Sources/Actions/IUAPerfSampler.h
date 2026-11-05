//
//  IUAPerfSampler.h
//  IUIAuto
//
//  App 进程性能采样器（公开 mach API，模拟器/真机均可用）：
//  - CPU%：task_threads + thread_info(THREAD_BASIC_INFO) 两次差值 / 墙钟时间
//  - 内存：task_info(TASK_VM_INFO) 的 phys_footprint / resident_size
//  - FPS：CADisplayLink 每秒帧数统计
//
//  与 xctrace（宿主侧录制 .trace）互补：xctrace 环境受限时（模拟器部分
//  服务不可用），本采样器仍提供可靠的区间性能数据。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IUAPerfSampler : NSObject

+ (instancetype)shared;

/// 当前是否在区间采样中
@property (nonatomic, readonly, getter=isSampling) BOOL sampling;

/// 启动区间采样。interval 为采样周期（秒，0.1~5，默认 0.5）。
/// 返回 NO 表示已在采样中。
- (BOOL)startSamplingWithInterval:(NSTimeInterval)interval;

/// 停止采样并返回统计结果：
/// {
///   duration, sampleCount,
///   cpuPercent:    { min, avg, max, p95 },      // 进程 CPU（单核=100）
///   cpuSystemPercent: { ... },                   // 全系统 CPU（host 统计）
///   memoryMB:      { physMin, physAvg, physMax, residentMax },
///   fps:           { min, avg, max, p95 },      // 采样窗口内有帧才有效
///   timeline: [ { t, cpu, physMB, fps }, ... ]  // 最多 600 点
/// }
- (nullable NSDictionary<NSString *, id> *)stopSampling;

/// 即时单点采样（轻量，不依赖 start）：{ cpuPercent, cpuSystemPercent,
/// physFootprintMB, residentMB, fps, timestamp }
+ (NSDictionary<NSString *, id> *)instantSample;

@end

NS_ASSUME_NONNULL_END
