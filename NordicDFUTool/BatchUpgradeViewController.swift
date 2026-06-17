import UIKit
import CoreBluetooth
import iOSMcuManagerLibrary

/// 设备升级状态枚举
/// 每个设备在批量升级过程中会经历以下状态流转：
/// waiting → connecting → upgrading → success/failed
enum DeviceUpgradeStatus {
    case waiting                    // 排队等待中，尚未开始
    case connecting                 // 正在建立 BLE 连接
    case upgrading(progress: Float) // 正在上传固件，progress 为 0.0~1.0
    case success                    // 升级成功，设备已运行新固件
    case failed(error: String)      // 升级失败，附带错误描述
    
    /// 状态的中文展示文本
    var displayText: String {
        switch self {
        case .waiting: return "等待中..."
        case .connecting: return "连接中..."
        case .upgrading(let progress): return String(format: "升级中 %.1f%%", progress * 100)
        case .success: return "✅ 升级成功"
        case .failed(let error): return "❌ 失败: \(error)"
        }
    }
}

/// 设备升级条目（每个待升级设备对应一个 Item）
class DeviceUpgradeItem {
    let peripheral: CBPeripheral        // BLE 外设对象
    var status: DeviceUpgradeStatus = .waiting  // 当前升级状态
    
    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }
}

/// 批量升级页面
/// OTA 升级流程（自动批量模式）：
/// 1. 从 AutoUpgradeViewController 传入固件信息和设备型号
/// 2. 下载固件包（或使用本地缓存）
/// 3. 扫描所有名称匹配的 BLE 设备
/// 4. 逐个连接设备并执行 DFU 升级（串行，一次一个）
/// 5. 统计升级结果（成功/失败数量）
///
/// 批量升级策略：串行逐个升级（非并行）
/// 原因：BLE 同一时间只能连接一个设备进行 DFU，升级完成后断开再连接下一个
class BatchUpgradeViewController: UIViewController {
    
    /// 要升级到的目标固件信息（从上个页面传入）
    private let firmware: FirmwareInfo
    /// 目标设备型号名称，用于扫描时按名称筛选设备
    private let deviceName: String
    /// 升级模式
    private let upgradeMode: FirmwareUpgradeMode
    
    // MARK: - UI 组件
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let statusLabel = UILabel()
    private let downloadProgressView = UIProgressView(progressViewStyle: .default)
    private let downloadLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let statisticsLabel = UILabel()
    private let logTextView = UITextView()
    private let tableView = UITableView()
    
    // MARK: - DFU 状态管理
    
    /// 下载后的固件文件本地路径
    private var firmwareFileURL: URL?
    /// 所有待升级的设备列表
    private var devices: [DeviceUpgradeItem] = []
    /// 当前正在升级的设备索引（-1 表示尚未开始）
    private var currentUpgradeIndex: Int = -1
    /// 当前设备的 BLE Transport 实例
    private var currentTransport: McuMgrBleTransport?
    /// 当前设备的 DFU Manager 实例
    private var currentDFUManager: FirmwareUpgradeManager?

    // MARK: - 统计数据
    private var totalDevices: Int = 0    // 待升级设备总数
    private var successCount: Int = 0    // 升级成功数
    private var failCount: Int = 0       // 升级失败数
    private var startTime: Date?         // 批量升级开始时间
    
    /// 初始化方法，传入固件信息和目标设备型号
    init(firmware: FirmwareInfo, deviceName: String, upgradeMode: FirmwareUpgradeMode = .confirmOnly) {
        self.firmware = firmware
        self.deviceName = deviceName
        self.upgradeMode = upgradeMode
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "批量升级 v\(firmware.version)"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        setupUI()
        // 页面加载后立即开始下载固件（或检查缓存）
        startDownload()
    }
    
