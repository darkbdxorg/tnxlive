import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:ffmpeg_kit_flutter_new_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_gpl/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ---------------------------------------------------------------------------
// Foreground task (keeps the process alive with the screen off)
// ---------------------------------------------------------------------------
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(LiveTaskHandler());
}

class LiveTaskHandler extends TaskHandler {
  DateTime? _started;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _started = timestamp;
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _refreshNotification(timestamp);
  }

  // The service runs in two modes, shared with the main isolate through
  // SharedPreferences key 'fg_mode': 'live' (streaming now) and 'schedule'
  // (armed, waiting for the scheduled start time).
  Future<void> _refreshNotification(DateTime timestamp) async {
    var mode = 'live';
    int? liveStartedMs;
    var startLabel = '';
    var stopLabel = '';
    try {
      final p = await SharedPreferences.getInstance();
      mode = p.getString('fg_mode') ?? 'live';
      liveStartedMs = p.getInt('live_started_ms');
      startLabel = p.getString('sched_start_label') ?? '';
      stopLabel = p.getString('sched_stop_label') ?? '';
    } catch (_) {
      // fall through with defaults (live mode)
    }
    if (mode == 'schedule') {
      FlutterForegroundTask.updateService(
        notificationTitle: 'TNxLive — Schedule ON',
        notificationText: 'Live shuru hobe $startLabel • bondho hobe $stopLabel',
      );
      return;
    }
    final start = liveStartedMs != null ? DateTime.fromMillisecondsSinceEpoch(liveStartedMs) : _started;
    if (start == null) return;
    final elapsed = timestamp.difference(start);
    FlutterForegroundTask.updateService(
      notificationTitle: 'TNxLive — LIVE cholche',
      notificationText: 'Duration: ${_fmtDuration(elapsed)} • Screen off thakleo stream cholbe',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}

String _fmtDuration(Duration d) {
  final h = d.inHours.toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const TNxLiveApp());
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------
const _bg = Color(0xFF070709);
const _card = Color(0xFF121216);
const _card2 = Color(0xFF1A1A20);
const _red = Color(0xFFE50914);
const _txtDim = Color(0xFF9A9AA5);

class TNxLiveApp extends StatelessWidget {
  const TNxLiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TNxLive',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(
          surface: _card,
          primary: _red,
          onPrimary: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _bg,
          elevation: 0,
          titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.5),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _card2,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _red, width: 1.4)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          hintStyle: const TextStyle(color: _txtDim, fontSize: 13),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : _txtDim),
          trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _red : _card2),
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Home
// ---------------------------------------------------------------------------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  // Playlist
  List<String> _videos = [];

  // Destinations
  bool _ytOn = true, _fbOn = false, _customOn = false;
  final _ytKey = TextEditingController();
  final _fbKey = TextEditingController();
  final _customUrl = TextEditingController();

  static const ytServer = 'rtmp://a.rtmp.youtube.com/live2/';
  static const fbServer = 'rtmp://live-api-s.facebook.com:443/rtmp/';

  // Settings
  String _quality = '720p';
  String _mode = 'reencode'; // reencode | copy

  // Streaming state
  bool _live = false;
  bool _starting = false;
  DateTime? _startedAt;
  Timer? _ticker;
  int? _sessionId;
  String _statBitrate = '—', _statFps = '—', _statSpeed = '—', _statSize = '—';

  final List<String> _logs = [];
  final _logScroll = ScrollController();
  late final AnimationController _pulse;

  bool _loading = true; // true while _loadPrefs runs (blocks save-back loops)

  // ---- Profiles (feature 7) ----
  List<Map<String, dynamic>> _profiles = [];
  int _activeProfile = 0;

  // ---- Schedule (feature 4) ----
  bool _schedOn = false;
  TimeOfDay _schedStart = const TimeOfDay(hour: 22, minute: 0);
  TimeOfDay _schedStop = const TimeOfDay(hour: 6, minute: 0);
  Timer? _schedTimer;
  bool _schedBusy = false;
  bool _liveBySchedule = false;
  DateTime? _schedSuppressedFor; // window-start the user manually stopped in
  DateTime? _schedFailWindow;
  int _schedFailCount = 0;
  bool _sessionEndedWithError = false;

  // ---- Battery guard (feature 9) ----
  final Battery _battery = Battery();
  final FlutterLocalNotificationsPlugin _notif = FlutterLocalNotificationsPlugin();
  int _batteryThreshold = 15;
  Timer? _batteryTimer;
  bool _batteryFired = false;
  String? _batteryWarn;

  static const _qualityMap = {
    '480p': (w: 854, h: 480, bitrate: '1200k', buf: '2400k'),
    '720p': (w: 1280, h: 720, bitrate: '2500k', buf: '5000k'),
    '1080p': (w: 1920, h: 1080, bitrate: '4500k', buf: '9000k'),
  };

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    _initForegroundTask();
    _initNotifications();
    _loadPrefs();
    for (final c in [_ytKey, _fbKey, _customUrl]) {
      c.addListener(_savePrefs);
    }
    _schedTimer = Timer.periodic(const Duration(seconds: 20), (_) => _scheduleCheck());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _schedTimer?.cancel();
    _batteryTimer?.cancel();
    _pulse.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  // ---------- prefs + profiles ----------
  Map<String, dynamic> _profileFromLegacy(SharedPreferences p) {
    return {
      'name': 'Profile 1',
      'ytOn': p.getBool('yt_on') ?? true,
      'ytKey': p.getString('yt_key') ?? '',
      'fbOn': p.getBool('fb_on') ?? false,
      'fbKey': p.getString('fb_key') ?? '',
      'customOn': p.getBool('custom_on') ?? false,
      'customUrl': p.getString('custom_url') ?? '',
      'quality': p.getString('quality') ?? '720p',
      'mode': p.getString('mode') ?? 'reencode',
    };
  }

  void _applyProfileToFields(Map<String, dynamic> prof) {
    _ytOn = prof['ytOn'] as bool? ?? true;
    _fbOn = prof['fbOn'] as bool? ?? false;
    _customOn = prof['customOn'] as bool? ?? false;
    _ytKey.text = prof['ytKey'] as String? ?? '';
    _fbKey.text = prof['fbKey'] as String? ?? '';
    _customUrl.text = prof['customUrl'] as String? ?? '';
    _quality = prof['quality'] as String? ?? '720p';
    _mode = prof['mode'] as String? ?? 'reencode';
    if (!_qualityMap.containsKey(_quality)) _quality = '720p';
    if (_mode != 'reencode' && _mode != 'copy') _mode = 'reencode';
  }

  Map<String, dynamic> _snapshotProfile(String name) {
    return {
      'name': name,
      'ytOn': _ytOn,
      'ytKey': _ytKey.text,
      'fbOn': _fbOn,
      'fbKey': _fbKey.text,
      'customOn': _customOn,
      'customUrl': _customUrl.text,
      'quality': _quality,
      'mode': _mode,
    };
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();

    // Profiles — migrate v1.0's individual saved keys into "Profile 1".
    var profiles = <Map<String, dynamic>>[];
    final raw = p.getString('profiles');
    if (raw != null && raw.isNotEmpty) {
      try {
        profiles = (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (_) {
        profiles = [];
      }
    }
    if (profiles.isEmpty) {
      profiles = [_profileFromLegacy(p)];
      await p.setString('profiles', jsonEncode(profiles));
      await p.setInt('active_profile', 0);
    }
    var active = p.getInt('active_profile') ?? 0;
    if (active < 0 || active >= profiles.length) active = 0;

    final schedOn = p.getBool('sched_on') ?? false;
    setState(() {
      _profiles = profiles;
      _activeProfile = active;
      _videos = p.getStringList('videos') ?? [];
      _applyProfileToFields(profiles[active]);
      _schedOn = schedOn;
      _schedStart = _todFromMinutes(p.getInt('sched_start_min') ?? 22 * 60);
      _schedStop = _todFromMinutes(p.getInt('sched_stop_min') ?? 6 * 60);
      final th = p.getInt('battery_threshold') ?? 15;
      _batteryThreshold = (th == 10 || th == 20) ? th : 15;
      _loading = false;
    });

    // Restore an armed schedule after an app relaunch.
    if (schedOn) {
      _addLog('Schedule age thekei ON chilo — restore holo');
      await _restoreScheduleService();
      _scheduleCheck();
    }
  }

  Future<void> _savePrefs() async {
    if (_loading) return;
    final p = await SharedPreferences.getInstance();
    await p.setStringList('videos', _videos);
    await p.setBool('yt_on', _ytOn);
    await p.setBool('fb_on', _fbOn);
    await p.setBool('custom_on', _customOn);
    await p.setString('yt_key', _ytKey.text);
    await p.setString('fb_key', _fbKey.text);
    await p.setString('custom_url', _customUrl.text);
    await p.setString('quality', _quality);
    await p.setString('mode', _mode);
    await p.setBool('sched_on', _schedOn);
    await p.setInt('sched_start_min', _schedStart.hour * 60 + _schedStart.minute);
    await p.setInt('sched_stop_min', _schedStop.hour * 60 + _schedStop.minute);
    await p.setInt('battery_threshold', _batteryThreshold);
    // Any field edit auto-saves back into the active profile.
    if (_profiles.isNotEmpty) {
      _profiles[_activeProfile] = _snapshotProfile(_profiles[_activeProfile]['name'] as String? ?? 'Profile ${_activeProfile + 1}');
      await p.setString('profiles', jsonEncode(_profiles));
      await p.setInt('active_profile', _activeProfile);
    }
  }

  TimeOfDay _todFromMinutes(int m) => TimeOfDay(hour: (m ~/ 60) % 24, minute: m % 60);

  String _fmtTod(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
  }

  // ---------- profiles ----------
  Future<void> _switchProfile(int i) async {
    if (_live || _starting || i == _activeProfile || i < 0 || i >= _profiles.length) return;
    setState(() {
      _activeProfile = i;
      _applyProfileToFields(_profiles[i]);
    });
    await _savePrefs();
    _addLog('Profile load holo: ${_profiles[i]['name']}');
  }

  Future<String?> _profileNameDialog(String title, String initial) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(hintText: 'Profile er nam dao'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: _txtDim))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _red),
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _addProfile() async {
    if (_live) return;
    if (_profiles.length >= 5) {
      _snack('Max 5 ta profile rakha jabe');
      return;
    }
    final name = await _profileNameDialog('Notun Profile', 'Profile ${_profiles.length + 1}');
    if (name == null || name.isEmpty) return;
    setState(() {
      _profiles.add(_snapshotProfile(name));
      _activeProfile = _profiles.length - 1;
    });
    await _savePrefs();
    _addLog('Notun profile add holo: $name (ekhon kar settings copy hoyeche — key/settings bodle nao)');
  }

  Future<void> _editActiveProfile() async {
    if (_live || _profiles.isEmpty) return;
    final current = _profiles[_activeProfile]['name'] as String? ?? 'Profile ${_activeProfile + 1}';
    final c = TextEditingController(text: current);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Profile Edit', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(hintText: 'Profile er nam'),
        ),
        actions: [
          if (_profiles.length > 1)
            TextButton(
              onPressed: () => Navigator.pop(ctx, '__delete__'),
              child: const Text('Delete', style: TextStyle(color: _red)),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: _txtDim))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _red),
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (action == null) return;
    if (action == '__delete__') {
      final removed = _profiles[_activeProfile]['name'];
      setState(() {
        _profiles.removeAt(_activeProfile);
        _activeProfile = 0;
        _applyProfileToFields(_profiles[0]);
      });
      await _savePrefs();
      _addLog('Profile delete holo: $removed');
      return;
    }
    if (action.isEmpty) return;
    setState(() {
      _profiles[_activeProfile] = _snapshotProfile(action);
    });
    await _savePrefs();
    _addLog('Profile er nam bodle holo: $action');
  }

  // ---------- notifications (battery guard + schedule alerts) ----------
  Future<void> _initNotifications() async {
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _notif.initialize(const InitializationSettings(android: androidInit));
      const channel = AndroidNotificationChannel(
        'tnxlive_alerts',
        'TNxLive Alerts',
        description: 'Battery komle ar schedule er alert',
        importance: Importance.high,
      );
      await _notif.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);
    } catch (_) {
      // alerts are best-effort; the in-app banner/log still work
    }
  }

  Future<void> _showAlert(int id, String title, String body) async {
    try {
      await _notif.show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'tnxlive_alerts',
            'TNxLive Alerts',
            channelDescription: 'Battery komle ar schedule er alert',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          ),
        ),
      );
    } catch (_) {}
  }

  // ---------- battery guard ----------
  void _startBatteryWatch() {
    _batteryTimer?.cancel();
    _batteryFired = false;
    if (mounted) setState(() => _batteryWarn = null);
    _batteryTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkBattery());
    _checkBattery();
  }

  Future<void> _checkBattery() async {
    if (!_live) return;
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      final charging = state == BatteryState.charging || state == BatteryState.full;
      if (charging) {
        // Re-arm only after charging back above threshold + 5.
        if (_batteryFired && level > _batteryThreshold + 5) {
          _batteryFired = false;
          if (mounted) setState(() => _batteryWarn = null);
          _addLog('Battery guard: charge $level% — guard abar active holo');
        }
        return;
      }
      if (level <= _batteryThreshold && !_batteryFired) {
        _batteryFired = true;
        final msg = 'Battery matro $level% — charger lagao! Na hole battery sesh hole live theme jabe';
        _addLog('⚠ Battery guard: $msg');
        if (mounted) setState(() => _batteryWarn = msg);
        await _showAlert(9001, 'TNxLive — Battery kom!', msg);
      }
    } catch (_) {}
  }

  // ---------- schedule ----------
  bool _inSchedWindow(DateTime now) {
    final cur = now.hour * 60 + now.minute;
    final s = _schedStart.hour * 60 + _schedStart.minute;
    final e = _schedStop.hour * 60 + _schedStop.minute;
    if (s < e) return cur >= s && cur < e;
    return cur >= s || cur < e; // overnight window (e.g. 22:00 → 06:00)
  }

  DateTime _windowStartOccurrence(DateTime now) {
    var d = DateTime(now.year, now.month, now.day, _schedStart.hour, _schedStart.minute);
    if (d.isAfter(now)) d = d.subtract(const Duration(days: 1));
    return d;
  }

  DateTime _nextOccurrence(TimeOfDay t, DateTime from) {
    var d = DateTime(from.year, from.month, from.day, t.hour, t.minute);
    if (!d.isAfter(from)) d = d.add(const Duration(days: 1));
    return d;
  }

  String _whenLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dd = DateTime(d.year, d.month, d.day);
    final day = dd == today ? 'aaj' : (dd == today.add(const Duration(days: 1)) ? 'kal' : '${d.day}/${d.month}');
    return '$day ${_fmtTod(TimeOfDay.fromDateTime(d))}';
  }

  String _schedNextText() {
    final now = DateTime.now();
    return 'Next live shuru: ${_whenLabel(_nextOccurrence(_schedStart, now))} • Next bondho: ${_whenLabel(_nextOccurrence(_schedStop, now))}';
  }

  Future<void> _setFgMode(String mode) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('fg_mode', mode);
    await p.setString('sched_start_label', _fmtTod(_schedStart));
    await p.setString('sched_stop_label', _fmtTod(_schedStop));
  }

  Future<void> _enterScheduleServiceMode() async {
    await _setFgMode('schedule');
    if (!await FlutterForegroundTask.isRunningService) {
      final r = await FlutterForegroundTask.startService(
        serviceId: 888,
        serviceTypes: [ForegroundServiceTypes.mediaPlayback],
        notificationTitle: 'TNxLive — Schedule ON',
        notificationText: 'Live shuru hobe ${_fmtTod(_schedStart)} • bondho hobe ${_fmtTod(_schedStop)}',
        callback: startCallback,
      );
      if (r is ServiceRequestFailure) _addLog('Foreground service warning: ${r.error}');
    } else {
      FlutterForegroundTask.updateService(
        notificationTitle: 'TNxLive — Schedule ON',
        notificationText: 'Live shuru hobe ${_fmtTod(_schedStart)} • bondho hobe ${_fmtTod(_schedStop)}',
      );
    }
  }

  Future<void> _restoreScheduleService() async {
    await _ensurePermissions();
    await _enterScheduleServiceMode();
  }

  Future<void> _armSchedule() async {
    if (_schedStart == _schedStop) {
      _snack('Start ar stop time ek hole hobe na — alada time dao');
      return;
    }
    final err = _validate();
    if (err != null) {
      _snack(err);
      return;
    }
    await _ensurePermissions();
    setState(() {
      _schedOn = true;
      _schedSuppressedFor = null;
      _schedFailCount = 0;
      _schedFailWindow = null;
    });
    await _savePrefs();
    await _enterScheduleServiceMode();
    _addLog('Schedule ON — live shuru ${_fmtTod(_schedStart)}, bondho ${_fmtTod(_schedStop)} (protidin)');
    _scheduleCheck(); // starts immediately if already inside the window
  }

  Future<void> _disarmSchedule() async {
    setState(() {
      _schedOn = false;
      _liveBySchedule = false;
    });
    await _savePrefs();
    _addLog('Schedule OFF kora holo');
    if (!_live && await FlutterForegroundTask.isRunningService) {
      await _setFgMode('live');
      await FlutterForegroundTask.stopService();
    }
  }

  Future<void> _scheduleCheck() async {
    if (!_schedOn || _schedBusy || _starting || !mounted) return;
    final now = DateTime.now();
    final inWin = _inSchedWindow(now);
    if (inWin && !_live) {
      final ws = _windowStartOccurrence(now);
      if (_schedSuppressedFor != null && _schedSuppressedFor!.isAtSameMomentAs(ws)) return;
      if (_schedFailWindow == null || !_schedFailWindow!.isAtSameMomentAs(ws)) {
        _schedFailWindow = ws;
        _schedFailCount = 0;
      }
      if (_schedFailCount >= 3) {
        _addLog('Schedule: ei window e stream 3 bar fail koreche — schedule OFF kore dilam');
        await _showAlert(9002, 'TNxLive — Schedule OFF', 'Stream bar bar fail koray schedule bondho kore dewa hoyeche. Key/net check kore abar ON koro.');
        await _disarmSchedule();
        return;
      }
      _schedBusy = true;
      _liveBySchedule = true;
      _addLog('Schedule time hoyeche — auto live start hocche');
      await _startLive();
      if (!_live) {
        // Validation/start failure — disarm instead of retry-spamming.
        _liveBySchedule = false;
        _addLog('Schedule live start holo na — schedule OFF kore dilam, settings check koro');
        await _disarmSchedule();
      }
      _schedBusy = false;
    } else if (!inWin && _live && _liveBySchedule) {
      _schedBusy = true;
      _addLog('Schedule stop time hoyeche — live bondho hocche');
      _liveBySchedule = false; // scheduled stop — manual-stop suppression must not apply
      await _stopLive();
      _schedBusy = false;
    }
  }

  // ---------- foreground task ----------
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'tnxlive_stream',
        channelName: 'TNxLive Streaming',
        channelDescription: 'Live stream cholakalin notification',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _ensurePermissions() async {
    final np = await FlutterForegroundTask.checkNotificationPermission();
    if (np != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    try {
      await _notif.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    } catch (_) {}
    final ignoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!ignoring) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  // ---------- logging ----------
  void _addLog(String line) {
    final clean = line.trim();
    if (clean.isEmpty) return;
    setState(() {
      _logs.add(clean);
      if (_logs.length > 100) _logs.removeRange(0, _logs.length - 100);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  // ---------- video picker ----------
  Future<void> _pickVideos() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.video, allowMultiple: true);
    if (res == null) return;
    final paths = res.files.map((f) => f.path).whereType<String>().where((p) => p.isNotEmpty).toList();
    if (paths.isEmpty) {
      _snack('Video file select holo na — abar try koro');
      return;
    }
    setState(() => _videos.addAll(paths));
    _savePrefs();
    _addLog('${paths.length} ta video playlist e add holo');
  }

  // ---------- destinations ----------
  List<({String name, String url})> _activeDestinations() {
    final list = <({String name, String url})>[];
    if (_ytOn && _ytKey.text.trim().isNotEmpty) {
      list.add((name: 'YouTube', url: '$ytServer${_ytKey.text.trim()}'));
    }
    if (_fbOn && _fbKey.text.trim().isNotEmpty) {
      list.add((name: 'Facebook', url: '$fbServer${_fbKey.text.trim()}'));
    }
    if (_customOn && _customUrl.text.trim().isNotEmpty) {
      list.add((name: 'Custom/TikTok', url: _customUrl.text.trim()));
    }
    return list;
  }

  int get _destCount => _activeDestinations().length;

  // ---------- streaming ----------
  String? _validate() {
    if (_videos.isEmpty) return 'Age playlist e ontoto 1 ta video add koro';
    if (!_ytOn && !_fbOn && !_customOn) return 'Ontoto 1 ta destination ON koro (YouTube / Facebook / Custom)';
    if (_ytOn && _ytKey.text.trim().isEmpty) return 'YouTube ON ache kintu Stream Key dewa hoy nai';
    if (_fbOn && _fbKey.text.trim().isEmpty) return 'Facebook ON ache kintu Stream Key dewa hoy nai';
    if (_customOn && _customUrl.text.trim().isEmpty) return 'Custom/TikTok ON ache kintu full RTMP URL dewa hoy nai';
    return null;
  }

  Future<String> _buildConcatFile() async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/tnxlive_playlist.txt');
    final buf = StringBuffer();
    for (final v in _videos) {
      buf.writeln("file '${v.replaceAll("'", r"'\''")}'");
    }
    await f.writeAsString(buf.toString());
    return f.path;
  }

  Future<void> _startLive() async {
    final err = _validate();
    if (err != null) {
      _snack(err);
      return;
    }
    setState(() => _starting = true);
    await _ensurePermissions();
    await _savePrefs();

    final dests = _activeDestinations();
    final listPath = await _buildConcatFile();

    // Build FFmpeg arguments
    final args = <String>['-re', '-stream_loop', '-1', '-f', 'concat', '-safe', '0', '-i', listPath];
    if (_mode == 'copy') {
      args.addAll(['-c', 'copy']);
    } else {
      final q = _qualityMap[_quality]!;
      args.addAll([
        '-vf', 'scale=${q.w}:${q.h}:force_original_aspect_ratio=decrease,pad=${q.w}:${q.h}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency',
        '-b:v', q.bitrate, '-maxrate', q.bitrate, '-bufsize', q.buf,
        '-pix_fmt', 'yuv420p', '-g', '60',
        '-c:a', 'aac', '-b:a', '128k', '-ar', '44100',
      ]);
    }
    if (dests.length == 1) {
      args.addAll(['-f', 'flv', dests.first.url]);
    } else {
      final tee = dests.map((d) => '[f=flv:onfail=ignore]${d.url}').join('|');
      args.addAll(['-f', 'tee', tee]);
    }

    _addLog('Stream start hocche → ${dests.map((d) => d.name).join(', ')}');
    _addLog('Mode: ${_mode == 'copy' ? 'Copy (no re-encode)' : 'Re-encode $_quality'} • ${_videos.length} video loop');
    _sessionEndedWithError = false;

    // Foreground service (process keep-alive + notification)
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fg_mode', 'live');
    await prefs.setInt('live_started_ms', DateTime.now().millisecondsSinceEpoch);
    if (!await FlutterForegroundTask.isRunningService) {
      final r = await FlutterForegroundTask.startService(
        serviceId: 888,
        serviceTypes: [ForegroundServiceTypes.mediaPlayback],
        notificationTitle: 'TNxLive — LIVE cholche',
        notificationText: 'Stream cholche • ${dests.map((d) => d.name).join(', ')}',
        callback: startCallback,
      );
      if (r is ServiceRequestFailure) _addLog('Foreground service warning: ${r.error}');
    } else {
      // Service may already be running in schedule mode — switch it to live.
      FlutterForegroundTask.updateService(
        notificationTitle: 'TNxLive — LIVE cholche',
        notificationText: 'Stream cholche • ${dests.map((d) => d.name).join(', ')}',
      );
    }
    await WakelockPlus.enable();

    FFmpegKitConfig.setLogLevel(21); // AV_LOG_INFO-ish; keep logs useful
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        final rc = await session.getReturnCode();
        if (!mounted) return;
        if (ReturnCode.isCancel(rc)) {
          _addLog('Stream bondho kora hoyeche');
        } else if (ReturnCode.isSuccess(rc)) {
          _addLog('Stream shesh hoyeche');
        } else {
          _sessionEndedWithError = true;
          final fail = await session.getFailStackTrace();
          _addLog('Stream error (code: $rc) ${fail ?? ''}');
          _snack('Stream theme geche — log dekho, key/net check koro');
        }
        await _cleanupAfterStop();
      },
      (log) => _addLog(log.getMessage()),
      (stats) {
        if (!mounted) return;
        setState(() {
          final br = stats.getBitrate();
          _statBitrate = br <= 0 ? '—' : (br >= 1000 ? '${(br / 1000).toStringAsFixed(2)} Mbps' : '${br.toStringAsFixed(0)} kbps');
          _statFps = stats.getVideoFps() <= 0 ? '—' : stats.getVideoFps().toStringAsFixed(0);
          _statSpeed = stats.getSpeed() <= 0 ? '—' : '${stats.getSpeed().toStringAsFixed(2)}x';
          final sz = stats.getSize();
          _statSize = sz <= 0 ? '—' : '${(sz / (1024 * 1024)).toStringAsFixed(1)} MB';
        });
      },
    );
    _sessionId = session.getSessionId();

    setState(() {
      _live = true;
      _starting = false;
      _startedAt = DateTime.now();
    });
    if (_liveBySchedule) {
      _schedFailCount = 0; // a successful scheduled start clears past failures
    }
    _startBatteryWatch();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _cleanupAfterStop() async {
    _ticker?.cancel();
    _batteryTimer?.cancel();
    // Count schedule-started streams that died with an error, so the
    // scheduler can give up after 3 failures in the same window.
    if (_liveBySchedule && _sessionEndedWithError) {
      _schedFailCount++;
    }
    _liveBySchedule = false;
    await WakelockPlus.disable();
    if (await FlutterForegroundTask.isRunningService) {
      if (_schedOn) {
        // Stay alive in schedule mode — the next scheduled start needs us.
        await _enterScheduleServiceMode();
      } else {
        await FlutterForegroundTask.stopService();
      }
    }
    if (mounted) {
      setState(() {
        _live = false;
        _starting = false;
        _startedAt = null;
        _batteryWarn = null;
        _statBitrate = '—'; _statFps = '—'; _statSpeed = '—'; _statSize = '—';
      });
    }
  }

  Future<void> _stopLive() async {
    // If the user manually stops a schedule-started stream, don't let the
    // scheduler restart it in the same window.
    if (_liveBySchedule) {
      _schedSuppressedFor = _windowStartOccurrence(DateTime.now());
      _addLog('Schedule-er live manually bondho kora holo — ei window e ar auto start hobe na');
    }
    _addLog('Stream bondho kora hocche…');
    final id = _sessionId;
    if (id != null) {
      await FFmpegKit.cancel(id);
    } else {
      await FFmpegKit.cancel();
    }
    // complete callback also cleans up; do it here too in case it lags
    await _cleanupAfterStop();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: _red, behavior: SnackBarBehavior.floating),
    );
  }

  // ---------- UI ----------
  Widget _cardBox({required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: padding,
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white.withValues(alpha: 0.06))),
      child: child,
    );
  }

  Widget _sectionTitle(String t, IconData icon) {
    return Row(children: [
      Icon(icon, size: 18, color: _red),
      const SizedBox(width: 8),
      Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    ]);
  }

  Widget _destRow({
    required String title,
    required String serverHint,
    required bool on,
    required ValueChanged<bool> onChanged,
    required TextEditingController controller,
    required String hint,
    required String helper,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            Text(serverHint, style: const TextStyle(color: _txtDim, fontSize: 11)),
          ])),
          Switch(value: on, onChanged: _live ? null : onChanged),
        ]),
        if (on) ...[
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            enabled: !_live,
            obscureText: false,
            autocorrect: false,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(hintText: hint),
          ),
          const SizedBox(height: 6),
          Text(helper, style: const TextStyle(color: _txtDim, fontSize: 11.5, height: 1.35)),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10, decoration: const BoxDecoration(color: _red, shape: BoxShape.circle)),
          const SizedBox(width: 9),
          const Text('TNxLive'),
        ]),
        actions: [
          IconButton(
            tooltip: 'Guide',
            icon: const Icon(Icons.menu_book_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GuidePage())),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          // ---- Status card ----
          _cardBox(
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (_, __) => Container(
                    width: 14, height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _live ? _red.withValues(alpha: 0.45 + 0.55 * _pulse.value) : const Color(0xFF3A3A42),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(_live ? 'LIVE' : 'OFFLINE',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2, color: _live ? _red : _txtDim)),
              ]),
              const SizedBox(height: 6),
              Text(_live ? _fmtDuration(elapsed) : '00:00:00',
                  style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
              Text(_live ? '$_destCount destination e stream jacche' : 'Start korte niche sob set kore LIVE chap dao',
                  style: const TextStyle(color: _txtDim, fontSize: 12.5)),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                _stat('Bitrate', _statBitrate),
                _stat('FPS', _statFps),
                _stat('Speed', _statSpeed),
                _stat('Sent', _statSize),
              ]),
            ]),
          ),

          // ---- Battery guard warning banner ----
          if (_batteryWarn != null)
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(color: const Color(0xFF3A0D10), borderRadius: BorderRadius.circular(14), border: Border.all(color: _red.withValues(alpha: 0.55))),
              child: Row(children: [
                const Icon(Icons.battery_alert_rounded, color: _red, size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(_batteryWarn!, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.35))),
              ]),
            ),

          // ---- Playlist ----
          _cardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: _sectionTitle('Playlist (Loop hobe)', Icons.playlist_play_rounded)),
                FilledButton.icon(
                  onPressed: _live ? null : _pickVideos,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Video Add'),
                  style: FilledButton.styleFrom(backgroundColor: _red, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9)),
                ),
              ]),
              const SizedBox(height: 8),
              if (_videos.isEmpty)
                const Text('Kono video nai. Video Add chap diye 1 ba ekadhik video select koro — segulai ek-er por ek loop hoye stream hobe.',
                    style: TextStyle(color: _txtDim, fontSize: 12.5, height: 1.4))
              else
                ..._videos.asMap().entries.map((e) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(radius: 15, backgroundColor: _card2, child: Text('${e.key + 1}', style: const TextStyle(fontSize: 12, color: Colors.white))),
                      title: Text(e.value.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: _txtDim)),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18, color: _txtDim),
                        onPressed: _live ? null : () { setState(() => _videos.removeAt(e.key)); _savePrefs(); },
                      ),
                    )),
            ]),
          ),

          // ---- Profiles ----
          _cardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: _sectionTitle('Profiles', Icons.switch_account_rounded)),
                IconButton(
                  tooltip: 'Profile edit / delete',
                  onPressed: _live ? null : _editActiveProfile,
                  icon: const Icon(Icons.edit_outlined, size: 19, color: _txtDim),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: 'Notun profile',
                  onPressed: _live ? null : _addProfile,
                  icon: const Icon(Icons.add_circle_outline, size: 20, color: _txtDim),
                  visualDensity: VisualDensity.compact,
                ),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (var i = 0; i < _profiles.length; i++)
                  ChoiceChip(
                    label: Text(_profiles[i]['name'] as String? ?? 'Profile ${i + 1}'),
                    selected: i == _activeProfile,
                    onSelected: _live ? null : (_) => _switchProfile(i),
                    selectedColor: _red,
                    backgroundColor: _card2,
                    labelStyle: TextStyle(color: i == _activeProfile ? Colors.white : _txtDim),
                    side: BorderSide.none,
                  ),
              ]),
              const SizedBox(height: 8),
              const Text('Profile select korle oi channel er key + quality/mode load hobe. Niche field edit korlei oi profile e auto-save hoy. Max 5 ta profile.',
                  style: TextStyle(color: _txtDim, fontSize: 11.5, height: 1.35)),
            ]),
          ),

          // ---- Destinations ----
          _cardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _sectionTitle('Destinations', Icons.sensors_rounded),
              _destRow(
                title: 'YouTube',
                serverHint: ytServer,
                on: _ytOn,
                onChanged: (v) { setState(() => _ytOn = v); _savePrefs(); },
                controller: _ytKey,
                hint: 'YouTube Stream Key ekhane bosao',
                helper: 'YouTube Studio → Create → Go Live → Stream theke key paba. Guide screen e details ache.',
              ),
              _destRow(
                title: 'Facebook',
                serverHint: fbServer,
                on: _fbOn,
                onChanged: (v) { setState(() => _fbOn = v); _savePrefs(); },
                controller: _fbKey,
                hint: 'Facebook Stream Key ekhane bosao',
                helper: 'Page er Live dashboard theke "Persistent stream key" nao — tahole protibar notun key lagbe na.',
              ),
              _destRow(
                title: 'TikTok / Custom RTMP',
                serverHint: 'Full URL (server + key eksathe)',
                on: _customOn,
                onChanged: (v) { setState(() => _customOn = v); _savePrefs(); },
                controller: _customUrl,
                hint: 'rtmp://... full combined URL bosao',
                helper: 'TikTok prottek session e notun server URL + key dey eksathe — oi full URL tai ekhane paste koro. 1000+ followers lage.',
              ),
              const SizedBox(height: 12),
              const Row(children: [
                Icon(Icons.lock_outline, size: 14, color: _txtDim),
                SizedBox(width: 6),
                Expanded(child: Text('Stream key sudhu tomar phone ei save thake — kono server e jay na.', style: TextStyle(color: _txtDim, fontSize: 11.5))),
              ]),
            ]),
          ),

          // ---- Settings ----
          _cardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _sectionTitle('Stream Settings', Icons.tune_rounded),
              const SizedBox(height: 12),
              const Text('Quality', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final q in ['480p', '720p', '1080p'])
                  ChoiceChip(
                    label: Text(q),
                    selected: _quality == q,
                    onSelected: _live ? null : (_) { setState(() => _quality = q); _savePrefs(); },
                    selectedColor: _red,
                    backgroundColor: _card2,
                    labelStyle: TextStyle(color: _quality == q ? Colors.white : _txtDim),
                    side: BorderSide.none,
                  ),
              ]),
              const SizedBox(height: 6),
              Text(
                _quality == '480p' ? '~1200 kbps — slow net er jonno bhalo' : _quality == '720p' ? '~2500 kbps — recommended, balance bhalo' : '~4500 kbps — fast net lage, phone gorom hote pare',
                style: const TextStyle(color: _txtDim, fontSize: 11.5),
              ),
              const SizedBox(height: 14),
              const Text('Mode', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                  label: const Text('Re-encode (Recommended)'),
                  selected: _mode == 'reencode',
                  onSelected: _live ? null : (_) { setState(() => _mode = 'reencode'); _savePrefs(); },
                  selectedColor: _red, backgroundColor: _card2,
                  labelStyle: TextStyle(color: _mode == 'reencode' ? Colors.white : _txtDim),
                  side: BorderSide.none,
                ),
                ChoiceChip(
                  label: const Text('Copy / Fast'),
                  selected: _mode == 'copy',
                  onSelected: _live ? null : (_) { setState(() => _mode = 'copy'); _savePrefs(); },
                  selectedColor: _red, backgroundColor: _card2,
                  labelStyle: TextStyle(color: _mode == 'copy' ? Colors.white : _txtDim),
                  side: BorderSide.none,
                ),
              ]),
              const SizedBox(height: 6),
              const Text('Copy mode e re-encode hoy na bole CPU/battery kom lage, kintu video age thekei H.264 + AAC format e thakte hobe, na hole stream cholbe na.',
                  style: TextStyle(color: _txtDim, fontSize: 11.5, height: 1.35)),
            ]),
          ),

          // ---- Schedule ----
          _cardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: _sectionTitle('Schedule — Auto Live', Icons.schedule_rounded)),
                Switch(value: _schedOn, onChanged: _starting ? null : (v) => v ? _armSchedule() : _disarmSchedule()),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: _timeTile('Live shuru', _schedStart, () async {
                  final t = await showTimePicker(context: context, initialTime: _schedStart);
                  if (t == null) return;
                  setState(() => _schedStart = t);
                  await _savePrefs();
                  if (_schedOn) await _enterScheduleServiceMode();
                })),
                const SizedBox(width: 10),
                Expanded(child: _timeTile('Live bondho', _schedStop, () async {
                  final t = await showTimePicker(context: context, initialTime: _schedStop);
                  if (t == null) return;
                  setState(() => _schedStop = t);
                  await _savePrefs();
                  if (_schedOn) await _enterScheduleServiceMode();
                })),
              ]),
              const SizedBox(height: 10),
              if (_schedOn)
                Text('🟢 Schedule ON — ${_schedNextText()}',
                    style: const TextStyle(color: Color(0xFF7BD88A), fontSize: 12, height: 1.4))
              else
                const Text('Schedule ON korle protidin ei time e nije nije live start hobe ar stop time e bondho hobe. Window er vitore thakle sathe sathe start hobe.',
                    style: TextStyle(color: _txtDim, fontSize: 11.5, height: 1.4)),
              const SizedBox(height: 6),
              const Text('Note: Schedule kaj korte hole app ta recent apps theke mara / force-stop kora jabe na — notification ta rekhe dio. Phone restart hole ekbar app khullei schedule abar active hoye jabe.',
                  style: TextStyle(color: _txtDim, fontSize: 11.5, height: 1.4)),
            ]),
          ),

          // ---- Battery Guard ----
          _cardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _sectionTitle('Battery Guard', Icons.battery_alert_rounded),
              const SizedBox(height: 10),
              const Text('Live chalakalin battery kome ei level er niche gele notification + warning asbe — ekbarei asbe, bar bar birokto korbe na. Charge kore level abar upore uthle guard nije nije abar active hobe.',
                  style: TextStyle(color: _txtDim, fontSize: 11.5, height: 1.4)),
              const SizedBox(height: 10),
              const Text('Warning level', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final th in [10, 15, 20])
                  ChoiceChip(
                    label: Text('$th%'),
                    selected: _batteryThreshold == th,
                    onSelected: (_) async {
                      setState(() {
                        _batteryThreshold = th;
                        _batteryFired = false;
                      });
                      await _savePrefs();
                    },
                    selectedColor: _red,
                    backgroundColor: _card2,
                    labelStyle: TextStyle(color: _batteryThreshold == th ? Colors.white : _txtDim),
                    side: BorderSide.none,
                  ),
              ]),
            ]),
          ),

          // ---- Log ----
          _cardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: _sectionTitle('Live Log', Icons.terminal_rounded)),
                TextButton.icon(
                  onPressed: () => setState(_logs.clear),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Clear'),
                  style: TextButton.styleFrom(foregroundColor: _txtDim),
                ),
              ]),
              const SizedBox(height: 8),
              Container(
                height: 170,
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFF050507), borderRadius: BorderRadius.circular(12)),
                child: _logs.isEmpty
                    ? const Text('Stream start korle ekhane FFmpeg log dekhte paba…', style: TextStyle(color: _txtDim, fontSize: 11.5, fontFamily: 'monospace'))
                    : ListView.builder(
                        controller: _logScroll,
                        itemCount: _logs.length,
                        itemBuilder: (_, i) => Text(_logs[i], style: const TextStyle(color: Color(0xFFB7F0C0), fontSize: 10.5, fontFamily: 'monospace', height: 1.35)),
                      ),
              ),
            ]),
          ),
          const Text('Tip: LIVE chalakalin phone charger e lagiye rakho, ar app ta recent apps theke swipe kore fello na.',
              textAlign: TextAlign.center, style: TextStyle(color: _txtDim, fontSize: 11.5)),
          const SizedBox(height: 8),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: SizedBox(
            height: 58,
            child: FilledButton.icon(
              onPressed: _starting ? null : (_live ? _stopLive : _startLive),
              icon: Icon(_live ? Icons.stop_circle_rounded : Icons.sensors_rounded, size: 24),
              label: Text(_starting ? 'START HOCCHE…' : _live ? 'STOP LIVE' : 'START LIVE',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
              style: FilledButton.styleFrom(
                backgroundColor: _live ? const Color(0xFF3A3A42) : _red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _timeTile(String label, TimeOfDay t, VoidCallback onTap) {
    return InkWell(
      onTap: _starting ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: _card2, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: _txtDim, fontSize: 11)),
          const SizedBox(height: 3),
          Row(children: [
            const Icon(Icons.access_time_rounded, size: 16, color: _red),
            const SizedBox(width: 6),
            Text(_fmtTod(t), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ]),
        ]),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(children: [
      Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(color: _txtDim, fontSize: 11)),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Guide
// ---------------------------------------------------------------------------
class GuidePage extends StatelessWidget {
  const GuidePage({super.key});

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
      );

  Widget _p(String t) => Text(t, style: const TextStyle(color: Color(0xFFC9C9D2), fontSize: 13.5, height: 1.55));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Guide — Key kothay paba')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 30),
        children: [
          _p('TNxLive diye tomar phone thekei ek ba ekadhik video loop kore YouTube, Facebook ar Custom RTMP (TikTok soho) te ek sathe live stream korte parba. Stream cholte phone ON, charger e lagano ar internet e thaka lagbe.'),
          _h('▶ YouTube Stream Key'),
          _p('1) Phone/PC browser e YouTube Studio kholo (studio.youtube.com)\n2) Upar theke Create → Go Live chap dao\n3) Left side e "Stream" select koro\n4) Niche "Stream Key" dekhte paba — Copy kore app er YouTube field e bosao\n\nNote: Channel e prothom bar live enable korte 24 ghonta lagte pare. Live age theke enable na thakle key diyeo stream jabe na. Ekbar newa persistent key bar bar use kora jay.'),
          _h('▶ Facebook Stream Key'),
          _p('1) Tomar Facebook Page theke Live / Create Live Video te jao\n2) "Use stream key" option select koro\n3) Settings e giye "Persistent stream key" ON koro — tahole key change hobe na\n4) Key copy kore app er Facebook field e bosao\n\nPersonal profile er key prottek live e change hoy, Page er persistent key tai bhalo.'),
          _h('▶ TikTok'),
          _p('TikTok sobcheye strict:\n• Live korte 1000+ followers + boyosh 18+ lage\n• TikTok kono permanent key dey na — prottek session e LIVE Studio / "Stream to PC" theke notun Server URL + Stream Key paba\n• Oi duita mile je full RTMP URL hoy (server URL + "/" + key) seta app er "TikTok / Custom RTMP" field e paste koro\n• Key purono hole kaj korbe na — live start er thik age notun key nio'),
          _h('⚠ Tips — stream jeno na kate'),
          _p('• LIVE chalakalin sob somoy charger lagiye rakho — encoding e battery khub druto jay\n• Prothom bar Start chaple battery optimization off korar permission chaibe — allow koro, na hole screen off hole system app bondho kore dite pare\n• App recent apps theke swipe kore fello na\n• Net slow hole 480p use koro; 1080p er jonno strong upload lage\n• WiFi hole sobcheye stable hoy'),
          _h('© Copyright Warning'),
          _p('Sudhu nijer banano / nijer rights ache emon video stream koro. Onner movie, gan, ba TV content loop kore stream dile YouTube/Facebook copyright strike dibe, channel o sash hote pare.'),
          _h('👤 Profiles'),
          _p('Alada alada channel er jonno alada profile rakha jay (max 5 ta). Profile e oi channel er YouTube/Facebook/TikTok key + ON/OFF + quality + mode save thake. Upar theke profile select korlei sob load hoye jabe, ar field e kichu bodlale oi profile ei auto-save hobe. Notun profile banate + chap dao, nam bodlate ba delete korte pencil icon chap dao.'),
          _h('⏰ Schedule — Auto Live'),
          _p('Protidin nirdishto time e auto live start/stop:\n1) Age playlist, key ar settings thik kore nao\n2) Schedule card e start ar stop time set koro\n3) Toggle ON koro — bas, protidin oi time e live start hobe\n\nWindow er vitore thaka obosthay ON korle sathe sathe live start hobe. Rat 10 ta → sokal 6 tar moto ulta (overnight) time o cholbe.\n\n⚠ Schedule kaj korte hole app ta force-stop kora jabe na ar notification ta rekhe dite hobe — system app mere dile schedule o theme jabe. Phone restart er por ekbar app khullei schedule abar active hoy.'),
          _h('🔋 Battery Guard'),
          _p('Live chalakalin battery set kora level (10/15/20%) er niche neme gele ekta notification + screen e warning asbe. Charge lagiye level abar threshold er upore uthle guard nije nije abar active hoy — tai ekbar warning dekhle charger lagiye dilei hobe.'),
          _h('Limit — shotti kotha'),
          _p('Eta phone-only system: phone off, battery sesh ba net chole gele LIVE o theme jabe. Phone na thakleo cholbe emon true 24/7 chaile alada server/VPS lage — seta onno setup.'),
        ],
      ),
    );
  }
}
