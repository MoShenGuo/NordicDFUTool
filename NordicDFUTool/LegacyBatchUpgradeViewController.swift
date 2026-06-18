import UIKit
import CoreBluetooth
import NordicDFU

/// 旧版 Nordic DFU 批量升级页面
/// 流程：下载固件 → 扫描匹配设备 → 逐个发送 OTA 指令进入 DFU 模式 → Nordic DFU 升级
class LegacyBatchUpgradeViewController: UIViewController {
    
    private let firmware: FirmwareInfo
    private let deviceName: String
    private let sendOTACommand: Bool
    
    // UI
    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let progressLabel = UILabel()
    private let statisticsLabel = UILabel()
    private let logTextView = UITextView()
    private let startButton = UIButton(type: .system)
    private let tableView = UITableView()
    
    // State
    private var firmwareFileURL: URL?
    private var devices: [DeviceUpgradeItem] = []
    private var currentUpgradeIndex: Int = -1
    private var legacyDFUManager: LegacyDFUManager?
    
    // Statistics
    private var totalDevices: Int = 0
    private var successCount: Int = 0
    private var failCount: Int = 0
    private var startTime: Date?
    
    init(firmware: FirmwareInfo, deviceName: String, sendOTACommand: Bool = true) {
        self.firmware = firmware
        self.deviceName = deviceName
        self.sendOTACommand = sendOTACommand
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.s("旧版DFU升级 v\(firmware.version)", "Legacy DFU v\(firmware.version)")
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        setupUI()
        startDownload()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        legacyDFUManager?.abort()
    }

    private func setupUI() {
        statusLabel.text = L10n.s("正在准备固件...", "Preparing firmware...")
        statusLabel.textAlignment = .center
        statusLabel.font = .boldSystemFont(ofSize: 16)
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        
        progressView.progress = 0
        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressView)
        