    private func setupUI() {
        statusLabel.text = "正在检查固件..."
        statusLabel.textAlignment = .center
        statusLabel.font = .boldSystemFont(ofSize: 16)
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        
        downloadProgressView.progress = 0
        downloadProgressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(downloadProgressView)
        
        downloadLabel.text = ""
        downloadLabel.textAlignment = .center
        downloadLabel.font = .systemFont(ofSize: 13)
        downloadLabel.textColor = .secondaryLabel
        downloadLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(downloadLabel)

        statisticsLabel.text = ""
        statisticsLabel.textAlignment = .center
        statisticsLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statisticsLabel.numberOfLines = 0
        statisticsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statisticsLabel)
        
        startButton.setTitle("🚀 开始批量升级", for: .normal)
        startButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        startButton.backgroundColor = .systemOrange
        startButton.setTitleColor(.white, for: .normal)
        startButton.layer.cornerRadius = 10
        startButton.isHidden = true
        startButton.addTarget(self, action: #selector(startBatchUpgrade), for: .touchUpInside)
        startButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(startButton)
        
        logTextView.isEditable = false
        logTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.backgroundColor = .systemGray6
        logTextView.layer.cornerRadius = 8
        logTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logTextView)
        
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(DeviceUpgradeCell.self, forCellReuseIdentifier: "DeviceUpgradeCell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            downloadProgressView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            downloadProgressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            downloadProgressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            downloadLabel.topAnchor.constraint(equalTo: downloadProgressView.bottomAnchor, constant: 4),
            downloadLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statisticsLabel.topAnchor.constraint(equalTo: downloadLabel.bottomAnchor, constant: 8),
            statisticsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statisticsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            startButton.topAnchor.constraint(equalTo: statisticsLabel.bottomAnchor, constant: 12),
            startButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            startButton.widthAnchor.constraint(equalToConstant: 220),
            startButton.heightAnchor.constraint(equalToConstant: 44),
            logTextView.topAnchor.constraint(equalTo: startButton.bottomAnchor, constant: 12),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logTextView.heightAnchor.constraint(equalToConstant: 100),
            tableView.topAnchor.constraint(equalTo: logTextView.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    // MARK: - 日志输出
    
    /// 追加日志到 logTextView，自动添加时间戳并滚动到底部
    private func appendLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.logTextView.text += "[\(timestamp)] \(message)\n"
            let bottom = NSRange(location: self.logTextView.text.count - 1, length: 1)
            self.logTextView.scrollRangeToVisible(bottom)
        }
    }
    
    /// 更新统计信息标签
    /// 统计各状态设备数量并显示已用时间
    private func updateStatistics() {
        // 统计成功数
        successCount = devices.filter { if case .success = $0.status { return true }; return false }.count
        // 统计失败数
        failCount = devices.filter { if case .failed = $0.status { return true }; return false }.count
        // 统计等待中的数量（包括 waiting/connecting/upgrading）
        let waitingCount = devices.filter {
            switch $0.status {
            case .waiting, .connecting, .upgrading: return true
            default: return false
            }
        }.count
        
        var statsText = "📊 总计: \(totalDevices) | ✅ 成功: \(successCount) | ❌ 失败: \(failCount)"
        if waitingCount > 0 {
            statsText += " | ⏳ 等待: \(waitingCount)"
        }
        if let start = startTime {
            let elapsed = Int(Date().timeIntervalSince(start))
            statsText += "\n⏱ 已用时: \(elapsed / 60)分\(elapsed % 60)秒"
        }
        statisticsLabel.text = statsText
    }
    
    // MARK: - 步骤1: 下载固件
    
