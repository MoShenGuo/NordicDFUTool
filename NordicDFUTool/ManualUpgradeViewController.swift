import UIKit
import iOSMcuManagerLibrary
import CoreBluetooth

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
        title = "手动升级"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        setupUI()
        updateStatistics()
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
    /// 前置检查：确保已选择文件 + 已连接设备，然后弹出模式选择
    @objc private func startUpgradeTapped() {
        // 检查是否已选择固件文件
        guard let fileURL = selectedFileURL else {
            appendLog("❌ 未选择文件")
            statusLabel.text = "❌ 未选择文件"
            statusLabel.textColor = .systemRed
            return
        }
        // 检查是否已连接 BLE 设备
        guard let peripheral = BLEManager.shared.currentPeripheral else {
            appendLog("❌ 未连接设备")
            statusLabel.text = "❌ 未连接设备，请先在首页连接"
            statusLabel.textColor = .systemRed
            return
        }
        
        // 弹出底部 ActionSheet 让用户选择升级模式
        showUpgradeModeSheet(fileURL: fileURL, peripheral: peripheral)
    }
    
    /// 从底部弹出升级模式选择框
    /// 四种模式对应 FirmwareUpgradeMode 的四个枚举值
    private func showUpgradeModeSheet(fileURL: URL, peripheral: CBPeripheral) {
        let sheet = UIAlertController(
            title: "选择升级模式",
            message: "不同模式决定固件写入后的确认策略",
            preferredStyle: .actionSheet
        )
        
        // 模式1: Test Only
        sheet.addAction(UIAlertAction(title: "🧪 仅测试 (Test Only)", style: .default) { [weak self] _ in
            self?.appendLog("📋 选择模式: Test Only")
            self?.startDFU(fileURL: fileURL, peripheral: peripheral, mode: .testOnly)
        })
        
        // 模式2: Confirm Only（推荐）
        sheet.addAction(UIAlertAction(title: "✅ 仅确认 (Confirm Only) - 推荐", style: .default) { [weak self] _ in
            self?.appendLog("📋 选择模式: Confirm Only (推荐)")
            self?.startDFU(fileURL: fileURL, peripheral: peripheral, mode: .confirmOnly)
        })
        
        // 模式3: Test and Confirm
        sheet.addAction(UIAlertAction(title: "🔄 测试并确认 (Test & Confirm)", style: .default) { [weak self] _ in
            self?.appendLog("📋 选择模式: Test and Confirm")
            self?.startDFU(fileURL: fileURL, peripheral: peripheral, mode: .testAndConfirm)
        })
        
        // 模式4: Upload Only
        sheet.addAction(UIAlertAction(title: "⬆️ 仅上传 (Upload Only)", style: .default) { [weak self] _ in
            self?.appendLog("📋 选择模式: Upload Only")
            self?.startDFU(fileURL: fileURL, peripheral: peripheral, mode: .uploadOnly)
        })
        
        // 取消
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        
        present(sheet, animated: true)
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
    /// 选择 .import 模式时，系统会将文件复制到 App 的 tmp 目录
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        selectedFileURL = url  // 保存选中的文件路径
        statusLabel.text = "✅ 已选择: \(url.lastPathComponent)"
        statusLabel.textColor = .systemGreen
        // 启用开始升级按钮
        startUpgradeButton.isEnabled = true
        startUpgradeButton.alpha = 1.0
        appendLog("📄 已选择文件: \(url.lastPathComponent)")
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