        progressLabel.text = ""
        progressLabel.textAlignment = .center
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressLabel)
        
        statisticsLabel.text = ""
        statisticsLabel.textAlignment = .center
        statisticsLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statisticsLabel.numberOfLines = 0
        statisticsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statisticsLabel)
        
        startButton.setTitle(L10n.s("🚀 开始批量升级", "🚀 Start Batch Upgrade"), for: .normal)
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
            progressView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            progressLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 4),
            progressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statisticsLabel.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 6),
            statisticsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statisticsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            startButton.topAnchor.constraint(equalTo: statisticsLabel.bottomAnchor, constant: 10),
            startButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            startButton.widthAnchor.constraint(equalToConstant: 220),
            startButton.heightAnchor.constraint(equalToConstant: 44),
            logTextView.topAnchor.constraint(equalTo: startButton.bottomAnchor, constant: 10),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logTextView.heightAnchor.constraint(equalToConstant: 100),
            tableView.topAnchor.constraint(equalTo: logTextView.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }
    
    private func appendLog(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.logTextView.text += "[\(ts)] \(msg)\n"
            let bottom = NSRange(location: self.logTextView.text.count - 1, length: 1)
            self.logTextView.scrollRangeToVisible(bottom)
        }
    }
    
    private func updateStatistics() {
        successCount = devices.filter { if case .success = $0.status { return true }; return false }.count
        failCount = devices.filter { if case .failed = $0.status { return true }; return false }.count
        var text = "📊 \(L10n.s("总计", "Total")): \(totalDevices) | ✅: \(successCount) | ❌: \(failCount)"
        if let start = startTime {
            let elapsed = Int(Date().timeIntervalSince(start))
            text += " | ⏱ \(elapsed/60)m\(elapsed%60)s"
        }
        statisticsLabel.text = text
    }

    // MARK: - 步骤1: 下载固件
    
    private func startDownload() {
        if let cachedURL = FirmwareService.shared.getCachedFirmware(for: firmware.firmwareUrl) {
            appendLog("📦 " + L10n.s("使用缓存固件", "Using cached firmware"))
            firmwareFileURL = cachedURL
            progressView.progress = 1.0
            progressLabel.text = L10n.s("已缓存", "Cached")
            downloadComplete()
            return
        }
        
        appendLog("⬇️ " + L10n.s("开始下载固件...", "Downloading firmware..."))
        FirmwareService.shared.downloadFirmware(from: firmware.firmwareUrl, skipIfCached: false, progress: { [weak self] progress in
            self?.progressView.progress = Float(progress)
            self?.progressLabel.text = String(format: "%.0f%%", progress * 100)
        }, completion: { [weak self] result in
            switch result {
            case .success(let fileURL):
                self?.firmwareFileURL = fileURL
                self?.downloadComplete()
            case .failure(let error):
                self?.statusLabel.text = "❌ " + L10n.s("下载失败", "Download failed")
                self?.statusLabel.textColor = .systemRed
                self?.appendLog("❌ \(error.localizedDescription)")
            }
        })
    }
    
    private func downloadComplete() {
        guard let fileURL = firmwareFileURL else { return }
        
        // 验证固件包
        do {
            let _ = try DFUFirmware(urlToZipFile: fileURL)
            appendLog("✅ " + L10n.s("固件验证通过", "Firmware validated"))
        } catch {
            statusLabel.text = "❌ " + L10n.s("固件包格式无效", "Invalid firmware format")
            statusLabel.textColor = .systemRed
            appendLog("❌ \(error.localizedDescription)")
            return
        }
        
        statusLabel.text = L10n.s("✅ 固件就绪，正在搜索设备...", "✅ Firmware ready, scanning devices...")
        scanForMatchingDevices()
    }
    
    // MARK: - 步骤2: 扫描设备
    
    private func scanForMatchingDevices() {
        appendLog("🔍 " + L10n.s("搜索匹配设备: \"\(deviceName)\"", "Scanning for: \"\(deviceName)\""))
        
        // 已连接设备如果匹配，加入列表
        if let connected = BLEManager.shared.currentPeripheral,
           let name = connected.name,
           name.lowercased().contains(deviceName.lowercased()) {
            devices.append(DeviceUpgradeItem(peripheral: connected))
            appendLog("📱 " + L10n.s("已添加已连接设备: \(name)", "Added connected device: \(name)"))
        }
        
        BLEManager.shared.scanForDevices(withName: deviceName, timeout: 8.0) { [weak self] peripherals in
            guard let self = self else { return }
            for p in peripherals {
                if !self.devices.contains(where: { $0.peripheral.identifier == p.identifier }) {
                    self.devices.append(DeviceUpgradeItem(peripheral: p))
                    self.appendLog("📱 " + L10n.s("发现设备: \(p.name ?? "Unknown")", "Found: \(p.name ?? "Unknown")"))
                }
            }
            self.totalDevices = self.devices.count
            if self.devices.isEmpty {
                self.statusLabel.text = "❌ " + L10n.s("未找到匹配设备", "No matching devices found")
                self.statusLabel.textColor = .systemRed
            } else {
                self.statusLabel.text = L10n.s("找到 \(self.devices.count) 个设备，点击开始", "Found \(self.devices.count) devices, tap to start")
                self.startButton.isHidden = false
            }
            self.updateStatistics()
            self.tableView.reloadData()
        }
    }

    // MARK: - 步骤3: 逐个升级
    
    @objc private func startBatchUpgrade() {
        startButton.isHidden = true
        statusLabel.text = "🚀 " + L10n.s("批量升级进行中...", "Batch upgrade in progress...")
        startTime = Date()
        currentUpgradeIndex = -1
        appendLog("🚀 " + L10n.s("开始批量升级，共 \(devices.count) 个设备", "Starting batch upgrade, \(devices.count) devices"))
        upgradeNextDevice()
    }
    
    private func upgradeNextDevice() {
        currentUpgradeIndex += 1
        
        if currentUpgradeIndex >= devices.count {
            // 全部完成
            updateStatistics()
            let elapsed = startTime.map { Int(Date().timeIntervalSince($0)) } ?? 0
            statusLabel.text = L10n.s(
                "升级完成！✅ \(successCount) ❌ \(failCount) ⏱ \(elapsed/60)m\(elapsed%60)s",
                "Complete! ✅ \(successCount) ❌ \(failCount) ⏱ \(elapsed/60)m\(elapsed%60)s")
            statusLabel.textColor = successCount == devices.count ? .systemGreen : .systemOrange
            appendLog("🏁 " + L10n.s("批量升级完成", "Batch upgrade complete"))
            return
        }
        
        let item = devices[currentUpgradeIndex]
        item.status = .connecting
        tableView.reloadRows(at: [IndexPath(row: currentUpgradeIndex, section: 0)], with: .automatic)
        updateStatistics()
        
        let name = item.peripheral.name ?? "Unknown"
        appendLog("📡 [\(currentUpgradeIndex+1)/\(devices.count)] \(name)")
        
        guard let fileURL = firmwareFileURL else {
            markCurrentFailed(L10n.s("固件文件丢失", "Firmware file missing"))
            return
        }
        
        legacyDFUManager?.abort()
        legacyDFUManager = LegacyDFUManager()
        legacyDFUManager?.delegate = self
        
        if sendOTACommand {
            // 旧版流程：需要先连接设备 → 发送 OTA 指令 → 设备进入 DFU 模式
            // 如果当前设备已连接，直接发送
            if BLEManager.shared.currentPeripheral?.identifier == item.peripheral.identifier {
                appendLog("📱 " + L10n.s("设备已连接，直接发送 OTA 指令", "Device connected, sending OTA command"))
                legacyDFUManager?.startLegacyOTA(peripheral: item.peripheral, firmwareURL: fileURL, writeCharacteristic: nil)
            } else {
                // 先断开当前连接，再连接目标设备
                BLEManager.shared.disconnect()
                appendLog("🔗 " + L10n.s("正在连接设备: \(name)", "Connecting: \(name)"))
                
                BLEManager.shared.onConnected = { [weak self] connectedPeripheral in
                    guard let self = self else { return }
                    guard connectedPeripheral.identifier == item.peripheral.identifier else { return }
                    self.appendLog("✅ " + L10n.s("已连接，发送 OTA 指令...", "Connected, sending OTA command..."))
                    self.legacyDFUManager?.startLegacyOTA(peripheral: connectedPeripheral, firmwareURL: fileURL, writeCharacteristic: nil)
                }
                
                BLEManager.shared.onDisconnected = { [weak self] peripheral, error in
                    guard let self = self else { return }
                    guard peripheral.identifier == item.peripheral.identifier else { return }
                    // 连接阶段断开的两种情况：
                    // 1. 连接超时/失败 → 如果是 sendOTACommand 模式，设备可能已经在 DFU 模式，尝试直接扫描
                    // 2. OTA 指令发送后设备正常断开 → LegacyDFUManager 内部会处理
                    if case .connecting = item.status {
                        DispatchQueue.main.async {
                            if self.sendOTACommand {
                                // 设备可能已进入 DFU 模式，尝试直接扫描 DFU 设备
                                self.appendLog("⚠️ " + L10n.s("连接断开，尝试扫描 DFU 设备...", "Disconnected, trying to scan DFU device..."))
                                item.status = .upgrading(progress: 0)
                                self.tableView.reloadRows(at: [IndexPath(row: self.currentUpgradeIndex, section: 0)], with: .automatic)
                                guard let fileURL = self.firmwareFileURL else {
                                    self.markCurrentFailed(L10n.s("固件文件丢失", "Firmware missing"))
                                    return
                                }
                                self.legacyDFUManager?.startScanDirectly(firmwareURL: fileURL)
                            } else {
                                self.markCurrentFailed(L10n.s("连接失败: \(error?.localizedDescription ?? "Timeout")", "Connect failed: \(error?.localizedDescription ?? "Timeout")"))
                            }
                        }
                    }
                }
                
                BLEManager.shared.connect(peripheral: item.peripheral)
            }
        } else {
            // 设备已在 DFU 模式，直接扫描 DFU 设备并升级
            appendLog("🔍 " + L10n.s("直接扫描 DFU 设备...", "Scanning for DFU device..."))
            legacyDFUManager?.startScanDirectly(firmwareURL: fileURL)
        }
    }
    
    private func markCurrentFailed(_ error: String) {
        guard currentUpgradeIndex < devices.count else { return }
        devices[currentUpgradeIndex].status = .failed(error: error)
        tableView.reloadRows(at: [IndexPath(row: currentUpgradeIndex, section: 0)], with: .automatic)
        appendLog("❌ \(error)")
        updateStatistics()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.upgradeNextDevice()
        }
    }
    
    private func markCurrentSuccess() {
        guard currentUpgradeIndex < devices.count else { return }
        devices[currentUpgradeIndex].status = .success
        tableView.reloadRows(at: [IndexPath(row: currentUpgradeIndex, section: 0)], with: .automatic)
        appendLog("🎉 " + L10n.s("升级成功", "Upgrade success"))
        updateStatistics()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.upgradeNextDevice()
        }
    }
}

