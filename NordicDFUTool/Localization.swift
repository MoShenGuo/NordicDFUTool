import Foundation

/// 国际化工具
/// 支持中文和英文，其他语言默认显示英文
struct L10n {
    
    /// 获取当前语言是否为中文
    private static var isChinese: Bool {
        guard let lang = Locale.preferredLanguages.first else { return false }
        return lang.hasPrefix("zh")
    }
    
    /// 本地化字符串
    static func s(_ chinese: String, _ english: String) -> String {
        return isChinese ? chinese : english
    }
}

// MARK: - 通用
extension L10n {
    static var cancel: String { s("取消", "Cancel") }
    static var confirm: String { s("确定", "OK") }
    static var back: String { s("返回", "Back") }
    static var refresh: String { s("刷新", "Refresh") }
    static var start: String { s("开始", "Start") }
    static var error: String { s("错误", "Error") }
    static var success: String { s("成功", "Success") }
    static var failed: String { s("失败", "Failed") }
    static var tip: String { s("提示", "Tip") }
}

// MARK: - 主页
extension L10n {
    static var appTitle: String { s("Nordic DFU Tool", "Nordic DFU Tool") }
    static var notConnected: String { s("未连接设备", "No device connected") }
    static var scanDevice: String { s("🔍 扫描设备", "🔍 Scan Devices") }
    static var manualUpgrade: String { s("📦 手动升级", "📦 Manual Upgrade") }
    static var autoUpgrade: String { s("🚀 自动升级", "🚀 Auto Upgrade") }
    static var clearCache: String { s("🗑️ 清理固件缓存", "🗑️ Clear Firmware Cache") }
    static var bleReady: String { s("🟢 蓝牙已就绪", "🟢 Bluetooth Ready") }
    static var bleOff: String { s("🔴 蓝牙已关闭，请打开蓝牙", "🔴 Bluetooth Off, please enable") }
    static var bleUnauthorized: String { s("⚠️ 蓝牙未授权，请在设置中允许", "⚠️ Bluetooth Unauthorized") }
    static var bleUnsupported: String { s("❌ 设备不支持蓝牙", "❌ Bluetooth Unsupported") }
    static var bleInitializing: String { s("⏳ 蓝牙初始化中...", "⏳ Bluetooth Initializing...") }
    static var connectFirst: String { s("请先扫描并连接一个设备", "Please scan and connect a device first") }
    static var bleUnavailable: String { s("蓝牙不可用", "Bluetooth Unavailable") }
}

// MARK: - 扫描
extension L10n {
    static var scanTitle: String { s("扫描设备", "Scan Devices") }
    static var scanning: String { s("🔍 正在扫描...", "🔍 Scanning...") }
    static func scanFound(_ count: Int) -> String {
        s("🔍 正在扫描... 已发现 \(count) 个设备", "🔍 Scanning... Found \(count) devices")
    }
    static func scanComplete(_ count: Int) -> String {
        s("✅ 扫描完成，发现 \(count) 个设备", "✅ Scan complete, found \(count) devices")
    }
    static var scanEmpty: String { s("❌ 未发现设备，请确认设备已开启并在附近", "❌ No devices found, check device is on and nearby") }
    static var scanDFUHint: String { s("💡 如果设备处于 DFU 模式，名称通常包含 \"DFU\"", "💡 Devices in DFU mode usually have \"DFU\" in their name") }
}

