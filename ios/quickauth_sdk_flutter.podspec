Pod::Spec.new do |s|
  s.name             = 'quickauth_sdk_flutter'
  s.version          = '0.1.0'
  s.summary          = 'QuickAuth Flutter SDK iOS bridge.'
  s.description      = <<-DESC
QuickAuth — phone OTP and WhatsApp marketing attribution.
On iOS, OTP autofill is handled by the OS via `textContentType=.oneTimeCode`,
so this plugin is a thin no-op shim.
                       DESC
  s.homepage         = 'https://quickauth.in'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'QuickAuth' => 'contact@quickauth.in' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
