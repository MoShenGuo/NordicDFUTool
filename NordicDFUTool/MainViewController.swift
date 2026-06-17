import UIKit
import CoreBluetooth

class MainViewController: UIViewController {
    
    private let statusLabel = UILabel()
    private let bleStatusLabel = UILabel()
    private let scanButton = UIButton(type: .system)
    private let manualUpgradeButton = UIButton(type: .system)
    private let autoUpgradeButton = UIButton(type: .system)
    private let clearCacheButton = UIButton(type: .system)
    private let cacheInfoLabel = UILabel()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Nordic DFU Tool"
        view.backgroundColor = .systemBackground
        // 设置返回按钮文字，子页面导航栏显示"返回"
        navigationItem.backBarButtonItem = UIBarButtonItem(title: "返回", style: .plain, target: nil, action: nil)
        setupUI()
        setupBLECallbacks()
        checkBluetoothAuthorization()
        updateCacheInfo()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateCacheInfo()
    }
    
    private func setupUI() {
        // BLE Status Label
        bleStatusLabel.text = "蓝牙状态: 检测中..."
        bleStatusLabel.textAlignment = .center
        bleStatusLabel.font = .systemFont(ofSize: 13)
        bleStatusLabel.textColor = .secondaryLabel
        bleStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bleStatusLabel)
        
        // Status Label
        statusLabel.text = "未连接设备"
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        
        // Scan Button
        configureButton(scanButton, title: "🔍 扫描设备", color: .systemBlue)
        scanButton.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        view.addSubview(scanButton)
        
        // Manual Upgrade Button
        configureButton(manualUpgradeButton, title: "📦 手动升级", color: .systemGreen)
        manualUpgradeButton.addTarget(self, action: #selector(manualUpgradeTapped), for: .touchUpInside)
        view.addSubview(manualUpgradeButton)
        
        // Auto Upgrade Button
        configureButton(autoUpgradeButton, title: "🚀 自动升级", color: .systemOrange)
        autoUpgradeButton.addTarget(self, action: #selector(autoUpgradeTapped), for: .touchUpInside)
        view.addSubview(autoUpgradeButton)
        
        // Clear Cache Button
        configureButton(clearCacheButton, title: "🗑️ 清理固件缓存", color: .systemRed)
        clearCacheButton.addTarget(self, action: #selector(clearCacheTapped), for: .touchUpInside)
        view.addSubview(clearCacheButton)
        
        // Cache Info Label
        cacheInfoLabel.text = ""
        cacheInfoLabel.textAlignment = .center
        cacheInfoLabel.font = .systemFont(ofSize: 12)
        cacheInfoLabel.textColor = .tertiaryLabel
        cacheInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cacheInfoLabel)
        
        NSLayoutConstraint.activate([
            bleStatusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            bleStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            bleStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            statusLabel.topAnchor.constraint(equalTo: bleStatusLabel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            scanButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 40),
            scanButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanButton.widthAnchor.constraint(equalToConstant: 260),
            scanButton.heightAnchor.constraint(equalToConstant: 50),
            
            manualUpgradeButton.topAnchor.constraint(equalTo: scanButton.bottomAnchor, constant: 20),
            manualUpgradeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            manualUpgradeButton.widthAnchor.constraint(equalToConstant: 260),
            manualUpgradeButton.heightAnchor.constraint(equalToConstant: 50),
            
            autoUpgradeButton.topAnchor.constraint(equalTo: manualUpgradeButton.bottomAnchor, constant: 20),
            autoUpgradeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            autoUpgradeButton.widthAnchor.constraint(equalToConstant: 260),
            autoUpgradeButton.heightAnchor.constraint(equalToConstant: 50),
            
            clearCacheButton.topAnchor.constraint(equalTo: autoUpgradeButton.bottomAnchor, constant: 40),
            clearCacheButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            clearCacheButton.widthAnchor.constraint(equalToConstant: 260),
            clearCacheButton.heightAnchor.constraint(equalToConstant: 50),
            
            cacheInfoLabel.topAnchor.constraint(equalTo: clearCacheButton.bottomAnchor, constant: 8),
            cacheInfoLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cacheInfoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }
    
    private func configureButton(_ button: UIButton, title: String, color: UIColor) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 18)
        button.backgroundColor = color
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        button.translatesAutoresizingMaskIntoConstraints = false
    }
    
    private func setupBLECallbacks() {
        BLEManager.shared.onConnected = { [weak self] peripheral in
            DispatchQueue.main.async {
                self?.statusLabel.text = "✅ 已连接: \(peripheral.name ?? "Unknown")"
                self?.statusLabel.textColor = .systemGreen
            }
        }
        
        BLEManager.shared.onDisconnected = { [weak self] peripheral, error in
            DispatchQueue.main.async {
                self?.statusLabel.text = "未连接设备"
                self?.statusLabel.textColor = .secondaryLabel
            }
        }
        
        BLEManager.shared.onBluetoothStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.updateBluetoothStatus(state)
            }
        }
    }
    
    // MARK: - 蓝牙授权处理
    
    private func checkBluetoothAuthorization() {
        // 触发蓝牙授权弹框
        BLEManager.shared.requestBluetoothAuthorization()
        updateBluetoothStatus(BLEManager.shared.state)
    }
    
    private func updateBluetoothStatus(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            bleStatusLabel.text = "🟢 蓝牙已就绪"
            bleStatusLabel.textColor = .systemGreen
            scanButton.isEnabled = true
            scanButton.alpha = 1.0
        case .poweredOff:
            bleStatusLabel.text = "🔴 蓝牙已关闭，请打开蓝牙"
            bleStatusLabel.textColor = .systemRed
            scanButton.isEnabled = false
            scanButton.alpha = 0.5
        case .unauthorized:
            bleStatusLabel.text = "⚠️ 蓝牙未授权，请在设置中允许"
            bleStatusLabel.textColor = .systemOrange
            scanButton.isEnabled = false
            scanButton.alpha = 0.5
            showBluetoothAuthorizationAlert()
        case .unsupported:
            bleStatusLabel.text = "❌ 设备不支持蓝牙"
            bleStatusLabel.textColor = .systemRed
            scanButton.isEnabled = false
            scanButton.alpha = 0.5
        default:
            bleStatusLabel.text = "⏳ 蓝牙初始化中..."
            bleStatusLabel.textColor = .secondaryLabel
        }
    }
    
    private func showBluetoothAuthorizationAlert() {
        let alert = UIAlertController(
            title: "需要蓝牙权限",
            message: "本应用需要蓝牙权限来扫描和连接 BLE 设备进行固件升级。请在系统设置中允许蓝牙访问。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "去设置", style: .default) { _ in
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsURL)
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }
    
    // MARK: - 缓存管理
    
    private func updateCacheInfo() {
        let cacheSize = FirmwareService.shared.getCacheSize()
        let cachedFiles = FirmwareService.shared.getCachedFirmwareFiles()
        if cacheSize > 0 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
            cacheInfoLabel.text = "缓存: \(cachedFiles.count) 个固件包，共 \(sizeStr)"
        } else {
            cacheInfoLabel.text = "暂无固件缓存"
        }
    }
    
    // MARK: - Actions
    
    @objc private func scanTapped() {
        guard BLEManager.shared.isReady else {
            showAlert(title: "蓝牙不可用", message: BLEManager.shared.stateDescription)
            return
        }
        
        let scanVC = ScanViewController()
        scanVC.onDeviceSelected = { [weak self] peripheral in
            BLEManager.shared.connect(peripheral: peripheral)
            self?.navigationController?.popViewController(animated: true)
        }
        navigationController?.pushViewController(scanVC, animated: true)
    }
    
    @objc private func manualUpgradeTapped() {
        guard BLEManager.shared.currentPeripheral != nil else {
            showAlert(title: "提示", message: "请先扫描并连接一个设备")
            return
        }
        let upgradeVC = ManualUpgradeViewController()
        navigationController?.pushViewController(upgradeVC, animated: true)
    }
    
    @objc private func autoUpgradeTapped() {
        let autoVC = AutoUpgradeViewController()
        navigationController?.pushViewController(autoVC, animated: true)
    }
    
    @objc private func clearCacheTapped() {
        let cacheSize = FirmwareService.shared.getCacheSize()
        let cachedFiles = FirmwareService.shared.getCachedFirmwareFiles()
        
        guard cacheSize > 0 else {
            showAlert(title: "提示", message: "暂无固件缓存需要清理")
            return
        }
        
        let sizeStr = ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
        let alert = UIAlertController(
            title: "确认清理",
            message: "将清理 \(cachedFiles.count) 个固件包（共 \(sizeStr)）。清理后下次升级将重新下载最新固件。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清理", style: .destructive) { [weak self] _ in
            let result = FirmwareService.shared.clearFirmwareCache()
            if result.success {
                let freedStr = ByteCountFormatter.string(fromByteCount: result.freedSize, countStyle: .file)
                self?.showAlert(title: "清理完成", message: "已释放 \(freedStr) 空间")
            } else {
                self?.showAlert(title: "清理失败", message: "部分文件无法删除")
            }
            self?.updateCacheInfo()
        })
        present(alert, animated: true)
    }
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}