    /// 开始下载固件（或使用本地缓存）
    /// 这是批量升级的第一步：确保本地有固件文件可用
    private func startDownload() {
        // 先检查本地缓存：如果之前下载过同一固件，直接使用缓存跳过下载
        if let cachedURL = FirmwareService.shared.getCachedFirmware(for: firmware.firmwareUrl) {
            appendLog("📦 使用缓存固件: \(cachedURL.lastPathComponent)")
            firmwareFileURL = cachedURL
            downloadProgressView.progress = 1.0
            downloadLabel.text = "已使用本地缓存（跳过下载）"
            statusLabel.text = "✅ 固件已就绪（缓存），正在搜索设备..."
            // 固件就绪，进入下一步：扫描匹配设备
            scanForMatchingDevices()
            return
        }
        
        // 没有缓存，需要从服务器下载
        appendLog("⬇️ 开始下载固件: \(firmware.firmwareUrl)")
        statusLabel.text = "正在下载固件..."
        
        FirmwareService.shared.downloadFirmware(from: firmware.firmwareUrl, skipIfCached: false, progress: { [weak self] progress in
            // 更新下载进度条
            self?.downloadProgressView.progress = Float(progress)
            self?.downloadLabel.text = String(format: "下载中 %.0f%%", progress * 100)
        }, completion: { [weak self] result in
            switch result {
            case .success(let fileURL):
                self?.firmwareFileURL = fileURL
                self?.downloadComplete()
            case .failure(let error):
                self?.statusLabel.text = "❌ 下载失败: \(error.localizedDescription)"
                self?.statusLabel.textColor = .systemRed
                self?.appendLog("❌ 下载失败: \(error.localizedDescription)")
            }
        })
    }

    /// 固件下载完成后的处理
    private func downloadComplete() {
        statusLabel.text = "✅ 固件下载完成，正在搜索设备..."
        downloadLabel.text = "下载完成"
        downloadProgressView.progress = 1.0
        appendLog("✅ 固件下载完成")
        // 进入下一步：扫描匹配设备
        scanForMatchingDevices()
    }
    
    // MARK: - 步骤2: 扫描匹配设备
    
    /// 扫描周围所有名称匹配目标型号的 BLE 设备
    /// 扫描策略：
    /// 1. 先检查当前是否已有连接的匹配设备，直接加入列表
    /// 2. 再广播扫描 8 秒，收集所有匹配的设备
    private func scanForMatchingDevices() {
        appendLog("🔍 开始搜索匹配设备: \"\(deviceName)\"")
        
        // 如果当前已有连接的设备且名称匹配，优先加入升级列表
        if let connected = BLEManager.shared.currentPeripheral,
           let name = connected.name,
           name.lowercased().contains(deviceName.lowercased()) {
            devices.append(DeviceUpgradeItem(peripheral: connected))
            appendLog("📱 已添加已连接设备: \(name)")
        }
        
        // 扫描 8 秒，收集所有名称匹配的设备
        BLEManager.shared.scanForDevices(withName: deviceName, timeout: 8.0) { [weak self] peripherals in
            guard let self = self else { return }
            
            // 将扫描到的设备加入列表（去重）
            for peripheral in peripherals {
                if !self.devices.contains(where: { $0.peripheral.identifier == peripheral.identifier }) {
                    self.devices.append(DeviceUpgradeItem(peripheral: peripheral))
                    self.appendLog("📱 发现设备: \(peripheral.name ?? "Unknown")")
                }
            }
            
            self.totalDevices = self.devices.count
            
            if self.devices.isEmpty {
                self.statusLabel.text = "❌ 未找到名称匹配 \"\(self.deviceName)\" 的设备"
                self.statusLabel.textColor = .systemRed
                self.appendLog("❌ 搜索完成，未找到匹配设备")
            } else {
                self.statusLabel.text = "找到 \(self.devices.count) 个匹配设备，点击开始升级"
                self.startButton.isHidden = false
                self.appendLog("✅ 搜索完成，找到 \(self.devices.count) 个匹配设备")
            }
            self.updateStatistics()
            self.tableView.reloadData()
        }
    }
    
    // MARK: - 步骤3: 批量升级主循环
    
    /// 点击"开始批量升级"按钮，启动升级主循环
    @objc private func startBatchUpgrade() {
        startButton.isHidden = true
        statusLabel.text = "🚀 批量升级进行中..."
        startTime = Date()           // 记录开始时间
        currentUpgradeIndex = -1     // 重置索引
        appendLog("🚀 开始批量升级，共 \(devices.count) 个设备")
        upgradeNextDevice()          // 开始升级第一个设备
    }

