import UIKit
import CoreBluetooth

class ScanViewController: UIViewController {
    
    var onDeviceSelected: ((CBPeripheral) -> Void)?
    
    private let filterField = UITextField()
    private let tableView = UITableView()
    private var allPeripherals: [CBPeripheral] = []
    private var filteredPeripherals: [CBPeripheral] = []
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    /// DFU 恢复升级的目标外设
    private var dfuRecoveryPeripheral: CBPeripheral?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.scanTitle
        view.backgroundColor = .systemBackground
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.refresh, style: .plain, target: self, action: #selector(refreshTapped))
        
        setupUI()
        checkBluetoothAndScan()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        BLEManager.shared.stopScan()
    }
    
    private func setupUI() {
        // Filter Field
        filterField.placeholder = L10n.s("🔍 输入设备名称过滤...", "🔍 Filter by device name...")
        filterField.borderStyle = .roundedRect
        filterField.font = .systemFont(ofSize: 15)
        filterField.clearButtonMode = .whileEditing
        filterField.autocorrectionType = .no
        filterField.autocapitalizationType = .none
        filterField.addTarget(self, action: #selector(filterChanged), for: .editingChanged)
        filterField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filterField)
        
        // Status Label
        statusLabel.text = ""
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        
        // Activity Indicator
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)

        // Table View
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DeviceCell")
        tableView.keyboardDismissMode = .onDrag
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            filterField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            filterField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            filterField.heightAnchor.constraint(equalToConstant: 40),
            
            statusLabel.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            activityIndicator.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            activityIndicator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    // MARK: - Filter
    
    @objc private func filterChanged() {
        applyFilter()
    }
    
    private func applyFilter() {
        let keyword = filterField.text?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if keyword.isEmpty {
            filteredPeripherals = allPeripherals
        } else {
            filteredPeripherals = allPeripherals.filter { peripheral in
                let name = (peripheral.name ?? "").lowercased()
                let uuid = peripheral.identifier.uuidString.lowercased()
                return name.contains(keyword) || uuid.contains(keyword)
            }
        }
        tableView.reloadData()
    }
    
    // MARK: - Bluetooth Check
    
    private func checkBluetoothAndScan() {
        if BLEManager.shared.isReady {
            startScanning()
        } else {
            statusLabel.text = "⚠️ \(BLEManager.shared.stateDescription)"
            statusLabel.textColor = .systemOrange
            
            BLEManager.shared.onBluetoothStateChanged = { [weak self] state in
                DispatchQueue.main.async {
                    if state == .poweredOn {
                        self?.statusLabel.text = ""
                        self?.startScanning()
                    } else {
                        self?.statusLabel.text = "⚠️ \(BLEManager.shared.stateDescription)"
                        self?.statusLabel.textColor = .systemOrange
                    }
                }
            }
        }
    }

    private func startScanning() {
        allPeripherals.removeAll()
        filteredPeripherals.removeAll()
        tableView.reloadData()
        activityIndicator.startAnimating()
        statusLabel.text = L10n.scanning
        statusLabel.textColor = .secondaryLabel
        
        BLEManager.shared.onPeripheralDiscovered = { [weak self] devices in
            DispatchQueue.main.async {
                self?.allPeripherals = devices
                self?.applyFilter()
                self?.statusLabel.text = L10n.scanFound(devices.count)
            }
        }
        
        BLEManager.shared.startScan()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.activityIndicator.stopAnimating()
            BLEManager.shared.stopScan()
            let count = self?.allPeripherals.count ?? 0
            if count == 0 {
                self?.statusLabel.text = L10n.scanEmpty
                self?.statusLabel.textColor = .systemOrange
            } else {
                self?.statusLabel.text = L10n.scanComplete(count)
                self?.statusLabel.textColor = .systemGreen
            }
        }
    }
    
    @objc private func refreshTapped() {
        filterField.text = ""
        checkBluetoothAndScan()
    }
}

// MARK: - UITableViewDataSource & Delegate
extension ScanViewController: UITableViewDataSource, UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return filteredPeripherals.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceCell", for: indexPath)
        let peripheral = filteredPeripherals[indexPath.row]
        let name = peripheral.name ?? "Unknown"
        
        // DFU 模式设备高亮显示
        if name.uppercased().contains("DFU") {
            cell.textLabel?.text = "⚡ \(name)"
            cell.textLabel?.textColor = .systemOrange
        } else {
            cell.textLabel?.text = name
            cell.textLabel?.textColor = .label
        }
        cell.detailTextLabel?.text = peripheral.identifier.uuidString
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        view.endEditing(true)
        let peripheral = filteredPeripherals[indexPath.row]
        
        // 检查是否是 DFU 模式设备
        if let name = peripheral.name, name.uppercased().contains("DFU") {
            showDFURecoveryAlert(peripheral: peripheral)
        } else {
            onDeviceSelected?(peripheral)
        }
    }
    
    // MARK: - DFU Recovery
    
    private func showDFURecoveryAlert(peripheral: CBPeripheral) {
        let alert = UIAlertController(
            title: L10n.dfuRecoveryTitle,
            message: L10n.dfuRecoveryDesc,
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: L10n.dfuRecoveryAction, style: .default) { [weak self] _ in
            self?.startDFURecovery(peripheral: peripheral)
        })
        
        alert.addAction(UIAlertAction(title: L10n.s("当作普通设备连接", "Connect as normal device"), style: .default) { [weak self] _ in
            self?.onDeviceSelected?(peripheral)
        })
        
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        present(alert, animated: true)
    }
    
    private func startDFURecovery(peripheral: CBPeripheral) {
        dfuRecoveryPeripheral = peripheral
        let types = ["public.zip-archive", "public.data", "com.apple.macbinary-archive"]
        let picker = UIDocumentPickerViewController(documentTypes: types, in: .import)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }
}

// MARK: - UIDocumentPickerDelegate (DFU Recovery)
extension ScanViewController: UIDocumentPickerDelegate {
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let dfuPeripheral = dfuRecoveryPeripheral else { return }
        
        // 深度校验固件包
        let result = FirmwareValidator.validate(fileURL: url)
        switch result {
        case .invalid(let reason):
            let alert = UIAlertController(title: L10n.invalidFirmware, message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.confirm, style: .default))
            present(alert, animated: true)
            return
        default:
            break
        }
        
        self.dfuRecoveryPeripheral = nil
        
        // 跳转到手动升级页面进行 DFU 恢复
        let upgradeVC = ManualUpgradeViewController()
        upgradeVC.preselectedDFUPeripheral = dfuPeripheral
        upgradeVC.preselectedFirmwareURL = url
        navigationController?.pushViewController(upgradeVC, animated: true)
    }
}
