import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pedometer/pedometer.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'app_settings.dart';
import 'database_helper.dart';
import 'stats_tab.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.instance.init();
  runApp(const StealthPedometerApp());
}

class StealthPedometerApp extends StatelessWidget {
  const StealthPedometerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StealthStep',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: Colors.greenAccent,
        colorScheme: const ColorScheme.dark(
          primary: Colors.greenAccent,
          secondary: Colors.green,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  static const _accent = Color(0xFF00E676);

  int _currentIndex = 0;
  int _statsRevision = 0;
  int _steps = 0;
  int _initialSteps = -1;
  int _stepsAtSessionStart = 0;
  double _distanceKm = 0.0;
  double _dailyKmGoal = AppSettings.defaultKmGoal;
  bool _isTracking = false;
  bool _goalCelebrated = false;
  String _activeDate = '';
  final List<LatLng> _routePoints = [];
  final MapController _mapController = MapController();

  StreamSubscription<StepCount>? _stepSubscription;
  StreamSubscription<Position>? _positionSubscription;
  Timer? _timer;
  
  int _secondsElapsed = 0;
  double _currentSpeedKmh = 0.0;
  int _lastKmNotified = 0;

  DateTime? _lastUiUpdate;
  DateTime? _lastDbWrite;

  String _todayKey() => DateTime.now().toIso8601String().split('T')[0];

  String get _formattedDuration {
    final h = _secondsElapsed ~/ 3600;
    final m = (_secondsElapsed % 3600) ~/ 60;
    final s = _secondsElapsed % 60;
    if (h > 0) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dailyKmGoal = AppSettings.instance.kmGoal;
    _activeDate = _todayKey();
    _goalCelebrated = AppSettings.instance.goalCelebratedDate == _activeDate;
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await [Permission.activityRecognition, Permission.location].request();
    await _loadTodayFromDb();
  }

  Future<void> _loadTodayFromDb() async {
    final all = await DatabaseHelper.instance.getAllDailyData();
    final today = _todayKey();
    Map<String, dynamic>? row;
    for (final r in all) {
      if (r['date'] == today) {
        row = r;
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _activeDate = today;
      _steps = (row?['steps'] as int?) ?? 0;
      _distanceKm = _steps * 0.762 / 1000;
      _lastKmNotified = _distanceKm.floor();
    });
  }

  Future<void> _rollToNewDayIfNeeded() async {
    final today = _todayKey();
    if (_activeDate.isEmpty) {
      _activeDate = today;
      return;
    }
    if (today == _activeDate) return;

    if (_steps > 0) {
      await DatabaseHelper.instance.saveDailyData(
        _activeDate,
        _steps,
        _distanceKm,
        _steps * 0.04,
        0,
      );
    }

    _activeDate = today;
    _steps = 0;
    _distanceKm = 0;
    _stepsAtSessionStart = 0;
    _initialSteps = -1;
    _goalCelebrated = false;
    _routePoints.clear();
    _secondsElapsed = 0;
    _currentSpeedKmh = 0.0;
    _lastKmNotified = 0;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _rollToNewDayIfNeeded();
    }
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive ||
            state == AppLifecycleState.detached) &&
        _steps >= 0) {
      _saveToDb();
    }
  }

  Future<void> _startTracking() async {
    if (_isTracking) return;
    await _rollToNewDayIfNeeded();

    final statuses = await [Permission.activityRecognition, Permission.location].request();
    if (statuses[Permission.activityRecognition]?.isDenied == true) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Serve il permesso attività fisica')),
      );
      return;
    }

    setState(() => _isTracking = true);
    _initialSteps = -1;
    _stepsAtSessionStart = _steps;
    
    // Azzera i dati volatili della sessione precedente
    setState(() {
      _routePoints.clear();
      _secondsElapsed = 0;
      _currentSpeedKmh = 0.0;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() => _secondsElapsed++);
    });

    _stepSubscription = Pedometer.stepCountStream.listen((StepCount event) {
      if (!mounted || !_isTracking) return;
      _onStepEvent(event);
    }, onError: (e) {
      debugPrint('Pedometer error: $e');
    });

    const locationSettings = LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 3);
    _positionSubscription = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) {
      if (!mounted || !_isTracking) return;
      if (position.accuracy > 25.0) return;
      
      final point = LatLng(position.latitude, position.longitude);
      
      setState(() {
        _routePoints.add(point);
        _currentSpeedKmh = position.speed > 0 ? (position.speed * 3.6) : 0.0;
      });
      
      if (_currentIndex == 1 && _routePoints.length > 1) {
        _mapController.move(point, _mapController.camera.zoom);
      }
    });
  }

  void _onStepEvent(StepCount event) {
    final today = _todayKey();
    if (today != _activeDate) {
      _rollToNewDayIfNeeded();
      _stepsAtSessionStart = 0;
      _initialSteps = event.steps;
    }

    if (_initialSteps == -1) _initialSteps = event.steps;
    final sessionDelta = event.steps - _initialSteps;
    final newSteps = _stepsAtSessionStart + sessionDelta;
    if (newSteps == _steps) return;

    _steps = newSteps < 0 ? 0 : newSteps;
    _distanceKm = (_steps * 0.762) / 1000;
    
    int currentKm = _distanceKm.floor();
    if (currentKm > _lastKmNotified && currentKm > 0) {
      _lastKmNotified = currentKm;
      _showPopup('🔥 Grande! Hai superato i $currentKm km!', isGoal: false);
    }

    _maybeSaveToDb();
    _maybeCelebrateGoal();

    final now = DateTime.now();
    if (_lastUiUpdate == null || now.difference(_lastUiUpdate!).inMilliseconds > 500) {
      _lastUiUpdate = now;
      setState(() {});
    }
  }

  void _maybeCelebrateGoal() {
    if (_goalCelebrated || _distanceKm < _dailyKmGoal) return;
    _goalCelebrated = true;
    AppSettings.instance.setGoalCelebratedDate(_activeDate);
    _showPopup('🏆 OBIETTIVO RAGGIUNTO: ${_dailyKmGoal.toStringAsFixed(1)} km completati!', isGoal: true);
  }

  void _showPopup(String message, {required bool isGoal}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars(); 
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        duration: const Duration(seconds: 10),
        backgroundColor: isGoal ? Colors.green.shade800 : const Color(0xFF1E1E1E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
    if (isGoal) {
      FlutterRingtonePlayer().playNotification();
    }
  }

  Future<void> _stopTracking() async {
    if (!_isTracking) return;
    _timer?.cancel();
    await _stepSubscription?.cancel();
    await _positionSubscription?.cancel();
    _stepSubscription = null;
    _positionSubscription = null;
    _initialSteps = -1;
    setState(() {
      _isTracking = false;
      _currentSpeedKmh = 0.0;
    });
    
    // Salva i dati giornalieri E la traccia GPS della sessione appena conclusa
    await _saveToDb();
    await DatabaseHelper.instance.saveRoute(_activeDate, _routePoints);
  }

  Future<void> _resetToday() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Reset sessione?'),
        content: const Text('Azzera timer e mappa della sessione in corso. I passi e i km totali di oggi NON verranno toccati.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annulla', style: TextStyle(color: Colors.grey))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirm != true) return;

    // Azzera SOLO i dati della sessione corrente in memoria RAM
    _timer?.cancel();
    _secondsElapsed = 0;
    _currentSpeedKmh = 0.0;
    _routePoints.clear();
    
    if (mounted) setState(() { _isTracking = false; });
  }

  Future<void> _editKmGoal() async {
    final controller = TextEditingController(text: _dailyKmGoal.toStringAsFixed(1));
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Obiettivo km giornaliero'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: 'km', hintText: 'es. 5.0'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annulla')),
          TextButton(
            onPressed: () {
              final v = double.tryParse(controller.text.replaceAll(',', '.'));
              if (v != null && v > 0) Navigator.pop(ctx, v);
            },
            child: const Text('Salva'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;

    await AppSettings.instance.setKmGoal(result);
    setState(() {
      _dailyKmGoal = result;
      _goalCelebrated = _distanceKm >= result && AppSettings.instance.goalCelebratedDate == _activeDate;
    });
    if (_distanceKm >= result) _maybeCelebrateGoal();
  }

  Future<void> _maybeSaveToDb() async {
    final now = DateTime.now();
    if (_lastDbWrite != null && now.difference(_lastDbWrite!).inMinutes < 1) return;
    _lastDbWrite = now;
    await _saveToDb();
  }

  Future<void> _saveToDb() async {
    await DatabaseHelper.instance.saveDailyData(
      _activeDate.isEmpty ? _todayKey() : _activeDate,
      _steps,
      _distanceKm,
      _steps * 0.04,
      0,
    );
  }

  void _openTab(int index) {
    setState(() {
      _currentIndex = index;
      if (index == 2) _statsRevision++;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stepSubscription?.cancel();
    _positionSubscription?.cancel();
    _mapController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('StealthStep', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2)),
        backgroundColor: Colors.black,
        elevation: 0,
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _buildDashboardTab(),
          _buildMapTab(),
          StatsTab(kmGoal: _dailyKmGoal, revision: _statsRevision),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: Colors.black,
        selectedItemColor: Colors.greenAccent,
        unselectedItemColor: Colors.grey,
        currentIndex: _currentIndex,
        onTap: _openTab,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Map'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'Stats'),
        ],
      ),
    );
  }

  Widget _buildDashboardTab() {
    final kmProgress = (_distanceKm / _dailyKmGoal).clamp(0.0, 1.0);
    final stepProgress = (_steps / 10000).clamp(0.0, 1.0);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              onTap: _editKmGoal,
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _accent.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.flag, color: _accent, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      'Goal ${_dailyKmGoal.toStringAsFixed(1)} km',
                      style: const TextStyle(color: _accent, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.edit, color: Colors.grey, size: 14),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 200,
                height: 200,
                child: CircularProgressIndicator(
                  value: kmProgress,
                  strokeWidth: 12,
                  backgroundColor: const Color(0xFF2D2D2D),
                  color: _accent,
                ),
              ),
              SizedBox(
                width: 170,
                height: 170,
                child: CircularProgressIndicator(
                  value: stepProgress,
                  strokeWidth: 6,
                  backgroundColor: const Color(0xFF2D2D2D),
                  color: const Color(0xFF69F0AE),
                ),
              ),
              Column(
                children: [
                  Icon(
                    _isTracking ? Icons.directions_walk : Icons.pause_circle,
                    size: 36,
                    color: _accent,
                  ),
                  const SizedBox(height: 8),
                  Text('$_steps', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
                  const Text('STEPS', style: TextStyle(color: Colors.grey, letterSpacing: 2)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: kmProgress,
              minHeight: 8,
              backgroundColor: const Color(0xFF2D2D2D),
              color: _accent,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            kmProgress >= 1
                ? 'Obiettivo km raggiunto'
                : 'Mancano ${(_dailyKmGoal - _distanceKm).clamp(0, _dailyKmGoal).toStringAsFixed(2)} km',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          
          Row(
            children: [
              _infoCard(Icons.route, '${_distanceKm.toStringAsFixed(2)} km', 'DISTANCE'),
              const SizedBox(width: 12),
              _infoCard(Icons.local_fire_department, '${(_steps * 0.04).toStringAsFixed(0)}', 'KCAL'),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _infoCard(Icons.timer, _formattedDuration, 'TIME'),
              const SizedBox(width: 12),
              _infoCard(Icons.speed, _currentSpeedKmh.toStringAsFixed(1), 'KM/H'),
            ],
          ),

          const SizedBox(height: 12),
          Row(
            children: [
              _controlButton(
                icon: Icons.play_arrow,
                label: 'START',
                color: _accent,
                enabled: !_isTracking,
                onPressed: _startTracking,
              ),
              const SizedBox(width: 10),
              _controlButton(
                icon: Icons.stop,
                label: 'STOP',
                color: Colors.orangeAccent,
                enabled: _isTracking,
                onPressed: _stopTracking,
              ),
              const SizedBox(width: 10),
              _controlButton(
                icon: Icons.refresh,
                label: 'RESET',
                color: Colors.redAccent,
                enabled: true,
                onPressed: _resetToday,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _isTracking ? 'Tracking attivo' : 'Tracking in pausa',
            style: TextStyle(
              color: _isTracking ? _accent : Colors.grey,
              fontSize: 12,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required String label,
    required Color color,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return Expanded(
      child: ElevatedButton.icon(
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(letterSpacing: 1)),
        style: ElevatedButton.styleFrom(
          backgroundColor: enabled ? color : const Color(0xFF2A2A2A),
          foregroundColor: enabled ? Colors.black : Colors.grey,
          disabledBackgroundColor: const Color(0xFF2A2A2A),
          disabledForegroundColor: Colors.grey,
          padding: const EdgeInsets.symmetric(vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  Widget _infoCard(IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Column(
          children: [
            Icon(icon, color: Colors.greenAccent, size: 30),
            const SizedBox(height: 10),
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildMapTab() {
    if (_routePoints.isEmpty) {
      return Center(
        child: Text(
          _isTracking
              ? 'Acquiring True GPS Signal...'
              : 'Premi START per registrare il percorso',
          style: const TextStyle(color: Colors.greenAccent),
        ),
      );
    }
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _routePoints.last,
        initialZoom: 17.0,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.linuxtuts.stealthstep',
        ),
        PolylineLayer(
          polylines: [
            Polyline(
              points: _routePoints,
              strokeWidth: 5.0,
              color: Colors.blueAccent,
            ),
          ],
        ),
      ],
    );
  }
}