    /// 升级下一个设备（递归调用，直到所有设备处理完毕）
    /// 批量升级核心逻辑：串行处理设备队列
    /// 每个设备的处理流程：连接 → DFU升级 → 断开 → 处理下一个
    private func upgradeNextDevice() {
        // 移动到下一个设备
        currentUpgradeIndex += 1
        
        // 递归终止条件：所有设备已处理完
        if currentUpgradeIndex >= devices.count {
            updateStatistics()
            let elapsed = startTime.map { Int(Date().timeIntervalSince($0)) } ?? 0
            statusLabel.text = "升级完成！成功: \(successCount) 失败: \(failCount) 用时: \(elapsed/60)分\(elapsed%60)秒"
            statusLabel.textColor = successCount == devices.count ? .systemGreen : .systemOrange
            appendLog("🏁 批量升级完成 - 成功: \(successCount), 失败: \(failCount)")
            return
        }
        
        let item = devices[currentUpgradeIndex]
        let peripheral = item.peripheral
        
        updateStatistics()
        
        // 验证设备名称确实匹配（防御性检查）
        guard let name = peripheral.name,
              name.lowercased().contains(deviceName.lowercased()) else {
            item.status = .failed(error: "设备名称不匹配")
            tableView.reloadRows(at: [IndexPath(row: currentUpgradeIndex, section: 0)], with: .automatic)
            appendLog("⚠️ 设备名称不匹配，跳过")
            BLEManager.shared.disconnect()
            upgradeNextDevice()  // 跳过此设备，处理下一个
            return
        }
        
        // 更新状态为"连接中"
        item.status = .connecting
        tableView.reloadRows(at: [IndexPath(row: currentUpgradeIndex, section: 0)], with: .automatic)
        appendLog("📡 正在连接设备 [\(currentUpgradeIndex + 1)/\(devices.count)]: \(name)")
        
        // 判断是否是当前已连接的设备
        if BLEManager.shared.currentPeripheral?.identifier == peripheral.identifier {
            // 如果目标设备就是当前已连接的，直接开始 DFU（无需重新连接）
            startDFUForCurrentDevice(item: item)
        } else {
            // 需要先断开当前设备，再连接目标设备
            BLEManager.shared.disconnect()
            
            // 设置连接成功回调
            BLEManager.shared.onConnected = { [weak self] connectedPeripheral in
                // 确认是目标设备连接成功
                guard connectedPeripheral.identifier == peripheral.identifier else { return }
                self?.appendLog("✅ 已连接: \(connectedPeripheral.name ?? "Unknown")")
                self?.startDFUForCurrentDevice(item: item)
            }
            
            // 设置断开回调（处理连接失败的情况）
            BLEManager.shared.onDisconnected = { [weak self] _, error in
                guard let self = self else { return }
                // 确认是当前正在处理的设备断开了
                if self.devices[self.currentUpgradeIndex].peripheral.identifier == peripheral.identifier {
                    // 只在"连接中"状态处理（排除升级过程中的正常断开）
                    if case .connecting = item.status {
                        let errMsg = error?.localizedDescription ?? "Unknown"
                        item.status = .failed(error: "连接失败: \(errMsg)")
                        self.appendLog("❌ 连接失败: \(errMsg)")
                        DispatchQueue.main.async {
                            self.tableView.reloadRows(at: [IndexPath(row: self.currentUpgradeIndex, section: 0)], with: .automatic)
                            self.updateStatistics()
                            self.upgradeNextDevice()  // 此设备失败，继续下一个
                        }
                    }
                }
            }
            
            // 发起连接请求
            BLEManager.shared.connect(peripheral: peripheral)
        }
    }

