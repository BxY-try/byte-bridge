import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:camera/camera.dart';
import 'discovery_service.dart';
import 'socket_service.dart';
import 'kilat_camera_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ByteBridgeApp());
}

/// Palet warna selaras dengan referensi desain numpad
class AppColors {
  static const Color scaffoldBg = Color(0xFFE8EEF1);
  static const Color housingBg = Color(0xFF8D8D8D);
  static const Color borderDark = Color(0xFF282A2E);
  static const Color keyNumber = Color(0xFFDCEBF0);
  static const Color keyOperator = Color(0xFFC4DBE1);
  static const Color keyDel = Color(0xFFD46C6D);
  static const Color keyEnter = Color(0xFF72B67D);
  static const Color textDark = Color(0xFF1B1E22);
  static const Color accentGreen = Color(0xFF237C58);
  static const Color accentGreenDark = Color(0xFF1B6547);
  static const Color textSecondary = Color(0xFF5A606A);
  static const Color cardBorder = Color(0xFFD8DDE3);
  static const Color cardInner = Color(0xFFF2F5F8);
}

class ByteBridgeApp extends StatelessWidget {
  const ByteBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ByteBridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: AppColors.scaffoldBg,
        cardColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.keyOperator,
          brightness: Brightness.light,
          surface: AppColors.scaffoldBg,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

enum ConnState { discovering, connecting, connected, disconnected, failed }

enum _KeyType { number, operator, del, enter, function }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SocketService _socketService = SocketService();
  ConnState _state = ConnState.discovering;
  String? _serverIp;
  int? _serverPort;
  int _currentTabIndex = 0;
  final TextEditingController _keyboardTextController = TextEditingController();
  final FocusNode _keyboardFocusNode = FocusNode();
  bool _keyboardManuallyClosed = false;

  // Riwayat teks keyboard terakhir untuk fitur isi ulang lokal
  String? _lastSentKeyboardText;

  // Pengaturan posisi & ukuran numpad dinamis (ala Gboard)
  double _numpadBottomOffset = 0.0; // 0 = mepet footer paling bawah
  double _numpadScale = 1.0; // 0.75 s/d 1.15
  double _numpadHorizontalAlign = 0.0; // -1.0 (kiri), 0.0 (tengah), 1.0 (kanan)
  bool _isAdjustingNumpad = false;

  // State Media Controller Dua Arah
  Map<String, dynamic>? _mediaState;
  Uint8List? _cachedThumbnailBytes;
  String? _cachedThumbnailHash;
  Timer? _mediaInterpolationTimer;
  double _localSeekPos = 0.0;
  double _serverSeekPos = 0.0;
  double _mediaDuration = 0.0;
  double _playbackRate = 1.0;
  String _playbackStatus = 'paused';
  DateTime _lastMediaSyncTime = DateTime.now();
  bool _isUserDraggingSeek = false;
  bool _isUserDraggingVolume = false;
  double _localVolume = 50.0;
  bool _isAdvancedExpanded = false;
  int _currentSpeedIndex = 1;
  final List<double> _speedOptions = [0.75, 1.0, 1.25, 1.5, 2.0];

  // State Cekrek AI
  File? _capturedImage;
  String? _extractedOcrText;
  String? _aiResponseAnswer;
  bool _isAiLoading = false;
  String _aiStatusMessage = '';
  final TextEditingController _aiPromptController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  // State Mode Kilat
  int _kilatShotCount = 0;
  Timer? _aiTimeoutTimer;

