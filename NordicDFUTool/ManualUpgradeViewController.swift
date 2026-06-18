import UIKit
import iOSMcuManagerLibrary
import CoreBluetooth
import NordicDFU
/// 手动升级页面
/// OTA 升级流程（手动模式）：
/// 1. 用户在首页先连接一个 BLE 设备
/// 2. 进入此页面，选择本地固件文件（.zip/.bin）
/// 3. 点击"开始升级"按钮，通过 McuManager 库执行 DFU
/// 4. DFU 过程：创建 BLE Transport → 解析固件包 → 分片传输 → 设备验证&重启
///
/// 使用的核心库：iOSMcuManagerLibrary（Nordic 官方 McuManager 库）
/// DFU 协议：SMP (Simple Management Protocol) over BLE
class ManualUpgradeViewController: UIViewController {
    
    // MARK: - UI 组件
    
    /// 选择固件文件按钮
    private let selectFileButton = UIButton(type: .system)
    /// 开始升级按钮
    private let startUpgradeButton = UIButton(type: .system)
    /// 升级进度条
    private let progressView = UIProgressView(progressViewStyle: .default)
    /// 状态标签（显示当前步骤或错误信息）
    private let statusLabel = UILabel()
    /// 进度百分比标签
    private let progressLabel = UILabel()
    /// 日志文本框（记录升级过程中的详细日志）
    private let logTextView = UITextView()
    /// 统计信息标签（成功/失败次数）
    private let statisticsLabel = UILabel()
    
    // MARK: - DFU 相关属性
    
    /// 用户选择的固件文件本地路径
    private var selectedFileURL: URL?
    
    /// DFU 升级管理器（iOSMcuManagerLibrary 核心类）
    /// FirmwareUpgradeManager 负责整个 DFU 流程的编排：
    /// 上传固件镜像 → 确认镜像 → 重置设备 → 等待设备重启
    private var dfuManager: FirmwareUpgradeManager?
    
    /// BLE 传输层（McuManager 通过此对象与设备通信）
    /// McuMgrBleTransport 封装了 BLE GATT 通信细节：
    /// 连接管理、MTU 协商、SMP 服务发现、数据分片发送/接收
    private var transport: McuMgrBleTransport?
    
    /// 旧版 DFU 管理器（iOSDFULibrary，用于不支持 SMP 的设备）
    private var legacyDFUManager: LegacyDFUManager?
    
    /// DFU 恢复模式：从扫描页面传入的 DFU 设备（用于中断后恢复升级）
    var preselectedDFUPeripheral: CBPeripheral?
    /// DFU 恢复模式：预选的固件文件
    var preselectedFirmwareURL: URL?
    
    /// 当前设备使用的 OTA 框架类型
    /// 在进入页面时通过检测 SMP 服务确定，后续选择固件和升级都依据此值
    private var frameworkType: OTAFrameworkType = .unknown
    
    // MARK: - 统计数据
    
    /// 当前升级开始时间（用于计算耗时）
    private var upgradeStartTime: Date?
    /// 本次会话总升级次数
    private var totalUpgrades: Int = 0
    /// 成功次数
    private var successUpgrades: Int = 0
    /// 失败次数
    private var failedUpgrades: Int = 0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.manualUpgrade
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        setupUI()
        updateStatistics()
        
        // DFU 恢复模式：预选 DFU 设备（已在 DFU 模式），直接走旧版
        if let dfuPeripheral = preselectedDFUPeripheral, let firmwareURL = preselectedFirmwareURL {
            frameworkType = .nordicDFU
            selectedFileURL = firmwareURL
            statusLabel.text = "🔄 DFU \(L10n.s("恢复模式", "Recovery Mode")): \(firmwareURL.lastPathComponent)"
            statusLabel.textColor = .systemBlue
            startUpgradeButton.isEnabled = false
            startUpgradeButton.alpha = 0.5
            appendLog("🔄 DFU \(L10n.s("恢复升级", "Recovery")): \(dfuPeripheral.name ?? "DFU Device")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startLegacyDFU(fileURL: firmwareURL, peripheral: dfuPeripheral, sendCommand: false)
            }
            return
        }
        
