platform :ios, '13.0'
use_frameworks!

target 'NordicDFUTool' do
  pod 'iOSMcuManagerLibrary', '~> 1.14'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
    end
  end
end
