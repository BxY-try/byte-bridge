import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'discovery_service.dart';
import 'socket_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ByteBridgeApp());
}

class ByteBridgeApp extends StatelessWidget {
  const ByteBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ByteBridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        cardColor: const Color(0xFF1C2640),
      ),
      home: const HomeScreen(),
    );
  }
}

enum ConnState { discovering, connecting, connected, disconnected, failed }

enum _KeyType { number, operator, function, delete, accent }

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
        title: const Text('Input IP Server Manual'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '192.168.1.5',
            labelText: 'Alamat IP PC',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.datetime,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Hubungkan'),
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
  Timer? _scrollInitialTimer;
  Timer? _scrollRepeatTimer;
  double _scrollDragAccumulator = 0;

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
    _deleteInitialTimer?.cancel();
    _deleteRepeatTimer?.cancel();
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

  Color get _statusColor {
    switch (_state) {
      case ConnState.connected:
        return Colors.greenAccent;
      case ConnState.failed:
        return Colors.redAccent;
      case ConnState.disconnected:
        return Colors.orangeAccent;
      default:
        return Colors.amberAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ByteBridge',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF131B2E),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _startDiscovery,
            tooltip: 'Cari ulang server',
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: _showManualIpDialog,
            tooltip: 'Input IP manual',
          ),
        ],
      ),
      body: Column(
        children: [
          // Connection Status Bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            color: _statusColor.withOpacity(0.12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.circle, size: 10, color: _statusColor),
                const SizedBox(width: 8),
                Text(
                  _statusText,
                  style: TextStyle(
                    color: _statusColor,
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
                _buildNavTab(),
                _buildMediaTab(),
                _buildShortcutsTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTabIndex,
        onDestinationSelected: (idx) {
          HapticFeedback.selectionClick();
          _stopDeleteRepeating();
          _stopScrollRepeating();
          setState(() => _currentTabIndex = idx);
        },
        backgroundColor: const Color(0xFF131B2E),
        indicatorColor: Colors.indigo.withOpacity(0.4),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dialpad),
            label: 'Numpad',
          ),
          NavigationDestination(
            icon: Icon(Icons.navigation),
            label: 'Navigasi',
          ),
          NavigationDestination(
            icon: Icon(Icons.music_note),
            label: 'Media',
          ),
          NavigationDestination(
            icon: Icon(Icons.bolt),
            label: 'Pintasan',
          ),
        ],
      ),
    );
  }

  // ---------- TAB 1: NUMPAD ----------
  Widget _buildNumpadTab() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Column(
        children: [
          // Top utility row: ESC, TAB, Nav arrows, Backspace
          Expanded(
            flex: 1,
            child: Row(
              children: [
                Expanded(child: _buildCalcKey('esc', label: 'ESC', type: _KeyType.function)),
                Expanded(child: _buildCalcKey('tab', label: 'TAB', type: _KeyType.function)),
                Expanded(child: _buildCalcKey('left', icon: Icons.chevron_left, type: _KeyType.function)),
                Expanded(child: _buildCalcKey('up', icon: Icons.expand_less, type: _KeyType.function)),
                Expanded(child: _buildCalcKey('down', icon: Icons.expand_more, type: _KeyType.function)),
                Expanded(child: _buildCalcKey('right', icon: Icons.chevron_right, type: _KeyType.function)),
                Expanded(child: _buildCalcKey('backspace', icon: Icons.backspace_outlined, type: _KeyType.delete)),
              ],
            ),
          ),
          // Number grid + operators
          Expanded(
            flex: 4,
            child: Row(
              children: [
                // Number grid (3 cols)
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Expanded(
                        child: Row(children: [
                          Expanded(child: _buildCalcKey('7')),
                          Expanded(child: _buildCalcKey('8')),
                          Expanded(child: _buildCalcKey('9')),
                        ]),
                      ),
                      Expanded(
                        child: Row(children: [
                          Expanded(child: _buildCalcKey('4')),
                          Expanded(child: _buildCalcKey('5')),
                          Expanded(child: _buildCalcKey('6')),
                        ]),
                      ),
                      Expanded(
                        child: Row(children: [
                          Expanded(child: _buildCalcKey('1')),
                          Expanded(child: _buildCalcKey('2')),
                          Expanded(child: _buildCalcKey('3')),
                        ]),
                      ),
                      Expanded(
                        child: Row(children: [
                          Expanded(flex: 2, child: _buildCalcKey('0')),
                          Expanded(child: _buildCalcKey('.', label: '.')),
                        ]),
                      ),
                    ],
                  ),
                ),
                // Operator column (right side)
                Expanded(
                  flex: 1,
                  child: Column(
                    children: [
                      Expanded(child: _buildCalcKey('/', label: '\u00F7', type: _KeyType.operator)),
                      Expanded(child: _buildCalcKey('*', label: '\u00D7', type: _KeyType.operator)),
                      Expanded(child: _buildCalcKey('-', label: '\u2212', type: _KeyType.operator)),
                      Expanded(child: _buildCalcKey('+', label: '+', type: _KeyType.operator)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Enter bar at the bottom
          Expanded(
            flex: 1,
            child: _buildCalcKey('enter', label: 'ENTER', type: _KeyType.accent),
          ),
        ],
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
    Color fgColor = Colors.white;
    double fontSize = 24;
    double iconSize = 24;

    switch (type) {
      case _KeyType.number:
        bgColor = const Color(0xFF1E2A45);
        fontSize = 26;
        break;
      case _KeyType.operator:
        bgColor = const Color(0xFF2A1E45);
        fgColor = const Color(0xFFB388FF);
        fontSize = 28;
        break;
      case _KeyType.function:
        bgColor = const Color(0xFF151D30);
        fgColor = const Color(0xFF8899BB);
        fontSize = 14;
        iconSize = 22;
        break;
      case _KeyType.delete:
        bgColor = const Color(0xFF3D1A1A);
        fgColor = const Color(0xFFFF8A80);
        iconSize = 22;
        break;
      case _KeyType.accent:
        bgColor = const Color(0xFF3949AB);
        fontSize = 18;
        break;
    }

    final isBackspace = key == 'backspace' || type == _KeyType.delete;

    return Padding(
      padding: const EdgeInsets.all(2.5),
      child: Material(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (!isBackspace) {
              _sendKey(key);
            }
          },
          onTapDown: isBackspace ? (_) => _startDeleteRepeating() : null,
          onTapUp: isBackspace ? (_) => _stopDeleteRepeating() : null,
          onTapCancel: isBackspace ? () => _stopDeleteRepeating() : null,
          splashColor: isBackspace
              ? Colors.redAccent.withOpacity(0.3)
              : Colors.white.withOpacity(0.15),
          highlightColor: Colors.white.withOpacity(0.08),
          child: Center(
            child: icon != null
                ? Icon(icon, size: iconSize, color: fgColor)
                : Text(
                    label ?? key,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: FontWeight.w600,
                      color: fgColor,
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
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Volume Card
            Card(
              color: const Color(0xFF131B2E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text('VOLUME PC', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 16),
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
            ),
            const SizedBox(height: 24),
            // Music Card
            Card(
              color: const Color(0xFF131B2E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text('KONTROL PEMUTAR MUSIK', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 16),
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCircleBtn(IconData icon, String key, {bool isLarge = false}) {
    return InkWell(
      onTap: () => _sendKey(key),
      borderRadius: BorderRadius.circular(40),
      child: Container(
        width: isLarge ? 72 : 56,
        height: isLarge ? 72 : 56,
        decoration: BoxDecoration(
          color: isLarge ? Colors.indigoAccent : const Color(0xFF1C2640),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: isLarge ? 36 : 26, color: Colors.white),
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
                      color: const Color(0xFF131B2E),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF1E2A45)),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'NAVIGASI / D-PAD',
                          style: TextStyle(
                            color: Colors.grey,
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
                      color: const Color(0xFF131B2E),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF1E2A45)),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    child: Column(
                      children: [
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.swap_vert, size: 14, color: Colors.indigoAccent),
                            SizedBox(width: 4),
                            Text(
                              'SCROLL PC',
                              style: TextStyle(
                                color: Colors.grey,
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
    return Material(
      color: const Color(0xFF1C2640),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _sendKey(key),
        splashColor: Colors.indigoAccent.withOpacity(0.3),
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(icon, size: 32, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildDpadCenterOk() {
    return Material(
      color: Colors.indigoAccent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _sendKey('enter'),
        splashColor: Colors.white.withOpacity(0.3),
        child: const SizedBox(
          width: 52,
          height: 52,
          child: Center(
            child: Text(
              'OK',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Colors.white,
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
    return Material(
      color: const Color(0xFF1C2640),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {},
        onTapDown: (_) => _startScrollRepeating(dy),
        onTapUp: (_) => _stopScrollRepeating(),
        onTapCancel: () => _stopScrollRepeating(),
        splashColor: Colors.indigoAccent.withOpacity(0.3),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: Colors.indigoAccent),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ],
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
          color: const Color(0xFF0F1523),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF1E2A45)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.unfold_more, color: Colors.indigoAccent.withOpacity(0.6), size: 28),
            const SizedBox(height: 4),
            Text(
              'Geser\nScroll',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey.shade400,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavActionBtn(String label, VoidCallback onPressed) {
    return OutlinedButton(
      onPressed: () {
        HapticFeedback.lightImpact();
        onPressed();
      },
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: const Color(0xFF151D30),
        side: const BorderSide(color: Color(0xFF2E3C5D)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
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
          return ElevatedButton(
            onPressed: () => _sendHotkey(s['keys'] as List<String>),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1C2640),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(8),
            ),
            child: Text(
              s['label'] as String,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          );
        },
      ),
    );
  }
}
