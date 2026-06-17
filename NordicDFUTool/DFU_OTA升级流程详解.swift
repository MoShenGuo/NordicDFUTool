/**
 ============================================================
 Nordic McuManager OTA 升级核心流程详解
 ============================================================
 
 本文件是对 iOSMcuManagerLibrary 中 FirmwareUpgradeManager 的
 start(images:using:) 方法及其后续完整调用链的逐行分析。
 
 ============================================================
 一、整体状态机流程图
 ============================================================
 
 start() 被调用后，FirmwareUpgradeManager 内部按照以下状态机运转：
 
 ┌─────────────────────────────────────────────────────────────┐
 │  start()                                                     │
 │    ↓                                                         │
 │  requestMcuMgrParameters  ← 查询设备 SMP 参数(缓冲区大小等)   │
 │    ↓                                                         │
 │  bootloaderInfo           ← 查询 Bootloader 类型(MCUBoot/SUIT)│
 │    ↓                                                         │
 │  bootloaderMode           ← 查询启动模式(Swap/DirectXIP/BareMetal)│
 │    ↓                                                         │
 │  validate                 ← 读取设备当前 Image List，判断哪些需上传│
 │    ↓                                                         │
 │  upload                   ← 分片上传固件数据到设备 secondary slot│
 │    ↓                                                         │
 │  [eraseAppSettings]       ← 可选：擦除 App 设置               │
 │    ↓                                                         │
 │  test / confirm           ← 根据 upgradeMode 标记新固件       │
 │    ↓                                                         │
 │  reset                    ← 发送重置命令，设备重启             │
 │    ↓                                                         │
 │  [等待断开 → 等待 swap → 重连]                                │
 │    ↓                                                         │
 │  success / fail           ← 升级结果                          │
 └─────────────────────────────────────────────────────────────┘
 
 ============================================================
 二、start(images:using:) 方法逐行分析
 ============================================================
*/

// ===== 以下是 FirmwareUpgradeManager+Public.swift 中 start() 方法的带注释版本 =====

