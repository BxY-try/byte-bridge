import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'discovery_service.dart';
import 'socket_service.dart';

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

  // Pengaturan posisi & ukuran numpad dinamis (ala Gboard)
  double _numpadBottomOffset = 0.0; // 0 = mepet footer paling bawah
  double _numpadScale = 1.0; // 0.75 s/d 1.15
  double _numpadHorizontalAlign = 0.0; // -1.0 (kiri), 0.0 (tengah), 1.0 (kanan)
  bool _isAdjustingNumpad = false;

  @override
  void initState() {
    super.initState();
    _startDiscovery();
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
        if (mounted) setState(() => _state = ConnState.disconnected);
      },
      onError: (_) {
        if (mounted) setState(() => _state = ConnState.disconnected);
      },
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
    _deleteInitialTimer?.cancel();
    _deleteRepeatTimer?.cancel();
    _arrowInitialTimer?.cancel();
    _arrowRepeatTimer?.cancel();
    _scrollInitialTimer?.cancel();
    _scrollRepeatTimer?.cancel();
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
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: (_currentTabIndex == 1 && MediaQuery.of(context).viewInsets.bottom > 0)
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
                        _keyboardFocusNode.requestFocus();
                      });
                    } else {
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
                        _buildDpadBtn(Icons.arrow_drop_down, 'down'),
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

  // ---------- TAB 3: MEDIA ----------
  Widget _buildMediaTab() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Volume Card
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.borderDark, width: 1.8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    const Text(
                      'VOLUME PC',
                      style: TextStyle(
                        color: Color(0xFF4B5563),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildCircleBtn(Icons.volume_down, 'volumedown'),
                        _buildCircleBtn(Icons.volume_off, 'volumemute'),
                        _buildCircleBtn(Icons.volume_up, 'volumeup'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Music Card
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.borderDark, width: 1.8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    const Text(
                      'KONTROL PEMUTAR MUSIK',
                      style: TextStyle(
                        color: Color(0xFF4B5563),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildCircleBtn(Icons.skip_previous, 'prevtrack'),
                        _buildCircleBtn(Icons.play_arrow, 'playpause', isLarge: true),
                        _buildCircleBtn(Icons.skip_next, 'nexttrack'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCircleBtn(IconData icon, String key, {bool isLarge = false}) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.borderDark, width: isLarge ? 2.2 : 1.8),
      ),
      child: Material(
        color: isLarge ? AppColors.keyEnter : AppColors.keyOperator,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _sendKey(key),
          splashColor: Colors.black12,
          child: SizedBox(
            width: isLarge ? 72 : 56,
            height: isLarge ? 72 : 56,
            child: Icon(
              icon,
              size: isLarge ? 36 : 26,
              color: AppColors.textDark,
            ),
          ),
        ),
      ),
    );
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

  // ---------- TAB 2: KEYBOARD HP (NATIVE BEHAVIOR) ----------
  Widget _buildKeyboardTab() {
    final bool isKeyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;

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
                            child: const Icon(Icons.keyboard, size: 20, color: AppColors.textDark),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'INPUT KEYBOARD PC',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textDark,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Ketik di HP, tekan Kirim / Enter di keyboard',
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
                              onPressed: () {
                                _keyboardFocusNode.unfocus();
                              },
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
                      // Text Field
                      TextField(
                        controller: _keyboardTextController,
                        focusNode: _keyboardFocusNode,
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
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Tombol Buka Keyboard jika tertutup
                if (!isKeyboardOpen) ...[
                  OutlinedButton.icon(
                    onPressed: () {
                      _keyboardFocusNode.requestFocus();
                    },
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
                // Quick Keystrokes Box (Enter, Backspace, Spasi, Paste PC)
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
                          icon: Icons.keyboard_return,
                          label: 'Enter',
                          onTap: () => _sendKey('enter'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _buildQuickKeyBtn(
                          icon: Icons.backspace_outlined,
                          label: 'Backspace',
                          onTap: () => _sendKey('backspace'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _buildQuickKeyBtn(
                          icon: Icons.space_bar,
                          label: 'Spasi',
                          onTap: () => _sendKey('space'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _buildQuickKeyBtn(
                          icon: Icons.content_paste,
                          label: 'Paste PC',
                          onTap: () => _sendHotkey(['ctrl', 'v']),
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
}