        // 正常模式：检测已连接设备支持哪种 OTA 框架
        detectFrameworkType()
    }
    
    /// 进入页面时检测设备的 OTA 框架类型
    private func detectFrameworkType() {
        guard let peripheral = BLEManager.shared.currentPeripheral else {
            frameworkType = .unknown
            statusLabel.text = L10n.s("请选择固件文件", "Please select firmware file")
            return
        }
        
        statusLabel.text = L10n.s("正在检测设备类型...", "Detecting device type...")
        statusLabel.textColor = .systemBlue
        appendLog("🔍 \(L10n.s("检测设备 OTA 协议...", "Detecting OTA protocol..."))")
        
        LegacyDFUManager.checkSMPSupport(peripheral: peripheral) { [weak self] supportsSMP in
            guard let self = self else { return }
            if supportsSMP {
                self.frameworkType = .mcuManager
                self.statusLabel.text = L10n.s("设备类型: McuManager (SMP)\n请选择 McuManager 格式固件包 (.zip 含 manifest.json)", "Device: McuManager (SMP)\nSelect McuManager firmware (.zip with manifest.json)")
                self.statusLabel.textColor = .systemGreen
                self.appendLog("✅ \(L10n.s("设备支持 SMP 协议", "Device supports SMP protocol"))")
            } else {
                self.frameworkType = .nordicDFU
                self.statusLabel.text = L10n.s("设备类型: Nordic DFU (旧版)\n请选择 Nordic DFU 格式固件包 (.zip 含 .dat + .bin)", "Device: Nordic DFU (Legacy)\nSelect Nordic DFU firmware (.zip with .dat + .bin)")
                self.statusLabel.textColor = .systemOrange
                self.appendLog("⚠️ \(L10n.s("设备使用旧版 Nordic DFU 协议", "Device uses legacy Nordic DFU protocol"))")
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 页面退出时取消正在进行的旧版 DFU，释放蓝牙资源
        // 这样再次进入时可以重新扫描和连接 DFU 设备
        legacyDFUManager?.abort()
        legacyDFUManager = nil
    }
    
    deinit {
        legacyDFUManager?.abort()
    }
    
    private func setupUI() {
        // Select File Button
        selectFileButton.setTitle("📂 选择固件文件 (.zip / .bin)", for: .normal)
        selectFileButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        selectFileButton.backgroundColor = .systemBlue
        selectFileButton.setTitleColor(.white, for: .normal)
        selectFileButton.layer.cornerRadius = 10
        selectFileButton.addTarget(self, action: #selector(selectFileTapped), for: .touchUpInside)
        selectFileButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(selectFileButton)
        
        // Status Label
        statusLabel.text = "请选择固件文件"
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        
        // Progress View
        progressView.progress = 0
        progressView.trackTintColor = .systemGray5
        progressView.progressTintColor = .systemBlue
        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressView)
        
        // Progress Label
        progressLabel.text = "0%"
        progressLabel.textAlignment = .center
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressLabel)
        
        // Statistics Label
        statisticsLabel.text = ""
        statisticsLabel.textAlignment = .center
        statisticsLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statisticsLabel.numberOfLines = 0
        statisticsLabel.textColor = .secondaryLabel
        statisticsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statisticsLabel)
        
        // Start Upgrade Button
        startUpgradeButton.setTitle("⬆️ 开始升级", for: .normal)
        startUpgradeButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        startUpgradeButton.backgroundColor = .systemGreen
        startUpgradeButton.setTitleColor(.white, for: .normal)
        startUpgradeButton.layer.cornerRadius = 10
        startUpgradeButton.isEnabled = false
        startUpgradeButton.alpha = 0.5
        startUpgradeButton.addTarget(self, action: #selector(startUpgradeTapped), for: .touchUpInside)
        startUpgradeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(startUpgradeButton)
        
        // Log TextView
        logTextView.isEditable = false
        logTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logTextView.backgroundColor = .systemGray6
        logTextView.layer.cornerRadius = 8
        logTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logTextView)
        
        NSLayoutConstraint.activate([
            selectFileButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            selectFileButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            selectFileButton.widthAnchor.constraint(equalToConstant: 280),
            selectFileButton.heightAnchor.constraint(equalToConstant: 44),
            
            statusLabel.topAnchor.constraint(equalTo: selectFileButton.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            progressView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            progressView.heightAnchor.constraint(equalToConstant: 8),
            
            progressLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 6),
            progressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            statisticsLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 10),
            statisticsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statisticsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            startUpgradeButton.topAnchor.constraint(equalTo: statisticsLabel.bottomAnchor, constant: 14),
            startUpgradeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            startUpgradeButton.widthAnchor.constraint(equalToConstant: 280),
            startUpgradeButton.heightAnchor.constraint(equalToConstant: 44),
            
            logTextView.topAnchor.constraint(equalTo: startUpgradeButton.bottomAnchor, constant: 16),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }
    
    // MARK: - 统计信息更新
    
    /// 更新统计标签的显示文字
    private func updateStatistics() {
        var text = "📊 本次会话: 总计 \(totalUpgrades) 次 | ✅ 成功 \(successUpgrades) | ❌ 失败 \(failedUpgrades)"
        if let start = upgradeStartTime {
            let elapsed = Int(Date().timeIntervalSince(start))
            text += "\n⏱ 当前升级耗时: \(elapsed / 60)分\(elapsed % 60)秒"
        }
        statisticsLabel.text = text
    }
    
    // MARK: - 用户交互
    
    /// 点击"选择固件文件"按钮
    /// 弹出系统文件选择器（UIDocumentPicker），支持 .zip 和 .bin 格式
    @objc private func selectFileTapped() {
        // 支持的文件类型：zip压缩包、通用二进制数据、macbinary
        let types = ["public.zip-archive", "public.data", "com.apple.macbinary-archive"]
        let picker = UIDocumentPickerViewController(documentTypes: types, in: .import)
        picker.delegate = self        // 文件选择结果通过代理回调
        picker.allowsMultipleSelection = false  // 只允许选一个文件
        present(picker, animated: true)
    }
    
    /// 点击"开始升级"按钮
    /// 框架类型已确定，固件已校验通过，直接开始对应流程
    @objc private func startUpgradeTapped() {
        guard let fileURL = selectedFileURL else {
            appendLog("❌ \(L10n.noFileSelected)")
            statusLabel.text = L10n.noFileSelected
            statusLabel.textColor = .systemRed
            return
        }
        guard let peripheral = BLEManager.shared.currentPeripheral else {
            appendLog("❌ \(L10n.noDeviceConnected)")
            statusLabel.text = L10n.noDeviceConnected
            statusLabel.textColor = .systemRed
            return
        }
        
        switch frameworkType {
        case .mcuManager:
            // 新版 SMP：弹出模式选择
            showSMPModeSheet(fileURL: fileURL, peripheral: peripheral)
        case .nordicDFU:
            // 旧版 DFU：弹出操作选择
            showLegacyDFUConfirm(fileURL: fileURL, peripheral: peripheral)
        case .unknown:
            // 兜底：重新检测
            showUpgradeModeSheet(fileURL: fileURL, peripheral: peripheral)
        }
    }
    
    /// 兜底：框架类型未知时重新检测
    private func showUpgradeModeSheet(fileURL: URL, peripheral: CBPeripheral) {
        appendLog("🔍 \(L10n.s("重新检测设备类型...", "Re-detecting device type..."))")
        statusLabel.text = L10n.detecting
        statusLabel.textColor = .systemBlue
        
        LegacyDFUManager.checkSMPSupport(peripheral: peripheral) { [weak self] supportsSMP in
            guard let self = self else { return }
            if supportsSMP {
                self.frameworkType = .mcuManager
                self.showSMPModeSheet(fileURL: fileURL, peripheral: peripheral)
            } else {
                self.frameworkType = .nordicDFU
                self.showLegacyDFUConfirm(fileURL: fileURL, peripheral: peripheral)
            }
        }
    }
    
    /// SMP 模式选择（新版设备）
    private func showSMPModeSheet(fileURL: URL, peripheral: CBPeripheral) {
        let sheet = UIAlertController(
            title: "选择升级模式",
            message: "设备支持 McuManager (SMP) 协议\n不同模式决定固件写入后的确认策略",
            preferredStyle: .actionSheet
        )
        
        sheet.addAction(UIAlertAction(title: "🧪 仅测试 (Test Only)", style: .default) { [weak self] _ in
            self?.appendLog("📋 选择模式: Test Only")
            self?.startDFU(fileURL: fileURL, peripheral: peripheral, mode: .testOnly)
        })
        
        sheet.addAction(UIAlertAction(title: "✅ 仅确认 (Confirm Only) - 推荐", style: .default) { [weak self] _ in
            self?.appendLog("📋 选择模式: Confirm Only (推荐)")
            self?.startDFU(fileURL: fileURL, peripheral: peripheral, mode: .confirmOnly)
        })
        
        sheet.addAction(UIAlertAction(title: "🔄 测试并确认 (Test & Confirm)", style: .default) { [weak self] _ in
            self?.appendLog("📋 选择模式: Test and Confirm")
            self?.startDFU(fileURL: fileURL, peripheral: peripheral, mode: .testAndConfirm)
        })
        
        sheet.addAction(UIAlertAction(title: "⬆️ 仅上传 (Upload Only)", style: .default) { [weak self] _ in
            self?.appendLog("📋 选择模式: Upload Only")
            self?.startDFU(fileURL: fileURL, peripheral: peripheral, mode: .uploadOnly)
        })
        
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }
    
    /// 旧版 DFU 确认弹框（不支持 SMP 的设备）
    private func showLegacyDFUConfirm(fileURL: URL, peripheral: CBPeripheral) {
        let sheet = UIAlertController(
            title: "旧版 DFU 升级",
            message: "该设备不支持 SMP 协议，将使用传统 Nordic DFU 方式升级。\n\n设备会先收到 OTA 指令进入 DFU Bootloader 模式，然后开始固件传输。",
            preferredStyle: .actionSheet
        )
        
        sheet.addAction(UIAlertAction(title: "🔄 发送OTA指令并升级", style: .default) { [weak self] _ in
            self?.startLegacyDFU(fileURL: fileURL, peripheral: peripheral, sendCommand: true)
        })
        
        sheet.addAction(UIAlertAction(title: "📡 直接扫描DFU设备（已在DFU模式）", style: .default) { [weak self] _ in
            self?.startLegacyDFU(fileURL: fileURL, peripheral: peripheral, sendCommand: false)
        })
        
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }
    
    // MARK: - 旧版 DFU 升级流程
    
    /// 启动旧版 Nordic DFU 升级
    private func startLegacyDFU(fileURL: URL, peripheral: CBPeripheral, sendCommand: Bool) {
        // 清理上一次的 DFU（如果有）
        legacyDFUManager?.abort()
        legacyDFUManager = nil
        
        // 在发送 OTA 指令之前，先深度验证固件包是否为有效的 Nordic DFU 格式
        // 避免发送了 OTA 指令设备进入 DFU 模式后，才发现固件包无法使用
        appendLog("🔍 \(L10n.s("验证固件包...", "Validating firmware..."))")
        do {
            // 尝试用 NordicDFU 库解析固件包，这会完整校验：
            // 1. ZIP 是否可解压
            // 2. 是否包含 manifest.json
            // 3. manifest.json 格式是否正确
            // 4. manifest 中引用的 .bin/.dat 文件是否存在
            let _ = try DFUFirmware(urlToZipFile: fileURL)
            appendLog("✅ \(L10n.s("固件包验证通过 (Nordic DFU 格式)", "Firmware validated (Nordic DFU format)"))")
        } catch {
            // 固件包不满足 Nordic DFU 要求，直接报错，不发送 OTA 指令
            let errorMsg = error.localizedDescription
            appendLog("❌ \(L10n.s("固件包验证失败", "Firmware validation failed")): \(errorMsg)")
            statusLabel.text = "❌ \(L10n.s("固件包无效", "Invalid firmware")): \(errorMsg)"
            statusLabel.textColor = .systemRed
            failedUpgrades += 1
            updateStatistics()
            startUpgradeButton.isEnabled = true
            startUpgradeButton.alpha = 1.0
            return
        }
        
        totalUpgrades += 1
        upgradeStartTime = Date()
        statusLabel.text = "⬆️ 正在升级（旧版 DFU）..."
        statusLabel.textColor = .systemBlue
        progressView.progress = 0
        progressLabel.text = "0%"
        startUpgradeButton.isEnabled = false
        startUpgradeButton.alpha = 0.5
        updateStatistics()
        
        legacyDFUManager = LegacyDFUManager()
        legacyDFUManager?.delegate = self
        
        if sendCommand {
            // 需要先发送 0x47 指令进入 DFU 模式
            // 注意：这里需要获取设备的写特征
            // 由于我们的 BLEManager 没有维护特征引用，这里传 nil
            // LegacyDFUManager 内部会处理
            appendLog("📡 发送 OTA 指令，等待设备进入 DFU 模式...")
            legacyDFUManager?.startLegacyOTA(peripheral: peripheral, firmwareURL: fileURL, writeCharacteristic: nil)
        } else {
            // 直接扫描已在 DFU 模式的设备
            appendLog("🔍 直接扫描 DFU 设备...")
            legacyDFUManager?.startScanDirectly(firmwareURL: fileURL)
        }
    }
    
    // MARK: - DFU 核心流程
    
    /// 启动 DFU（Device Firmware Update）固件升级流程
    ///
    /// - Parameters:
    ///   - fileURL: 固件文件本地路径（.zip 格式，内含 manifest + .bin 镜像）
    ///   - peripheral: 已连接的 BLE 外设对象
    ///   - mode: 升级模式（confirmOnly/testOnly/testAndConfirm/uploadOnly）
    private func startDFU(fileURL: URL, peripheral: CBPeripheral, mode: FirmwareUpgradeMode = .confirmOnly) {
        appendLog("📡 开始升级: \(peripheral.name ?? "Unknown")")
        appendLog("📦 固件文件: \(fileURL.lastPathComponent)")
        
        // 更新统计和 UI 状态
        totalUpgrades += 1
        upgradeStartTime = Date()
        statusLabel.text = "⬆️ 正在升级..."
        statusLabel.textColor = .systemBlue
        progressView.progress = 0
        progressLabel.text = "0%"
        
        // 禁用按钮防止重复操作
        startUpgradeButton.isEnabled = false
        startUpgradeButton.alpha = 0.5
        updateStatistics()
        
        // ====== 步骤1: 创建 BLE Transport ======
        // McuMgrBleTransport 是 McuManager 库的 BLE 传输层
        // 它会自动发现设备上的 SMP Service (UUID: 8D53DC1D-1DB7-4CD3-868B-8A527460AA84)
        // 并通过 SMP Characteristic 进行数据读写
        // 内部处理了 MTU 协商、数据分片、请求-响应匹配等 BLE 通信细节
        transport = McuMgrBleTransport(peripheral)
        
        guard let transport = transport else {
            appendLog("❌ 创建 BLE Transport 失败")
            statusLabel.text = "❌ 创建 BLE Transport 失败"
            statusLabel.textColor = .systemRed
            failedUpgrades += 1
            updateStatistics()
            startUpgradeButton.isEnabled = true
            startUpgradeButton.alpha = 1.0
            return
        }
        
        // ====== 步骤2: 创建 DFU 管理器 ======
        // FirmwareUpgradeManager 是 DFU 升级的核心控制器
        // 参数 transport: 指定通过哪个传输通道发送数据
        // 参数 delegate: self，升级过程中的状态变化、进度、完成/失败都通过代理回调
        dfuManager = FirmwareUpgradeManager(transport: transport, delegate: self)
        
        do {
            // ====== 步骤3: 解析固件包 ======
            // McuMgrPackage 会解析 .zip 文件中的 manifest.json
            // manifest.json 描述了固件包中有哪些镜像文件（可能有多个 image slot）
            // 每个 image 包含：文件路径、目标 slot 编号、版本号等
            // 解析后得到 package.images 数组，每个元素是一个待上传的固件镜像
            let package = try McuMgrPackage(from: fileURL)
            
            // ====== 步骤4: 配置升级参数 ======
            let config = FirmwareUpgradeConfiguration(
                estimatedSwapTime: 10.0,
                eraseAppSettings: false,
                pipelineDepth: 3,
                upgradeMode: mode
            )
            
            // ====== 步骤5: 启动升级 ======
            // start() 会触发以下内部流程：
            // 1. validate: 检查设备当前固件状态（读取 image list）
            // 2. upload: 将固件数据分片通过 SMP 协议上传到设备的 secondary slot
            // 3. test/confirm: 标记新固件为待测试/已确认
            // 4. reset: 发送重置命令让设备重启
            // 5. 设备重启后从新的 image slot 启动，升级完成
            try dfuManager?.start(images: package.images, using: config)
            appendLog("✅ DFU 已启动...")
        } catch {
            // 固件包解析失败或启动 DFU 失败
            appendLog("❌ 启动 DFU 失败: \(error.localizedDescription)")
            statusLabel.text = "❌ 启动失败: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
            failedUpgrades += 1
            updateStatistics()
            startUpgradeButton.isEnabled = true
            startUpgradeButton.alpha = 1.0
        }
    }
    
    /// 在日志文本框中追加一条日志
    /// - Parameter message: 日志内容
    private func appendLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self?.logTextView.text += "[\(timestamp)] \(message)\n"
            // 自动滚动到最新日志
            if let textView = self?.logTextView {
                let bottom = NSRange(location: textView.text.count - 1, length: 1)
                textView.scrollRangeToVisible(bottom)
            }
        }
    }
}

