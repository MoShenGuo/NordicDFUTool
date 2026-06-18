//
//  OTAUpgradeView.m
//  Ble SDK Demo
//
//  Created by yang sai on 2025/01/10.
//

#import "OTAUpgradeView.h"
#if __has_include("Ble_SDK_Demo-Swift.h")
#import "Ble_SDK_Demo-Swift.h"
#elif __has_include("Ble SDK Demo-Swift.h")
#import "Ble SDK Demo-Swift.h"
#elif __has_include(<Ble_SDK_Demo/Ble_SDK_Demo-Swift.h>)
#import <Ble_SDK_Demo/Ble_SDK_Demo-Swift.h>
#endif

@interface OTAUpgradeView () <MyBleDelegate, DFUHelperDelegate>
{
    UIButton *btnBack;
    UIButton *btnUpgrade;
    UIProgressView *progressView;
    UILabel *lblProgress;
    UILabel *lblStatus;
    
    CBPeripheral *dfuPeripheral;
    NSTimer *scanTimer;
    BOOL isWaitingForDFU;
    
    DFUHelper *dfuHelper;
}
@end

@implementation OTAUpgradeView

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor whiteColor];
    dfuHelper = [[DFUHelper alloc] init];
    dfuHelper.delegate = self;
    [self setupUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [NewBle sharedManager].delegate = self;
}

- (void)setupUI {
    
    // 返回按钮
    btnBack = [[UIButton alloc] initWithFrame:CGRectMake(20*Proportion, 50*Proportion, 80*Proportion, 40*Proportion)];
    btnBack.backgroundColor = [UIColor lightGrayColor];
    btnBack.layer.cornerRadius = 10 * Proportion;
    [btnBack setTitle:LocalForkey(@"返回") forState:UIControlStateNormal];
    [btnBack setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [btnBack addTarget:self action:@selector(backAction) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btnBack];
    
    // 标题
    UILabel *lblTitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 50*Proportion, Width, 40*Proportion)];
    lblTitle.text = LocalForkey(@"OTA 升级");
    lblTitle.textAlignment = NSTextAlignmentCenter;
    lblTitle.font = [UIFont boldSystemFontOfSize:20];
    [self.view addSubview:lblTitle];
    
    // 状态标签
    lblStatus = [[UILabel alloc] initWithFrame:CGRectMake(40*Proportion, 200*Proportion, Width - 80*Proportion, 60*Proportion)];
    lblStatus.text = LocalForkey(@"准备升级");
    lblStatus.textAlignment = NSTextAlignmentCenter;
    lblStatus.font = [UIFont systemFontOfSize:16];
    lblStatus.textColor = [UIColor darkGrayColor];
    lblStatus.numberOfLines = 0;
    [self.view addSubview:lblStatus];
    
    // 进度条
    progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progressView.frame = CGRectMake(40*Proportion, 290*Proportion, Width - 80*Proportion, 20*Proportion);
    progressView.progress = 0.0;
    progressView.progressTintColor = [UIColor systemBlueColor];
    progressView.trackTintColor = [UIColor lightGrayColor];
    progressView.transform = CGAffineTransformMakeScale(1.0, 2.0);
    [self.view addSubview:progressView];
    
    // 进度百分比
    lblProgress = [[UILabel alloc] initWithFrame:CGRectMake(0, 310*Proportion, Width, 30*Proportion)];
    lblProgress.text = @"0%";
    lblProgress.textAlignment = NSTextAlignmentCenter;
    lblProgress.font = [UIFont boldSystemFontOfSize:22];
    [self.view addSubview:lblProgress];
    
    // 升级按钮
    btnUpgrade = [[UIButton alloc] initWithFrame:CGRectMake((Width - 200*Proportion)/2, 380*Proportion, 200*Proportion, 50*Proportion)];
    btnUpgrade.backgroundColor = [UIColor systemBlueColor];
    btnUpgrade.layer.cornerRadius = 10 * Proportion;
    [btnUpgrade setTitle:LocalForkey(@"开始升级") forState:UIControlStateNormal];
    [btnUpgrade setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btnUpgrade.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [btnUpgrade addTarget:self action:@selector(upgradeAction) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btnUpgrade];
}

#pragma mark - Actions

- (void)backAction {
    [dfuHelper abortDFU];
    [self stopScanTimer];
    [[NewBle sharedManager] Stopscan];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)upgradeAction {
    btnUpgrade.enabled = NO;
    btnUpgrade.backgroundColor = [UIColor grayColor];
    progressView.progress = 0.0;
    lblProgress.text = @"0%";
    isWaitingForDFU = YES;
    dfuPeripheral = nil;
    
    // 判断设备是否处于连接状态
    if ([[NewBle sharedManager] isConnectOrConnecting]) {
        // 已连接：发送OTA指令，设备会断开并进入DFU模式
        lblStatus.text = LocalForkey(@"正在发送OTA指令...");
        [[NewBle sharedManager] startOTA];
    } else {
        // 未连接：跳过OTA指令，直接扫描DFU设备
        lblStatus.text = LocalForkey(@"设备未连接，直接扫描DFU设备...");
        [self startScanForDFU];
    }
}