/*
func start(images: [ImageManager.Image], using configuration: FirmwareUpgradeConfiguration = FirmwareUpgradeConfiguration()) {
*/
/*
    // ============ start() 方法体 ============
    
    // 1. 加锁：使用 Objective-C 互斥锁保证线程安全
    //    防止多个线程同时调用 start() 导致状态混乱
    objc_sync_enter(self)
    defer {
        objc_sync_exit(self)  // 方法结束时自动解锁
    }
    
    // 2. 线程检查：确保在主线程调用
    //    UI 相关的 delegate 回调需要在主线程执行
    self.imageManager.verifyOnMainThread()
    
    // 3. 状态检查：如果已经有升级在进行中，直接返回不重复启动
    //    state == .none 表示当前空闲，可以开始新的升级
    guard state == .none else {
        log(msg: "Firmware upgrade is already in progress", atLevel: .warning)
        return
    }
    
    // 4. 保存升级参数
    //    将传入的 images 数组包装成内部使用的 FirmwareUpgradeImage 对象
    //    FirmwareUpgradeImage 在原始 Image 基础上增加了状态追踪字段：
    //    uploaded(是否已上传), tested(是否已测试), confirmed(是否已确认)
    self.images = images.map { FirmwareUpgradeImage($0) }
    
    // 5. 保存升级配置
    //    configuration 包含：estimatedSwapTime, eraseAppSettings,
    //    pipelineDepth, upgradeMode 等参数
    self.configuration = configuration
    
    // 6. 重置 bootloader 类型（后续会通过查询设备来确定）
    self.bootloader = nil
    
    // 7. 建立循环引用防止 self 被释放
    //    升级是一个长时间异步过程，必须确保 manager 不被 ARC 释放
    //    升级结束（成功/失败/取消）时会置为 nil 释放循环引用
    cyclicReferenceHolder = { return self }
    
    // 8. 日志输出：记录升级开始，包含镜像数量和升级模式
    log(msg: "Upgrade started with \(images.count) image(s) using '\(configuration.upgradeMode)' mode",
        atLevel: .application)
    
    // 9. 通知代理：升级已开始
    //    对应我们代码中的 upgradeDidStart(controller:) 回调
    delegate?.upgradeDidStart(controller: self)
    
    // 10. 进入状态机第一步：请求 McuMgr 参数
    requestMcuMgrParameters()
}
*/
/*
 ============================================================
 三、requestMcuMgrParameters() - 查询设备 SMP 参数
 ============================================================
 
 目的：获取设备端 SMP 协议的缓冲区参数，用于优化传输速度
 
 func requestMcuMgrParameters() {
     // 切换状态为 .requestMcuMgrParameters
     objc_sync_setState(.requestMcuMgrParameters)
     if !paused {
         // 向设备发送 params 命令，查询设备的 SMP 缓冲区配置
         // 返回值包含 bufferCount(缓冲区数量) 和 bufferSize(单个缓冲区大小)
         defaultManager.params(callback: mcuManagerParametersCallback)
     }
 }
 
 mcuManagerParametersCallback 处理逻辑：
 - 如果设备不支持（NCS 2.0 以下），跳过，用默认参数继续
 - 如果支持，获取 bufferCount 和 bufferSize
 - 将 bufferSize 设置到 configuration.reassemblyBufferSize
 - 如果 bufferSize < MTU，降低 MTU 以匹配
 - 最后调用 bootloaderInfo() 进入下一步
 
 ============================================================
 四、bootloaderInfo() - 查询 Bootloader 信息
 ============================================================
 
 目的：确定设备使用的 Bootloader 类型（MCUBoot / SUIT）
 
 func bootloaderInfo() {
     objc_sync_setState(.bootloaderInfo)
     if !paused {
         // 发送 BootloaderInfo 查询命令
         // 返回值告知是 MCUBoot 还是 SUIT Bootloader
         defaultManager.bootloaderInfo(query: .name, callback: bootloaderInfoCallback)
     }
 }
 
 bootloaderInfoCallback 处理逻辑：
 - 如果不支持此命令（旧固件），默认假设为 MCUBoot
 - 如果是 SUIT Bootloader：直接进入 upload 状态（SUIT 有自己的流程）
 - 如果是 MCUBoot：继续查询 bootloaderMode()
 
 ============================================================
 五、bootloaderMode() - 查询启动模式
 ============================================================
 
 目的：确定设备的 image swap 策略
 
 func bootloaderMode() {
     objc_sync_setState(.bootloaderInfo)
     if !paused {
         // 查询具体模式：Swap/DirectXIP/BareMetal 等
         defaultManager.bootloaderInfo(query: .mode, callback: bootloaderModeCallback)
     }
 }
 
 bootloaderModeCallback 处理逻辑：
 - DirectXIP NoRevert: 覆盖 upgradeMode 为 .uploadOnly（不需要 test/confirm）
 - BareMetal (Firmware Loader): 修改 slot 为 primary (0)
 - 其他模式: 保持用户配置
 - 最后调用 validate() 进入验证阶段
*/
/*
 ============================================================
 六、validate() - 验证设备当前固件状态
 ============================================================
 
 目的：读取设备上所有 image slot 的状态，判断哪些固件需要上传
 这是 DFU 最关键的前置步骤，决定了后续要做什么
 
 func validate() {
     objc_sync_setState(.validate)
     if !paused {
         // 发送 Image List 命令，获取设备所有 slot 的固件信息
         // 返回值包含每个 slot 的：image编号, slot编号, hash, 版本, 状态
         imageManager.list(callback: listCallback)
     }
 }
 
 listCallback 处理逻辑（核心验证逻辑）：
 
 对每个待上传的 image 执行以下判断：
 
 1. Hash 匹配检查：
    - 如果设备上已有相同 hash 的固件 → 无需上传，标记为 uploaded
    - 如果已 confirmed → 标记为 confirmed + tested
    - 如果已 pending → 标记为 tested
 
 2. Secondary Slot 状态检查：
    - 如果 secondary slot 有旧固件且已 confirmed →
      先 confirm primary slot（解锁 secondary）
    - 如果 secondary slot 是 pending 状态 →
      先 reset 设备（让 pending image 生效），然后重新 validate
    - 其他情况 → 旧固件会被覆盖写入
 
 3. DirectXIP 特殊处理：
    - 有两个候选 slot，选择非 active 的 slot 上传
    - 如果另一个 slot 已有相同固件，跳过上传
 
 验证完成后，延迟 0.1 秒调用 upload()
 （延迟是为了避免固件端丢弃首批数据包）
 
 ============================================================
 七、upload() - 上传固件数据
 ============================================================
 
 目的：将固件二进制数据分片通过 SMP 协议上传到设备
 这是整个 DFU 中耗时最长的阶段
 
 func upload() {
     objc_sync_setState(.upload)
     if !paused {
         // 过滤出尚未上传的 images
         let imagesToUpload = images.filter { !$0.uploaded }.map { ImageManager.Image($0) }
         
         // 如果所有 image 都已上传（validate 阶段发现设备已有），跳过上传
         guard !imagesToUpload.isEmpty else {
             uploadDidFinish()
             return
         }
         
         // 调用 ImageManager.upload() 开始分片上传
         // 参数 configuration 中的 pipelineDepth 控制并发分片数
         // delegate: self 用于接收进度回调
         _ = imageManager.upload(images: imagesToUpload, using: configuration, delegate: self)
     }
 }
 
 上传过程中的回调：
 - uploadProgressDidChange: 每发送一批数据触发，更新进度
 - uploadDidFinish: 所有数据上传完成
 - uploadDidFail: 上传出错
 - uploadDidCancel: 用户取消
 
 上传内部实现（ImageManager）：
 - 按 MTU 大小将固件数据切分成多个 chunk
 - 每个 chunk 封装为 SMP Upload 命令发送
 - pipelineDepth > 1 时，同时发送多个 chunk（流水线传输）
 - 设备收到后存入 secondary slot 的 flash
 - 通过 offset 追踪已上传的位置
*/
/*
 ============================================================
 八、uploadDidFinish() - 上传完成后的分支处理
 ============================================================
 
 上传完成后，根据 upgradeMode 执行不同的后续步骤：
 
 func uploadDidFinish() {
     // 先检查是否需要擦除 App Settings
     if configuration.eraseAppSettings {
         eraseAppSettings()  // 擦除后会再次调用 uploadDidFinish
         return
     }
     
     // 根据 upgradeMode 决定后续流程：
     switch configuration.upgradeMode {
     
     case .confirmOnly:
         // 模式说明：上传 → confirm → reset
         // confirm 命令将新固件标记为"永久"（permanent）
         // 设备重启后直接运行新固件，不需要再确认
         confirm(firstUnconfirmedImage)
         
     case .testOnly:
         // 模式说明：上传 → test → reset
         // test 命令将新固件标记为"待测试"（pending）
         // 设备重启后运行新固件一次，如果不 confirm，下次重启回滚到旧固件
         test(firstUntestedImage)
         
     case .testAndConfirm:
         // 模式说明：上传 → test → reset → 重连 → confirm
         // 先 test，设备重启后确认新固件可以正常运行，再 confirm 永久生效
         // 最安全的模式，但流程最长
         test(firstUntestedImage)
         
     case .uploadOnly:
         // 模式说明：上传 → reset（仅 SUIT 使用）
         // SUIT Bootloader 自行处理固件验证和切换
         reset()
     }
 }
 
 ============================================================
 九、test() - 标记新固件为"待测试"
 ============================================================
 
 func test(_ image: FirmwareUpgradeImage) {
     objc_sync_setState(.test)
     if !paused {
         // 发送 Image Test 命令
         // 参数是固件的 hash，设备据此找到对应的 image slot
         // 执行后，该 slot 会被标记为 pending（下次重启时启动）
         imageManager.test(hash: [UInt8](image.hash), callback: testCallback)
     }
 }
 
 testCallback 处理逻辑：
 - 验证设备返回的 image 状态中目标 slot 是否为 pending
 - 如果还有未 test 的 image，继续发送 test 命令
 - 所有 image 都 tested 后，调用 reset() 重启设备
 
 ============================================================
 十、confirm() - 确认新固件永久生效
 ============================================================
 
 func confirm(_ image: FirmwareUpgradeImage) {
     objc_sync_setState(.confirm)
     if !paused {
         // 发送 Image Confirm 命令
         // 将目标 slot 的固件标记为 permanent（永久生效）
         // 设备重启后会一直运行此固件，不会回滚
         imageManager.confirm(hash: [UInt8](image.hash), callback: confirmCallback)
     }
 }
 
 confirmCallback 处理逻辑：
 - 验证设备返回的 image 是否为 permanent 状态
 - 如果是 .confirmOnly 模式，confirm 完成后调用 reset()
 - 如果是 .testAndConfirm 模式，confirm 完成后直接 success()
   （因为 test 阶段已经 reset 过一次了）
*/
/*
 ============================================================
 十一、reset() - 发送重置命令
 ============================================================
 
 func reset() {
     objc_sync_setState(.reset)
     if !paused {
         // 添加 transport 观察者，监听设备断开事件
         // 设备收到 reset 后会断开 BLE 连接并重启
         defaultManager.transport.addObserver(self)
         // 发送 Reset 命令给设备
         defaultManager.reset(callback: resetCallback)
     }
 }
 
 resetCallback 处理逻辑：
 - 确认 reset 命令发送成功
 - 记录 resetResponseTime（用于计算 swap 等待时间）
 - 然后等待 transport 状态变化回调（设备断开）
 
 ============================================================
 十二、transport(_:didChangeStateTo:) - 设备断开后的处理
 ============================================================
 
 设备收到 reset 命令后会：
 1. 断开 BLE 连接
 2. 重启 MCU
 3. Bootloader 执行 image swap（如果有 pending image）
 4. 从新的 image slot 启动
 5. 重新开始 BLE 广播
 
 func transport(_ transport: McuMgrTransport, didChangeStateTo state: McuMgrTransportState) {
     // 移除观察者（只需要收到一次断开通知）
     transport.removeObserver(self)
     
     // 只处理断开状态
     guard state == .disconnected else { return }
     
     // 计算剩余等待时间
     // estimatedSwapTime 是用户配置的预估 swap 时间
     // 实际需要等待的 = estimatedSwapTime - 已经过去的时间
     let timeSinceReset = now.timeIntervalSince(resetResponseTime)
     let remainingTime = configuration.estimatedSwapTime - timeSinceReset
     
     // DirectXIP 模式不需要 swap，立即重连
     // 其他模式需要等待 swap 完成后再重连
     guard waitForReconnectRequired else {
         reconnect()
         return
     }
     
     // 等待 swap 完成后发起重连
     DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime) {
         self.reconnect()
     }
 }
 
 ============================================================
 十三、reconnect() - 重连设备并完成升级
 ============================================================
 
 func reconnect() {
     // 通过 transport 重新建立 BLE 连接
     imageManager.transport.connect { result in
         switch result {
         case .connected:
             // 重连成功
         case .deferred:
             // 连接被延迟（某些情况下系统会自动重连）
         case .failed(let error):
             // 重连失败 → 升级失败
             self.fail(error: error)
             return
         }
         
         // 根据当前状态决定下一步
         switch self.state {
         case .reset:
             switch self.configuration.upgradeMode {
             case .testAndConfirm:
                 // test&Confirm 模式：重连后需要 confirm 所有 image
                 self.listAfterUploadReset()
             default:
                 // 其他模式：重连成功即表示升级完成
                 self.success()
             }
         default:
             break
         }
     }
 }
 
 ============================================================
 十四、success() / fail() - 最终结果
 ============================================================
 
 func success() {
     objc_sync_setState(.success)    // 状态设为成功
     state = .none                   // 重置为空闲
     paused = false                  // 清除暂停标志
     delegate?.upgradeDidComplete()  // 通知外部升级成功
     cyclicReferenceHolder = nil     // 释放循环引用，允许 ARC 回收
 }
 
 func fail(error: Error) {
     let tmp = state                     // 保存失败时的状态
     state = .none                       // 重置为空闲
     paused = false                      // 清除暂停标志
     delegate?.upgradeDidFail(inState: tmp, with: error)  // 通知外部失败
     cyclicReferenceHolder = nil         // 释放循环引用
 }
*/
/*
 ============================================================
 十五、FirmwareUpgradeConfiguration 配置参数详解
 ============================================================
 
 在我们的项目中使用的配置：
 
 let config = FirmwareUpgradeConfiguration(
     estimatedSwapTime: 10.0,   // 预估 swap 时间 10 秒
     eraseAppSettings: false,   // 不擦除 app 设置
     pipelineDepth: 3           // 管道深度 3（并发发送3个分片）
 )
 
 各参数说明：
 
 1. estimatedSwapTime (TimeInterval)
    - 作用：设备重启后执行 image swap 的预估耗时
    - 重要性：这个时间决定了 reset 后等多久再重连
    - 如果设置太短：设备还在 swap，重连会失败
    - 如果设置太长：用户等待时间变长
    - 建议值：nRF52 系列 10~15秒，nRF53 系列 5~10秒
    - DirectXIP 模式下此参数被忽略（无 swap 过程）
 
 2. eraseAppSettings (Bool)
    - 作用：上传完成后、test/confirm 之前，是否擦除设备应用设置
    - false = 保留设备上的用户配置数据（WiFi密码、配对信息等）
    - true = 清除所有应用设置（恢复出厂配置）
    - 一般 OTA 升级设为 false，除非固件有不兼容的配置变更
 
 3. pipelineDepth (Int)
    - 作用：SMP 管道深度，即同时发送多少个数据分片
    - 值为 1：传统模式，发一个等一个响应再发下一个
    - 值 > 1：流水线模式，连续发送多个分片不等响应
    - 效果：pipelineDepth=3 可以将上传速度提升 2~3 倍
    - 风险：值过大可能超出设备缓冲区导致丢包
    - 建议值：3~4 比较稳妥
 
 4. upgradeMode (FirmwareUpgradeMode) - 默认 .confirmOnly
    四种模式：
    - .confirmOnly：上传 → confirm → reset（最常用）
      新固件直接标记为永久，重启即生效
    - .testOnly：上传 → test → reset
      新固件标记为测试，运行一次后如果不 confirm 会回滚
    - .testAndConfirm：上传 → test → reset → 重连 → confirm
      最安全，先测试运行再确认，但流程最长
    - .uploadOnly：上传 → reset（SUIT 专用）
      SUIT Bootloader 自己处理验证
 
 5. byteAlignment (ImageUploadAlignment) - 默认 .disabled
    - SMP 管道传输时的字节对齐设置
    - pipelineDepth > 1 时才有意义
    - 用于精确计算 offset 跳跃值
 
 6. reassemblyBufferSize (UInt64) - 默认 0
    - 设备端重组缓冲区大小
    - 如果 > 0，数据包大小可以超过 MTU
    - 设备端会将多个 BLE 包重组为完整的 SMP 消息
    - 可大幅提升传输速度，但需要设备端支持
 
 ============================================================
 十六、upgradeMode 四种模式的完整流程对比
 ============================================================
 
 .confirmOnly（项目默认使用）:
   upload → confirm(hash) → reset → 断开 → swap → 重连 → success
   特点：一次重启，新固件永久生效
 
 .testOnly:
   upload → test(hash) → reset → 断开 → swap → 重连 → success
   特点：新固件仅运行一次，不 confirm 则下次重启回滚
 
 .testAndConfirm:
   upload → test(hash) → reset → 断开 → swap → 重连
   → listAfterUploadReset → confirm(hash) → success
   特点：两步确认，最安全但最慢
 
 .uploadOnly（SUIT）:
   upload → reset → 断开 → 重连 → success
   特点：Bootloader 自行处理验证切换
 
 ============================================================
 十七、Image Slot 概念说明
 ============================================================
 
 Nordic MCUBoot 使用双 Slot 机制：
 
 ┌─────────────────────────────────────┐
 │  Primary Slot (Slot 0)              │
 │  当前运行的固件                      │
 │  状态: active, confirmed            │
 └─────────────────────────────────────┘
 ┌─────────────────────────────────────┐
 │  Secondary Slot (Slot 1)            │
 │  新上传的固件存放位置                 │
 │  状态: pending (test后) /           │
 │        permanent (confirm后)        │
 └─────────────────────────────────────┘
 
 Image Swap 过程：
 1. 新固件上传到 Secondary Slot
 2. test/confirm 标记 Secondary Slot 为 pending/permanent
 3. Reset 后 Bootloader 检测到标记
 4. 将 Primary 和 Secondary 的内容互换（swap）
 5. 从 Primary Slot 启动新固件
 
 回滚机制（testOnly 模式）：
 - test 后如果新固件运行正常但未 confirm
 - 下次重启时 Bootloader 会 swap 回旧固件
 - 这是 MCUBoot 的安全机制，防止坏固件变砖
 
 ============================================================
 十八、本项目中 OTA 的完整调用链总结
 ============================================================
 
 我们的代码调用：
   try dfuManager?.start(images: package.images, using: config)
 
 实际执行链：
   start()
     → requestMcuMgrParameters()     [SMP: os/params]
     → bootloaderInfo()              [SMP: os/bootloader_info name]
     → bootloaderMode()              [SMP: os/bootloader_info mode]
     → validate()                    [SMP: img/list]
     → upload()                      [SMP: img/upload × N 次]
       → uploadProgressDidChange()   [回调进度]
     → uploadDidFinish()
     → confirm()                     [SMP: img/confirm]
     → reset()                       [SMP: os/reset]
     → [设备断开，等待 swap]
     → reconnect()                   [BLE 重连]
     → success()                     [回调完成]
 
 SMP 命令通过 BLE 的 SMP Characteristic 发送：
 - Service UUID:  8D53DC1D-1DB7-4CD3-868B-8A527460AA84
 - Characteristic UUID: DA2E7828-FBCE-4E01-AE9E-261174997C48
 - 所有 SMP 命令都通过这一个 Characteristic 读写完成
*/
/*
 ============================================================
 十九、ImageManager.upload(data:image:offset:alignment:callback:)
      逐行详细分析
 ============================================================
 
 这是 OTA 固件上传中最底层的单包发送方法。
 每次调用发送一个数据分片（chunk）到设备。
 完整的固件上传是通过反复调用此方法实现的。
 
 方法签名：
 public func upload(data: Data, image: Int, offset: UInt64,
                    alignment: ImageUploadAlignment,
                    callback: @escaping McuMgrCallback<McuMgrUploadResponse>)
 
 参数说明：
 - data: 完整的固件镜像二进制数据（整个 .bin 文件内容）
 - image: 目标 image 编号（0=App Core, 1=Net Core）
 - offset: 当前分片在 data 中的起始偏移量（字节）
 - alignment: 字节对齐方式（管道传输时使用）
 - callback: 设备响应的回调
 
 ============================================================
 逐行代码分析：
 ============================================================
*/