// MARK: - UIDocumentPickerDelegate（文件选择回调）
extension ManualUpgradeViewController: UIDocumentPickerDelegate {
    
    /// 用户成功选择了文件
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        
        // 根据已确定的框架类型，只校验对应格式的固件包
        switch frameworkType {
        case .mcuManager:
            validateForMcuManager(url: url)
        case .nordicDFU:
            validateForNordicDFU(url: url)
        case .unknown:
            // 未知类型，两种都尝试
            let result = FirmwareValidator.validate(fileURL: url)
            switch result {
            case .validMcuManager, .validNordicDFU:
                selectedFileURL = url
                statusLabel.text = "✅ \(L10n.s("已选择", "Selected")): \(url.lastPathComponent)"
                statusLabel.textColor = .systemGreen
                startUpgradeButton.isEnabled = true
                startUpgradeButton.alpha = 1.0
            case .invalid(let reason):
                rejectFirmware(reason: reason)
            }
        }
    }
    
    /// 验证是否为有效的 McuManager 固件包
    private func validateForMcuManager(url: URL) {
        guard url.pathExtension.lowercased() == "zip" else {
            rejectFirmware(reason: L10n.firmwareNotZip)
            return
        }
        
        do {
            let _ = try McuMgrPackage(from: url)
            // 解析成功，有效的 McuManager 格式
            selectedFileURL = url
            statusLabel.text = "✅ \(L10n.s("已选择 (McuManager格式)", "Selected (McuManager format)")): \(url.lastPathComponent)"
            statusLabel.textColor = .systemGreen
            startUpgradeButton.isEnabled = true
            startUpgradeButton.alpha = 1.0
            appendLog("📄 \(L10n.s("固件验证通过", "Firmware validated")): \(url.lastPathComponent) [McuManager ✓]")
        } catch {
            rejectFirmware(reason: L10n.s(
                "该固件包不是 McuManager 格式。\n当前设备需要含 manifest.json 的固件包。\n\n错误: \(error.localizedDescription)",
                "Not a McuManager firmware.\nThis device requires a package with manifest.json.\n\nError: \(error.localizedDescription)"))
        }
    }
    
    /// 验证是否为有效的 Nordic DFU 固件包
    private func validateForNordicDFU(url: URL) {
        guard url.pathExtension.lowercased() == "zip" else {
            rejectFirmware(reason: L10n.firmwareNotZip)
            return
        }
        
        do {
            let _ = try DFUFirmware(urlToZipFile: url)
            // 解析成功，有效的 Nordic DFU 格式
            selectedFileURL = url
            statusLabel.text = "✅ \(L10n.s("已选择 (Nordic DFU格式)", "Selected (Nordic DFU format)")): \(url.lastPathComponent)"
            statusLabel.textColor = .systemGreen
            startUpgradeButton.isEnabled = true
            startUpgradeButton.alpha = 1.0
            appendLog("📄 \(L10n.s("固件验证通过", "Firmware validated")): \(url.lastPathComponent) [Nordic DFU ✓]")
        } catch {
            rejectFirmware(reason: L10n.s(
                "该固件包不是有效的 Nordic DFU 格式。\n当前设备需要含 .dat + .bin 的固件包。\n\n错误: \(error.localizedDescription)",
                "Not a valid Nordic DFU firmware.\nThis device requires a package with .dat + .bin.\n\nError: \(error.localizedDescription)"))
        }
    }
    
    /// 拒绝固件：红色提示，按钮置灰
    private func rejectFirmware(reason: String) {
        selectedFileURL = nil
        statusLabel.text = "❌ \(reason)"
        statusLabel.textColor = .systemRed
        startUpgradeButton.isEnabled = false
        startUpgradeButton.alpha = 0.5
        appendLog("❌ \(L10n.s("固件包不符合要求", "Firmware not compatible")): \(reason)")
    }
}

