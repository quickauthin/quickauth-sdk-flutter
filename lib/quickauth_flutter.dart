/// QuickAuth Flutter SDK — phone OTP (SMS / WhatsApp) and WhatsApp marketing
/// attribution.
///
/// ```dart
/// await QuickAuth.init(
///   onTokenExpiry: () async => (await myApi.fetch('/api/quickauth-token')).sessionToken,
/// );
/// final session = await QuickAuth.auth.startOTP(phone: '+919876543210');
/// final result  = await QuickAuth.auth.verifyOTP(
///   sessionId: session.sessionId,
///   code: '123456',
/// );
/// ```
library quickauth_flutter;

// ---- Core ----
export 'src/core/config.dart';
export 'src/core/consent.dart';
export 'src/core/api_client.dart' show QuickAuthApiException, TokenManager;

// ---- Auth ----
export 'src/auth/auth_event.dart';
export 'src/auth/otp_service.dart';
export 'src/auth/whatsapp_login.dart';
export 'src/auth/whatsapp_otp_retriever.dart';

// ---- Attribution ----
export 'src/attribution/attribution_service.dart';

// ---- UI ----
export 'src/ui/quickauth_login_button.dart';
export 'src/ui/quickauth_otp_field.dart';
export 'src/ui/theme.dart';

// ---- Facade ----
export 'src/quickauth_facade.dart';