/*
 // ===== 第一行 =====
 let packetOverhead = calculatePacketOverhead(data: data, image: image, offset: UInt64(offset))
 
 作用：计算本次数据包的"开销"（非数据部分占用的字节数）
 
 开销包含：
 - McuMgr Header (8字节)：SMP 协议头
 - CBOR 编码的 payload 字段（不含实际数据部分）：
   * "off" 字段：偏移量的 CBOR 编码
   * "data" 字段：仅占位符（1字节），用于计算包头大小
   * 首包额外字段："image"(image编号), "len"(总长度), "sha"(SHA256校验)
 - CoAP Header (如果使用 CoAP 传输，额外25字节)
 - 额外预留5字节安全余量
 
 calculatePacketOverhead 内部实现：
 1. 构建一个"模板" payload，data 字段只放1字节占位
 2. 如果 offset==0（首包），额外加入 image/len/sha 字段
 3. 调用 McuManager.buildPacket() 构建完整包
 4. 返回 完整包大小 + 5（安全余量）
 
 为什么需要计算开销？
 因为 BLE 有 MTU 限制（如 251 字节），必须知道头部占多少，
 才能确定实际数据能塞多少字节进这个包。
*/
/*
 // ===== 第二行 =====
 let payloadLength = maxDataPacketLengthFor(data: data, at: offset, with: packetOverhead, and: uploadConfiguration)
 
 作用：计算本次分片能携带的最大数据字节数
 
 计算公式：
   maxPacketSize = max(reassemblyBufferSize, MTU)   // 取较大值作为包上限
   maxDataLength = maxPacketSize - packetOverhead    // 减去开销 = 可用数据空间
   如果启用了字节对齐：
     maxDataLength = (maxDataLength / alignment) * alignment  // 向下对齐
   最终结果 = min(maxDataLength, 剩余未发送字节数)  // 不超过剩余数据量
 
 举例：
   MTU = 251, packetOverhead = 52（首包有额外字段）
   maxDataLength = 251 - 52 = 199 字节
   如果固件总共 50000 字节，首包最多发 199 字节数据
   
   如果 reassemblyBufferSize = 2048（设备支持重组）：
   maxDataLength = 2048 - 52 = 1996 字节
   可以发更大的分片（超过 MTU），设备端重组还原
 
 
 // ===== 第三行 =====
 let chunkOffset = offset
 
 作用：记录本次分片的起始偏移量
 就是传入的 offset 参数，表示从 data 的第几个字节开始切片
 
 
 // ===== 第四行 =====
 let chunkEnd = min(chunkOffset + payloadLength, UInt64(data.count))
 
 作用：计算本次分片的结束位置
 取 "起始位置 + 最大长度" 和 "数据总长度" 的较小值
 确保不会越界读取数据
 
 举例：
   data.count = 50000, chunkOffset = 49900, payloadLength = 199
   chunkEnd = min(49900+199, 50000) = min(50099, 50000) = 50000
   实际只发 100 字节（最后一个分片）
*/
/*
 // ===== 第五行：构建 CBOR payload =====
 var payload: [String:CBOR] = ["data": CBOR.byteString([UInt8](data[chunkOffset..<chunkEnd])),
                               "off": CBOR.unsignedInt(chunkOffset)]
 
 作用：构建 SMP Upload 命令的 CBOR 编码 payload
 
 payload 是一个字典，包含：
 - "data": 本次要发送的固件数据切片
   * 从 data[chunkOffset..<chunkEnd] 取出字节数组
   * 编码为 CBOR byteString 类型
   * 这就是实际写入设备 flash 的固件数据
   
 - "off": 本次数据在完整固件中的偏移量
   * 告诉设备这段数据应该写入 flash 的哪个位置
   * 设备用这个值决定写入 secondary slot 的具体地址
   * 编码为 CBOR unsignedInt 类型
 
 
 // ===== 第六~七行：首包额外字段 =====
 let uploadTimeoutInSeconds: Int
 if chunkOffset == 0 {
 
 作用：判断是否是首包（offset == 0）
 首包需要携带额外的元数据信息，让设备知道：
 - 要接收多大的固件
 - 固件的校验值
 - 写入哪个 image/slot
 
 
 // ===== 首包内部逻辑 =====
 
     // 0 is Default behavior, so we can ignore adding it and
     // the firmware will do the right thing.
     if image > 0 {
         payload.updateValue(CBOR.unsignedInt(UInt64(image)), forKey: "image")
     }
     
 作用：如果目标 image 不是默认的 0（App Core），需要显式指定
 - image=0 是默认值，不发也行，设备默认写入 image 0 的 secondary slot
 - image=1（Net Core）或更大值需要显式告诉设备
 
 
     payload.updateValue(CBOR.unsignedInt(UInt64(data.count)), forKey: "len")
     
 作用：告诉设备固件数据的总长度
 - "len" 字段只在首包发送
 - 设备据此分配 flash 空间并知道何时接收完毕
 - 例如 data.count = 50000，设备知道总共要接收 50000 字节
 
 
     payload.updateValue(CBOR.byteString([UInt8](data.sha256())), forKey: "sha")
     
 作用：发送固件数据的 SHA-256 哈希值
 - "sha" 字段只在首包发送
 - 设备接收完所有数据后，会计算已接收数据的 SHA-256
 - 与这个值比对，确保传输过程中数据没有损坏
 - 如果校验失败，设备会拒绝这个固件
 
 
     // When uploading offset 0, we might trigger an erase on the firmware's end.
     // Hence, the longer timeout.
     uploadTimeoutInSeconds = McuManager.DEFAULT_SEND_TIMEOUT_SECONDS
     
 作用：首包使用较长的超时时间
 - 设备收到 offset=0 的首包后，可能需要先擦除 secondary slot 的 flash
 - Flash 擦除操作耗时较长（可能数秒到十几秒）
 - 所以首包的响应等待时间设置得更长（DEFAULT_SEND_TIMEOUT_SECONDS）
 - 避免因为擦除耗时导致误判超时
*/
/*
 // ===== 非首包的分支 =====
 } else {
     uploadTimeoutInSeconds = McuManager.FAST_TIMEOUT
 }
 
 作用：后续包使用较短的超时时间
 - 非首包不需要擦除 flash，设备只需写入一小段数据
 - 写入速度很快，所以使用 FAST_TIMEOUT（较短超时）
 - 提高传输效率，快速检测到真正的通信故障
 
 
 // ===== 最后一行：发送 SMP 命令 =====
 send(op: .write, commandId: ImageID.upload, payload: payload,
      timeout: uploadTimeoutInSeconds, callback: callback)
 
 作用：通过 SMP 协议将构建好的数据包发送到设备
 
 参数解析：
 - op: .write
   * SMP 操作类型为"写入"（Op Code = 2）
   * 对应 CBOR 中的 write request
   
 - commandId: ImageID.upload
   * 命令 ID = 1，表示这是 Image Upload 命令
   * 属于 Image Management Group (group = 1)
   
 - payload: 上面构建的 CBOR 字典
   * 包含 "data", "off"，首包额外有 "image", "len", "sha"
   
 - timeout: 超时时间（秒）
   * 首包用长超时（等待 flash erase）
   * 后续包用短超时
   
 - callback: 设备响应后的回调
   * 设备处理完数据后会返回 McuMgrUploadResponse
   * 响应中包含 "off" 字段 = 设备期望的下一个偏移量
   * 上层根据这个 off 值决定下次从哪里继续发送
 
 send() 方法内部做了什么：
 1. 将 payload 编码为 CBOR 二进制格式
 2. 添加 SMP Header（8字节：op, flags, length, group, seq, command）
 3. 通过 McuMgrBleTransport 写入 BLE Characteristic
 4. 等待设备通过同一 Characteristic 返回 Notification
 5. 解析响应数据并调用 callback
 
 
 ============================================================
 二十、upload() 方法在整个上传循环中的位置
 ============================================================
 
 完整上传循环：
 
 upload(images:using:delegate:)        ← 开始上传入口
   │
   ├→ upload(data, image, offset=0)    ← 发送首包
   │     │
   │     ↓ callback 返回 response.off
   │
   ├→ uploadCallback 处理响应
   │     │
   │     ├── 检查错误/取消/暂停
   │     │
   │     ├── 如果 off == data.count → 上传完成！
   │     │     └── uploadDidFinish() → 通知 FirmwareUpgradeManager
   │     │
   │     └── 如果 off < data.count → 继续发送
   │           │
   │           ├── pipelineDepth == 1: 直接调用 sendNext(from: off)
   │           │
   │           └── pipelineDepth > 1: 通过 uploadPipeline 管道调度
   │                 │
   │                 └── 同时发送多个 sendNext() 调用
   │
   └→ sendNext(from: offset)
         │
         └→ upload(data, image, offset, alignment, callback)  ← 回到本方法！
              （循环直到所有字节发送完毕）
 
 
 ============================================================
 二十一、uploadCallback（上传响应回调）逐行分析
 ============================================================
 
 这是 upload() 发送后设备返回响应的处理逻辑：
 
 uploadCallback = { [weak self] (response, error) in
 
     // 1. 错误处理
     if let error {
         // 特殊情况：MTU 不足
         if case McuMgrTransportError.insufficientMtu(let newMtu) = error {
             // 设备告知当前 MTU 太大，需要降低
             try self.setMtu(newMtu)    // 降低 MTU 值
             self.restartUpload()       // 用新 MTU 重新开始上传
             return
         }
         // 其他错误：取消上传，通知失败
         self.cancelUpload(error: error)
         return
     }
     
     // 2. 校验 match 字段
     guard response?.match ?? true else {
         // match=false 表示设备报告 offset 不匹配
         // 可能是数据包乱序或丢失，中止上传
         self.cancelUpload(error: ImageUploadError.offsetMismatch)
         return
     }
     
     // 3. 检查 response 中的 off 字段
     if let offset = response.off {
         // off 是设备告诉我们的"下次应该从哪个 offset 开始发"
         self.uploadLastOffset = offset
         
         // 通知管道已收到确认（用于流水线计数）
         self.uploadPipeline.receivedData(with: offset)
         
         // 4. 通知进度更新
         self.uploadDelegate?.uploadProgressDidChange(
             bytesSent: Int(offset),
             imageSize: currentImageData.count,
             timestamp: Date()
         )
         
         // 5. 检查是否取消/暂停
         if self.uploadState == .none { /* 已取消 */ return }
         guard self.uploadState == .uploading else { return /* 已暂停 */ }
         
         // 6. 检查当前 image 是否上传完成
         if offset == currentImageData.count {
             // 当前 image 上传完毕
             if self.uploadIndex == images.count - 1 {
                 // 所有 image 都上传完了 → 通知完成
                 self.uploadDelegate?.uploadDidFinish()
             } else {
                 // 还有下一个 image → 切换到下一个继续上传
                 self.uploadIndex += 1
                 self.imageData = images[self.uploadIndex].data
                 self.sendNext(from: 0)  // 从 offset=0 开始新 image
             }
             return
         }
         
         // 7. 还有数据要发 → 通过管道调度下一批发送
         self.uploadPipeline.pipelinedSend(ofSize: imageData.count) { offset in
             // 管道会根据 pipelineDepth 决定同时发几个
             self.sendNext(from: offset)
             // 返回预测的下一个 offset（用于管道追踪）
             return offset + payloadLength
         }
     }
 }
