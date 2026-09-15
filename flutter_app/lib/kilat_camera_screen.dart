import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'socket_service.dart';

class KilatCameraScreen extends StatefulWidget {
  final SocketService socketService;
  final String? prompt;
  final Function(int shotCount, File? lastImage, String lastOcr)? onFinished;

  const KilatCameraScreen({
    Key? key,
    required this.socketService,
    this.prompt,
    this.onFinished,
  }) : super(key: key);

  @override
  State<KilatCameraScreen> createState() => _KilatCameraScreenState();
}

class _KilatCameraScreenState extends State<KilatCameraScreen>
    with SingleTickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _selectedCameraIndex = 0;
  bool _isCameraReady = false;
  String? _initError;

  // Zoom
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 8.0;

  // Flash
  FlashMode _flashMode = FlashMode.auto;

  // Focus & AF/AE Lock
  Offset? _focusPoint;
  bool _isFocusLocked = false;
  Timer? _focusDismissTimer;
  late AnimationController _focusAnimController;
  late Animation<double> _focusScaleAnim;

  // Shutter & Capturing
  bool _isCapturing = false;
  double _shutterFlashOpacity = 0.0;
  int _shotCount = 0;
  File? _lastCapturedFile;
  String _lastOcrText = '';
  String _statusMessage = 'Arahkan ke soal lalu tap shutter ⚡';
  Timer? _statusResetTimer;

  @override
  void initState() {
    super.initState();
    _focusAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _focusScaleAnim = Tween<double>(begin: 1.4, end: 1.0).animate(
      CurvedAnimation(parent: _focusAnimController, curve: Curves.easeOutBack),
    );

    _initCamera();
    _setupAiListener();
  }

  void _setupAiListener() {
    // Tangkap balasan dari server PC untuk update HUD real-time
    widget.socketService.onAiResponse = (data) {
      if (!mounted) return;
      final model = data['model'] ?? 'Gemini';
      if (data['success'] == true) {
        _showStatus('✅ Soal #$_shotCount dijawab ($model) di PC!', isPersistent: false);
      } else {
        _showStatus('❌ Server PC: ${data['error'] ?? 'Gagal memproses'}', isPersistent: false);
      }
    };
  }

  Future<void> _initCamera([int cameraIndex = 0]) async {
    setState(() {
      _isCameraReady = false;
      _initError = null;
    });

    try {
      if (_cameras.isEmpty) {
        _cameras = await availableCameras();
      }

      if (_cameras.isEmpty) {
        setState(() => _initError = 'Tidak ada sensor kamera yang ditemukan di perangkat.');
        return;
      }

      _selectedCameraIndex = cameraIndex.clamp(0, _cameras.length - 1);
      final camera = _cameras[_selectedCameraIndex];

      final controller = CameraController(
        camera,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();

      // Dapatkan range zoom yang didukung lensa
      try {
        _minZoom = await controller.getMinZoomLevel();
        final hwMaxZoom = await controller.getMaxZoomLevel();
        // Batasi zoom maksimal perangkat agar gambar tetap tajam (maks 8x)
        _maxZoom = hwMaxZoom > 8.0 ? 8.0 : (hwMaxZoom < _minZoom ? _minZoom : hwMaxZoom);
      } catch (_) {
        _minZoom = 1.0;
        _maxZoom = 4.0;
      }

      _currentZoom = _minZoom;
      try {
        await controller.setZoomLevel(_currentZoom);
        await controller.setFlashMode(_flashMode);
      } catch (_) {}

      if (mounted) {
        setState(() {
          _controller = controller;
          _isCameraReady = true;
        });
      }
    } catch (e) {
      debugPrint('Error init camera: $e');
      if (mounted) {
        setState(() {
          _initError = 'Gagal mengakses kamera: $e';
          _isCameraReady = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _focusDismissTimer?.cancel();
    _statusResetTimer?.cancel();
    _focusAnimController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  void _showStatus(String msg, {bool isPersistent = false}) {
    setState(() => _statusMessage = msg);
    _statusResetTimer?.cancel();
    if (!isPersistent) {
      _statusResetTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) {
          setState(() {
            _statusMessage = _isFocusLocked
                ? '🔒 Fokus Terkunci — Siap jepret ⚡'
                : 'Arahkan ke soal lalu tap shutter ⚡';
          });
        }
      });
    }
  }

  // ========== FITUR ZOOM ==========
  Future<void> _setZoom(double zoom) async {
    if (_controller == null || !_isCameraReady) return;
    final clamped = zoom.clamp(_minZoom, _maxZoom);
    try {
      await _controller!.setZoomLevel(clamped);
      setState(() => _currentZoom = clamped);
    } catch (e) {
      debugPrint('Set zoom error: $e');
    }
  }

  // ========== FITUR FLASH ==========
  Future<void> _cycleFlash() async {
    if (_controller == null || !_isCameraReady) return;
    HapticFeedback.selectionClick();
    FlashMode nextMode;
    switch (_flashMode) {
      case FlashMode.auto:
        nextMode = FlashMode.always;
        break;
      case FlashMode.always:
        nextMode = FlashMode.torch;
        break;
      case FlashMode.torch:
        nextMode = FlashMode.off;
        break;
      case FlashMode.off:
      default:
        nextMode = FlashMode.auto;
        break;
    }

    try {
      await _controller!.setFlashMode(nextMode);
      setState(() => _flashMode = nextMode);
      final label = nextMode == FlashMode.auto
          ? 'Flash Otomatis'
          : nextMode == FlashMode.always
              ? 'Flash Nyala'
              : nextMode == FlashMode.torch
                  ? 'Lampu Senter (Torch)'
                  : 'Flash Mati';
      _showStatus('⚡ $label');
    } catch (e) {
      debugPrint('Flash error: $e');
    }
  }

  // ========== FITUR SWITCH KAMERA (DEPAN/BELAKANG) ==========
  Future<void> _switchCamera() async {
    if (_cameras.length <= 1) return;
    HapticFeedback.mediumImpact();
    final nextIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _controller?.dispose();
    await _initCamera(nextIndex);
  }

  // ========== TAP-TO-FOCUS & AF/AE LOCK (LONG PRESS) ==========
  void _onTapToFocus(TapUpDetails details, BoxConstraints constraints) async {
    if (_controller == null || !_isCameraReady) return;
    HapticFeedback.selectionClick();

    // Jika sebelumnya AF/AE terkunci, tap biasa akan membuka kunci kembali ke mode auto
    if (_isFocusLocked) {
      try {
        await _controller!.setFocusMode(FocusMode.auto);
        await _controller!.setExposureMode(ExposureMode.auto);
      } catch (_) {}
      setState(() => _isFocusLocked = false);
      _showStatus('🔓 Kunci Fokus dilepas (Auto Focus aktif)');
    }

    final double x = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final double y = (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);

    try {
      await _controller!.setFocusPoint(Offset(x, y));
      await _controller!.setExposurePoint(Offset(x, y));
    } catch (e) {
      debugPrint('Focus error: $e');
    }

    setState(() {
      _focusPoint = details.localPosition;
    });

    _focusAnimController.forward(from: 0.0);
    _focusDismissTimer?.cancel();
    _focusDismissTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted && !_isFocusLocked) {
        setState(() => _focusPoint = null);
      }
    });
  }

  void _onLongPressToLockFocus(LongPressStartDetails details, BoxConstraints constraints) async {
    if (_controller == null || !_isCameraReady) return;
    HapticFeedback.heavyImpact();

    final double x = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final double y = (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);

    try {
      await _controller!.setFocusPoint(Offset(x, y));
      await _controller!.setFocusMode(FocusMode.locked);
      await _controller!.setExposurePoint(Offset(x, y));
      await _controller!.setExposureMode(ExposureMode.locked);
    } catch (e) {
      debugPrint('AF/AE Lock error: $e');
    }

    setState(() {
      _isFocusLocked = true;
      _focusPoint = details.localPosition;
    });

    _focusAnimController.forward(from: 0.0);
    _showStatus('🔒 AF/AE TERKUNCI! Fokus tidak akan berubah.', isPersistent: true);
  }

  // ========== SHUTTER KILAT: JEPET BERUNTUN TANPA KONFIRMASI ==========
  Future<void> _captureInstant() async {
    if (_controller == null || !_isCameraReady || _isCapturing) return;

    HapticFeedback.mediumImpact();

    // Animasi kilat shutter (snap flash) persis kamera native
    setState(() {
      _isCapturing = true;
      _shutterFlashOpacity = 0.85;
      _shotCount++;
    });

    Future.delayed(const Duration(milliseconds: 70), () {
      if (mounted) setState(() => _shutterFlashOpacity = 0.0);
    });

    try {
      final XFile photo = await _controller!.takePicture();
      final capturedFile = File(photo.path);

      setState(() {
        _lastCapturedFile = capturedFile;
      });

      _showStatus('📸 Soal #$_shotCount — Memproses OCR & kirim ke PC...', isPersistent: true);

      // OCR & Pengiriman dijalankan di background tanpa memblokir kamera
      _processOcrAndSend(capturedFile, _shotCount);
    } catch (e) {
      debugPrint('Take picture error: $e');
      _showStatus('❌ Gagal jepret: $e');
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      }
    }
  }

  Future<void> _processOcrAndSend(File photoFile, int shotIndex) async {
    String ocrResult = '';
    try {
      final inputImage = InputImage.fromFilePath(photoFile.path);
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
      await textRecognizer.close();
      ocrResult = recognizedText.text.trim();
    } catch (e) {
      debugPrint('ML Kit OCR error (Kilat Camera): $e');
    }

    if (!mounted) return;

    setState(() {
      _lastOcrText = ocrResult;
    });

    final prompt = (widget.prompt != null && widget.prompt!.trim().isNotEmpty)
        ? widget.prompt!.trim()
        : null;

    if (ocrResult.isNotEmpty) {
      _showStatus('⚡ Soal #$shotIndex — Teks terdeteksi, dikirim ke AI...');
      widget.socketService.sendAiQuery(text: ocrResult, prompt: prompt);
    } else {
      // Fallback: Kirim base64 gambar langsung ke server jika ML Kit HP kosong
      _showStatus('🔄 Soal #$shotIndex — Mengirim gambar ke server PC...');
      try {
        final bytes = await photoFile.readAsBytes();
        final base64Img = base64Encode(bytes);
        widget.socketService.sendAiQuery(imageBase64: base64Img, prompt: prompt);
      } catch (e) {
        _showStatus('❌ Gagal encode gambar: $e');
      }
    }
  }

  void _finishAndExit() {
    widget.onFinished?.call(_shotCount, _lastCapturedFile, _lastOcrText);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_initError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 54, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text(
                _initError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () => _initCamera(_selectedCameraIndex),
                icon: const Icon(Icons.refresh),
                label: const Text('Coba Lagi'),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF59E0B)),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Kembali', style: TextStyle(color: Colors.white70)),
              )
            ],
          ),
        ),
      );
    }

    if (!_isCameraReady || _controller == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFF59E0B), strokeWidth: 3),
            SizedBox(height: 16),
            Text(
              'Menyiapkan kamera resolusi tinggi...',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Sensor camera ratio handling:
        // Pada Flutter camera portrait, raw ratio biasanya > 1.0 (misal 16/9 = 1.77 atau 4/3 = 1.33).
        // Di layar potret HP, rasio yang benar adalah 1.0 / rawRatio (misal 9/16 = 0.56 atau 3/4 = 0.75).
        final rawRatio = _controller!.value.aspectRatio;
        final previewRatio = rawRatio > 1.0 ? (1.0 / rawRatio) : rawRatio;

        return Stack(
          fit: StackFit.expand,
          children: [
            // 1. VIEWFINDER KAMERA (ASPECT RATIO PRESISI — TIDAK GEPENG/PENYOK)
            Center(
              child: AspectRatio(
                aspectRatio: previewRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Gesture Detector: Pinch-to-zoom & Tap to Focus / Long-press AF/AE Lock
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: (details) {
                        _baseZoom = _currentZoom;
                      },
                      onScaleUpdate: (details) {
                        final newZoom = _baseZoom * details.scale;
                        _setZoom(newZoom);
                      },
                      onTapUp: (details) => _onTapToFocus(details, constraints),
                      onLongPressStart: (details) => _onLongPressToLockFocus(details, constraints),
                      child: CameraPreview(_controller!),
                    ),

                    // Ring Indikator Fokus (Muncul saat tap/long press)
                    if (_focusPoint != null)
                      Positioned(
                        left: _focusPoint!.dx - 36,
                        top: _focusPoint!.dy - 36,
                        child: AnimatedBuilder(
                          animation: _focusAnimController,
                          builder: (context, child) {
                            return Transform.scale(
                              scale: _focusScaleAnim.value,
                              child: child,
                            );
                          },
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 72,
                                height: 72,
                                decoration: BoxDecoration(
                                  shape: BoxShape.rectangle,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: _isFocusLocked
                                        ? const Color(0xFFFBBF24)
                                        : const Color(0xFFFDE047),
                                    width: 2.2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.4),
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                                child: _isFocusLocked
                                    ? const Center(
                                        child: Icon(
                                          Icons.lock,
                                          color: Color(0xFFFBBF24),
                                          size: 26,
                                        ),
                                      )
                                    : null,
                              ),
                              if (_isFocusLocked)
                                Container(
                                  margin: const EdgeInsets.only(top: 4),
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFBBF24),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'AF/AE LOCK',
                                    style: TextStyle(
                                      color: Colors.black,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),

                    // Efek Flash Shutter Snap (Layar kilat 70ms saat shutter ditekan)
                    AnimatedOpacity(
                      opacity: _shutterFlashOpacity,
                      duration: const Duration(milliseconds: 70),
                      child: Container(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),

            // 2. TOP BAR OVERLAY
            Positioned(
              top: 12,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  // Tombol Tutup / Selesai (✕)
                  _buildFrostedButton(
                    icon: Icons.close,
                    onTap: _finishAndExit,
                  ),
                  const SizedBox(width: 10),

                  // Badge Mode Kilat & Shot Count
                  Expanded(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.65),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _shotCount > 0
                                ? const Color(0xFFF59E0B)
                                : Colors.white24,
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.flash_on, color: Color(0xFFF59E0B), size: 16),
                            const SizedBox(width: 6),
                            Text(
                              _shotCount == 0
                                  ? 'Mode Kilat'
                                  : '$_shotCount Soal Tersimpan',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Tombol Flash
                  _buildFrostedButton(
                    icon: _flashMode == FlashMode.auto
                        ? Icons.flash_auto
                        : _flashMode == FlashMode.always
                            ? Icons.flash_on
                            : _flashMode == FlashMode.torch
                                ? Icons.highlight
                                : Icons.flash_off,
                    iconColor: _flashMode != FlashMode.off
                        ? const Color(0xFFF59E0B)
                        : Colors.white70,
                    onTap: _cycleFlash,
                  ),

                  // Tombol Switch Kamera (jika ada lebih dari 1 kamera)
                  if (_cameras.length > 1) ...[
                    const SizedBox(width: 8),
                    _buildFrostedButton(
                      icon: Icons.flip_camera_android,
                      onTap: _switchCamera,
                    ),
                  ],
                ],
              ),
            ),

            // 3. FLOATING STATUS BANNER (HUD)
            Positioned(
              top: 72,
              left: 20,
              right: 20,
              child: AnimatedOpacity(
                opacity: _statusMessage.isNotEmpty ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: _isFocusLocked
                          ? const Color(0xFF78350F).withOpacity(0.9)
                          : Colors.black.withOpacity(0.72),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _isFocusLocked
                            ? const Color(0xFFFBBF24)
                            : Colors.white12,
                        width: 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.4),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _isFocusLocked ? const Color(0xFFFEF3C7) : Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // 4. BOTTOM BAR: ZOOM PILLS + SHUTTER + THUMBNAIL
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Quick Zoom Pills (1x, 2x, dll.)
                  _buildZoomControls(),
                  const SizedBox(height: 18),

                  // Control Row: Thumbnail | Shutter | Selesai
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Thumbnail Terakhir (Pojok Kiri)
                        SizedBox(
                          width: 58,
                          height: 58,
                          child: _lastCapturedFile != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Image.file(
                                        _lastCapturedFile!,
                                        fit: BoxFit.cover,
                                      ),
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: const Color(0xFFF59E0B),
                                            width: 1.5,
                                          ),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),

                        // Shutter Button Besar (Tengah)
                        GestureDetector(
                          onTap: _isCapturing ? null : _captureInstant,
                          child: Container(
                            width: 78,
                            height: 78,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 4.5,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(4.5),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 120),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _isCapturing
                                      ? const Color(0xFFF59E0B)
                                      : Colors.white,
                                ),
                                child: _isCapturing
                                    ? const Center(
                                        child: SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.8,
                                            color: Colors.black87,
                                          ),
                                        ),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),

                        // Tombol "Selesai" (Pojok Kanan)
                        SizedBox(
                          width: 58,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: _finishAndExit,
                                icon: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white.withOpacity(0.2),
                                  ),
                                  child: const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                ),
                              ),
                              const Text(
                                'Selesai',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
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
          ],
        );
      },
    );
  }

  Widget _buildFrostedButton({
    required IconData icon,
    required VoidCallback onTap,
    Color iconColor = Colors.white,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 1.0),
        ),
        child: Icon(icon, color: iconColor, size: 22),
      ),
    );
  }

  Widget _buildZoomControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white12, width: 1.0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildZoomChip(1.0, '1x'),
          if (_maxZoom >= 2.0) _buildZoomChip(2.0, '2x'),
          if (_currentZoom != 1.0 && _currentZoom != 2.0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                '${_currentZoom.toStringAsFixed(1)}x',
                style: const TextStyle(
                  color: Color(0xFFFBBF24),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildZoomChip(double zoomLevel, String label) {
    final isSelected = (_currentZoom - zoomLevel).abs() < 0.15;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        _setZoom(zoomLevel);
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF59E0B) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