// MARK: - 升级相关
extension L10n {
    static var selectFirmware: String { s("📂 选择固件文件 (.zip / .bin)", "📂 Select Firmware (.zip / .bin)") }
    static var startUpgrade: String { s("⬆️ 开始升级", "⬆️ Start Upgrade") }
    static var selectFileFirst: String { s("请选择固件文件", "Please select a firmware file") }
    static var noFileSelected: String { s("❌ 未选择文件", "❌ No file selected") }
    static var noDeviceConnected: String { s("❌ 未连接设备，请先在首页连接", "❌ No device connected") }
    static var detecting: String { s("正在检测设备类型...", "Detecting device type...") }
    static var smpSupported: String { s("✅ 设备支持 SMP 协议，使用 McuManager OTA", "✅ Device supports SMP, using McuManager OTA") }
    static var smpNotSupported: String { s("⚠️ 设备不支持 SMP 协议，将使用旧版 Nordic DFU", "⚠️ Device doesn't support SMP, using legacy Nordic DFU") }
    
    // 模式选择
    static var selectMode: String { s("选择升级模式", "Select Upgrade Mode") }
    static var selectModeDesc: String { s("不同模式决定固件写入后的确认策略", "Different modes determine firmware confirmation strategy") }
    static var modeTestOnly: String { s("🧪 仅测试 (Test Only)", "🧪 Test Only") }
    static var modeConfirmOnly: String { s("✅ 仅确认 (Confirm Only) - 推荐", "✅ Confirm Only - Recommended") }
    static var modeTestAndConfirm: String { s("🔄 测试并确认 (Test & Confirm)", "🔄 Test & Confirm") }
    static var modeUploadOnly: String { s("⬆️ 仅上传 (Upload Only)", "⬆️ Upload Only") }
    
    // 旧版 DFU
    static var legacyDFUTitle: String { s("旧版 DFU 升级", "Legacy DFU Upgrade") }
    static var legacyDFUDesc: String { s("该设备不支持 SMP 协议，将使用传统 Nordic DFU 方式升级。\n\n设备会先收到 OTA 指令进入 DFU Bootloader 模式，然后开始固件传输。", "Device doesn't support SMP. Will use legacy Nordic DFU.\n\nDevice will receive OTA command to enter DFU Bootloader, then firmware transfer starts.") }
    static var sendOTAAndUpgrade: String { s("🔄 发送OTA指令并升级", "🔄 Send OTA Command & Upgrade") }
    static var scanDFUDirectly: String { s("📡 直接扫描DFU设备（已在DFU模式）", "📡 Scan DFU Device Directly (already in DFU mode)") }
    
    // 固件包验证
    static var invalidFirmware: String { s("固件包无效", "Invalid Firmware Package") }
    static func firmwareValidationFailed(_ reason: String) -> String {
        s("固件包校验失败: \(reason)", "Firmware validation failed: \(reason)")
    }
    static var firmwareNotZip: String { s("请选择 .zip 格式的固件包", "Please select a .zip firmware package") }
    static var firmwareNoManifest: String { s("固件包中未找到 manifest.json（McuManager 格式）或 .dat/.bin 文件（Nordic DFU 格式）", "No manifest.json (McuManager) or .dat/.bin files (Nordic DFU) found in firmware package") }
    static var firmwareCorrupt: String { s("固件包文件损坏，无法解析", "Firmware package is corrupt and cannot be parsed") }
    
    // 升级进度
    static var upgradeComplete: String { s("🎉 升级完成！", "🎉 Upgrade Complete!") }
    static func upgradeFailed(_ msg: String) -> String {
        s("❌ 升级失败: \(msg)", "❌ Upgrade failed: \(msg)")
    }
    static var upgradeCancelled: String { s("⚠️ 升级已取消", "⚠️ Upgrade cancelled") }
}

// MARK: - DFU 恢复
extension L10n {
    static var dfuRecoveryTitle: String { s("DFU 模式恢复升级", "DFU Mode Recovery") }
    static var dfuRecoveryDesc: String { s("检测到设备处于 DFU 模式（上次升级可能中断）。\n是否直接对该设备进行固件升级？", "Device appears to be in DFU mode (previous upgrade may have been interrupted).\nUpgrade this device directly?") }
    static var dfuRecoveryAction: String { s("选择固件并升级", "Select Firmware & Upgrade") }
}
