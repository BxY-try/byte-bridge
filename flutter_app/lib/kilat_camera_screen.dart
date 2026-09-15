import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'socket_service.dart';

/// Pilihan rasio kamera (Aspect Ratio)
enum CameraAspectRatioMode {
  ratio4x3('4:3', 3.0 / 4.0, 'Standar 4:3 (Dokumen/Buku)'),
  ratio16x9('16:9', 9.0 / 16.0, 'Layar Lebar 16:9 (Cinematic)'),
  ratio1x1('1:1', 1.0, 'Persegi 1:1 (Fokus 1 Soal)'),
  full('Full', null, 'Layar Penuh (Full Screen)');

  final String label;
  final double? ratio; // width / height pada orientasi potret
  final String description;

  const CameraAspectRatioMode(this.label, this.ratio, this.description);
}

class KilatCameraScreen extends StatefulWidget {
  final SocketService socketService;
  final String? prompt;
  final Function(int shotCount, File? lastImage, String lastOcr)? onFinished;
  final CameraAspectRatioMode initialRatio;

  const KilatCameraScreen({
    Key? key,
    required this.socketService,
    this.prompt,
    this.onFinished,
    this.initialRatio = CameraAspectRatioMode.ratio4x3,
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

  double get _sensorPortraitRatio {
    if (_controller == null || !_controller!.value.isInitialized) return 3.0 / 4.0;
    final rawRatio = _controller!.value.aspectRatio;
    return rawRatio > 1.0 ? (1.0 / rawRatio) : rawRatio;
  }

  // Rasio Kamera (Aspect Ratio)
  late CameraAspectRatioMode _aspectRatioMode;
  bool _showRatioSelector = false;

  // Zoom
  double _currentZoom = 1.0;
  double _baseZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 8.0;
  late final ValueNotifier<double> _zoomNotifier;
  bool _showZoomBubble = false;
  Timer? _zoomBubbleTimer;
  DateTime _lastZoomApplyTime = DateTime.fromMillisecondsSinceEpoch(0);

  // Flash
  FlashMode _flashMode = FlashMode.auto;

  // Focus & AF/AE Lock
  Offset? _focusPoint;
  double _focusOpacity = 1.0;
  bool _isFocusLocked = false;
  Timer? _focusDismissTimer;
  late AnimationController _focusAnimController;
  late Animation<double> _focusScaleAnim;

  // Pointer tracking untuk Tap vs Long Press vs Pinch
  int _pointers = 0;
  Offset? _pointerDownPos;
  DateTime? _pointerDownTime;
  bool _hasMoved = false;
  bool _isLongPressTriggered = false;
  Timer? _longPressTimer;

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
    _aspectRatioMode = widget.initialRatio;
    _zoomNotifier = ValueNotifier<double>(1.0);

    _focusAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _focusScaleAnim = Tween<double>(begin: 1.35, end: 1.0).animate(
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
      _focusPoint = null;
      _isFocusLocked = false;
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
      _zoomNotifier.value = _minZoom;

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
    _zoomBubbleTimer?.cancel();
    _longPressTimer?.cancel();
    _statusResetTimer?.cancel();
    _focusAnimController.dispose();
    _zoomNotifier.dispose();
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
                ? '🔒 AF/AE TERKUNCI — Ketuk layar untuk membuka kunci'
                : 'Arahkan ke soal lalu tap shutter ⚡';
          });
        }
      });
    }
  }

  // ========== FITUR ZOOM (PINCH & CHIPS) ==========

  Future<void> _setZoom(double zoom) async {
    if (_controller == null || !_isCameraReady) return;
    final clamped = zoom.clamp(_minZoom, _maxZoom);
    _zoomNotifier.value = clamped;
    _currentZoom = clamped;

    try {
      await _controller!.setZoomLevel(clamped);
    } catch (e) {
      debugPrint('Set zoom error: $e');
    }

    if (mounted) {
      setState(() => _showZoomBubble = true);
    }

    _zoomBubbleTimer?.cancel();
    _zoomBubbleTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _showZoomBubble = false);
    });
  }

  void _onPinchZoomUpdate(double scale) {
    if (_controller == null || !_isCameraReady) return;

    final targetZoom = (_baseZoom * scale).clamp(_minZoom, _maxZoom);
    _zoomNotifier.value = targetZoom;

    if (!_showZoomBubble && mounted) {
      setState(() => _showZoomBubble = true);
    }

    // Throttling ~30ms agar channel Camera2 tidak tersendat
    final now = DateTime.now();
    if (now.difference(_lastZoomApplyTime).inMilliseconds >= 32) {
      _lastZoomApplyTime = now;
      _controller!.setZoomLevel(targetZoom).catchError((e) {
        debugPrint('Throttled zoom error: $e');
      });
    }
  }

  void _onPinchZoomEnd() {
    if (_controller == null || !_isCameraReady) return;

    final finalZoom = _zoomNotifier.value;
    _controller!.setZoomLevel(finalZoom).catchError((e) {
      debugPrint('Final zoom error: $e');
    });

    if (mounted) {
      setState(() {
        _currentZoom = finalZoom;
      });
    }

    _zoomBubbleTimer?.cancel();
    _zoomBubbleTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _showZoomBubble = false);
    });
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

  // ========== TAP-TO-FOCUS & AF/AE LOCK ==========

  Future<void> _handleTapToFocus(Offset localPos, double previewWidth, double previewHeight) async {
    if (_controller == null || !_isCameraReady) return;

    // Jika sedang dalam kondisi terkunci, ketuk sekali akan membuka kuncinya
    if (_isFocusLocked) {
      await _unlockAfAe();
      return;
    }

    HapticFeedback.selectionClick();

    // Hitung koordinat sensor dengan memperhitungkan pemotongan BoxFit.cover
    final double sensorPortraitRatio = _sensorPortraitRatio;
    final double targetRatio = previewWidth / previewHeight;
    double nx = localPos.dx / previewWidth;
    double ny = localPos.dy / previewHeight;

    if (targetRatio > sensorPortraitRatio) {
      // Sensor lebih tinggi dibanding jendela preview (crop atas-bawah)
      final double renderedHeight = previewWidth / sensorPortraitRatio;
      final double dyOffset = (renderedHeight - previewHeight) / 2.0;
      ny = (localPos.dy + dyOffset) / renderedHeight;
    } else if (targetRatio < sensorPortraitRatio) {
      // Sensor lebih lebar dibanding jendela preview (crop kiri-kanan)
      final double renderedWidth = previewHeight * sensorPortraitRatio;
      final double dxOffset = (renderedWidth - previewWidth) / 2.0;
      nx = (localPos.dx + dxOffset) / renderedWidth;
    }

    nx = nx.clamp(0.0, 1.0);
    ny = ny.clamp(0.0, 1.0);

    try {
      if (_controller!.value.focusPointSupported) {
        await _controller!.setFocusPoint(Offset(nx, ny));
      }
      if (_controller!.value.exposurePointSupported) {
        await _controller!.setExposurePoint(Offset(nx, ny));
      }
      await _controller!.setFocusMode(FocusMode.auto);
      await _controller!.setExposureMode(ExposureMode.auto);
    } catch (e) {
      debugPrint('Set focus point error: $e');
    }

    setState(() {
      _focusPoint = localPos;
      _focusOpacity = 1.0;
      _isFocusLocked = false;
    });

    _focusAnimController.forward(from: 0.0);

    // Auto-dismiss kotak fokus setelah 2.5 detik dengan transisi halus
    _focusDismissTimer?.cancel();
    _focusDismissTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && !_isFocusLocked) {
        setState(() => _focusOpacity = 0.0);
        Future.delayed(const Duration(milliseconds: 260), () {
          if (mounted && !_isFocusLocked && _focusOpacity == 0.0) {
            setState(() => _focusPoint = null);
          }
        });
      }
    });
  }

  Future<void> _triggerAfAeLock(
    Offset localPos,
    double previewWidth,
    double previewHeight,
  ) async {
    if (_controller == null || !_isCameraReady) return;

    HapticFeedback.heavyImpact();

    // Hitung koordinat sensor dengan memperhitungkan pemotongan BoxFit.cover
    final double sensorPortraitRatio = _sensorPortraitRatio;
    final double targetRatio = previewWidth / previewHeight;
    double nx = localPos.dx / previewWidth;
    double ny = localPos.dy / previewHeight;

    if (targetRatio > sensorPortraitRatio) {
      final double renderedHeight = previewWidth / sensorPortraitRatio;
      final double dyOffset = (renderedHeight - previewHeight) / 2.0;
      ny = (localPos.dy + dyOffset) / renderedHeight;
    } else if (targetRatio < sensorPortraitRatio) {
      final double renderedWidth = previewHeight * sensorPortraitRatio;
      final double dxOffset = (renderedWidth - previewWidth) / 2.0;
      nx = (localPos.dx + dxOffset) / renderedWidth;
    }

    nx = nx.clamp(0.0, 1.0);
    ny = ny.clamp(0.0, 1.0);

    try {
      if (_controller!.value.focusPointSupported) {
        await _controller!.setFocusPoint(Offset(nx, ny));
      }
      if (_controller!.value.exposurePointSupported) {
        await _controller!.setExposurePoint(Offset(nx, ny));
      }
      await _controller!.setFocusMode(FocusMode.locked);
      await _controller!.setExposureMode(ExposureMode.locked);
    } catch (e) {
      debugPrint('AF/AE Lock error: $e');
    }

    _focusDismissTimer?.cancel();

    setState(() {
      _focusPoint = localPos;
      _focusOpacity = 1.0;
      _isFocusLocked = true;
    });

    _focusAnimController.forward(from: 0.0);
    _showStatus('🔒 AF/AE TERKUNCI — Ketuk layar untuk membuka kunci', isPersistent: true);
  }

  Future<void> _unlockAfAe() async {
    if (_controller == null || !_isCameraReady) return;

    HapticFeedback.selectionClick();

    try {
      if (_controller!.value.focusPointSupported) {
        await _controller!.setFocusPoint(null);
      }
      if (_controller!.value.exposurePointSupported) {
        await _controller!.setExposurePoint(null);
      }
      await _controller!.setFocusMode(FocusMode.auto);
      await _controller!.setExposureMode(ExposureMode.auto);
    } catch (e) {
      debugPrint('Reset focus mode error: $e');
    }

    setState(() {
      _isFocusLocked = false;
      _focusOpacity = 0.0;
    });

    Future.delayed(const Duration(milliseconds: 260), () {
      if (mounted && !_isFocusLocked) {
        setState(() => _focusPoint = null);
      }
    });

    _showStatus('🔓 Kunci Fokus dilepas (Auto Focus aktif)');
  }

  // ========== CROPPING GAMBAR SESUAI RASIO TERPILIH ==========
  Future<File> _cropImageToRatio(File originalFile, double targetRatio) async {
    try {
      final bytes = await originalFile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      final double imgW = image.width.toDouble();
      final double imgH = image.height.toDouble();

      double cropW, cropH, cropX, cropY;

      if (imgW < imgH) {
        // Buffer potret native (lebar < tinggi)
        final currentRatio = imgW / imgH;
        if ((currentRatio - targetRatio).abs() < 0.02) {
          image.dispose();
          codec.dispose();
          return originalFile;
        }
        if (currentRatio > targetRatio) {
          cropW = imgH * targetRatio;
          cropH = imgH;
          cropX = (imgW - cropW) / 2.0;
          cropY = 0.0;
        } else {
          cropW = imgW;
          cropH = imgW / targetRatio;
          cropX = 0.0;
          cropY = (imgH - cropH) / 2.0;
        }
      } else {
        // Buffer lanskap dari sensor hardware (lebar >= tinggi)
        // Di layar potret: sumbu vertikal layar = lebar sensor (imgW), sumbu horizontal layar = tinggi sensor (imgH)
        final currentPortraitRatio = imgH / imgW;
        if ((currentPortraitRatio - targetRatio).abs() < 0.02) {
          image.dispose();
          codec.dispose();
          return originalFile;
        }
        if (currentPortraitRatio > targetRatio) {
          cropH = imgW * targetRatio;
          cropW = imgW;
          cropX = 0.0;
          cropY = (imgH - cropH) / 2.0;
        } else {
          cropH = imgH;
          cropW = imgH / targetRatio;
          cropX = (imgW - cropW) / 2.0;
          cropY = 0.0;
        }
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, cropW, cropH));
      final srcRect = Rect.fromLTWH(cropX, cropY, cropW, cropH);
      final dstRect = Rect.fromLTWH(0, 0, cropW, cropH);
      canvas.drawImageRect(image, srcRect, dstRect, Paint());

      final picture = recorder.endRecording();
      final croppedImage = await picture.toImage(cropW.round(), cropH.round());
      final byteData = await croppedImage.toByteData(format: ui.ImageByteFormat.png);

      image.dispose();
      picture.dispose();
      croppedImage.dispose();
      codec.dispose();

      if (byteData == null) return originalFile;

      final croppedPath = originalFile.path.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '_ratio.png');
      final croppedFile = File(croppedPath);
      await croppedFile.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      return croppedFile;
    } catch (e) {
      debugPrint('Error cropping image to ratio: $e');
      return originalFile;
    }
  }

  // ========== SHUTTER KILAT: JEPRET BERUNTUN TANPA KONFIRMASI ==========
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

      // Hitung rasio target saat pemotretan berlangsung
      final double targetRatio = _aspectRatioMode.ratio ??
          (MediaQuery.of(context).size.width / MediaQuery.of(context).size.height);

      setState(() {
        _lastCapturedFile = capturedFile;
      });

      _showStatus('📸 Soal #$_shotCount — Memproses OCR & kirim ke PC...', isPersistent: true);

      // OCR & Pengiriman dijalankan di background tanpa memblokir kamera
      _processOcrAndSend(capturedFile, _shotCount, targetRatio);
    } catch (e) {
      debugPrint('Take picture error: $e');
      _showStatus('❌ Gagal jepret: $e');
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      }
    }
  }

  Future<void> _processOcrAndSend(File photoFile, int shotIndex, double targetRatio) async {
    File effectiveFile = photoFile;

    // Jika pengguna memilih rasio selain Full, crop gambar agar sesuai bingkai yang dilihat pengguna
    if (_aspectRatioMode != CameraAspectRatioMode.full) {
      try {
        effectiveFile = await _cropImageToRatio(photoFile, targetRatio);
        if (mounted) {
          setState(() {
            _lastCapturedFile = effectiveFile;
          });
        }
      } catch (e) {
        debugPrint('Crop failed, fallback to original: $e');
      }
    }

    String ocrResult = '';
    try {
      final inputImage = InputImage.fromFilePath(effectiveFile.path);
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
        final bytes = await effectiveFile.readAsBytes();
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
        final screenWidth = constraints.maxWidth;
        final screenHeight = constraints.maxHeight;
        final screenRatio = screenWidth / screenHeight;

        // Sensor camera ratio handling:
        // Pada Flutter camera portrait, raw ratio biasanya > 1.0 (misal 16/9 = 1.77 atau 4/3 = 1.33).
        // Di layar potret HP, rasio yang benar adalah 1.0 / rawRatio (misal 9/16 = 0.56 atau 3/4 = 0.75).
        final rawRatio = _controller!.value.aspectRatio;
        final sensorPortraitRatio = rawRatio > 1.0 ? (1.0 / rawRatio) : rawRatio;

        // Tentukan rasio target sesuai pilihan pengguna
        final double targetRatio = _aspectRatioMode.ratio ?? screenRatio;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Background hitam penuh
            Container(color: Colors.black),

            // 1. VIEWFINDER KAMERA DENGAN SEPARATED GESTURE HANDLING & BEBAS DISTORSI
            Center(
              child: AspectRatio(
                aspectRatio: targetRatio,
                child: LayoutBuilder(
                  builder: (context, previewConstraints) {
                    final previewWidth = previewConstraints.maxWidth;
                    final previewHeight = previewConstraints.maxHeight;

                    return ClipRect(
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (event) {
                          _pointers++;
                          if (_pointers == 1) {
                            _pointerDownPos = event.localPosition;
                            _pointerDownTime = DateTime.now();
                            _hasMoved = false;
                            _isLongPressTriggered = false;

                            _longPressTimer?.cancel();
                            _longPressTimer = Timer(const Duration(milliseconds: 500), () {
                              if (_pointers == 1 && !_hasMoved && mounted && _pointerDownPos != null) {
                                _isLongPressTriggered = true;
                                _triggerAfAeLock(_pointerDownPos!, previewWidth, previewHeight);
                              }
                            });
                          } else if (_pointers >= 2) {
                            // Gesture 2 jari (pinch): Batalkan long press & sembunyikan kotak fokus sementara jika tidak terkunci
                            _longPressTimer?.cancel();
                            _hasMoved = true;
                            if (!_isFocusLocked) {
                              setState(() => _focusPoint = null);
                            }
                            _baseZoom = _zoomNotifier.value;
                          }
                        },
                        onPointerMove: (event) {
                          if (_pointers == 1 && _pointerDownPos != null) {
                            if ((event.localPosition - _pointerDownPos!).distance > 12.0) {
                              _hasMoved = true;
                              _longPressTimer?.cancel();
                            }
                          }
                        },
                        onPointerUp: (event) {
                          _longPressTimer?.cancel();
                          if (_pointers == 1 && !_hasMoved && !_isLongPressTriggered && _pointerDownTime != null) {
                            final duration = DateTime.now().difference(_pointerDownTime!).inMilliseconds;
                            if (duration < 400) {
                              _handleTapToFocus(event.localPosition, previewWidth, previewHeight);
                            }
                          }
                          _pointers = (_pointers - 1).clamp(0, 10);
                          if (_pointers == 0) {
                            _pointerDownPos = null;
                            _pointerDownTime = null;
                            _isLongPressTriggered = false;
                          }
                        },
                        onPointerCancel: (event) {
                          _pointers = 0;
                          _longPressTimer?.cancel();
                          _pointerDownPos = null;
                          _pointerDownTime = null;
                          _isLongPressTriggered = false;
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: (details) {
                            _baseZoom = _zoomNotifier.value;
                          },
                          onScaleUpdate: (details) {
                            if (details.pointerCount >= 2) {
                              _onPinchZoomUpdate(details.scale);
                            }
                          },
                          onScaleEnd: (details) {
                            _onPinchZoomEnd();
                          },
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // Feed kamera diskalakan proporsional tanpa distorsi (FittedBox cover)
                              FittedBox(
                                fit: BoxFit.cover,
                                child: SizedBox(
                                  width: previewWidth,
                                  height: previewWidth / sensorPortraitRatio,
                                  child: CameraPreview(_controller!),
                                ),
                              ),

                              // Kotak Reticle Indikator Fokus (Tap / AF/AE Lock)
                              _buildFocusIndicator(previewWidth, previewHeight),

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
                    );
                  },
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
                  const SizedBox(width: 8),

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

                  // Tombol Pemilih Rasio Kamera (Aspect Ratio)
                  _buildRatioButton(),
                  const SizedBox(width: 8),

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

            // 2b. MENU FLOATING PEMILIHAN RASIO KAMERA
            if (_showRatioSelector)
              Positioned(
                top: 64,
                left: 16,
                right: 16,
                child: Center(
                  child: _buildRatioSelectorBar(),
                ),
              ),

            // 3. FLOATING STATUS BANNER (HUD)
            Positioned(
              top: _showRatioSelector ? 116 : 72,
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
                          ? const Color(0xFF78350F).withOpacity(0.92)
                          : Colors.black.withOpacity(0.72),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _isFocusLocked
                            ? const Color(0xFFFBBF24)
                            : Colors.white12,
                        width: 1.2,
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
            // 4. BOTTOM BAR: FLOATING ZOOM BUBBLE + ZOOM PILLS + SHUTTER + THUMBNAIL
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Floating Zoom Bubble saat cubit / zoom
                  _buildFloatingZoomBubble(),

                  // Quick Zoom Pills (1x, 2x, dynamic)
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

  // ========== WIDGET KOTAK FOKUS (RETICLE KUNING) ==========
  Widget _buildFocusIndicator(double previewWidth, double previewHeight) {
    if (_focusPoint == null) return const SizedBox.shrink();

    const double boxSize = 74.0;
    final double left = (_focusPoint!.dx - boxSize / 2).clamp(8.0, previewWidth - boxSize - 8.0);
    final double top = (_focusPoint!.dy - boxSize / 2).clamp(8.0, previewHeight - boxSize - 8.0);

    return Positioned(
      left: left,
      top: top,
      child: AnimatedOpacity(
        opacity: _focusOpacity,
        duration: const Duration(milliseconds: 240),
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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Badge AF/AE LOCK permanen saat mode terkunci
              if (_isFocusLocked)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.55),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock, color: Colors.black87, size: 11),
                      SizedBox(width: 4),
                      Text(
                        'AF/AE LOCK',
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ),

              // Kotak Fokus Reticle
              Container(
                width: boxSize,
                height: boxSize,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _isFocusLocked ? const Color(0xFFF59E0B) : const Color(0xFFFFD600),
                    width: _isFocusLocked ? 2.6 : 2.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.45),
                      blurRadius: 6,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (_isFocusLocked)
                      const Icon(
                        Icons.lock_rounded,
                        color: Color(0xFFF59E0B),
                        size: 28,
                      )
                    else ...[
                      // Titik tengah reticle
                      Container(
                        width: 5,
                        height: 5,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFFD600),
                          shape: BoxShape.circle,
                        ),
                      ),
                      // Indikator exposure sun di samping kanan atas
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Icon(
                          Icons.wb_sunny_rounded,
                          color: const Color(0xFFFFD600).withOpacity(0.9),
                          size: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ========== WIDGET FLOATING ZOOM BUBBLE ==========
  Widget _buildFloatingZoomBubble() {
    return ValueListenableBuilder<double>(
      valueListenable: _zoomNotifier,
      builder: (context, zoomValue, child) {
        return AnimatedOpacity(
          opacity: _showZoomBubble ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 180),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.75),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFF59E0B), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 8,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.zoom_in, color: Color(0xFFF59E0B), size: 16),
                const SizedBox(width: 5),
                Text(
                  '${zoomValue.toStringAsFixed(1)}x',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13.5,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
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
    return ValueListenableBuilder<double>(
      valueListenable: _zoomNotifier,
      builder: (context, zoomVal, child) {
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
              _buildZoomChip(1.0, '1x', zoomVal),
              if (_maxZoom >= 2.0) _buildZoomChip(2.0, '2x', zoomVal),
              if ((zoomVal - 1.0).abs() > 0.15 && (zoomVal - 2.0).abs() > 0.15)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${zoomVal.toStringAsFixed(1)}x',
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildZoomChip(double zoomLevel, String label, double currentVal) {
    final isSelected = (currentVal - zoomLevel).abs() < 0.15;
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

  // ========== WIDGET TOMBOL & SELECTOR RASIO KAMERA ==========
  void _setAspectRatio(CameraAspectRatioMode mode) {
    HapticFeedback.selectionClick();
    setState(() {
      _aspectRatioMode = mode;
      _showRatioSelector = false;
      _focusPoint = null;
      _isFocusLocked = false;
    });
    _showStatus('📐 Rasio Kamera: ${mode.description}');
  }

  void _toggleRatioSelector() {
    HapticFeedback.selectionClick();
    setState(() {
      _showRatioSelector = !_showRatioSelector;
    });
  }

  Widget _buildRatioButton() {
    return GestureDetector(
      onTap: _toggleRatioSelector,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: _showRatioSelector
              ? const Color(0xFFF59E0B)
              : Colors.black.withOpacity(0.55),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _showRatioSelector ? const Color(0xFFF59E0B) : Colors.white24,
            width: 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.aspect_ratio_rounded,
              size: 14,
              color: _showRatioSelector ? Colors.black : const Color(0xFFF59E0B),
            ),
            const SizedBox(width: 4),
            Text(
              _aspectRatioMode.label,
              style: TextStyle(
                color: _showRatioSelector ? Colors.black : Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 11.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRatioSelectorBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.88),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFF59E0B), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.6),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: CameraAspectRatioMode.values.map((mode) {
          final isSelected = mode == _aspectRatioMode;
          return GestureDetector(
            onTap: () => _setAspectRatio(mode),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFFF59E0B) : Colors.white.withOpacity(0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                mode.label,
                style: TextStyle(
                  color: isSelected ? Colors.black : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
