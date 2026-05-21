import 'package:flutter/material.dart';
import 'package:quickauth/quickauth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await QuickAuth.init(
    // In production, this callback hits YOUR backend, which proxies to
    // QuickAuth's POST /v1/sdk/session using your client secret.
    // The demo build below uses the unsafe-direct escape hatch so the
    // example app stays self-contained.
    onTokenExpiry: () async => '',
    unsafeDirectClientId: 'qa_ci_demo',
    unsafeDirectClientSecret: 'qa_cs_demo',
    consent: true,
    debug: true,
  );
  // Capture launch attribution. In production, parse the actual launch URI
  // (e.g. via `app_links` / `uni_links`) and pass it as `launchUri`.
  await QuickAuth.attribution.captureLaunch();
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QuickAuth Example',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: QuickAuthColors.accentDeep,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: QuickAuthColors.background,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _phone = TextEditingController(text: '+919876543210');
  final TextEditingController _otp = TextEditingController();
  String? _jwt;
  String? _appHash;
  String? _error;
  OtpSession? _session;

  @override
  void initState() {
    super.initState();
    QuickAuth.auth.getAppHash().then((h) {
      if (mounted) setState(() => _appHash = h);
    });
  }

  @override
  void dispose() {
    _phone.dispose();
    _otp.dispose();
    super.dispose();
  }

  Future<void> _headlessStart() async {
    setState(() => _error = null);
    try {
      final s = await QuickAuth.auth.startOTP(
        phone: _phone.text.trim(),
        channel: OtpChannel.auto,
      );
      setState(() => _session = s);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _headlessVerify() async {
    final s = _session;
    if (s == null) return;
    try {
      final r = await QuickAuth.auth.verifyOTP(
        sessionId: s.sessionId,
        code: _otp.text.trim(),
      );
      setState(() => _jwt = r.jwt);
      await QuickAuth.attribution.trackConversion(event: 'login');
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('QuickAuth Example'),
        backgroundColor: QuickAuthColors.card,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_appHash != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('App hash: $_appHash',
                      style: const TextStyle(fontSize: 12)),
                ),
              const Text('Component mode',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              QuickAuthLoginButton(
                phone: _phone.text,
                text: 'Continue with QuickAuth',
                style: QuickAuthButtonStyle.primary,
                onSuccess: (jwt) => setState(() => _jwt = jwt),
                onError: (e) => setState(() => _error = e.toString()),
              ),
              const SizedBox(height: 12),
              QuickAuthLoginButton(
                phone: _phone.text,
                text: 'Continue with WhatsApp',
                style: QuickAuthButtonStyle.whatsapp,
                channel: OtpChannel.whatsapp,
                onSuccess: (jwt) => setState(() => _jwt = jwt),
                onError: (e) => setState(() => _error = e.toString()),
              ),
              const Divider(height: 40),
              const Text('Headless mode',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              TextField(
                controller: _phone,
                decoration: const InputDecoration(labelText: 'Phone (E.164)'),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _headlessStart,
                child: const Text('Send OTP'),
              ),
              if (_session != null) ...<Widget>[
                const SizedBox(height: 16),
                QuickAuthOtpField(
                  controller: _otp,
                  digitCount: 6,
                  autoFocus: true,
                  onCodeFilled: (_) => _headlessVerify(),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _headlessVerify,
                  child: const Text('Verify'),
                ),
              ],
              const SizedBox(height: 24),
              if (_jwt != null) Text('JWT: $_jwt',
                  style: const TextStyle(color: QuickAuthColors.accentDarker)),
              if (_error != null) Text('Error: $_error',
                  style: const TextStyle(color: QuickAuthColors.danger)),
            ],
          ),
        ),
      ),
    );
  }
}
