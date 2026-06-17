import UIKit
import CoreBluetooth
import iOSMcuManagerLibrary

class AutoUpgradeViewController: UIViewController {
    
    private let deviceNameField = UITextField()
    private let queryButton = UIButton(type: .system)
    private let tableView = UITableView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    
    private var firmwareList: [FirmwareInfo] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "自动升级"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backBarButtonItem = UIBarButtonItem(title: "返回", style: .plain, target: nil, action: nil)
        setupUI()
    }
    
    private func setupUI() {
        // Device Name Input
        deviceNameField.placeholder = "输入设备型号 (例如: 2602)"
        deviceNameField.borderStyle = .roundedRect
        deviceNameField.font = .systemFont(ofSize: 16)
        deviceNameField.autocorrectionType = .no
        deviceNameField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(deviceNameField)
        
        // Query Button
        queryButton.setTitle("🔍 查询固件版本", for: .normal)
        queryButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        queryButton.backgroundColor = .systemBlue
        queryButton.setTitleColor(.white, for: .normal)
        queryButton.layer.cornerRadius = 10
        queryButton.addTarget(self, action: #selector(queryTapped), for: .touchUpInside)
        queryButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(queryButton)
        
        // Activity Indicator
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)
        
        // Message Label - 显示错误或成功信息
        messageLabel.text = ""
        messageLabel.textAlignment = .center
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        
        // TableView
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(FirmwareCell.self, forCellReuseIdentifier: "FirmwareCell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            deviceNameField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            deviceNameField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            deviceNameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            deviceNameField.heightAnchor.constraint(equalToConstant: 44),
            
            queryButton.topAnchor.constraint(equalTo: deviceNameField.bottomAnchor, constant: 12),
            queryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            queryButton.widthAnchor.constraint(equalToConstant: 200),
            queryButton.heightAnchor.constraint(equalToConstant: 44),
            
            activityIndicator.centerYAnchor.constraint(equalTo: queryButton.centerYAnchor),
            activityIndicator.leadingAnchor.constraint(equalTo: queryButton.trailingAnchor, constant: 12),
            
            messageLabel.topAnchor.constraint(equalTo: queryButton.bottomAnchor, constant: 12),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            tableView.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }
    
    // MARK: - Actions
    
    @objc private func queryTapped() {
        guard let deviceName = deviceNameField.text, !deviceName.isEmpty else {
            showMessage("⚠️ 请输入设备型号", color: .systemOrange)
            return
        }
        
        view.endEditing(true)
        activityIndicator.startAnimating()
        queryButton.isEnabled = false
        showMessage("正在查询...", color: .secondaryLabel)
        
        FirmwareService.shared.fetchFirmwareList(deviceName: deviceName) { [weak self] result in
            self?.activityIndicator.stopAnimating()
            self?.queryButton.isEnabled = true
            
            switch result {
            case .success(let list):
                self?.firmwareList = list
                self?.tableView.reloadData()
                if list.isEmpty {
                    self?.showMessage("❌ 未找到该设备型号的固件", color: .systemOrange)
                } else {
                    self?.showMessage("✅ 找到 \(list.count) 个固件版本，选择版本开始升级", color: .systemGreen)
                }
            case .failure(let error):
                self?.showMessage("❌ 查询失败: \(error.localizedDescription)", color: .systemRed)
            }
        }
    }
    
    private func showMessage(_ text: String, color: UIColor) {
        messageLabel.text = text
        messageLabel.textColor = color
    }
    
    private func confirmUpgrade(firmware: FirmwareInfo) {
        let deviceName = deviceNameField.text ?? ""
        
        // 检查是否有缓存
        let hasCached = FirmwareService.shared.getCachedFirmware(for: firmware.firmwareUrl) != nil
        var message = "将下载 v\(firmware.version) 固件并升级所有名称包含 \"\(deviceName)\" 的设备。"
        if hasCached {
            message = "v\(firmware.version) 固件已有本地缓存，将跳过下载直接升级所有名称包含 \"\(deviceName)\" 的设备。"
        }
        message += "\n\n请选择升级模式："
        
        // 使用底部 ActionSheet 选择升级模式
        let sheet = UIAlertController(title: "确认自动升级 v\(firmware.version)", message: message, preferredStyle: .actionSheet)
        
        sheet.addAction(UIAlertAction(title: "🧪 仅测试 (Test Only)", style: .default) { [weak self] _ in
            self?.startAutoUpgrade(firmware: firmware, deviceName: deviceName, mode: .testOnly)
        })
        
        sheet.addAction(UIAlertAction(title: "✅ 仅确认 (Confirm Only) - 推荐", style: .default) { [weak self] _ in
            self?.startAutoUpgrade(firmware: firmware, deviceName: deviceName, mode: .confirmOnly)
        })
        
        sheet.addAction(UIAlertAction(title: "🔄 测试并确认 (Test & Confirm)", style: .default) { [weak self] _ in
            self?.startAutoUpgrade(firmware: firmware, deviceName: deviceName, mode: .testAndConfirm)
        })
        
        sheet.addAction(UIAlertAction(title: "⬆️ 仅上传 (Upload Only)", style: .default) { [weak self] _ in
            self?.startAutoUpgrade(firmware: firmware, deviceName: deviceName, mode: .uploadOnly)
        })
        
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        
        present(sheet, animated: true)
    }
    
    private func startAutoUpgrade(firmware: FirmwareInfo, deviceName: String, mode: FirmwareUpgradeMode) {
        let batchVC = BatchUpgradeViewController(firmware: firmware, deviceName: deviceName, upgradeMode: mode)
        navigationController?.pushViewController(batchVC, animated: true)
    }
}

// MARK: - UITableView
extension AutoUpgradeViewController: UITableViewDataSource, UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return firmwareList.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FirmwareCell", for: indexPath) as! FirmwareCell
        let firmware = firmwareList[indexPath.row]
        cell.configure(with: firmware)
        return cell
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 80
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let firmware = firmwareList[indexPath.row]
        confirmUpgrade(firmware: firmware)
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
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
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
        timeLabel.text = "上传时间: \(firmware.uploadTime)"
        urlLabel.text = firmware.firmwareUrl
        
        // 显示缓存标记
        let hasCached = FirmwareService.shared.getCachedFirmware(for: firmware.firmwareUrl) != nil
        if hasCached {
            cacheTag.text = " 已缓存 "
            cacheTag.isHidden = false
        } else {
            cacheTag.isHidden = true
        }
    }
}
