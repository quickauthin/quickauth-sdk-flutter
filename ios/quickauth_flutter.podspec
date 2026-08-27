Pod::Spec.new do |s|
  # MUST stay identical to `name:` in pubspec.yaml, and this file MUST be named
  # <that name>.podspec. Flutter's podhelper.rb resolves a plugin's podspec purely
  # by that convention (.symlinks/plugins/<name>/ios/<name>.podspec) — a mismatch
  # fails `pod install` with "No podspec found", never a warning.
  s.name             = 'quickauth_flutter'
  s.version          = '1.2.0'
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
