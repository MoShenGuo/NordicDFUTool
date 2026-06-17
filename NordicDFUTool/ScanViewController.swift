import UIKit
import CoreBluetooth

class ScanViewController: UIViewController {
    
    var onDeviceSelected: ((CBPeripheral) -> Void)?
    
    private let tableView = UITableView()
    private var peripherals: [CBPeripheral] = []
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "扫描设备"
        view.backgroundColor = .systemBackground
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "刷新", style: .plain, target: self, action: #selector(refreshTapped))
        
        setupUI()
        checkBluetoothAndScan()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        BLEManager.shared.stopScan()
    }
    
    private func setupUI() {
        // Status Label
        statusLabel.text = ""
        statusLabel.textAlignment = .center
        statusLabel.font = .systemFont(ofSize: 14)
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
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            activityIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            
            tableView.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    // MARK: - Bluetooth Check
    
    private func checkBluetoothAndScan() {
        if BLEManager.shared.isReady {
            startScanning()
        } else {
            statusLabel.text = "⚠️ \(BLEManager.shared.stateDescription)"
            statusLabel.textColor = .systemOrange
            
            // 监听蓝牙状态变化
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
        peripherals.removeAll()
        tableView.reloadData()
        activityIndicator.startAnimating()
        statusLabel.text = "🔍 正在扫描..."
        statusLabel.textColor = .secondaryLabel
        
        BLEManager.shared.onPeripheralDiscovered = { [weak self] devices in
            DispatchQueue.main.async {
                self?.peripherals = devices
                self?.tableView.reloadData()
                self?.statusLabel.text = "🔍 正在扫描... 已发现 \(devices.count) 个设备"
            }
        }
        
        BLEManager.shared.startScan()
        
        // 10秒后停止扫描
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.activityIndicator.stopAnimating()
            BLEManager.shared.stopScan()
            let count = self?.peripherals.count ?? 0
            if count == 0 {
                self?.statusLabel.text = "❌ 未发现设备，请确认设备已开启并在附近"
                self?.statusLabel.textColor = .systemOrange
            } else {
                self?.statusLabel.text = "✅ 扫描完成，发现 \(count) 个设备"
                self?.statusLabel.textColor = .systemGreen
            }
        }
    }
    
    @objc private func refreshTapped() {
        checkBluetoothAndScan()
    }
}

// MARK: - UITableViewDataSource & Delegate
extension ScanViewController: UITableViewDataSource, UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return peripherals.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceCell", for: indexPath)
        let peripheral = peripherals[indexPath.row]
        cell.textLabel?.text = peripheral.name ?? "Unknown"
        cell.detailTextLabel?.text = peripheral.identifier.uuidString
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let peripheral = peripherals[indexPath.row]
        onDeviceSelected?(peripheral)
    }
}
