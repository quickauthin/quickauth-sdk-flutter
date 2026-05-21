# QuickAuth Flutter SDK

Phone OTP (SMS / WhatsApp) authentication and WhatsApp marketing attribution
for Flutter apps.

```
[Q] quickauth — drop-in OTP + click attribution for Flutter
```

- Twilio-Verify-style ephemeral session tokens — your client secret never
  leaves your backend.
- Headless mode for custom UIs, component mode for drop-in widgets.
- Android SMS Retriever (auto-read OTPs). iOS uses native `oneTimeCode`
  autofill.
- Click-to-WhatsApp deep links.
- Launch attribution + conversion events with built-in DPDP / GDPR consent
  gating.

## Install

```bash
flutter pub add quickauth
```

`pubspec.yaml`:

```yaml
dependencies:
  quickauth: ^0.2.0
```

## How auth works (read this first)

QuickAuth follows the same pattern Twilio Verify uses for mobile SDKs:

1. **Your backend** mints a short-lived (10 min) `sessionToken` JWT by
   calling `POST https://api.quickauth.in/v1/sdk/session` server-to-server,
   authenticated with your **client secret** (which lives only on your
   server).
2. **The SDK** uses that JWT as `Authorization: Bearer <sessionToken>` for
   every QuickAuth API call.
3. About 30 seconds before the token expires the SDK calls your
   `onTokenExpiry` callback, which fetches a fresh token from your backend.

This way the client secret never ships in the app binary and tokens are
always rotatable.

## Quick start — headless

```dart
await QuickAuth.init(
  onTokenExpiry: () async {
    // Hit YOUR backend, which proxies to QuickAuth's /v1/sdk/session.
    final res = await myApi.fetch('/api/quickauth-token');
    return res.sessionToken as String;
  },
);

final session = await QuickAuth.auth.startOTP(
  phone: '+919876543210',
  channel: OtpChannel.auto,
);

final result = await QuickAuth.auth.verifyOTP(
  sessionId: session.sessionId,
  code: '123456',
);
print(result.jwt);
```

Auto-read inbound OTPs on Android:

```dart
final sub = QuickAuth.auth.observeOTP().listen((code) {
  controller.text = code;
});
```

## Server-side: minting `sessionToken`

Below is a minimal **Dart Frog / Shelf** example for the customer-side
endpoint that the SDK's `onTokenExpiry` callback hits.

### Dart Frog

```dart
// routes/api/quickauth-token.dart
import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:http/http.dart' as http;

const _quickAuthBase = 'https://api.quickauth.in';

Future<Response> onRequest(RequestContext context) async {
  // 1. Authenticate the caller — only logged-in users may mint tokens.
  final user = await context.read<AuthService>().currentUser(context.request);
  if (user == null) {
    return Response(statusCode: 401);
  }

  // 2. Server-to-server call to QuickAuth using YOUR client secret.
  final res = await http.post(
    Uri.parse('$_quickAuthBase/v1/sdk/session'),
    headers: <String, String>{
      'content-type': 'application/json',
      'x-client-id': const String.fromEnvironment('QUICKAUTH_CLIENT_ID'),
      'x-client-secret': const String.fromEnvironment('QUICKAUTH_CLIENT_SECRET'),
    },
    body: jsonEncode(<String, dynamic>{
      // Optional — bind the session to your user for audit logs.
      'subject': user.id,
    }),
  );
  if (res.statusCode != 200) {
    return Response(statusCode: 502, body: res.body);
  }

  final json = jsonDecode(res.body) as Map<String, dynamic>;
  // QuickAuth returns: { "sessionToken": "<jwt>", "expiresIn": 600 }
  return Response.json(body: <String, dynamic>{
    'sessionToken': json['sessionToken'],
    'expiresIn':    json['expiresIn'],
  });
}
```

### Plain Shelf

```dart
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;

final router = Router()
  ..get('/api/quickauth-token', (Request req) async {
    final user = await currentUserOrNull(req);
    if (user == null) return Response.unauthorized('login required');

    final res = await http.post(
      Uri.parse('https://api.quickauth.in/v1/sdk/session'),
      headers: <String, String>{
        'content-type': 'application/json',
        'x-client-id':     Platform.environment['QUICKAUTH_CLIENT_ID']!,
        'x-client-secret': Platform.environment['QUICKAUTH_CLIENT_SECRET']!,
      },
      body: jsonEncode(<String, dynamic>{'subject': user.id}),
    );
    if (res.statusCode != 200) {
      return Response.internalServerError(body: res.body);
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    return Response.ok(jsonEncode(<String, dynamic>{
      'sessionToken': json['sessionToken'],
      'expiresIn':    json['expiresIn'],
    }), headers: <String, String>{'content-type': 'application/json'});
  });
```

