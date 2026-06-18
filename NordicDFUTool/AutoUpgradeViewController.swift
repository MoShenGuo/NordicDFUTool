import UIKit
import CoreBluetooth
import iOSMcuManagerLibrary
import NordicDFU

class AutoUpgradeViewController: UIViewController {
    
    private let deviceNameField = UITextField()
    private let queryButton = UIButton(type: .system)
    private let frameworkSegment = UISegmentedControl(items: ["McuManager (新)", "Nordic DFU (旧)"])
    private let frameworkHintLabel = UILabel()
    private let tableView = UITableView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    
    private var firmwareList: [FirmwareInfo] = []
    
    /// 用户选择的框架类型
    private var selectedFramework: OTAFrameworkType = .unknown
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.s("自动升级", "Auto Upgrade")
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backBarButtonItem = UIBarButtonItem(title: L10n.back, style: .plain, target: nil, action: nil)
        setupUI()
        autoDetectFramework()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    // MARK: - 自动检测框架（已连接设备型号匹配输入框时）
    
    private func autoDetectFramework() {
        // 如果有已连接设备，检测框架类型并预选
        if let peripheral = BLEManager.shared.currentPeripheral, let name = peripheral.name {
            LegacyDFUManager.checkSMPSupport(peripheral: peripheral) { [weak self] supportsSMP in
                guard let self = self else { return }
                if supportsSMP {
                    self.frameworkSegment.selectedSegmentIndex = 0
                    self.selectedFramework = .mcuManager
                } else {
                    self.frameworkSegment.selectedSegmentIndex = 1
                    self.selectedFramework = .nordicDFU
                }
                self.updateFrameworkHint()
                if self.deviceNameField.text?.isEmpty ?? true {
                    self.frameworkHintLabel.text = L10n.s(
                        "已连接设备: \(name)，已自动选择框架",
                        "Connected: \(name), framework auto-selected")
                }
            }
        }
        
        // 监听输入框变化，检查与已连接设备是否匹配
        deviceNameField.addTarget(self, action: #selector(deviceNameChanged), for: .editingChanged)
    }
    
    /// 输入框内容变化时，检查与已连接设备的匹配情况
    @objc private func deviceNameChanged() {
        checkDeviceNameMatch()
    }
    
    /// 检查输入框型号与已连接设备是否匹配
    /// 不匹配时标红提示用户需要手动选择框架
    private func checkDeviceNameMatch() {
        guard let inputName = deviceNameField.text, !inputName.isEmpty else {
            // 输入框为空，不提示
            return
        }
        
        guard let peripheral = BLEManager.shared.currentPeripheral, let connectedName = peripheral.name else {
            // 没有连接设备，提示需要手动选择
            frameworkHintLabel.text = L10n.s(
                "⚠️ 未连接设备，请手动选择升级框架",
                "⚠️ No device connected, please select framework manually")
            frameworkHintLabel.textColor = .systemOrange
            return
        }
        
        // 判断已连接设备名称是否包含输入的型号
        if connectedName.lowercased().contains(inputName.lowercased()) {
            // 匹配：自动检测的框架有效
            updateFrameworkHint()
        } else {
            // 不匹配：标红提示，重置框架选择
            frameworkSegment.selectedSegmentIndex = UISegmentedControl.noSegment
            selectedFramework = .unknown
            frameworkHintLabel.text = L10n.s(
                "🔴 输入型号 \"\(inputName)\" 与已连接设备 \"\(connectedName)\" 不匹配！\n请手动选择升级框架（McuManager 或 Nordic DFU）",
                "🔴 Input \"\(inputName)\" doesn't match connected \"\(connectedName)\"!\nPlease manually select framework")
            frameworkHintLabel.textColor = .systemRed
        }
    }
    
    @objc private func frameworkChanged() {
        switch frameworkSegment.selectedSegmentIndex {
        case 0:
            selectedFramework = .mcuManager
        case 1:
            selectedFramework = .nordicDFU
        default:
            selectedFramework = .unknown
        }
        updateFrameworkHint()
    }
    
    private func updateFrameworkHint() {
        switch selectedFramework {
        case .mcuManager:
            frameworkHintLabel.text = L10n.s(
                "🟢 McuManager: 固件包需含 manifest.json",
                "🟢 McuManager: firmware must contain manifest.json")
            frameworkHintLabel.textColor = .systemGreen
        case .nordicDFU:
            frameworkHintLabel.text = L10n.s(
                "🟠 Nordic DFU: 固件包需含 .dat + .bin",
                "🟠 Nordic DFU: firmware must contain .dat + .bin")
            frameworkHintLabel.textColor = .systemOrange
        case .unknown:
            frameworkHintLabel.text = L10n.s(
                "请选择升级框架", "Please select upgrade framework")
            frameworkHintLabel.textColor = .secondaryLabel
        }
    }

    // MARK: - UI Setup
    
    private func setupUI() {
        deviceNameField.placeholder = L10n.s("输入设备型号 (例如: 2602)", "Enter device model (e.g. 2602)")
        deviceNameField.borderStyle = .roundedRect
        deviceNameField.font = .systemFont(ofSize: 16)
        deviceNameField.autocorrectionType = .no
        deviceNameField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(deviceNameField)
        
        // 框架选择
        frameworkSegment.selectedSegmentIndex = UISegmentedControl.noSegment
        frameworkSegment.addTarget(self, action: #selector(frameworkChanged), for: .valueChanged)
        frameworkSegment.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameworkSegment)
        
        frameworkHintLabel.text = L10n.s("请选择升级框架", "Please select upgrade framework")
        frameworkHintLabel.textAlignment = .center
        frameworkHintLabel.font = .systemFont(ofSize: 12)
        frameworkHintLabel.textColor = .secondaryLabel
        frameworkHintLabel.numberOfLines = 0
        frameworkHintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameworkHintLabel)
        
        queryButton.setTitle(L10n.s("🔍 查询固件版本", "🔍 Query Firmware"), for: .normal)
        queryButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        queryButton.backgroundColor = .systemBlue
        queryButton.setTitleColor(.white, for: .normal)
        queryButton.layer.cornerRadius = 10
        queryButton.addTarget(self, action: #selector(queryTapped), for: .touchUpInside)
        queryButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(queryButton)
        
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)
        
        messageLabel.text = ""
        messageLabel.textAlignment = .center
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(FirmwareCell.self, forCellReuseIdentifier: "FirmwareCell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            deviceNameField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            deviceNameField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            deviceNameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            deviceNameField.heightAnchor.constraint(equalToConstant: 44),
            
            frameworkSegment.topAnchor.constraint(equalTo: deviceNameField.bottomAnchor, constant: 10),
            frameworkSegment.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            frameworkSegment.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            frameworkHintLabel.topAnchor.constraint(equalTo: frameworkSegment.bottomAnchor, constant: 4),
            frameworkHintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            frameworkHintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            queryButton.topAnchor.constraint(equalTo: frameworkHintLabel.bottomAnchor, constant: 10),
            queryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            queryButton.widthAnchor.constraint(equalToConstant: 200),
            queryButton.heightAnchor.constraint(equalToConstant: 44),
            
            activityIndicator.centerYAnchor.constraint(equalTo: queryButton.centerYAnchor),
            activityIndicator.leadingAnchor.constraint(equalTo: queryButton.trailingAnchor, constant: 12),
            
            messageLabel.topAnchor.constraint(equalTo: queryButton.bottomAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            tableView.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 10),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    // MARK: - Actions
    
    @objc private func queryTapped() {
        guard let deviceName = deviceNameField.text, !deviceName.isEmpty else {
            showMessage(L10n.s("⚠️ 请输入设备型号", "⚠️ Please enter device model"), color: .systemOrange)
            return
        }
        
        guard selectedFramework != .unknown else {
            checkDeviceNameMatch()
            showMessage(L10n.s("⚠️ 请先选择升级框架（McuManager 或 Nordic DFU）", "⚠️ Please select upgrade framework first"), color: .systemOrange)
            return
        }
        
        // 检查网络
        guard PermissionManager.checkNetwork(from: self) else { return }
        
        view.endEditing(true)
        activityIndicator.startAnimating()
        queryButton.isEnabled = false
        showMessage(L10n.s("正在查询...", "Querying..."), color: .secondaryLabel)
        
        FirmwareService.shared.fetchFirmwareList(deviceName: deviceName) { [weak self] result in
            self?.activityIndicator.stopAnimating()
            self?.queryButton.isEnabled = true
            
            switch result {
            case .success(let list):
                self?.firmwareList = list
                self?.tableView.reloadData()
                if list.isEmpty {
                    self?.showMessage(L10n.s("❌ 未找到该设备型号的固件", "❌ No firmware found for this model"), color: .systemOrange)
                } else {
                    self?.showMessage(L10n.s("✅ 找到 \(list.count) 个固件版本，选择版本开始升级", "✅ Found \(list.count) firmware versions, select to upgrade"), color: .systemGreen)
                }
            case .failure(let error):
                self?.showMessage(L10n.s("❌ 查询失败: \(error.localizedDescription)", "❌ Query failed: \(error.localizedDescription)"), color: .systemRed)
            }
        }
    }
    
    private func showMessage(_ text: String, color: UIColor) {
        messageLabel.text = text
        messageLabel.textColor = color
    }
    
    // MARK: - 选择固件版本后的处理
    
    private func confirmUpgrade(firmware: FirmwareInfo) {
        let deviceName = deviceNameField.text ?? ""
        
        switch selectedFramework {
        case .mcuManager:
            showMcuManagerModeSheet(firmware: firmware, deviceName: deviceName)
        case .nordicDFU:
            showNordicDFUConfirmSheet(firmware: firmware, deviceName: deviceName)
        case .unknown:
            showMessage(L10n.s("⚠️ 请先选择升级框架", "⚠️ Please select framework first"), color: .systemOrange)
        }
    }
    
    /// McuManager 模式选择
    private func showMcuManagerModeSheet(firmware: FirmwareInfo, deviceName: String) {
        let hasCached = FirmwareService.shared.getCachedFirmware(for: firmware.firmwareUrl) != nil
        var msg = L10n.s("固件 v\(firmware.version) 将通过 McuManager 升级", "Firmware v\(firmware.version) via McuManager")
        if hasCached { msg += "\n" + L10n.s("（已缓存，跳过下载）", "(Cached, skip download)") }
        
        let sheet = UIAlertController(title: L10n.selectMode, message: msg, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: L10n.modeTestOnly, style: .default) { [weak self] _ in
            self?.startMcuManagerUpgrade(firmware: firmware, deviceName: deviceName, mode: .testOnly)
        })
        sheet.addAction(UIAlertAction(title: L10n.modeConfirmOnly, style: .default) { [weak self] _ in
            self?.startMcuManagerUpgrade(firmware: firmware, deviceName: deviceName, mode: .confirmOnly)
        })
        sheet.addAction(UIAlertAction(title: L10n.modeTestAndConfirm, style: .default) { [weak self] _ in
            self?.startMcuManagerUpgrade(firmware: firmware, deviceName: deviceName, mode: .testAndConfirm)
        })
        sheet.addAction(UIAlertAction(title: L10n.modeUploadOnly, style: .default) { [weak self] _ in
            self?.startMcuManagerUpgrade(firmware: firmware, deviceName: deviceName, mode: .uploadOnly)
        })
        sheet.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        present(sheet, animated: true)
    }
    
    /// Nordic DFU 操作选择
    private func showNordicDFUConfirmSheet(firmware: FirmwareInfo, deviceName: String) {
        let hasCached = FirmwareService.shared.getCachedFirmware(for: firmware.firmwareUrl) != nil
        var msg = L10n.s("固件 v\(firmware.version) 将通过 Nordic DFU (旧版) 升级", "Firmware v\(firmware.version) via Nordic DFU (legacy)")
        if hasCached { msg += "\n" + L10n.s("（已缓存，跳过下载）", "(Cached, skip download)") }
        
        let sheet = UIAlertController(title: L10n.s("Nordic DFU 升级", "Nordic DFU Upgrade"), message: msg, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: L10n.sendOTAAndUpgrade, style: .default) { [weak self] _ in
            self?.startNordicDFUUpgrade(firmware: firmware, deviceName: deviceName, sendCommand: true)
        })
        sheet.addAction(UIAlertAction(title: L10n.scanDFUDirectly, style: .default) { [weak self] _ in
            self?.startNordicDFUUpgrade(firmware: firmware, deviceName: deviceName, sendCommand: false)
        })
        sheet.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        present(sheet, animated: true)
    }