// MARK: - LegacyDFUManagerDelegate
extension LegacyBatchUpgradeViewController: LegacyDFUManagerDelegate {
    
    func legacyDFU(_ manager: LegacyDFUManager, didChangeState description: String) {
        appendLog("📍 \(description)")
        statusLabel.text = description
    }
    
    func legacyDFU(_ manager: LegacyDFUManager, didUpdateProgress progress: Int, speed: Double, part: Int, totalParts: Int) {
        guard currentUpgradeIndex < devices.count else { return }
        let p = Float(progress) / 100.0
        devices[currentUpgradeIndex].status = .upgrading(progress: p)
        tableView.reloadRows(at: [IndexPath(row: currentUpgradeIndex, section: 0)], with: .none)
        progressView.progress = p
        progressLabel.text = "\(progress)%"
    }
    
    func legacyDFUDidComplete(_ manager: LegacyDFUManager) {
        markCurrentSuccess()
    }
    
    func legacyDFU(_ manager: LegacyDFUManager, didFailWithError error: String) {
        markCurrentFailed(error)
    }
}

// MARK: - UITableView
extension LegacyBatchUpgradeViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { devices.count }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 80 }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceUpgradeCell", for: indexPath) as! DeviceUpgradeCell
        cell.configure(with: devices[indexPath.row])
        return cell
    }
}