#pragma mark - MyBleDelegate

- (void)Disconnect:(NSError *)error {
    if (isWaitingForDFU) {
        lblStatus.text = LocalForkey(@"设备已断开，等待进入DFU模式...");
        // 延迟3秒再开始扫描，给设备时间重启进入DFU bootloader
        [self performSelector:@selector(startScanForDFU) withObject:nil afterDelay:3.0];
    }
}

- (void)scanWithPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary<NSString *,id> *)advertisementData RSSI:(NSNumber *)RSSI {
    
    if (!isWaitingForDFU) return;
    
    NSString *deviceName = peripheral.name;
    if (deviceName.length == 0) return;
    
    // 查找设备名包含"DFU"的设备
    if ([deviceName.uppercaseString containsString:@"DFU"]) {
        NSLog(@"找到DFU设备: %@", deviceName);
        
        dfuPeripheral = peripheral;
        isWaitingForDFU = NO;
        
        [[NewBle sharedManager] Stopscan];
        [self stopScanTimer];
        
        lblStatus.text = [NSString stringWithFormat:LocalForkey(@"已找到DFU设备: %@\n正在开始固件升级..."), deviceName];
        
        // 延迟1秒后开始DFU
        [self performSelector:@selector(startDFUProcess) withObject:nil afterDelay:1.0];
    }
}

- (void)ConnectSuccessfully {}
- (void)EnableCommunicate {}
- (void)ConnectFailedWithError:(NSError *)error {}

-(void)BleCommunicateWithPeripheral:(CBPeripheral*)Peripheral data:(NSData *)data
{
    
}

#pragma mark - 扫描DFU设备

- (void)startScanForDFU {
    NSLog(@"开始扫描DFU设备...");
    lblStatus.text = LocalForkey(@"正在扫描DFU设备...");
    [[NewBle sharedManager] startScanningWithServices:nil];
    
    scanTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(scanTimeout) userInfo:nil repeats:NO];
}

- (void)scanTimeout {
    if (isWaitingForDFU) {
        isWaitingForDFU = NO;
        [[NewBle sharedManager] Stopscan];
        lblStatus.text = LocalForkey(@"未找到DFU设备，请重试");
        btnUpgrade.enabled = YES;
        btnUpgrade.backgroundColor = [UIColor systemBlueColor];
    }
}

- (void)stopScanTimer {
    if (scanTimer) {
        [scanTimer invalidate];
        scanTimer = nil;
    }
}

#pragma mark - 开始Nordic DFU

- (void)startDFUProcess {
    
    NSString *firmwarePath = [[NSBundle mainBundle] pathForResource:@"JCV4_07_V061_2" ofType:@"zip"];
    if (!firmwarePath) {
        lblStatus.text = LocalForkey(@"错误：未找到固件文件");
        btnUpgrade.enabled = YES;
        btnUpgrade.backgroundColor = [UIColor systemBlueColor];
        return;
    }
    
    [dfuHelper startDFUWithCentralManager:[NewBle sharedManager].CentralManage
                               peripheral:dfuPeripheral
                             outerZipPath:firmwarePath
                                needUnzip:NO];
}

#pragma mark - DFUHelperDelegate

- (void)dfuDidChangeState:(NSString *)stateDescription completed:(BOOL)completed {
    lblStatus.text = stateDescription;
    
    if (completed) {
        progressView.progress = 1.0;
        lblProgress.text = @"100%";
        btnUpgrade.enabled = YES;
        btnUpgrade.backgroundColor = [UIColor systemBlueColor];
        [btnUpgrade setTitle:LocalForkey(@"升级完成") forState:UIControlStateNormal];
        
        // DFU完成，恢复NewBle的delegate
        [NewBle sharedManager].delegate = self;
    }
}

- (void)dfuDidUpdateProgress:(NSInteger)progress speed:(double)speed part:(NSInteger)part totalParts:(NSInteger)totalParts {
    progressView.progress = (float)progress / 100.0;
    lblProgress.text = [NSString stringWithFormat:@"%ld%%", (long)progress];
    
    if (totalParts > 1) {
        lblStatus.text = [NSString stringWithFormat:LocalForkey(@"正在传输固件 (%ld/%ld)...\n速度: %.1f KB/s"), (long)part, (long)totalParts, speed / 1024.0];
    } else {
        lblStatus.text = [NSString stringWithFormat:LocalForkey(@"正在传输固件...\n速度: %.1f KB/s"), speed / 1024.0];
    }
}

- (void)dfuDidFailWithError:(NSString *)message {
    lblStatus.text = [NSString stringWithFormat:LocalForkey(@"升级失败: %@"), message];
    btnUpgrade.enabled = YES;
    btnUpgrade.backgroundColor = [UIColor systemBlueColor];
    [btnUpgrade setTitle:LocalForkey(@"重新升级") forState:UIControlStateNormal];
    
    // DFU失败，恢复NewBle的delegate
    [NewBle sharedManager].delegate = self;
}

#pragma mark - Dealloc

- (void)dealloc {
    [self stopScanTimer];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

@end
