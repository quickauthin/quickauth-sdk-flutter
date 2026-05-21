import 'package:flutter/material.dart';

import '../core/config.dart';
import '../quickauth_facade.dart';
import 'quickauth_otp_field.dart';
import 'theme.dart';

/// One-tap "Continue with QuickAuth" button.
///
/// On tap:
/// 1. Calls `QuickAuth.auth.startOTP(phone, channel)`.
/// 2. Pushes a modal sheet hosting a 6-digit input.
/// 3. Calls [onSuccess] with the resolved JWT, or [onError] on any failure.
class QuickAuthLoginButton extends StatefulWidget {
  /// Creates the button.
  const QuickAuthLoginButton({
    super.key,
    required this.phone,
    required this.onSuccess,
    this.onError,
    this.text = 'Continue',
    this.style = QuickAuthButtonStyle.primary,
    this.channel = OtpChannel.auto,
    this.icon,
  });

  /// E.164 phone number to send the OTP to.
  final String phone;

  /// Called with the verified JWT on success.
  final void Function(String jwt) onSuccess;

  /// Called when start/verify fails.
  final void Function(Object error)? onError;

  /// Button label.
  final String text;

  /// Visual variant.
  final QuickAuthButtonStyle style;

  /// Override the OTP channel (auto / sms / whatsapp).
  final OtpChannel channel;

  /// Optional leading icon.
  final Widget? icon;

  @override
  State<QuickAuthLoginButton> createState() => _QuickAuthLoginButtonState();
}

class _QuickAuthLoginButtonState extends State<QuickAuthLoginButton> {
  bool _busy = false;

  ({Color bg, Color fg, BorderSide? border}) _palette() {
    switch (widget.style) {
      case QuickAuthButtonStyle.accent:
        return (bg: QuickAuthColors.accent, fg: QuickAuthColors.ink, border: null);
      case QuickAuthButtonStyle.ghost:
        return (
          bg: QuickAuthColors.card,
          fg: QuickAuthColors.ink,
          border: const BorderSide(color: QuickAuthColors.line, width: 0.5),
        );
      case QuickAuthButtonStyle.whatsapp:
        return (bg: QuickAuthColors.whatsapp, fg: Colors.white, border: null);
      case QuickAuthButtonStyle.primary:
        return (bg: QuickAuthColors.ink, fg: Colors.white, border: null);
    }
  }

  Future<void> _onPressed() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final session = await QuickAuth.auth.startOTP(
        phone: widget.phone,
        channel: widget.channel,
      );
      if (!mounted) return;
      final code = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: QuickAuthColors.card,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (sheetCtx) => _OtpSheet(phone: widget.phone),
      );
      if (code == null) {
        return;
      }
      final result = await QuickAuth.auth.verifyOTP(
        sessionId: session.sessionId,
        code: code,
      );
      widget.onSuccess(result.jwt);
    } catch (e) {
      widget.onError?.call(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _palette();
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: p.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: p.border ?? BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _busy ? null : _onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                if (widget.icon != null) ...<Widget>[
                  IconTheme.merge(
                    data: IconThemeData(color: p.fg, size: 18),
                    child: widget.icon!,
                  ),
                  const SizedBox(width: 8),
                ],
                if (_busy)
                  SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(p.fg),
                    ),
                  )
                else
                  Text(
                    widget.text,
                    style: QuickAuthTextStyles.button.copyWith(color: p.fg),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OtpSheet extends StatefulWidget {
  const _OtpSheet({required this.phone});

  final String phone;

  @override
  State<_OtpSheet> createState() => _OtpSheetState();
}

class _OtpSheetState extends State<_OtpSheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + viewInsets),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 18),
            decoration: BoxDecoration(
              color: QuickAuthColors.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Text(
            'Enter the code',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w500,
              color: QuickAuthColors.ink,
              fontFamilyFallback: QuickAuthTextStyles.sans,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Sent to ${widget.phone}',
            style: TextStyle(
              fontSize: 14,
              color: QuickAuthColors.inkSoft,
              fontFamilyFallback: QuickAuthTextStyles.sans,
            ),
          ),
          const SizedBox(height: 20),
          QuickAuthOtpField(
            controller: _controller,
            digitCount: 6,
            autoFocus: true,
            onCodeFilled: (code) => Navigator.of(context).pop(code),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
          ),
        ],
      ),
    );
  }
}