Keep `QUICKAUTH_CLIENT_SECRET` in your server's secret manager — never embed
it in the app.

## Quick start — component mode

```dart
QuickAuthLoginButton(
  phone: '+919876543210',
  text: 'Continue with QuickAuth',
  style: QuickAuthButtonStyle.primary,
  onSuccess: (jwt) => Navigator.of(context).pushReplacementNamed('/home'),
  onError:   (e)   => debugPrint('$e'),
)
```

```dart
QuickAuthOtpField(
  controller: _otp,
  digitCount: 6,
  autoFocus: true,
  onCodeFilled: (code) => verify(code),
)
```

## WhatsApp login

```dart
await QuickAuth.auth.startWhatsAppLogin(
  businessNumber: '+919574980048',
);
```

## Attribution

```dart
final attribution = await QuickAuth.attribution.captureLaunch(
  launchUri: Uri.parse(launchUrl),
);
await QuickAuth.attribution.trackConversion(
  event: 'signup',
  value: 0,
  currency: 'INR',
);
```

## Consent (DPDP / GDPR)

The SDK never sends analytics calls until consent is granted.

```dart
QuickAuth.consent.set(true);   // grant
QuickAuth.consent.set(false);  // revoke (also wipes qa_clid)
```

Calls made while denied are queued and replayed automatically when consent
flips to `true`.

## Android setup

Add to `android/app/src/main/AndroidManifest.xml` (only if you don't already
have it):

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

The SMS Retriever API requires the OTP message body to end with the 11-char
**app-signing hash** for your build. Print it on first run:

```dart
final hash = await QuickAuth.auth.getAppHash();
debugPrint('Paste this into your QuickAuth template: $hash');
```

Then paste the hash into your QuickAuth dashboard SMS template body. Each
build (debug / release / Play-signed) has a different hash.

## iOS setup

Nothing to do — iOS handles OTP autofill natively. Our `QuickAuthOtpField`
already declares `autofillHints: [AutofillHints.oneTimeCode]`.

For the strongest match, configure Associated Domains pointing at your
`apple-app-site-association` so OTPs delivered via WhatsApp / iMessage from
your registered sender autofill instantly. This is optional.

## API reference

### `QuickAuth.init`

| Parameter                   | Default                    | Notes                                       |
| --------------------------- | -------------------------- | ------------------------------------------- |
| `onTokenExpiry`             | required                   | `Future<String> Function()` returning a fresh `sessionToken` |
| `apiBaseUrl`                | `https://api.quickauth.in` |                                             |
| `initialToken`              | `null`                     | Pre-warmed JWT to skip the first round-trip |
| `unsafeDirectClientId`      | `null`                     | **Unsafe** — see below                      |
| `unsafeDirectClientSecret`  | `null`                     | **Unsafe** — see below                      |
| `consent`                   | `false`                    | Persisted after first call                  |
| `debug`                     | `false`                    | Enables `debugPrint` traces                 |

#### Unsafe direct mode (trusted-enterprise only)

If you're shipping a first-party app that you fully control and you're
willing to embed the QuickAuth client secret in your binary, you can skip
the customer-backend hop:

```dart
await QuickAuth.init(
  onTokenExpiry: () async => '', // ignored when unsafe-direct is set
  unsafeDirectClientId:     'qa_ci_xxx',
  unsafeDirectClientSecret: 'qa_cs_xxx',
);
```

The SDK will print:

```
[QuickAuth] ⚠️ UNSAFE mode: client_secret embedded; for trusted-enterprise only
```

Do not enable this in any app shipped to third-party customers.

### `QuickAuth.auth`

- `Future<OtpSession> startOTP({required String phone, OtpChannel channel = OtpChannel.auto})`
- `Future<OtpResult> verifyOTP({required String code, String? sessionId})`
- `Stream<String> observeOTP()` — Android only; empty stream on iOS
- `Future<String?> getAppHash()` — Android only
- `Future<bool> startWhatsAppLogin({required String businessNumber, ...})`

### `QuickAuth.attribution`

- `Future<AttributionResult> captureLaunch({Uri? launchUri})`
- `Future<void> trackConversion({required String event, num value = 0, String currency = 'INR', Map<String, dynamic>? metadata})`
- `Future<String?> qaClid()`

### Widgets

- `QuickAuthLoginButton` — opens an OTP sheet, returns a JWT
- `QuickAuthOtpField`    — pin-style cells with auto-fill

### Theme

`QuickAuthColors`, `QuickAuthTextStyles`, `QuickAuthButtonStyle` —
all values mirror the brand tokens in `quickauth-website/src/styles/tokens.css`.

## License

MIT — see [LICENSE](LICENSE).