    /// 对当前已连接的设备执行 DFU 升级
    /// 这是批量升级中每个设备的核心 DFU 执行方法
    /// 流程与 ManualUpgradeViewController.startDFU() 相同：
    /// 创建 Transport → 创建 Manager → 解析固件包 → 启动升级
    ///
    /// - Parameter item: 当前设备的升级条目
    private func startDFUForCurrentDevice(item: DeviceUpgradeItem) {
        // 确保固件文件存在
        guard let fileURL = firmwareFileURL else {
            item.status = .failed(error: "固件文件不存在")
            tableView.reloadRows(at: [IndexPath(row: currentUpgradeIndex, section: 0)], with: .automatic)
            appendLog("❌ 固件文件不存在")
            updateStatistics()
            upgradeNextDevice()
            return
        }
        
        // 更新状态为"升级中"，进度从0开始
        item.status = .upgrading(progress: 0)
        tableView.reloadRows(at: [IndexPath(row: currentUpgradeIndex, section: 0)], with: .automatic)
        appendLog("⬆️ 开始固件升级...")
        
        // 创建 BLE Transport（基于当前设备的 CBPeripheral）
        // McuMgrBleTransport 会自动发现 SMP 服务并建立通信通道
        currentTransport = McuMgrBleTransport(item.peripheral)
        
        guard let transport = currentTransport else {
            item.status = .failed(error: "创建 Transport 失败")
            tableView.reloadRows(at: [IndexPath(row: currentUpgradeIndex, section: 0)], with: .automatic)
            appendLog("❌ 创建 BLE Transport 失败")
            updateStatistics()
            upgradeNextDevice()
            return
        }
        
        // 创建 DFU 管理器，delegate 设为 self 接收升级回调
        currentDFUManager = FirmwareUpgradeManager(transport: transport, delegate: self)
        
        do {
            // 解析固件包（.zip → manifest.json → images）
            let package = try McuMgrPackage(from: fileURL)
            // 配置升级参数
            let config = FirmwareUpgradeConfiguration(
                estimatedSwapTime: 10.0,  // 等待设备重启切换固件的超时时间
                eraseAppSettings: false,  // 不擦除设备应用设置
                pipelineDepth: 3,         // 并发传输深度，提升上传速度
                upgradeMode: upgradeMode  // 使用用户选择的升级模式
            )
            // 启动 DFU：开始向设备上传固件并执行升级流程
            try currentDFUManager?.start(images: package.images, using: config)
        } catch {
            item.status = .failed(error: error.localizedDescription)
            tableView.reloadRows(at: [IndexPath(row: currentUpgradeIndex, section: 0)], with: .automatic)
            appendLog("❌ DFU启动失败: \(error.localizedDescription)")
            updateStatistics()
            upgradeNextDevice()
        }
    }
}

// MARK: - FirmwareUpgradeDelegate（DFU 升级代理回调）
// 批量升级时，每个设备的 DFU 过程都通过这些回调通知结果
// 完成/失败后会自动断开连接并调用 upgradeNextDevice() 处理下一个设备
extension BatchUpgradeViewController: FirmwareUpgradeDelegate {
    
    /// DFU 升级已启动（manager 开始工作）
    func upgradeDidStart(controller: FirmwareUpgradeController) {
        appendLog("🚀 DFU 升级已启动")
    }
    
    /// DFU 状态机状态变更
    /// 状态流转: validate → upload → test → confirm → reset → complete
    func upgradeStateDidChange(from previousState: FirmwareUpgradeState, to newState: FirmwareUpgradeState) {
        appendLog("📍 状态变更: \(previousState) → \(newState)")
    }
    
    /// 当前设备 DFU 升级成功
    /// 处理逻辑：标记成功 → 断开连接 → 等待1秒 → 升级下一个设备
    /// 等待1秒是为了给设备重启和 BLE 广播恢复留出时间
    func upgradeDidComplete() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentUpgradeIndex < self.devices.count else { return }
            let item = self.devices[self.currentUpgradeIndex]
            // 标记此设备升级成功
            item.status = .success
            self.tableView.reloadRows(at: [IndexPath(row: self.currentUpgradeIndex, section: 0)], with: .automatic)
            self.appendLog("🎉 设备升级成功: \(item.peripheral.name ?? "Unknown")")
            self.updateStatistics()
            
