import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'database_helper.dart';

class StatsTab extends StatefulWidget {
  final double kmGoal;
  final int revision;

  const StatsTab({
    super.key,
    required this.kmGoal,
    required this.revision,
  });

  @override
  State<StatsTab> createState() => _StatsTabState();
}

class _StatsTabState extends State<StatsTab> {
  static const _accent = Color(0xFF00E676);

  String _filter = 'WEEK';
  List<Map<String, dynamic>> _data = [];
  List<String> _labels = [];

  double get _goalSteps => widget.kmGoal * 1000 / 0.762;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  @override
  void didUpdateWidget(covariant StatsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      _loadStats();
    }
  }

  Future<void> _loadStats() async {
    final all = await DatabaseHelper.instance.getAllDailyData();
    final count = _filter == 'WEEK' ? 7 : (_filter == 'MONTH' ? 30 : all.length);
    final subset = all.length > count ? all.sublist(all.length - count) : all;

    final now = DateTime.now();
    final expected = _filter == 'YEAR' ? null : count;

    final Map<String, int> byDate = {
      for (final row in subset) row['date'] as String: row['steps'] as int,
    };

    final List<Map<String, dynamic>> filled = [];
    final List<String> labels = [];
    if (expected != null) {
      for (int i = expected - 1; i >= 0; i--) {
        final d = now.subtract(Duration(days: i));
        final key = d.toIso8601String().split('T')[0];
        filled.add({'date': key, 'steps': byDate[key] ?? 0});
        labels.add('${d.day}/${d.month}');
      }
    } else {
      for (final row in subset) {
        final d = DateTime.parse(row['date'] as String);
        filled.add(row);
        labels.add('${d.day}/${d.month}');
      }
    }

    setState(() {
      _data = filled;
      _labels = labels;
    });
  }

  Future<void> _showRoutePopup(String date) async {
    final points = await DatabaseHelper.instance.getRoute(date);
    if (!mounted) return;
    
    if (points.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nessun percorso GPS salvato per questo giorno.', style: TextStyle(color: Colors.white)),
          backgroundColor: Color(0xFF1E1E1E),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Row(
          children: [
            const Icon(Icons.map, color: _accent),
            const SizedBox(width: 8),
            Text('Sessione del $date', style: const TextStyle(color: _accent, fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: FlutterMap(
              options: MapOptions(
                initialCenter: points.last,
                initialZoom: 15.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.linuxtuts.stealthstep',
                ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: points,
                      strokeWidth: 5.0,
                      color: Colors.blueAccent,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Chiudi', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  double get _maxY {
    double max = _goalSteps;
    for (final row in _data) {
      final s = (row['steps'] as int).toDouble();
      if (s > max) max = s;
    }
    return ((max / 2000).ceil() * 2000).toDouble();
  }

  int get _yInterval => _maxY <= 20000 ? 5000 : 10000;

  int get _totalSteps => _data.fold(0, (sum, row) => sum + (row['steps'] as int));

  Widget _statCard(IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Icon(icon, color: _accent, size: 22),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('ATTIVITÀ', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: _accent)),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'WEEK', label: Text('Week')),
                  ButtonSegment(value: 'MONTH', label: Text('Month')),
                  ButtonSegment(value: 'YEAR', label: Text('Year')),
                ],
                selected: {_filter},
                onSelectionChanged: (s) {
                  _filter = s.first;
                  _loadStats();
                },
                style: SegmentedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  selectedForegroundColor: Colors.black,
                  selectedBackgroundColor: _accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _statCard(Icons.directions_walk, '${(_totalSteps / 1000).toStringAsFixed(1)}k', 'TOTAL STEPS'),
              const SizedBox(width: 10),
              _statCard(Icons.route, '${((_totalSteps * 0.762) / 1000).toStringAsFixed(1)} km', 'DISTANCE'),
              const SizedBox(width: 10),
              _statCard(Icons.local_fire_department, '${(_totalSteps * 0.04).round()}', 'KCAL'),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: _data.isEmpty
                ? const Center(child: Text('No data yet. Keep walking!', style: TextStyle(color: Colors.grey)))
                : BarChart(
                    BarChartData(
                      maxY: _maxY,
                      alignment: BarChartAlignment.spaceAround,
                      extraLinesData: ExtraLinesData(
                        horizontalLines: [
                          HorizontalLine(
                            y: _goalSteps,
                            color: _accent.withValues(alpha: 0.45),
                            strokeWidth: 1,
                            dashArray: const [6, 4],
                            label: HorizontalLineLabel(
                              show: true,
                              alignment: Alignment.topRight,
                              style: const TextStyle(color: Colors.grey, fontSize: 10),
                              labelResolver: (_) => 'goal ${widget.kmGoal.toStringAsFixed(1)} km',
                            ),
                          ),
                        ],
                      ),
                      barTouchData: BarTouchData(
                        enabled: true,
                        touchCallback: (FlTouchEvent event, barTouchResponse) async {
                          // IL FIX È TUTTO QUI: Nessun filtro preventivo sull'interazione!
                          if (barTouchResponse == null || barTouchResponse.spot == null) return;
                          
                          if (event is FlTapUpEvent) {
                            final index = barTouchResponse.spot!.touchedBarGroupIndex;
                            if (index >= 0 && index < _data.length) {
                              _showRoutePopup(_data[index]['date'] as String);
                            }
                          }
                        },
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipColor: (_) => const Color(0xFF262626),
                          getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                            '${rod.toY.round()} steps',
                            const TextStyle(color: _accent, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: _yInterval.toDouble(),
                        getDrawingHorizontalLine: (v) => const FlLine(color: Color(0xFF2A2A2A), strokeWidth: 1, dashArray: [4, 4]),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 42,
                            interval: _yInterval.toDouble(),
                            getTitlesWidget: (value, meta) => Text(
                              value >= 1000 ? '${(value / 1000).toStringAsFixed(0)}k' : value.round().toString(),
                              style: const TextStyle(color: Colors.grey, fontSize: 11),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 28,
                            interval: (_data.length / 7).ceilToDouble(),
                            getTitlesWidget: (value, meta) {
                              final i = value.toInt();
                              if (i < 0 || i >= _labels.length) return const SizedBox.shrink();
                              return Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Text(_labels[i], style: const TextStyle(color: Colors.grey, fontSize: 11)),
                              );
                            },
                          ),
                        ),
                      ),
                      barGroups: [
                        for (int i = 0; i < _data.length; i++)
                          BarChartGroupData(
                            x: i,
                            barRods: [
                              BarChartRodData(
                                toY: (_data[i]['steps'] as int).toDouble(),
                                width: _data.length > 12 ? 8 : 20,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                gradient: const LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [Color(0xFF00C853), Color(0xFF69F0AE)],
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
