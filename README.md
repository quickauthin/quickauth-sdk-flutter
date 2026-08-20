# QuickAuth — Flutter Phone Authentication & OTP SDK

[![pub package](https://img.shields.io/pub/v/quickauth_flutter.svg)](https://pub.dev/packages/quickauth_flutter)
[![pub points](https://img.shields.io/pub/points/quickauth_flutter)](https://pub.dev/packages/quickauth_flutter/score)
[![likes](https://img.shields.io/pub/likes/quickauth_flutter)](https://pub.dev/packages/quickauth_flutter/score)
[![platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS-blue.svg)](https://pub.dev/packages/quickauth_flutter)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**Passwordless phone number authentication for Flutter** — verify users with a
one-time password (OTP) delivered over **SMS or WhatsApp**, with **OneTap silent
re-authentication**, automatic **SMS autofill on Android**, native **OTP autofill
on iOS**, and built-in **DPDP / GDPR consent** gating. QuickAuth is a
verification provider (Twilio-Verify style): your backend stays the source of
truth for user sessions, so you never ship a secret in your app.

> Looking for phone login, OTP verification, WhatsApp OTP, passwordless auth, or
> 2FA in your Flutter app? That's exactly what `quickauth_flutter` does.

- 📱 **Phone OTP login** over **SMS** and **WhatsApp** (auto channel selection with fallback)
- ⚡ **OneTap** — returning users on a trusted device are verified with no OTP to type
- 🔒 **Secret-safe** — short-lived session tokens minted by *your* backend; client secret never leaves your server
- 🎯 **Headless or drop-in UI** — build your own screens, or use the ready-made login button & OTP field
- 🤖 **Android SMS Retriever** auto-reads the code; **iOS** uses native `oneTimeCode` autofill
- 💬 **Click-to-WhatsApp** login deep links
- 📊 **Attribution & conversion events** with consent-gated device metadata
- 🇮🇳 **DPDP** + 🇪🇺 **GDPR** consent gating out of the box

## Table of contents

- [Install](#install)
- [How authentication works](#how-authentication-works-read-this-first)
- [Quick start (headless)](#quick-start-headless)
- [OneTap silent re-auth](#onetap-silent-re-authentication)
- [Drop-in UI widgets](#drop-in-ui-widgets)
- [WhatsApp login](#whatsapp-login)
- [Consent (DPDP / GDPR)](#consent-dpdp--gdpr)
- [Platform setup](#platform-setup)
- [Backend: minting a session token](#backend-minting-a-session-token)
- [FAQ](#faq)

## Install

```bash
flutter pub add quickauth_flutter
```

```yaml
# pubspec.yaml
dependencies:
  quickauth_flutter: ^1.1.1
```

```dart
import 'package:quickauth_flutter/quickauth_flutter.dart';
```

## How authentication works (read this first)

QuickAuth **verifies phone numbers** — it does not create sessions for you. That
keeps you in control of your users and keeps your API secret off the device:

1. **Your backend** mints a short-lived (10 min) `sessionToken` by calling
   `POST https://api.quickauth.in/v1/sdk/session` server-to-server with your
   **client secret** (which lives only on your server).
2. **The SDK** uses that token to run the OTP flow directly against QuickAuth.
3. On success the SDK returns a `requestId`. **Your backend** confirms it via
   `GET /v1/auth/status?requestId=…`, then looks up / creates the user and mints
   **your own** session. You own sessions, roles, and sign-out — forever.

## Quick start (headless)

Build your own UI and let the SDK drive the state machine through typed events.

```dart
// 1. Initialise once at app startup.
await QuickAuth.init(
  onTokenExpiry: () async {
    // Hit YOUR backend, which proxies to QuickAuth's /v1/sdk/session.
    final res = await myApi.get('/api/quickauth-token');
    return res.sessionToken as String;
  },
  onAuthEvent: (event) {
    switch (event) {
      case OtpSentEvent():     showOtpScreen();               // code was sent
      case OtpAutoReadEvent(): prefillCode(event.code);        // Android auto-read the SMS
      case VerifiedEvent():    finishLogin(event.requestId);   // ✅ verified (OTP *or* OneTap)
      case OtpFailedEvent():   showError(event.message);        // wrong code — retryable
      case AuthErrorEvent():   showError(event.message);        // network / rate-limit
    }
  },
);

// 2. Send the OTP (E.164 phone number required).
await QuickAuth.auth.initiate(
  phone: '+919876543210',
  channel: OtpChannel.auto, // or OtpChannel.sms / OtpChannel.whatsapp
);

// 3. Submit the code the user typed.
await QuickAuth.auth.submitOtp('123456');

// 4. On VerifiedEvent, confirm requestId on YOUR backend and start your session.
```

## OneTap silent re-authentication

OneTap is **automatic** — there's no flag to enable. On the first successful
login the SDK stores a device token. On the next `initiate()` for a trusted
device, QuickAuth returns `VERIFIED` immediately, so `VerifiedEvent` fires
**without sending an OTP**. Your headless handler already covers it:

```dart
case VerifiedEvent(): finishLogin(event.requestId); // fires instantly for trusted devices
```

Sign the device out (disable OneTap for next time) with:

```dart
await QuickAuth.auth.reset(forgetDevice: true);
```

## Drop-in UI widgets

Prefer not to build screens? Use the bundled components:

```dart
QuickAuthLoginButton(
  phone: '+919876543210',
  text: 'Continue with phone',
  onSuccess: (requestId) => Navigator.of(context).pushReplacementNamed('/home'),
  onError:   (e)         => debugPrint('$e'),
);

QuickAuthOtpField(
  controller: _otp,
  digitCount: 6,
  autoFocus: true,
  onCodeFilled: (code) => QuickAuth.auth.submitOtp(code),
);
```

## WhatsApp login

Open a click-to-WhatsApp login conversation:

```dart
await QuickAuth.auth.startWhatsAppLogin(
  businessNumber: '+919574980048',
);
```

## Consent (DPDP / GDPR)

The SDK sends **no** analytics or device metadata until consent is granted.

```dart
QuickAuth.consent.set(true);  // grant  — queued events replay automatically
QuickAuth.consent.set(false); // revoke — clears stored click id
```

## Platform setup

| Platform | Minimum | Notes |
|---|---|---|
| **Android** | `minSdk 21` | Add `<uses-permission android:name="android.permission.INTERNET"/>`. SMS auto-read uses the SMS Retriever API — your OTP template must end with the 11-char app hash from `QuickAuth.auth.getAppHash()`. |
| **iOS** | iOS 12+ | Nothing required — `QuickAuthOtpField` declares `AutofillHints.oneTimeCode` for native OTP autofill. |

## Backend: minting a session token

The SDK's `onTokenExpiry` callback should hit an endpoint on **your** server
that proxies to QuickAuth using your client secret:

```dart
// Server-side (Dart Frog / Shelf / any framework)
final res = await http.post(
  Uri.parse('https://api.quickauth.in/v1/sdk/session'),
  headers: {
    'x-client-id':     env['QUICKAUTH_CLIENT_ID']!,
    'x-client-secret': env['QUICKAUTH_CLIENT_SECRET']!, // never ship this in the app
  },
);
// → { "sessionToken": "<jwt>", "expiresIn": 600 }
```

Full backend guide: <https://quickauth.in/docs/backend>

## FAQ

**Is this passwordless / 2FA?** Yes — QuickAuth is phone-based passwordless auth
and works as a second factor. Users prove control of a phone number via an OTP
sent over SMS or WhatsApp.

**Does it issue a login token (JWT)?** No. QuickAuth returns a `requestId` that
your backend confirms server-to-server, then mints your own session. This keeps
you the identity owner and keeps your secret off the device.

**Which channels are supported?** SMS and WhatsApp. Use `OtpChannel.auto` to let
QuickAuth pick the best channel with fallback, or force one explicitly.

**Does OTP autofill work?** Yes — Android via the SMS Retriever API (no SMS
permission needed) and iOS via native one-time-code autofill.

## Links

- 🌐 Website: <https://quickauth.in>
- 📚 Docs: <https://quickauth.in/docs>
- 🐛 Issues: <https://github.com/quickauthin/quickauth-sdk-flutter/issues>

## License

[MIT](LICENSE) © QuickAuth