// MARK: - FirmwareUpgradeDelegate（DFU 升级代理回调）
// 这些方法由 FirmwareUpgradeManager 在升级过程中调用
// 用于通知升级状态变化、进度更新、完成或失败
extension ManualUpgradeViewController: FirmwareUpgradeDelegate {
    
    /// DFU 升级已启动
    /// 在调用 start() 后，manager 准备就绪时触发
    func upgradeDidStart(controller: FirmwareUpgradeController) {
        appendLog("🚀 升级开始")
    }
    
    /// DFU 状态机状态变化
    /// 状态流转顺序: validate → upload → test → confirm → reset → success
    /// - validate: 检查设备当前 image 状态（读取 slot 信息）
    /// - upload: 正在上传固件数据到设备的 secondary slot
    /// - test: 标记新固件为"待测试"（下次重启生效）
    /// - confirm: 确认新固件（永久切换到新固件）
    /// - reset: 发送重置命令，设备即将重启
    func upgradeStateDidChange(from previousState: FirmwareUpgradeState, to newState: FirmwareUpgradeState) {
        appendLog("📍 状态: \(previousState) → \(newState)")
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = "📍 \(newState)"
            self?.statusLabel.textColor = .systemBlue
        }
    }
    
    /// DFU 升级成功完成
    /// 设备已经成功刷入新固件并重启
    /// 此时设备运行的是新版本固件
    func upgradeDidComplete() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.progressView.progress = 1.0
            self.progressLabel.text = "100%"
            self.statusLabel.text = "🎉 升级完成！"
            self.statusLabel.textColor = .systemGreen
            // 恢复按钮状态
            self.startUpgradeButton.isEnabled = true
            self.startUpgradeButton.alpha = 1.0
            // 更新统计
            self.successUpgrades += 1
            self.updateStatistics()
        }
        appendLog("🎉 升级完成！")
    }
    
    /// DFU 升级失败
    /// 可能的失败原因：
    /// - 设备断开连接
    /// - 固件校验失败（签名不匹配）
    /// - 上传过程中设备拒绝数据
    /// - swap 超时（设备重启后未能切换到新固件）
    /// - Parameters:
    ///   - state: 失败时处于的 DFU 阶段
    ///   - error: 具体错误信息
    func upgradeDidFail(inState state: FirmwareUpgradeState, with error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusLabel.text = "❌ 升级失败: \(error.localizedDescription)"
            self.statusLabel.textColor = .systemRed
            self.startUpgradeButton.isEnabled = true
            self.startUpgradeButton.alpha = 1.0
            self.failedUpgrades += 1
            self.updateStatistics()
        }
        appendLog("❌ 升级失败 [\(state)]: \(error.localizedDescription)")
    }
    
    /// DFU 升级被取消
    /// 用户主动取消或系统中断时触发
    func upgradeDidCancel(state: FirmwareUpgradeState) {
        appendLog("⚠️ 升级已取消 [\(state)]")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusLabel.text = "⚠️ 升级已取消"
            self.statusLabel.textColor = .systemOrange
            self.startUpgradeButton.isEnabled = true
            self.startUpgradeButton.alpha = 1.0
            self.failedUpgrades += 1
            self.updateStatistics()
        }
    }
    
    /// 固件上传进度更新
    /// 在 upload 阶段，每发送一批数据后触发
    /// - Parameters:
    ///   - bytesSent: 已发送的字节数
    ///   - imageSize: 固件镜像总大小（字节）
    ///   - timestamp: 时间戳
    func uploadProgressDidChange(bytesSent: Int, imageSize: Int, timestamp: Date) {
        DispatchQueue.main.async { [weak self] in
            // 计算当前进度（0.0 ~ 1.0）
            let progress = Float(bytesSent) / Float(imageSize)
            self?.progressView.progress = progress
            self?.progressLabel.text = String(format: "%.1f%%", progress * 100)
            self?.updateStatistics()
        }
    }
}