    // MARK: - McuManager 升级（下载 → 验证 → 跳转批量升级页面）
    
    private func startMcuManagerUpgrade(firmware: FirmwareInfo, deviceName: String, mode: FirmwareUpgradeMode) {
        showMessage(L10n.s("正在准备固件...", "Preparing firmware..."), color: .systemBlue)
        
        FirmwareService.shared.downloadFirmware(from: firmware.firmwareUrl, progress: { [weak self] progress in
            self?.showMessage(String(format: L10n.s("下载中 %.0f%%", "Downloading %.0f%%"), progress * 100), color: .systemBlue)
        }, completion: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let fileURL):
                // 验证是否为有效 McuManager 格式
                do {
                    let _ = try McuMgrPackage(from: fileURL)
                } catch {
                    self.showMessage("❌ " + L10n.s(
                        "固件包不符合 McuManager 格式:\n\(error.localizedDescription)",
                        "Firmware not McuManager format:\n\(error.localizedDescription)"), color: .systemRed)
                    return
                }
                
                self.showMessage("✅ " + L10n.s("固件验证通过，进入批量升级...", "Firmware validated, starting batch upgrade..."), color: .systemGreen)
                
                // 判断已连接设备是否匹配输入框型号
                self.handleConnectedDeviceAndProceed(deviceName: deviceName) {
                    // 跳转到批量升级页面
                    let batchVC = BatchUpgradeViewController(firmware: firmware, deviceName: deviceName, upgradeMode: mode)
                    self.navigationController?.pushViewController(batchVC, animated: true)
                }
                
            case .failure(let error):
                self.showMessage("❌ " + L10n.s("下载失败: \(error.localizedDescription)", "Download failed: \(error.localizedDescription)"), color: .systemRed)
            }
        })
    }
    
    // MARK: - Nordic DFU 升级（下载 → 验证 → 跳转批量升级页面）
    
    private func startNordicDFUUpgrade(firmware: FirmwareInfo, deviceName: String, sendCommand: Bool) {
        showMessage(L10n.s("正在准备固件...", "Preparing firmware..."), color: .systemBlue)
        
        FirmwareService.shared.downloadFirmware(from: firmware.firmwareUrl, progress: { [weak self] progress in
            self?.showMessage(String(format: L10n.s("下载中 %.0f%%", "Downloading %.0f%%"), progress * 100), color: .systemBlue)
        }, completion: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let fileURL):
                // 验证是否为有效 Nordic DFU 格式
                do {
                    let _ = try DFUFirmware(urlToZipFile: fileURL)
                } catch {
                    self.showMessage("❌ " + L10n.s(
                        "固件包不符合 Nordic DFU 格式:\n\(error.localizedDescription)",
                        "Firmware not Nordic DFU format:\n\(error.localizedDescription)"), color: .systemRed)
                    return
                }
                
                self.showMessage("✅ " + L10n.s("固件验证通过，进入批量升级...", "Firmware validated, starting batch upgrade..."), color: .systemGreen)
                
                // 跳转到旧版批量升级页面
                self.handleConnectedDeviceAndProceed(deviceName: deviceName) {
                    let batchVC = LegacyBatchUpgradeViewController(firmware: firmware, deviceName: deviceName, sendOTACommand: sendCommand)
                    self.navigationController?.pushViewController(batchVC, animated: true)
                }
                
            case .failure(let error):
                self.showMessage("❌ " + L10n.s("下载失败: \(error.localizedDescription)", "Download failed: \(error.localizedDescription)"), color: .systemRed)
            }
        })
    }
    
    // MARK: - 处理已连接设备与输入框型号的匹配关系
    
    /// 如果已连接设备型号与输入框不一样，先断开；一样的话后面会算进批量升级列表
    private func handleConnectedDeviceAndProceed(deviceName: String, then action: @escaping () -> Void) {
        if let connected = BLEManager.shared.currentPeripheral, let name = connected.name {
            if !name.lowercased().contains(deviceName.lowercased()) {
                // 已连接设备型号不匹配，断开
                BLEManager.shared.disconnect()
                showMessage(L10n.s("已断开不匹配的设备: \(name)", "Disconnected non-matching device: \(name)"), color: .secondaryLabel)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    action()
                }
                return
            }
        }
        // 匹配或无连接，直接继续
        action()
    }
}