  @override
  void initState() {
    super.initState();
    _startDiscovery();
    // Timer interpolasi lokal (halus tanpa spam network)
    _mediaInterpolationTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_mediaState != null && _playbackStatus == 'playing' && !_isUserDraggingSeek && _mediaDuration > 0) {
        final elapsed = DateTime.now().difference(_lastMediaSyncTime).inMilliseconds / 1000.0;
        final cur = (_serverSeekPos + elapsed * _playbackRate).clamp(0.0, _mediaDuration);
        if (mounted && (cur - _localSeekPos).abs() > 0.25) {
          setState(() {
            _localSeekPos = cur;
          });
        }
      }
    });
  }

  void _onMediaStateReceived(Map<String, dynamic> data) {
    if (!mounted) return;
    setState(() {
      _mediaState = data;
      // Handle thumbnail caching (menghemat 99.8% bandwidth)
      final String? thumbStr = data['thumbnail'] as String?;
      final String? thumbHash = data['thumbnail_hash'] as String?;
      if (thumbStr != null && thumbStr.isNotEmpty) {
        try {
          final String base64Content = thumbStr.contains(',') ? thumbStr.split(',').last : thumbStr;
          _cachedThumbnailBytes = base64Decode(base64Content);
          _cachedThumbnailHash = thumbHash;
        } catch (_) {}
      } else if (thumbHash != null && thumbHash == _cachedThumbnailHash && _cachedThumbnailBytes != null) {
        // Thumbnail sama, pertahankan yang ada di cache
      } else if (data['available'] == false) {
        _cachedThumbnailBytes = null;
      }

      _serverSeekPos = (data['position'] as num?)?.toDouble() ?? 0.0;
      _mediaDuration = (data['duration'] as num?)?.toDouble() ?? 0.0;
      _playbackRate = (data['playback_rate'] as num?)?.toDouble() ?? 1.0;
      _playbackStatus = (data['status'] as String?) ?? 'paused';
      _lastMediaSyncTime = DateTime.now();

      if (!_isUserDraggingSeek) {
        _localSeekPos = _serverSeekPos.clamp(0.0, _mediaDuration > 0 ? _mediaDuration : 100.0);
      }
      if (!_isUserDraggingVolume) {
        _localVolume = (data['volume'] as num?)?.toDouble() ?? 50.0;
      }

      final rate = (data['playback_rate'] as num?)?.toDouble();
      if (rate != null) {
        final idx = _speedOptions.indexOf(rate);
        if (idx != -1) _currentSpeedIndex = idx;
      }
    });
  }

  void _sendMediaCommand(String action, [dynamic value]) {
    HapticFeedback.lightImpact();
    _socketService.sendMediaCommand(action, value);
  }

  Future<void> _startDiscovery() async {
    setState(() => _state = ConnState.discovering);
    final info = await discoverServer();
    if (info == null) {
      setState(() => _state = ConnState.failed);
      return;
    }
    _connectTo(info.ip, info.port);
  }

  void _connectTo(String ip, int port) {
    setState(() {
      _serverIp = ip;
      _serverPort = port;
      _state = ConnState.connecting;
    });

    _socketService.connect(
      ip: ip,
      port: port,
      onConnect: () {
        if (mounted) setState(() => _state = ConnState.connected);
      },
      onDisconnect: () {
        _aiTimeoutTimer?.cancel();
        if (mounted) {
          setState(() {
            _state = ConnState.disconnected;
            if (_isAiLoading || _isKilatProcessing) {
              _isAiLoading = false;
              _isKilatProcessing = false;
              _aiStatusMessage = '❌ Terputus dari PC saat menunggu respon AI.';
            }
          });
        }
      },
      onError: (_) {
        _aiTimeoutTimer?.cancel();
        if (mounted) {
          setState(() {
            _state = ConnState.disconnected;
            if (_isAiLoading || _isKilatProcessing) {
              _isAiLoading = false;
              _isKilatProcessing = false;
              _aiStatusMessage = '❌ Koneksi terputus ke PC.';
            }
          });
        }
      },
      onMediaState: _onMediaStateReceived,
      onAiResponse: _onAiResponseReceived,
    );
  }

  void _onAiResponseReceived(Map<String, dynamic> data) {
    if (!mounted) return;
    _aiTimeoutTimer?.cancel();
    setState(() {
      _isAiLoading = false;
      if (data['success'] == true) {
        _extractedOcrText = data['ocr_text'];
        _aiResponseAnswer = data['llm_answer'];
        final model = data['model'] ?? 'Gemini';
        if (_kilatShotCount > 0) {
          _aiStatusMessage = '✅ Soal #$_kilatShotCount dijawab ($model) — Cek Terminal PC! Siap jepret lagi ⚡';
        } else {
          _aiStatusMessage = '✅ Selesai ($model)! Jawaban di Terminal PC & clipboard.';
        }
      } else {
        _aiStatusMessage = '❌ Error: ${data['error'] ?? 'Gagal memproses AI'}';
      }
    });
  }

  void _startAiTimeoutTimer() {
    _aiTimeoutTimer?.cancel();
    _aiTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (mounted && _isAiLoading) {
        setState(() {
          _isAiLoading = false;
          _aiStatusMessage = '❌ Timeout: Server tidak merespons dalam 30 detik. Silakan coba lagi.';
        });
      }
    });
  }

  Future<void> _takePhotoAndProcess({bool fromGallery = false}) async {
    HapticFeedback.mediumImpact();
    try {
      final XFile? photo = await _picker.pickImage(
        source: fromGallery ? ImageSource.gallery : ImageSource.camera,
        maxWidth: 1920,
        imageQuality: 85,
      );
      if (photo == null) return;

      setState(() {
        _capturedImage = File(photo.path);
        _isAiLoading = true;
        _aiStatusMessage = '📸 Memproses ekstraksi teks (OCR)...';
        _aiResponseAnswer = null;
      });

      String ocrResult = '';
      try {
        final inputImage = InputImage.fromFilePath(photo.path);
        final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
        final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
        await textRecognizer.close();
        ocrResult = recognizedText.text.trim();
      } catch (e) {
        debugPrint('ML Kit OCR error: $e');
      }

      setState(() {
        _extractedOcrText = ocrResult;
      });

      final prompt = _aiPromptController.text.trim().isNotEmpty ? _aiPromptController.text.trim() : null;

      _startAiTimeoutTimer();
      if (ocrResult.isNotEmpty) {
        setState(() {
          _aiStatusMessage = '⚡ Mengirim teks OCR ke Gemini via Terminal Server PC...';
        });
        _socketService.sendAiQuery(text: ocrResult, prompt: prompt);
      } else {
        // Fallback jika ML Kit tidak mendeteksi teks di HP, kirim ke server PC untuk RapidOCR lokal
        setState(() {
          _aiStatusMessage = '🔄 Menjalankan OCR lokal di server PC (0 vision token)...';
        });
        final bytes = await photo.readAsBytes();
        final base64Img = base64Encode(bytes);
        _socketService.sendAiQuery(imageBase64: base64Img, prompt: prompt);
      }
    } catch (e) {
      _aiTimeoutTimer?.cancel();
      setState(() {
        _isAiLoading = false;
        _aiStatusMessage = '❌ Gagal: $e';
      });
    }
  }

  // ========== MODE KILAT METHODS ==========

  Future<void> _openKilatCamera() async {
    HapticFeedback.mediumImpact();
    final prompt = _aiPromptController.text.trim().isNotEmpty
        ? _aiPromptController.text.trim()
        : null;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => KilatCameraScreen(
          socketService: _socketService,
          prompt: prompt,
          onFinished: (shotCount, lastImage, lastOcr) {
            if (mounted && shotCount > 0) {
              setState(() {
                _kilatShotCount += shotCount;
                if (lastImage != null) _capturedImage = lastImage;
                if (lastOcr.isNotEmpty) _extractedOcrText = lastOcr;
                _aiStatusMessage = '⚡ Mode Kilat: $shotCount soal terkirim ke PC! Cek terminal PC.';
              });
            }
          },
        ),
      ),
    );
  }

  Future<void> _showManualIpDialog() async {
    final controller = TextEditingController(text: _serverIp ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.borderDark, width: 1.8),
        ),
        title: const Text(
          'Input IP Server Manual',
          style: TextStyle(color: AppColors.textDark, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: AppColors.textDark),
          decoration: InputDecoration(
            hintText: '192.168.1.5',
            labelText: 'Alamat IP PC',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.borderDark),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.housingBg, width: 2),
            ),
          ),
          keyboardType: TextInputType.datetime,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal', style: TextStyle(color: Color(0xFF6B7280))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.keyEnter,
              foregroundColor: AppColors.textDark,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: AppColors.borderDark, width: 1.5),
              ),
            ),
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Hubungkan', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      _connectTo(result, 8080);
    }
  }

  Timer? _deleteInitialTimer;
  Timer? _deleteRepeatTimer;
  Timer? _arrowInitialTimer;
  Timer? _arrowRepeatTimer;
  Timer? _scrollInitialTimer;
  Timer? _scrollRepeatTimer;
  double _scrollDragAccumulator = 0;

  void _sendTextInput(String text) {
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    _socketService.sendTextInput(text);
  }

  void _submitKeyboardText() {
    final text = _keyboardTextController.text;
    if (text.trim().isEmpty) return;
    _sendTextInput(text);
    setState(() {
      _lastSentKeyboardText = text;
    });
    _keyboardTextController.clear();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: AppColors.keyEnter, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Teks terkirim ke PC: "$text"',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ],
        ),
        duration: const Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.borderDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  void _recallLastSentText() {
    if (_lastSentKeyboardText == null || _lastSentKeyboardText!.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _keyboardTextController.text = _lastSentKeyboardText!;
      _keyboardTextController.selection = TextSelection.fromPosition(
        TextPosition(offset: _keyboardTextController.text.length),
      );
    });
    _openKeyboard();
  }

  FocusNode get _currentActiveFocusNode => _keyboardFocusNode;

  bool _isSoftKeyboardVisible(BuildContext context) {
    if (!mounted) return false;
    final double insetsBottom = MediaQuery.of(context).viewInsets.bottom;
    if (insetsBottom == 0) {
      _keyboardManuallyClosed = false;
      return false;
    }
    if (_keyboardManuallyClosed) {
      return false;
    }
    return insetsBottom > 0;
  }

  void _openKeyboard() {
    if (!mounted) return;
    final bool isAlreadyVisible = _isSoftKeyboardVisible(context);
    final currentFocus = _currentActiveFocusNode;

    // Mekanisme anti-flickering:
    // Jika input box aktif sudah fokus DAN keyboard memang sudah aktif terbuka di layar,
    // jangan panggil requestFocus ataupun TextInput.show lagi.
    if (currentFocus.hasFocus && isAlreadyVisible) {
      return;
    }

    if (_keyboardManuallyClosed) {
      setState(() {
        _keyboardManuallyClosed = false;
      });
    }

    if (!currentFocus.hasFocus) {
      currentFocus.requestFocus();
    }
    SystemChannels.textInput.invokeMethod('TextInput.show');
  }

  void _closeKeyboard() {
    if (!mounted) return;
    setState(() {
      _keyboardManuallyClosed = true;
    });
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  Future<void> _pasteToPc() async {
    HapticFeedback.lightImpact();
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text != null && text.isNotEmpty) {
        _sendTextInput(text);
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle, color: AppColors.keyEnter, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Clipboard HP ter-paste ke PC: "$text"',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
              duration: const Duration(milliseconds: 1500),
              behavior: SnackBarBehavior.floating,
              backgroundColor: AppColors.borderDark,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          );
        }
        return;
      }
    } catch (_) {}

    // Fallback jika clipboard HP kosong, kirim pintasan Ctrl+V ke PC
    _sendHotkey(['ctrl', 'v']);
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.info_outline, color: AppColors.keyOperator, size: 18),
              SizedBox(width: 8),
              Text(
                'Menjalankan Paste (Ctrl+V) di PC',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.borderDark,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  void _sendKey(String key) {
    HapticFeedback.lightImpact();
    _socketService.sendKey(key);
  }

  void _sendHotkey(List<String> keys) {
    HapticFeedback.mediumImpact();
    _socketService.sendHotkey(keys);
  }

  void _sendScroll(int dy) {
    HapticFeedback.selectionClick();
    _socketService.sendMouseScroll(dy);
  }

  void _startDeleteRepeating() {
    _sendKey('backspace');
    _deleteInitialTimer?.cancel();
    _deleteRepeatTimer?.cancel();
    _deleteInitialTimer = Timer(const Duration(milliseconds: 350), () {
      _deleteRepeatTimer = Timer.periodic(const Duration(milliseconds: 65), (_) {
        _sendKey('backspace');
      });
    });
  }

  void _stopDeleteRepeating() {
    _deleteInitialTimer?.cancel();
    _deleteInitialTimer = null;
    _deleteRepeatTimer?.cancel();
    _deleteRepeatTimer = null;
  }

  void _startArrowRepeating(String key) {
    _sendKey(key);
    _arrowInitialTimer?.cancel();
    _arrowRepeatTimer?.cancel();
    _arrowInitialTimer = Timer(const Duration(milliseconds: 300), () {
      _arrowRepeatTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
        _sendKey(key);
      });
    });
  }

  void _stopArrowRepeating() {
    _arrowInitialTimer?.cancel();
    _arrowInitialTimer = null;
    _arrowRepeatTimer?.cancel();
    _arrowRepeatTimer = null;
  }

  void _startScrollRepeating(int dy) {
    _sendScroll(dy);
    _scrollInitialTimer?.cancel();
    _scrollRepeatTimer?.cancel();
    _scrollInitialTimer = Timer(const Duration(milliseconds: 300), () {
      _scrollRepeatTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        _sendScroll(dy);
      });
    });
  }

  void _stopScrollRepeating() {
    _scrollInitialTimer?.cancel();
    _scrollInitialTimer = null;
    _scrollRepeatTimer?.cancel();
    _scrollRepeatTimer = null;
  }

  @override
  void dispose() {
    _keyboardTextController.dispose();
    _keyboardFocusNode.dispose();
    _aiPromptController.dispose();
    _deleteInitialTimer?.cancel();
    _deleteRepeatTimer?.cancel();
    _arrowInitialTimer?.cancel();
    _arrowRepeatTimer?.cancel();
    _scrollInitialTimer?.cancel();
    _scrollRepeatTimer?.cancel();
    _mediaInterpolationTimer?.cancel();
    _aiTimeoutTimer?.cancel();
    _socketService.dispose();
    super.dispose();
  }

  String get _statusText {
    switch (_state) {
      case ConnState.discovering:
        return 'Mencari server di WiFi...';
      case ConnState.connecting:
        return 'Menghubungkan ke $_serverIp...';
      case ConnState.connected:
        return 'Terhubung ke $_serverIp';
      case ConnState.disconnected:
        return 'Terputus, menghubungkan ulang...';
      case ConnState.failed:
        return 'Server tidak ditemukan. Coba input IP manual.';
    }
  }

  Color get _statusBgColor {
    switch (_state) {
      case ConnState.connected:
        return const Color(0xFFE2F3E5);
      case ConnState.failed:
        return const Color(0xFFFDE8E8);
      case ConnState.disconnected:
        return const Color(0xFFFEF3C7);
      default:
        return const Color(0xFFE6F3F7);
    }
  }

  Color get _statusBorderColor {
    switch (_state) {
      case ConnState.connected:
        return AppColors.keyEnter;
      case ConnState.failed:
        return AppColors.keyDel;
      case ConnState.disconnected:
        return const Color(0xFFF6AD55);
      default:
        return const Color(0xFF7DD3FC);
    }
  }

  Color get _statusTextColor {
    switch (_state) {
      case ConnState.connected:
        return const Color(0xFF1E4627);
      case ConnState.failed:
        return const Color(0xFF742A2A);
      case ConnState.disconnected:
        return const Color(0xFF7B341E);
      default:
        return const Color(0xFF075985);
    }
  }

  Color get _statusDotColor {
    switch (_state) {
      case ConnState.connected:
        return const Color(0xFF2E7D32);
      case ConnState.failed:
        return const Color(0xFFE53E3E);
      case ConnState.disconnected:
        return const Color(0xFFDD6B20);
      default:
        return const Color(0xFF0284C7);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ByteBridge',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
          ),
        ),
        backgroundColor: AppColors.scaffoldBg,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textDark),
            onPressed: _startDiscovery,
            tooltip: 'Cari ulang server',
          ),
          IconButton(
            icon: const Icon(Icons.edit, color: AppColors.textDark),
            onPressed: _showManualIpDialog,
            tooltip: 'Input IP manual',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(
            color: const Color(0xFFD8DDE3),
            height: 1.0,
          ),
        ),
      ),
      body: Column(
        children: [
          // Connection Status Bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            decoration: BoxDecoration(
              color: _statusBgColor,
              border: Border(
                bottom: BorderSide(color: _statusBorderColor.withOpacity(0.5), width: 1.0),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.circle, size: 9, color: _statusDotColor),
                const SizedBox(width: 8),
                Text(
                  _statusText,
                  style: TextStyle(
                    color: _statusTextColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          // Active Tab Body
          Expanded(
            child: IndexedStack(
              index: _currentTabIndex,
              children: [
                _buildNumpadTab(),
                _buildKeyboardTab(),
                _buildMediaTab(),
                _buildShortcutsTab(),
                _buildNavTab(),
                _buildAiAssistantTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: (_currentTabIndex == 1 && _isSoftKeyboardVisible(context))
          ? null
          : Container(
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: Color(0xFFD8DDE3), width: 1.0),
                ),
              ),
              child: NavigationBarTheme(
                data: NavigationBarThemeData(
                  height: 56,
                  indicatorColor: AppColors.keyOperator,
                  labelTextStyle: MaterialStateProperty.resolveWith((states) {
                    if (states.contains(MaterialState.selected)) {
                      return const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textDark,
                      );
                    }
                    return const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF5A606A),
                    );
                  }),
                ),
                child: NavigationBar(
                  height: 56,
                  selectedIndex: _currentTabIndex,
                  onDestinationSelected: (idx) {
                    HapticFeedback.selectionClick();
                    _stopDeleteRepeating();
                    _stopArrowRepeating();
                    _stopScrollRepeating();
                    setState(() => _currentTabIndex = idx);
                    if (idx == 1) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _openKeyboard();
                      });
                    } else {
                      _keyboardManuallyClosed = false;
                      _keyboardFocusNode.unfocus();
                    }
                  },
                  backgroundColor: const Color(0xFFF2F5F8),
                  surfaceTintColor: Colors.transparent,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.dialpad, size: 20, color: Color(0xFF5A606A)),
                      selectedIcon: Icon(Icons.dialpad, size: 20, color: AppColors.textDark),
                      label: 'Numpad',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.keyboard, size: 20, color: Color(0xFF5A606A)),
                      selectedIcon: Icon(Icons.keyboard, size: 20, color: AppColors.textDark),
                      label: 'Keyboard',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.music_note, size: 20, color: Color(0xFF5A606A)),
                      selectedIcon: Icon(Icons.music_note, size: 20, color: AppColors.textDark),
                      label: 'Media',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.bolt, size: 20, color: Color(0xFF5A606A)),
                      selectedIcon: Icon(Icons.bolt, size: 20, color: AppColors.textDark),
                      label: 'Pintasan',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.navigation, size: 20, color: Color(0xFF5A606A)),
                      selectedIcon: Icon(Icons.navigation, size: 20, color: AppColors.textDark),
                      label: 'Navigasi',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.camera_alt_outlined, size: 20, color: Color(0xFF5A606A)),
                      selectedIcon: Icon(Icons.camera_alt, size: 20, color: AppColors.textDark),
                      label: 'Cekrek AI',
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  // ---------- TAB 1: NUMPAD (MEPET FOOTER + RESIZE/REPOSITION DINAMIS GBOARD STYLE) ----------
  Widget _buildNumpadTab() {
    return SafeArea(
      child: Column(
        children: [
          // Control Panel / Tombol Pengaturan Posisi & Ukuran (Gboard Style)
          if (_isAdjustingNumpad)
            _buildNumpadAdjustPanel()
          else
            Padding(
              padding: const EdgeInsets.only(right: 14, top: 4),
              child: Align(
                alignment: Alignment.topRight,
                child: GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _isAdjustingNumpad = true);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFCBD5E1), width: 1.0),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.04),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.tune, size: 13, color: Color(0xFF5A606A)),
                        SizedBox(width: 4),
                        Text(
                          'Atur Posisi',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF5A606A),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // Area Numpad: Ditempatkan mepet ke bawah (bottom footer)
          Expanded(
            child: Align(
              alignment: Alignment(_numpadHorizontalAlign, 1.0),
              child: Padding(
                padding: EdgeInsets.only(
                  left: 8,
                  right: 8,
                  bottom: _numpadBottomOffset + 2,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Drag Handle saat Mode Adjust aktif
                    if (_isAdjustingNumpad)
                      GestureDetector(
                        onVerticalDragUpdate: (details) {
                          setState(() {
                            _numpadBottomOffset = (_numpadBottomOffset - details.delta.dy).clamp(0.0, 180.0);
                          });
                        },
                        child: Container(
                          width: 380 * _numpadScale,
                          height: 22,
                          margin: const EdgeInsets.only(bottom: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2563EB).withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFF2563EB).withOpacity(0.3), width: 1.2),
                          ),
                          child: const Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.drag_handle, size: 16, color: Color(0xFF1D4ED8)),
                                SizedBox(width: 4),
                                Text(
                                  'Tahan & Geser Atas-Bawah',
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1D4ED8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    // Housing Numpad Utama
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox(
                        width: 380 * _numpadScale,
                        height: 520 * _numpadScale,
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.housingBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _isAdjustingNumpad ? const Color(0xFF2563EB) : AppColors.borderDark,
                              width: _isAdjustingNumpad ? 2.8 : 2.4,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.14),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.all(6.0),
                          child: Column(
                            children: [
                              // Navigasi Arah Inverted-T
                              _buildNavArrowCluster(),
                              const SizedBox(height: 6),
                              // Grid Numpad
                              Expanded(
                                child: Column(
                                  children: [
                                    // Baris 1: %, /, *, -
                                    Expanded(
                                      flex: 1,
                                      child: Row(
                                        children: [
                                          Expanded(child: _buildCalcKey('%', label: '%', type: _KeyType.operator)),
                                          Expanded(child: _buildCalcKey('/', label: '/', type: _KeyType.operator)),
                                          Expanded(child: _buildCalcKey('*', label: '*', type: _KeyType.operator)),
                                          Expanded(child: _buildCalcKey('-', label: '-', type: _KeyType.operator)),
                                        ],
                                      ),
                                    ),
                                    // Baris 2 sampai 5: 3 kolom angka di kiri, 1 kolom (+ dan Enter) di kanan
                                    Expanded(
                                      flex: 4,
                                      child: Row(
                                        children: [
                                          // 3 Kolom Kiri: 789, 456, 123, 0 . Del
                                          Expanded(
                                            flex: 3,
                                            child: Column(
                                              children: [
                                                Expanded(
                                                  child: Row(
                                                    children: [
                                                      Expanded(child: _buildCalcKey('7')),
                                                      Expanded(child: _buildCalcKey('8')),
                                                      Expanded(child: _buildCalcKey('9')),
                                                    ],
                                                  ),
                                                ),
                                                Expanded(
                                                  child: Row(
                                                    children: [
                                                      Expanded(child: _buildCalcKey('4')),
                                                      Expanded(child: _buildCalcKey('5')),
                                                      Expanded(child: _buildCalcKey('6')),
                                                    ],
                                                  ),
                                                ),
                                                Expanded(
                                                  child: Row(
                                                    children: [
                                                      Expanded(child: _buildCalcKey('1')),
                                                      Expanded(child: _buildCalcKey('2')),
                                                      Expanded(child: _buildCalcKey('3')),
                                                    ],
                                                  ),
                                                ),
                                                Expanded(
                                                  child: Row(
                                                    children: [
                                                      Expanded(child: _buildCalcKey('0')),
                                                      Expanded(child: _buildCalcKey('.', label: '.')),
                                                      Expanded(
                                                        child: _buildCalcKey(
                                                          'backspace',
                                                          label: 'Del',
                                                          type: _KeyType.del,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          // 1 Kolom Kanan: + dan Enter
                                          Expanded(
                                            flex: 1,
                                            child: Column(
                                              children: [
                                                Expanded(
                                                  flex: 1,
                                                  child: _buildCalcKey('+', label: '+', type: _KeyType.operator),
                                                ),
                                                Expanded(
                                                  flex: 1,
                                                  child: _buildCalcKey('enter', label: 'Enter', type: _KeyType.enter),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNumpadAdjustPanel() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.borderDark, width: 1.8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.open_with, size: 16, color: AppColors.textDark),
              const SizedBox(width: 6),
              const Text(
                'Atur Posisi & Ukuran',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: AppColors.textDark,
                ),
              ),
              const Spacer(),
              // Reset Mepet Bawah
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _numpadBottomOffset = 0.0;
                    _numpadScale = 1.0;
                    _numpadHorizontalAlign = 0.0;
                  });
                  HapticFeedback.selectionClick();
                },
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.vertical_align_bottom, size: 15),
                label: const Text('Mepet Bawah', style: TextStyle(fontSize: 11)),
              ),
              const SizedBox(width: 4),
              // Tombol Selesai
              FilledButton(
                onPressed: () {
                  setState(() => _isAdjustingNumpad = false);
                  HapticFeedback.selectionClick();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.keyEnter,
                  foregroundColor: AppColors.textDark,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Selesai ✓', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Slider Posisi Vertikal
          Row(
            children: [
              const SizedBox(
                width: 76,
                child: Text('Tinggi:', style: TextStyle(fontSize: 11, color: Color(0xFF4B5563))),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: AppColors.keyEnter,
                    thumbColor: AppColors.borderDark,
                  ),
                  child: Slider(
                    value: _numpadBottomOffset,
                    min: 0.0,
                    max: 180.0,
                    onChanged: (val) {
                      setState(() => _numpadBottomOffset = val);
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '${_numpadBottomOffset.round()}px',
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          // Slider Ukuran / Skala
          Row(
            children: [
              const SizedBox(
                width: 76,
                child: Text('Ukuran:', style: TextStyle(fontSize: 11, color: Color(0xFF4B5563))),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: AppColors.keyOperator,
                    thumbColor: AppColors.borderDark,
                  ),
                  child: Slider(
                    value: _numpadScale,
                    min: 0.75,
                    max: 1.15,
                    onChanged: (val) {
                      setState(() => _numpadScale = val);
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '${(_numpadScale * 100).round()}%',
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          // Pilihan Posisi Satu Tangan (Kiri / Tengah / Kanan)
          Row(
            children: [
              const SizedBox(
                width: 76,
                child: Text('Satu Tangan:', style: TextStyle(fontSize: 11, color: Color(0xFF4B5563))),
              ),
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: _buildAlignBtn('Kiri', -1.0)),
                    const SizedBox(width: 6),
                    Expanded(child: _buildAlignBtn('Tengah', 0.0)),
                    const SizedBox(width: 6),
                    Expanded(child: _buildAlignBtn('Kanan', 1.0)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAlignBtn(String label, double alignVal) {
    final bool isSelected = _numpadHorizontalAlign == alignVal;
    return InkWell(
      onTap: () {
        setState(() => _numpadHorizontalAlign = alignVal);
        HapticFeedback.selectionClick();
      },
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.keyOperator : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? AppColors.borderDark : const Color(0xFFCBD5E1),
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: AppColors.textDark,
          ),
        ),
      ),
    );
  }

  Widget _buildNavArrowCluster() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.black.withOpacity(0.15),
          width: 1.2,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildNavArrowBtn(Icons.arrow_drop_up, 'up'),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildNavArrowBtn(Icons.arrow_left, 'left'),
              const SizedBox(width: 6),
              _buildNavArrowBtn(Icons.arrow_drop_down, 'down'),
              const SizedBox(width: 6),
              _buildNavArrowBtn(Icons.arrow_right, 'right'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavArrowBtn(IconData icon, String key) {
    return SizedBox(
      width: 70,
      height: 40,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.keyOperator,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: AppColors.borderDark,
            width: 1.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 3,
              offset: const Offset(0, 1.5),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _sendKey(key),
            onTapDown: (_) => _startArrowRepeating(key),
            onTapUp: (_) => _stopArrowRepeating(),
            onTapCancel: () => _stopArrowRepeating(),
            child: Center(
              child: Icon(
                icon,
                size: 28,
                color: AppColors.textDark,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCalcKey(
    String key, {
    String? label,
    IconData? icon,
    _KeyType type = _KeyType.number,
  }) {
    Color bgColor;
    double fontSize = 24;

    switch (type) {
      case _KeyType.number:
        bgColor = AppColors.keyNumber;
        fontSize = 24;
        break;
      case _KeyType.operator:
        bgColor = AppColors.keyOperator;
        fontSize = 24;
        break;
      case _KeyType.del:
        bgColor = AppColors.keyDel;
        fontSize = 20;
        break;
      case _KeyType.enter:
        bgColor = AppColors.keyEnter;
        fontSize = 20;
        break;
      case _KeyType.function:
        bgColor = AppColors.keyOperator;
        fontSize = 14;
        break;
    }

    final isDel = key == 'backspace' || key == 'del' || type == _KeyType.del;

    return Padding(
      padding: const EdgeInsets.all(3.0),
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: AppColors.borderDark,
            width: 1.8,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              if (!isDel) {
                _sendKey(key);
              }
            },
            onTapDown: isDel ? (_) => _startDeleteRepeating() : null,
            onTapUp: isDel ? (_) => _stopDeleteRepeating() : null,
            onTapCancel: isDel ? () => _stopDeleteRepeating() : null,
            splashColor: Colors.black.withOpacity(0.12),
            highlightColor: Colors.black.withOpacity(0.06),
            child: Center(
              child: icon != null
                  ? Icon(icon, size: 22, color: AppColors.textDark)
                  : Text(
                      label ?? key,
                      style: TextStyle(
                        fontSize: fontSize,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- TAB 2: NAVIGATION & SCROLL ----------
  Widget _buildNavTab() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          // Row 1: Presentation & General Hotkeys
          Row(
            children: [
              Expanded(child: _buildNavActionBtn('F5', () => _sendKey('f5'))),
              const SizedBox(width: 6),
              Expanded(child: _buildNavActionBtn('Shift+F5', () => _sendHotkey(['shift', 'f5']))),
              const SizedBox(width: 6),
              Expanded(child: _buildNavActionBtn('ESC', () => _sendKey('esc'))),
              const SizedBox(width: 6),
              Expanded(child: _buildNavActionBtn('Space', () => _sendKey('space'))),
            ],
          ),
          const SizedBox(height: 10),
          // Row 2: Center Interactive Area (D-Pad & Scroll Zone)
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // D-Pad Left
                Expanded(
                  flex: 5,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.housingBg,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.borderDark, width: 2.0),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'NAVIGASI / D-PAD',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.0,
                          ),
                        ),
                        const Spacer(),
                        _buildDpadBtn(Icons.arrow_drop_up, 'up'),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildDpadBtn(Icons.arrow_left, 'left'),
                            const SizedBox(width: 6),
                            _buildDpadCenterOk(),
                            const SizedBox(width: 6),
                            _buildDpadBtn(Icons.arrow_right, 'right'),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildDpadActionBtn(
                              icon: Icons.backspace_outlined,
                              label: 'Bksp',
                              onTap: () => _sendKey('backspace'),
                              onTapDown: (_) => _startDeleteRepeating(),
                              onTapUp: (_) => _stopDeleteRepeating(),
                              onTapCancel: () => _stopDeleteRepeating(),
                              bgColor: AppColors.keyDel.withOpacity(0.22),
                              borderColor: AppColors.keyDel,
                            ),
                            const SizedBox(width: 6),
                            _buildDpadBtn(Icons.arrow_drop_down, 'down'),
                            const SizedBox(width: 6),
                            _buildDpadActionBtn(
                              icon: Icons.delete_outline,
                              label: 'Del',
                              onTap: () => _sendKey('del'),
                              bgColor: AppColors.keyOperator,
                            ),
                          ],
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Scroll Zone Right
                Expanded(
                  flex: 4,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.housingBg,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.borderDark, width: 2.0),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    child: Column(
                      children: [
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.swap_vert, size: 14, color: Colors.white),
                            SizedBox(width: 4),
                            Text(
                              'SCROLL PC',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _buildScrollButton(
                          icon: Icons.keyboard_double_arrow_up,
                          label: 'SCROLL UP',
                          dy: 120,
                        ),
                        const SizedBox(height: 8),
                        Expanded(child: _buildScrollTouchpad()),
                        const SizedBox(height: 8),
                        _buildScrollButton(
                          icon: Icons.keyboard_double_arrow_down,
                          label: 'SCROLL DOWN',
                          dy: -120,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Row 3: Page & Document Navigation
          Row(
            children: [
              Expanded(child: _buildNavActionBtn('Page Up', () => _sendKey('pageup'))),
              const SizedBox(width: 6),
              Expanded(child: _buildNavActionBtn('Page Down', () => _sendKey('pagedown'))),
              const SizedBox(width: 6),
              Expanded(child: _buildNavActionBtn('Home', () => _sendKey('home'))),
              const SizedBox(width: 6),
              Expanded(child: _buildNavActionBtn('End', () => _sendKey('end'))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDpadBtn(IconData icon, String key) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.keyNumber,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderDark, width: 1.6),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _sendKey(key),
          onTapDown: (_) => _startArrowRepeating(key),
          onTapUp: (_) => _stopArrowRepeating(),
          onTapCancel: () => _stopArrowRepeating(),
          splashColor: Colors.black12,
          child: SizedBox(
            width: 52,
            height: 52,
            child: Icon(icon, size: 32, color: AppColors.textDark),
          ),
        ),
      ),
    );
  }

  Widget _buildDpadActionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    GestureTapDownCallback? onTapDown,
    GestureTapUpCallback? onTapUp,
    GestureTapCancelCallback? onTapCancel,
    Color? bgColor,
    Color? borderColor,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: bgColor ?? AppColors.keyNumber,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor ?? AppColors.borderDark, width: 1.6),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.lightImpact();
            onTap();
          },
          onTapDown: onTapDown,
          onTapUp: onTapUp,
          onTapCancel: onTapCancel,
          splashColor: Colors.black12,
          child: SizedBox(
            width: 52,
            height: 52,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 21, color: AppColors.textDark),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textDark,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDpadCenterOk() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.keyEnter,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderDark, width: 1.8),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _sendKey('enter'),
          splashColor: Colors.black12,
          child: const SizedBox(
            width: 52,
            height: 52,
            child: Center(
              child: Text(
                'OK',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: AppColors.textDark,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScrollButton({
    required IconData icon,
    required String label,
    required int dy,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.keyOperator,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderDark, width: 1.6),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {},
          onTapDown: (_) => _startScrollRepeating(dy),
          onTapUp: (_) => _stopScrollRepeating(),
          onTapCancel: () => _stopScrollRepeating(),
          splashColor: Colors.black12,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: AppColors.textDark),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.textDark,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScrollTouchpad() {
    return GestureDetector(
      onVerticalDragStart: (_) {
        _scrollDragAccumulator = 0;
      },
      onVerticalDragUpdate: (details) {
        _scrollDragAccumulator += details.primaryDelta ?? 0;
        const double threshold = 12.0;
        if (_scrollDragAccumulator.abs() >= threshold) {
          final int steps = (_scrollDragAccumulator / threshold).truncate();
          _scrollDragAccumulator -= steps * threshold;
          _sendScroll(steps * 120);
        }
      },
      onVerticalDragEnd: (_) {
        _scrollDragAccumulator = 0;
      },
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppColors.keyNumber,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.borderDark, width: 1.6),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.unfold_more, color: AppColors.textDark.withOpacity(0.7), size: 28),
            const SizedBox(height: 4),
            Text(
              'Geser\nScroll',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textDark.withOpacity(0.8),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavActionBtn(String label, VoidCallback onPressed) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.keyNumber,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderDark, width: 1.6),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.lightImpact();
            onPressed();
          },
          splashColor: Colors.black12,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- TAB 3: MEDIA (Opsi 3 - Card Minimalis One-Hand Friendly) ----------
  Widget _buildMediaTab() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Header (Judul Media + Edit Icon placeholder)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Media',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textDark,
                        letterSpacing: -0.5,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 20, color: AppColors.textSecondary),
                      onPressed: () {},
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // 2. Container Card Utama Berorientasi Bawah (Fixed Height inside Expanded)
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: AppColors.cardBorder, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 18,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      // Spacer Fleksibel di paling atas (menyusut saat Advanced Panel membesar ke atas)
                      const Spacer(),

                      // Media Info Card
                      _buildMediaInfoCard(),
                      const SizedBox(height: 12),

                      // Volume Bar Horizontal
                      _buildVolumeBar(),
                      const SizedBox(height: 14),

                      // Main Controls (Prev / Play-Pause / Next)
                      _buildMainControlsRow(),
                      const SizedBox(height: 14),

                      // Advanced Panel (Animasi Dorong ke Atas)
                      AnimatedSize(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOutCubic,
                        alignment: Alignment.bottomCenter,
                        child: _isAdvancedExpanded
                            ? Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _buildAdvancedPanel(),
                              )
                            : const SizedBox.shrink(),
                      ),

                      // Tombol Toggle "Kontrol Lanjutan" (Anchor point tetap di posisi paling bawah)
                      _buildAdvancedToggleButton(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMediaInfoCard() {
    final bool isAvailable = _mediaState?['available'] == true;
    final String title = isAvailable ? (_mediaState?['title'] ?? 'Tidak Ada Media') : 'Tidak Ada Media';
    final String artist = isAvailable ? (_mediaState?['artist'] ?? (_mediaState?['album'] ?? 'Putar media di PC')) : 'Putar musik/video di PC untuk mengontrol';
    final String appName = _mediaState?['app_name'] ?? 'PC Audio';
    final String procName = _mediaState?['process_name'] ?? 'Windows';

    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardInner,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.cardBorder, width: 1),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              // Thumbnail Box
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: AppColors.keyOperator,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                clipBehavior: Clip.antiAlias,
                child: _cachedThumbnailBytes != null
                    ? Image.memory(_cachedThumbnailBytes!, fit: BoxFit.cover)
                    : const Center(
                        child: Icon(Icons.music_note, color: AppColors.textSecondary, size: 28),
                      ),
              ),
              const SizedBox(width: 12),
              // Meta Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Source Switcher Pill
                    InkWell(
                      onTap: _showSessionSwitcherBottomSheet,
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              appName,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: AppColors.textDark),
                            ),
                            Text(
                              ' · $procName',
                              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                            ),
                            const SizedBox(width: 4),
                            const Icon(Icons.keyboard_arrow_down, size: 14, color: AppColors.textSecondary),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    // Title
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textDark,
                      ),
                    ),
                    // Artist
                    Text(
                      artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Seek Slider & Time Labels
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: AppColors.accentGreen,
              inactiveTrackColor: const Color(0xFFD5DFE3),
              thumbColor: AppColors.accentGreen,
            ),
            child: Slider(
              value: _localSeekPos.clamp(0.0, _mediaDuration > 0 ? _mediaDuration : 100.0),
              min: 0.0,
              max: _mediaDuration > 0 ? _mediaDuration : 100.0,
              onChanged: (isAvailable && _mediaDuration > 0)
                  ? (val) {
                      setState(() {
                        _isUserDraggingSeek = true;
                        _localSeekPos = val;
                      });
                    }
                  : null,
              onChangeEnd: (isAvailable && _mediaDuration > 0)
                  ? (val) {
                      _isUserDraggingSeek = false;
                      _sendMediaCommand('seek', val);
                    }
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_localSeekPos),
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                ),
                Text(
                  _formatDuration(_mediaDuration),
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVolumeBar() {
    final bool isMuted = _mediaState?['is_muted'] == true;

    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: AppColors.cardInner,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.cardBorder, width: 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          // Mute Button
          IconButton(
            icon: Icon(
              isMuted ? Icons.volume_off : Icons.volume_up,
              color: isMuted ? AppColors.keyDel : AppColors.textDark,
              size: 20,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => _sendMediaCommand('toggle_mute'),
          ),
          const SizedBox(width: 8),
          // Volume Slider
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: AppColors.accentGreen,
                inactiveTrackColor: const Color(0xFFD5DFE3),
                thumbColor: AppColors.accentGreen,
              ),
              child: Slider(
                value: _localVolume.clamp(0.0, 100.0),
                min: 0.0,
                max: 100.0,
                onChanged: (val) {
                  setState(() {
                    _isUserDraggingVolume = true;
                    _localVolume = val;
                  });
                },
                onChangeEnd: (val) {
                  _isUserDraggingVolume = false;
                  _sendMediaCommand('set_volume', val.round());
                },
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Percentage Label
          SizedBox(
            width: 36,
            child: Text(
              '${_localVolume.round()}%',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainControlsRow() {
    final bool isAvailable = _mediaState?['available'] == true;
    final Map<String, dynamic>? ctrl = _mediaState?['controls'] as Map<String, dynamic>?;
    final bool canPrev = isAvailable && (ctrl?['can_previous'] == true);
    final bool canNext = isAvailable && (ctrl?['can_next'] == true);
    final bool isPlaying = _playbackStatus == 'playing';

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Previous Button
        _buildTransportCircleBtn(
          icon: Icons.skip_previous_rounded,
          size: 62,
          iconSize: 28,
          enabled: canPrev,
          onTap: () => _sendMediaCommand('previous'),
        ),
        const SizedBox(width: 20),
        // Play / Pause Button (Large Green Accent)
        Container(
          width: 78,
          height: 78,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [Color(0xFF278C64), Color(0xFF1B6547)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF237C58).withOpacity(0.38),
                blurRadius: 18,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _sendMediaCommand('play_pause'),
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 40,
                color: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(width: 20),
        // Next Button
        _buildTransportCircleBtn(
          icon: Icons.skip_next_rounded,
          size: 62,
          iconSize: 28,
          enabled: canNext,
          onTap: () => _sendMediaCommand('next'),
        ),
      ],
    );
  }

  Widget _buildTransportCircleBtn({
    required IconData icon,
    required double size,
    required double iconSize,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.35,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFFEAF2F4),
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.cardBorder, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: Icon(icon, size: iconSize, color: AppColors.textDark),
          ),
        ),
      ),
    );
  }

  Widget _buildAdvancedPanel() {
    final bool isAvailable = _mediaState?['available'] == true;
    final Map<String, dynamic>? ctrl = _mediaState?['controls'] as Map<String, dynamic>?;
    final bool isShuffle = _mediaState?['shuffle'] == true;
    final String repeat = _mediaState?['repeat'] as String? ?? 'none';
    final bool isRepeatActive = repeat != 'none';

    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardInner,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.cardBorder, width: 1),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          // Shuffle
          _buildAdvActionItem(
            icon: Icons.shuffle_rounded,
            label: 'Shuffle',
            isActive: isShuffle,
            enabled: isAvailable && (ctrl?['can_shuffle'] == true),
            onTap: () => _sendMediaCommand('shuffle', !isShuffle),
          ),
          // Repeat
          _buildAdvActionItem(
            icon: repeat == 'track' ? Icons.repeat_one_rounded : Icons.repeat_rounded,
            label: repeat == 'track' ? '1 Track' : 'Repeat',
            isActive: isRepeatActive,
            enabled: isAvailable && (ctrl?['can_repeat'] == true),
            onTap: () => _sendMediaCommand('repeat'),
          ),
          // Queue (Buka Session Switcher)
          _buildAdvActionItem(
            icon: Icons.queue_music_rounded,
            label: 'Queue',
            isActive: false,
            enabled: true,
            onTap: _showSessionSwitcherBottomSheet,
          ),
          // Speed
          _buildAdvActionItem(
            customWidget: Text(
              '${_speedOptions[_currentSpeedIndex]}x',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.textDark),
            ),
            label: 'Speed',
            isActive: false,
            enabled: isAvailable,
            onTap: () {
              setState(() {
                _currentSpeedIndex = (_currentSpeedIndex + 1) % _speedOptions.length;
              });
              _sendMediaCommand('set_rate', _speedOptions[_currentSpeedIndex]);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAdvActionItem({
    IconData? icon,
    Widget? customWidget,
    required String label,
    required bool isActive,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.35,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive ? AppColors.accentGreen : Colors.white,
                  border: Border.all(color: isActive ? AppColors.accentGreen : AppColors.cardBorder),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.03),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: customWidget ??
                      Icon(
                        icon,
                        size: 20,
                        color: isActive ? Colors.white : AppColors.textDark,
                      ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                label,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdvancedToggleButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          setState(() {
            _isAdvancedExpanded = !_isAdvancedExpanded;
          });
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.cardInner,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.cardBorder, width: 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Kontrol Lanjutan',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
              AnimatedRotation(
                turns: _isAdvancedExpanded ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: const Icon(Icons.keyboard_arrow_down_rounded, size: 22, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSessionSwitcherBottomSheet() {
    HapticFeedback.lightImpact();
    final List<dynamic> sessions = _mediaState?['sessions'] as List<dynamic>? ?? [];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Pilih Pemutar Media',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.textDark),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Aplikasi yang sedang aktif memutar audio/video di PC:',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                if (sessions.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text('Tidak ada sesi media aktif.', style: TextStyle(color: AppColors.textSecondary)),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: sessions.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, idx) {
                        final s = sessions[idx] as Map<String, dynamic>;
                        final bool isCurrent = s['is_current'] == true;
                        return InkWell(
                          onTap: () {
                            _sendMediaCommand('switch_session', s['id']);
                            Navigator.pop(context);
                          },
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isCurrent ? AppColors.accentGreen.withOpacity(0.08) : AppColors.cardInner,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isCurrent ? AppColors.accentGreen : AppColors.cardBorder,
                                width: isCurrent ? 1.5 : 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s['app_name'] ?? 'Media',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.textDark),
                                      ),
                                      Text(
                                        s['process_name'] ?? 'Windows',
                                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                                      ),
                                    ],
                                  ),
                                ),
                                if (isCurrent)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: AppColors.accentGreen,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: const Text(
                                      'Aktif',
                                      style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(double totalSeconds) {
    if (totalSeconds.isNaN || totalSeconds < 0) totalSeconds = 0;
    final int minutes = totalSeconds ~/ 60;
    final int seconds = (totalSeconds % 60).floor();
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  // ---------- TAB 4: SHORTCUTS ----------
  Widget _buildShortcutsTab() {
    final shortcuts = [
      {'label': 'Copy (Ctrl+C)', 'keys': ['ctrl', 'c']},
      {'label': 'Paste (Ctrl+V)', 'keys': ['ctrl', 'v']},
      {'label': 'Undo (Ctrl+Z)', 'keys': ['ctrl', 'z']},
      {'label': 'Redo (Ctrl+Y)', 'keys': ['ctrl', 'y']},
      {'label': 'Save (Ctrl+S)', 'keys': ['ctrl', 's']},
      {'label': 'Select All (Ctrl+A)', 'keys': ['ctrl', 'a']},
      {'label': 'Desktop (Win+D)', 'keys': ['win', 'd']},
      {'label': 'Switch (Alt+Tab)', 'keys': ['alt', 'tab']},
      {'label': 'Screenshot', 'keys': ['win', 'shift', 's']},
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.2,
        ),
        itemCount: shortcuts.length,
        itemBuilder: (context, idx) {
          final s = shortcuts[idx];
          return Container(
            decoration: BoxDecoration(
              color: AppColors.keyNumber,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.borderDark, width: 1.8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(13),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _sendHotkey(s['keys'] as List<String>),
                splashColor: Colors.black12,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      s['label'] as String,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textDark,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------- TAB 2: KEYBOARD HP ----------
  Widget _buildKeyboardTab() {
    final bool isKeyboardOpen = _isSoftKeyboardVisible(context);

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Kartu Input Teks Utama
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.borderDark, width: 2.0),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.08),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: AppColors.keyOperator,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.borderDark, width: 1.5),
                            ),
                            child: const Icon(
                              Icons.keyboard,
                              size: 20,
                              color: AppColors.textDark,
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'KEYBOARD PC',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textDark,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Ketik di HP, periksa, lalu tekan Kirim ke PC',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF6B7280),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isKeyboardOpen)
                            TextButton.icon(
                              onPressed: _closeKeyboard,
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(Icons.keyboard_hide, size: 18, color: Color(0xFF6B7280)),
                              label: const Text('Tutup', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _buildKeyboardInputArea(),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Tombol Buka Keyboard jika tertutup
                if (!isKeyboardOpen) ...[
                  OutlinedButton.icon(
                    onPressed: _openKeyboard,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.textDark,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: const BorderSide(color: AppColors.borderDark, width: 1.6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.keyboard_alt_outlined, size: 20),
                    label: const Text(
                      'Buka Keyboard HP',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                // Quick Keystrokes Box: Tab PC, Paste ke PC, Enter PC
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.housingBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.borderDark, width: 1.8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: _buildQuickKeyBtn(
                          icon: Icons.keyboard_tab,
                          label: 'Tab PC',
                          onTap: () => _sendKey('tab'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _buildQuickKeyBtn(
                          icon: Icons.content_paste_go,
                          label: 'Paste ke PC',
                          onTap: _pasteToPc,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _buildQuickKeyBtn(
                          icon: Icons.keyboard_return,
                          label: 'Enter PC',
                          onTap: () => _sendKey('enter'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeyboardInputArea() {
    final bool hasLastSent =
        _lastSentKeyboardText != null && _lastSentKeyboardText!.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _keyboardTextController,
          focusNode: _keyboardFocusNode,
          onTap: _openKeyboard,
          maxLines: 4,
          minLines: 2,
          textInputAction: TextInputAction.send,
          onSubmitted: (_) => _submitKeyboardText(),
          style: const TextStyle(
            color: AppColors.textDark,
            fontSize: 15,
            height: 1.3,
          ),
          decoration: InputDecoration(
            hintText: 'Ketik pesan, URL, atau perintah teks di sini...',
            hintStyle: TextStyle(
              color: AppColors.textDark.withOpacity(0.4),
              fontSize: 13,
            ),
            filled: true,
            fillColor: const Color(0xFFF7FAFC),
            contentPadding: const EdgeInsets.all(12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.borderDark, width: 1.8),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Action buttons: Kirim ke PC & Hapus
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _submitKeyboardText,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.keyEnter,
                  foregroundColor: AppColors.textDark,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: const BorderSide(color: AppColors.borderDark, width: 1.6),
                  ),
                ),
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text(
                  'Kirim ke PC',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () {
                _keyboardTextController.clear();
                HapticFeedback.selectionClick();
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textDark,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                side: const BorderSide(color: AppColors.borderDark, width: 1.6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                'Hapus',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
          ],
        ),
        if (hasLastSent) ...[
          const SizedBox(height: 10),
          // Tombol Isi Ulang Teks Terakhir (Zero PC side-effect, murni lokal di HP)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFCBD5E1), width: 1.2),
            ),
            child: Row(
              children: [
                const Icon(Icons.history, size: 15, color: Color(0xFF64748B)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Terkirim: "${_lastSentKeyboardText!}"',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF475569),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                InkWell(
                  onTap: _recallLastSentText,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.borderDark, width: 1.2),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.replay_rounded, size: 13, color: AppColors.textDark),
                        SizedBox(width: 4),
                        Text(
                          'Isi Ulang',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textDark,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildQuickKeyBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.keyNumber,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderDark, width: 1.5),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.lightImpact();
            onTap();
          },
          splashColor: Colors.black12,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: AppColors.textDark),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textDark,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- TAB 6: ASISTEN CEKREK AI & OCR ----------
  Widget _buildAiAssistantTab() {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header Info Card
            Container(
              padding: const EdgeInsets.all(14.0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.cardBorder, width: 1.5),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.keyOperator.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.psychology, color: AppColors.accentGreen, size: 26),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Asisten Cekrek AI (OCR + LLM)',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14.5,
                            color: AppColors.textDark,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Foto teks/soal di layar -> AI menjawab di Terminal PC & tersalin di clipboard Windows.',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textSecondary,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // ===== OPSI 1 (UTAMA): MODE KILAT FULL SCREEN =====
            GestureDetector(
              onTap: _openKilatCamera,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFFFBEB), Color(0xFFFEF3C7)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFF59E0B), width: 2.0),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFF59E0B).withOpacity(0.18),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(
                        color: Color(0xFFF59E0B),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.flash_on, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                '⚡ BUKA KAMERA KILAT',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF92400E),
                                  letterSpacing: 0.3,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF92400E),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'KONTINU',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          const Text(
                            'Layar penuh • Tanpa centang/silang • Zoom & Kunci Fokus (AF/AE Lock) • Tetap di dalam kamera',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF78350F),
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios, size: 16, color: Color(0xFFB45309)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ===== OPSI 2: KAMERA BAWAAN SISTEM (SATU PER SATU) =====
            ElevatedButton(
              onPressed: _isAiLoading ? null : () => _takePhotoAndProcess(fromGallery: false),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.keyEnter,
                foregroundColor: AppColors.textDark,
                disabledBackgroundColor: AppColors.keyEnter.withOpacity(0.5),
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: const BorderSide(color: AppColors.borderDark, width: 1.6),
                ),
                elevation: 2,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.camera_alt, size: 22, color: AppColors.textDark),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '📸 Kamera Standar (Satu per Satu)',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        _isAiLoading ? 'Sedang memproses...' : 'Buka kamera HP biasa dengan konfirmasi centang/silang',
                        style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.normal),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // ===== OPSI 3: PILIH DARI GALERI =====
            OutlinedButton.icon(
              onPressed: _isAiLoading ? null : () => _takePhotoAndProcess(fromGallery: true),
              icon: const Icon(Icons.photo_library_outlined, size: 18, color: AppColors.textSecondary),
              label: const Text(
                'Unggah gambar dari Galeri / Screenshot HP',
                style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.cardBorder),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
            const SizedBox(height: 12),

            // Input Instruksi Tambahan (Opsional) — SELALU TAMPIL, TIDAK DI-CLEAR
            TextField(
              controller: _aiPromptController,
              decoration: InputDecoration(
                hintText: 'Instruksi tambahan (opsional, misal: "Pilih jawaban yang benar" atau "Jelaskan ringkas")',
                hintStyle: const TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.cardBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.cardBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppColors.accentGreen, width: 1.5),
                ),
                suffixIcon: _aiPromptController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18, color: AppColors.textSecondary),
                        onPressed: () {
                          _aiPromptController.clear();
                          setState(() {});
                        },
                      )
                    : null,
              ),
              style: const TextStyle(fontSize: 12, color: AppColors.textDark),
              maxLines: 2,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),

            // Status Card / Loading
            if (_isAiLoading)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF93C5FD)),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF2563EB)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _aiStatusMessage,
                        style: const TextStyle(fontSize: 12.5, color: Color(0xFF1E40AF), fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              )
            else if (_aiStatusMessage.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _aiStatusMessage.startsWith('❌') ? const Color(0xFFFEF2F2)
                      : _aiStatusMessage.startsWith('⚡') ? const Color(0xFFFFFBEB)
                      : const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _aiStatusMessage.startsWith('❌') ? const Color(0xFFFCA5A5)
                        : _aiStatusMessage.startsWith('⚡') ? const Color(0xFFFCD34D)
                        : const Color(0xFF86EFAC),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _aiStatusMessage.startsWith('❌') ? Icons.error_outline
                          : _aiStatusMessage.startsWith('⚡') ? Icons.flash_on
                          : Icons.check_circle_outline,
                      size: 20,
                      color: _aiStatusMessage.startsWith('❌') ? const Color(0xFFDC2626)
                          : _aiStatusMessage.startsWith('⚡') ? const Color(0xFFF59E0B)
                          : const Color(0xFF16A34A),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _aiStatusMessage,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _aiStatusMessage.startsWith('❌') ? const Color(0xFF991B1B)
                              : _aiStatusMessage.startsWith('⚡') ? const Color(0xFF92400E)
                              : const Color(0xFF166534),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),

            // Big PC Terminal Notice Card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF334155)),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.desktop_windows, color: Color(0xFF38BDF8), size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Tampilan Utama: Layar Terminal PC',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Jawaban lengkap AI otomatis dicetak pada jendela Terminal Server PC Anda dengan ukuran font besar & jelas.\n'
                    'Clipboard Windows juga sudah otomatis tersinkronisasi (siap di-paste dengan Ctrl+V jika Anda mau).',
                    style: TextStyle(fontSize: 11.5, color: Color(0xFFCBD5E1), height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Teks OCR yang Terdeteksi (jika ada)
            if (_extractedOcrText != null && _extractedOcrText!.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Teks Terbaca dari Layar (OCR):',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppColors.textDark),
                        ),
                        GestureDetector(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            Clipboard.setData(ClipboardData(text: _extractedOcrText!));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Teks OCR disalin!'), duration: Duration(seconds: 1)),
                            );
                          },
                          child: const Icon(Icons.copy, size: 16, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Text(
                        _extractedOcrText!,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFF334155)),
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

            // Ringkasan Jawaban di Layar HP (jika ada)
            if (_aiResponseAnswer != null && _aiResponseAnswer!.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.keyEnter, width: 1.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.smart_toy_outlined, size: 18, color: AppColors.accentGreen),
                            SizedBox(width: 6),
                            Text(
                              'Ringkasan Jawaban di HP:',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5, color: AppColors.textDark),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 18, color: AppColors.accentGreen),
                          tooltip: 'Salin jawaban',
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            Clipboard.setData(ClipboardData(text: _aiResponseAnswer!));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Jawaban disalin ke clipboard HP!'), duration: Duration(seconds: 1)),
                            );
                          },
                        ),
                      ],
                    ),
                    const Divider(height: 12, color: AppColors.cardBorder),
                    Text(
                      _aiResponseAnswer!,
                      style: const TextStyle(fontSize: 12, color: AppColors.textDark, height: 1.4),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