// MARK: - LegacyDFUManagerDelegate（旧版 DFU 代理回调）

extension ManualUpgradeViewController: LegacyDFUManagerDelegate {
    
    func legacyDFU(_ manager: LegacyDFUManager, didChangeState description: String) {
        appendLog("📍 \(description)")
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = description
            self?.statusLabel.textColor = .systemBlue
        }
    }
    
    func legacyDFU(_ manager: LegacyDFUManager, didUpdateProgress progress: Int, speed: Double, part: Int, totalParts: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.progressView.progress = Float(progress) / 100.0
            self?.progressLabel.text = "\(progress)%"
            if totalParts > 1 {
                self?.statusLabel.text = "正在传输固件 (\(part)/\(totalParts))...\n速度: \(String(format: "%.1f", speed / 1024.0)) KB/s"
            } else {
                self?.statusLabel.text = "正在传输固件...\n速度: \(String(format: "%.1f", speed / 1024.0)) KB/s"
            }
        }
    }
    
    func legacyDFUDidComplete(_ manager: LegacyDFUManager) {
        appendLog("🎉 旧版 DFU 升级完成！")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.progressView.progress = 1.0
            self.progressLabel.text = "100%"
            self.statusLabel.text = "🎉 升级完成！"
            self.statusLabel.textColor = .systemGreen
            self.startUpgradeButton.isEnabled = true
            self.startUpgradeButton.alpha = 1.0
            self.successUpgrades += 1
            self.updateStatistics()
        }
    }
    
    func legacyDFU(_ manager: LegacyDFUManager, didFailWithError error: String) {
        appendLog("❌ 旧版 DFU 失败: \(error)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusLabel.text = "❌ 升级失败: \(error)"
            self.statusLabel.textColor = .systemRed
            self.startUpgradeButton.isEnabled = true
            self.startUpgradeButton.alpha = 1.0
            self.failedUpgrades += 1
            self.updateStatistics()
        }
    }
}
