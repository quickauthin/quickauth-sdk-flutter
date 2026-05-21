import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../quickauth_facade.dart';
import 'theme.dart';

/// Pin-style OTP input — N cells, single digit each, auto-advance, paste
/// distribution, and Android `observeOTP()` auto-fill.
///
/// Usage:
/// ```dart
/// QuickAuthOtpField(
///   controller: _ctl,
///   digitCount: 6,
///   onCodeFilled: (code) => verify(code),
///   autoFocus: true,
/// )
/// ```
class QuickAuthOtpField extends StatefulWidget {
  /// Creates the field.
  const QuickAuthOtpField({
    super.key,
    required this.controller,
    this.digitCount = 6,
    this.onCodeFilled,
    this.autoFocus = false,
    this.cellWidth = 44,
    this.cellHeight = 54,
    this.observeAndroidSms = true,
  });

  /// Controller bound to the assembled code (e.g. `'123456'`).
  final TextEditingController controller;

  /// Number of digit cells.
  final int digitCount;

  /// Called when all cells are filled (and only digits are present).
  final void Function(String code)? onCodeFilled;

  /// Whether the first cell receives focus on mount.
  final bool autoFocus;

  /// Width of each cell.
  final double cellWidth;

  /// Height of each cell.
  final double cellHeight;

  /// When `true`, subscribes to `QuickAuth.auth.observeOTP()` and auto-fills
  /// on the first emitted code (Android only). Disabled if [QuickAuth] is not
  /// initialised.
  final bool observeAndroidSms;

  @override
  State<QuickAuthOtpField> createState() => _QuickAuthOtpFieldState();
}

class _QuickAuthOtpFieldState extends State<QuickAuthOtpField> {
  late final List<TextEditingController> _cells;
  late final List<FocusNode> _nodes;
  StreamSubscription<String>? _smsSub;

  @override
  void initState() {
    super.initState();
    _cells = List<TextEditingController>.generate(
      widget.digitCount,
      (_) => TextEditingController(),
    );
    _nodes = List<FocusNode>.generate(widget.digitCount, (_) => FocusNode());

    if (widget.observeAndroidSms && QuickAuth.isInitialized) {
      _smsSub = QuickAuth.auth.observeOTP().listen(_applyAutoCode);
    }
  }

  @override
  void dispose() {
    _smsSub?.cancel();
    for (final c in _cells) {
      c.dispose();
    }
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _applyAutoCode(String code) {
    final digits = code.replaceAll(RegExp(r'\D'), '');
    if (digits.length < widget.digitCount) return;
    for (var i = 0; i < widget.digitCount; i++) {
      _cells[i].text = digits[i];
    }
    final assembled = digits.substring(0, widget.digitCount);
    widget.controller.text = assembled;
    widget.onCodeFilled?.call(assembled);
  }

  void _onChanged(int i, String v) {
    if (v.length > 1) {
      final digits = v.replaceAll(RegExp(r'\D'), '');
      for (var k = 0; k < widget.digitCount; k++) {
        _cells[k].text = k < digits.length ? digits[k] : '';
      }
      final last = (digits.length - 1).clamp(0, widget.digitCount - 1);
      _nodes[last].requestFocus();
    } else if (v.isNotEmpty && i < widget.digitCount - 1) {
      _nodes[i + 1].requestFocus();
    } else if (v.isEmpty && i > 0) {
      _nodes[i - 1].requestFocus();
    }
    final code = _cells.map((c) => c.text).join();
    widget.controller.text = code;
    if (code.length == widget.digitCount && !code.contains(RegExp(r'\D'))) {
      widget.onCodeFilled?.call(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        for (int i = 0; i < widget.digitCount; i++)
          SizedBox(
            width: widget.cellWidth,
            height: widget.cellHeight,
            child: TextField(
              controller: _cells[i],
              focusNode: _nodes[i],
              autofocus: widget.autoFocus && i == 0,
              keyboardType: TextInputType.number,
              textInputAction: i == widget.digitCount - 1
                  ? TextInputAction.done
                  : TextInputAction.next,
              textAlign: TextAlign.center,
              maxLength: 1,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              autofillHints: const <String>[AutofillHints.oneTimeCode],
              style: QuickAuthTextStyles.otpDigit,
              decoration: InputDecoration(
                counterText: '',
                contentPadding: EdgeInsets.zero,
                enabledBorder: OutlineInputBorder(
                  borderSide: const BorderSide(color: QuickAuthColors.line),
                  borderRadius: BorderRadius.circular(8),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: const BorderSide(
                    color: QuickAuthColors.accentDeep,
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onChanged: (v) => _onChanged(i, v),
            ),
          ),
      ],
    );
  }
}