*/
/*
 ============================================================
 二十二、SMP Upload 数据包在 BLE 上的完整格式
 ============================================================
 
 一个完整的 SMP Upload 包结构（以首包为例）：
 
 ┌───────────────────────────────────────────────────────────────┐
 │ BLE Layer (L2CAP)                                             │
 ├───────────────────────────────────────────────────────────────┤
 │ ATT Layer (GATT Write Without Response)                       │
 │ Characteristic: DA2E7828-FBCE-4E01-AE9E-261174997C48         │
 ├───────────────────────────────────────────────────────────────┤
 │ SMP Header (8 bytes)                                          │
 │ ┌─────┬───────┬────────┬───────┬─────┬──────────┐            │
 │ │ Op  │ Flags │ Length │ Group │ Seq │ Command  │            │
 │ │ 0x02│ 0x00  │ XXXX   │ 0x0001│ XX  │ 0x01     │            │
 │ │Write│       │payload │ Image │ 序号 │ Upload   │            │
 │ │     │       │  len   │ Mgmt  │     │          │            │
 │ └─────┴───────┴────────┴───────┴─────┴──────────┘            │
 ├───────────────────────────────────────────────────────────────┤
 │ CBOR Payload                                                  │
 │ {                                                             │
 │   "data": <固件数据切片的字节数组>,     // 最大约 MTU-开销      │
 │   "off":  <当前偏移量>,                // uint64              │
 │   "image": <image编号>,                // 仅首包，且 >0 时     │
 │   "len":  <固件总长度>,                // 仅首包              │
 │   "sha":  <固件SHA256哈希>             // 仅首包              │
 │ }                                                             │
 └───────────────────────────────────────────────────────────────┘
 
 设备响应格式：
 ┌───────────────────────────────────────────────────────────────┐
 │ SMP Header (8 bytes) + CBOR Payload                           │
 │ {                                                             │
 │   "rc":  0,              // 返回码，0=成功                     │
 │   "off": <下次期望的偏移量> // 设备告诉 host 下次从哪里继续发    │
 │ }                                                             │
 └───────────────────────────────────────────────────────────────┘
 
 
 ============================================================
 二十三、Pipeline（管道传输）工作原理
 ============================================================
 
 传统模式 (pipelineDepth = 1)：
   发送 chunk[0] → 等响应 → 发送 chunk[1] → 等响应 → ...
   每个 RTT（往返时间）只能传一个包，慢！
 
 管道模式 (pipelineDepth = 3)：
   发送 chunk[0] ─┐
   发送 chunk[1] ─┤ 不等响应，连续发3个
   发送 chunk[2] ─┘
   ← 收到 chunk[0] 响应 → 立即发送 chunk[3]
   ← 收到 chunk[1] 响应 → 立即发送 chunk[4]
   ...
   始终保持3个"在途"的包，充分利用带宽
 
 管道传输要求：
 1. 设备端支持（有足够的 SMP 缓冲区）
 2. 需要 byteAlignment 来精确预测每个 chunk 的大小
 3. uploadPipeline 对象跟踪已发送/已确认的包数量
 
 速度对比（以 BLE MTU=251 为例）：
 - pipelineDepth=1: 约 2-3 KB/s
 - pipelineDepth=3: 约 6-9 KB/s
 - pipelineDepth=4 + reassemblyBuffer: 约 10-15 KB/s
 
 
 ============================================================
 二十四、完整的单包发送时序图
 ============================================================
 
 App (iOS)                          Device (nRF)
   │                                    │
   │  ① BLE Write (SMP Upload cmd)     │
   │  data[0..199], off=0, len=50000   │
   │ ──────────────────────────────────→│
   │                                    │ ② 设备收到首包
   │                                    │    擦除 secondary slot flash
   │                                    │    写入前 199 字节
   │                                    │
   │  ③ BLE Notify (SMP Response)      │
   │  { rc: 0, off: 199 }             │
   │ ←──────────────────────────────────│
   │                                    │
   │  ④ 计算下一个 chunk               │
   │  data[199..398], off=199          │
   │ ──────────────────────────────────→│
   │                                    │ ⑤ 写入 flash[199..398]
   │                                    │
   │  ⑥ { rc: 0, off: 398 }           │
   │ ←──────────────────────────────────│
   │                                    │
   │  ... 重复直到 off == 50000 ...     │
   │                                    │
   │  ⑦ 最后一包: data[49801..50000]   │
   │ ──────────────────────────────────→│
   │                                    │ ⑧ 写入完成
   │                                    │    校验 SHA-256
   │  ⑨ { rc: 0, off: 50000 }         │
   │ ←──────────────────────────────────│
   │                                    │
   │  ⑩ off == data.count              │
   │     上传完成! → uploadDidFinish()  │
   │                                    │
*/
