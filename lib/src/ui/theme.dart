import 'package:flutter/material.dart';

/// Brand colours used by the bundled QuickAuth widgets. Sourced from
/// `quickauth-website/src/styles/tokens.css`.
class QuickAuthColors {
  QuickAuthColors._();

  /// Primary brand green (`--accent`).
  static const Color accent = Color(0xFF00E640);

  /// Deeper brand green used for text/contrast (`--accent-deep`).
  static const Color accentDeep = Color(0xFF00C637);

  /// Even darker green for hover/pressed (`--accent-darker`).
  static const Color accentDarker = Color(0xFF00772B);

  /// Subtle green tint background (`--accent-soft`).
  static const Color accentSoft = Color(0xFFE6F9EC);

  /// Black ink for primary text/buttons (`--ink`).
  static const Color ink = Color(0xFF0A0A0A);

  /// Soft ink (`--ink-soft`).
  static const Color inkSoft = Color(0xFF555555);

  /// Muted ink (`--ink-mute`).
  static const Color inkMute = Color(0xFF888888);

  /// Page background (`--bg`).
  static const Color background = Color(0xFFFAFAF7);

  /// Card background (`--bg-card`).
  static const Color card = Color(0xFFFFFFFF);

  /// 0.08 black hairline (`--line`).
  static const Color line = Color(0x14000000);

  /// WhatsApp green (`--wa`).
  static const Color whatsapp = Color(0xFF25D366);

  /// Danger red.
  static const Color danger = Color(0xFFB94C4C);
}

/// Typography presets matching the site (Inter Tight + Instrument Serif +
/// JetBrains Mono).
class QuickAuthTextStyles {
  QuickAuthTextStyles._();

  /// Sans-serif font family (defaults to system if Inter Tight isn't loaded).
  static const List<String> sans = <String>[
    'Inter Tight',
    'Inter',
    'system-ui',
  ];

  /// Italic display serif for the wordmark.
  static const List<String> serif = <String>['Instrument Serif', 'Georgia'];

  /// Monospace for the `[Q]` mono badge.
  static const List<String> mono = <String>['JetBrains Mono', 'monospace'];

  /// Button label.
  static const TextStyle button = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: Colors.white,
    fontFamilyFallback: sans,
  );

  /// OTP cell digit.
  static const TextStyle otpDigit = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w500,
    color: QuickAuthColors.ink,
    fontFamilyFallback: mono,
  );
}

/// Visual variant of [QuickAuthLoginButton].
enum QuickAuthButtonStyle {
  /// Black background, white label — matches `.btn-primary` on the site.
  primary,

  /// Brand-green background, ink label — matches `.btn-accent`.
  accent,

  /// White background with hairline border — matches `.btn-ghost`.
  ghost,

  /// WhatsApp brand green for click-to-chat login — matches `--wa`.
  whatsapp,
}