// MARK: - UITableView
extension AutoUpgradeViewController: UITableViewDataSource, UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return firmwareList.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FirmwareCell", for: indexPath) as! FirmwareCell
        cell.configure(with: firmwareList[indexPath.row])
        return cell
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 80
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        confirmUpgrade(firmware: firmwareList[indexPath.row])
    }
}

// MARK: - FirmwareCell
class FirmwareCell: UITableViewCell {
    
    private let versionLabel = UILabel()
    private let timeLabel = UILabel()
    private let urlLabel = UILabel()
    private let cacheTag = UILabel()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupCell()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupCell() {
        versionLabel.font = .boldSystemFont(ofSize: 16)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(versionLabel)
        
        cacheTag.font = .systemFont(ofSize: 11, weight: .medium)
        cacheTag.textColor = .white
        cacheTag.backgroundColor = .systemGreen
        cacheTag.layer.cornerRadius = 4
        cacheTag.layer.masksToBounds = true
        cacheTag.textAlignment = .center
        cacheTag.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cacheTag)
        
        timeLabel.font = .systemFont(ofSize: 13)
        timeLabel.textColor = .secondaryLabel
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(timeLabel)
        
        urlLabel.font = .systemFont(ofSize: 11)
        urlLabel.textColor = .tertiaryLabel
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(urlLabel)
        
        accessoryType = .disclosureIndicator
        
        NSLayoutConstraint.activate([
            versionLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            versionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cacheTag.centerYAnchor.constraint(equalTo: versionLabel.centerYAnchor),
            cacheTag.leadingAnchor.constraint(equalTo: versionLabel.trailingAnchor, constant: 8),
            cacheTag.widthAnchor.constraint(equalToConstant: 44),
            cacheTag.heightAnchor.constraint(equalToConstant: 18),
            timeLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 4),
            timeLabel.leadingAnchor.constraint(equalTo: versionLabel.leadingAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),
            urlLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 2),
            urlLabel.leadingAnchor.constraint(equalTo: versionLabel.leadingAnchor),
            urlLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),
        ])
    }
    
    func configure(with firmware: FirmwareInfo) {
        versionLabel.text = "📦 v\(firmware.version)"
        timeLabel.text = L10n.s("上传时间: \(firmware.uploadTime)", "Upload: \(firmware.uploadTime)")
        urlLabel.text = firmware.firmwareUrl
        let hasCached = FirmwareService.shared.getCachedFirmware(for: firmware.firmwareUrl) != nil
        cacheTag.text = L10n.s(" 已缓存 ", " Cached ")
        cacheTag.isHidden = !hasCached
    }
}