            // 断开当前设备的 BLE 连接
            BLEManager.shared.disconnect()
            // 延迟1秒后开始升级下一个设备（给 BLE 协议栈恢复时间）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.upgradeNextDevice()
            }
        }
    }
    
    /// 当前设备 DFU 升级失败
    /// 处理逻辑：标记失败 → 断开连接 → 等待1秒 → 继续升级下一个设备
    /// 单个设备失败不影响其他设备的升级
    func upgradeDidFail(inState state: FirmwareUpgradeState, with error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentUpgradeIndex < self.devices.count else { return }
            let item = self.devices[self.currentUpgradeIndex]
            let errMsg = "[\(state)] \(error.localizedDescription)"
            // 标记此设备升级失败，记录失败阶段和错误信息
            item.status = .failed(error: errMsg)
            self.tableView.reloadRows(at: [IndexPath(row: self.currentUpgradeIndex, section: 0)], with: .automatic)
            self.appendLog("❌ 升级失败: \(errMsg)")
            self.updateStatistics()
            
            // 断开连接并继续下一个
            BLEManager.shared.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.upgradeNextDevice()
            }
        }
    }

    /// 升级被取消
    func upgradeDidCancel(state: FirmwareUpgradeState) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentUpgradeIndex < self.devices.count else { return }
            let item = self.devices[self.currentUpgradeIndex]
            item.status = .failed(error: "已取消")
            self.tableView.reloadRows(at: [IndexPath(row: self.currentUpgradeIndex, section: 0)], with: .automatic)
            self.appendLog("⚠️ 升级已取消")
            self.updateStatistics()
            self.upgradeNextDevice()
        }
    }
    
    /// 固件上传进度回调
    /// 在 upload 阶段，每次发送数据后触发
    /// 用于更新当前设备的进度显示
    /// - Parameters:
    ///   - bytesSent: 已发送字节数
    ///   - imageSize: 固件镜像总大小
    ///   - timestamp: 时间戳
    func uploadProgressDidChange(bytesSent: Int, imageSize: Int, timestamp: Date) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentUpgradeIndex < self.devices.count else { return }
            // 计算上传进度
            let progress = Float(bytesSent) / Float(imageSize)
            let item = self.devices[self.currentUpgradeIndex]
            // 更新设备状态中的进度值
            item.status = .upgrading(progress: progress)
            // 刷新对应 cell 显示进度条
            self.tableView.reloadRows(at: [IndexPath(row: self.currentUpgradeIndex, section: 0)], with: .none)
        }
    }
}

// MARK: - UITableView DataSource & Delegate
extension BatchUpgradeViewController: UITableViewDataSource, UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return devices.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceUpgradeCell", for: indexPath) as! DeviceUpgradeCell
        let item = devices[indexPath.row]
        cell.configure(with: item)
        return cell
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 80
    }
}

// MARK: - DeviceUpgradeCell（设备升级列表 Cell）
/// 显示每个设备的名称、升级进度条、当前状态
class DeviceUpgradeCell: UITableViewCell {
    
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        
        nameLabel.font = .boldSystemFont(ofSize: 15)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)
        
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)
        
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.trackTintColor = .systemGray5
        contentView.addSubview(progressView)
        
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            progressView.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 10),
            progressView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            progressView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            progressView.heightAnchor.constraint(equalToConstant: 6),
            statusLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// 根据设备升级状态配置 Cell 显示
    func configure(with item: DeviceUpgradeItem) {
        nameLabel.text = item.peripheral.name ?? item.peripheral.identifier.uuidString
        statusLabel.text = item.status.displayText
        
        switch item.status {
        case .waiting:
            progressView.progress = 0
            progressView.progressTintColor = .systemGray
            statusLabel.textColor = .secondaryLabel
        case .connecting:
            progressView.progress = 0
            progressView.progressTintColor = .systemBlue
            statusLabel.textColor = .systemBlue
        case .upgrading(let progress):
            progressView.progress = progress
            progressView.progressTintColor = .systemBlue
            statusLabel.textColor = .systemBlue
        case .success:
            progressView.progress = 1.0
            progressView.progressTintColor = .systemGreen
            statusLabel.textColor = .systemGreen
        case .failed:
            progressView.progressTintColor = .systemRed
            statusLabel.textColor = .systemRed
        }
    }
}
