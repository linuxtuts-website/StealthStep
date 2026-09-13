import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:latlong2/latlong.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    // Versione aggiornata a 2
    _database = await _initDB('stealth_pedometer.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    // Aggiunto il parametro onUpgrade
    return await openDatabase(
      path, 
      version: 2, 
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE daily_steps (
        date TEXT PRIMARY KEY,
        steps INTEGER NOT NULL,
        distance REAL NOT NULL,
        calories REAL NOT NULL,
        active_time INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS saved_routes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        date TEXT NOT NULL,
        coordinates_json TEXT NOT NULL
      )
    ''');
  }

  // NUOVA FUNZIONE: Eseguita solo se il DB passa da V1 a V2
  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS saved_routes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          date TEXT NOT NULL,
          coordinates_json TEXT NOT NULL
        )
      ''');
    }
  }

  Future<void> saveDailyData(String date, int steps, double distance, double calories, int activeTime) async {
    final db = await instance.database;
    await db.insert('daily_steps', {
      'date': date, 'steps': steps, 'distance': distance, 'calories': calories, 'active_time': activeTime,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getAllDailyData() async {
    final db = await instance.database;
    return await db.query('daily_steps', orderBy: 'date ASC');
  }

  Future<void> saveRoute(String date, List<LatLng> points) async {
    final db = await instance.database;
    await db.delete('saved_routes', where: 'date = ?', whereArgs: [date]);
    if (points.isEmpty) return;
    
    final List<Map<String, double>> coords = points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList();
    final String jsonStr = jsonEncode(coords);
    
    await db.insert('saved_routes', {
      'date': date,
      'coordinates_json': jsonStr,
    });
  }

  Future<List<LatLng>> getRoute(String date) async {
    final db = await instance.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'saved_routes',
      where: 'date = ?',
      whereArgs: [date],
      orderBy: 'id DESC',
      limit: 1
    );
    if (maps.isEmpty) return [];
    
    final String jsonStr = maps.first['coordinates_json'] as String;
    final List<dynamic> decoded = jsonDecode(jsonStr);
    return decoded.map((p) => LatLng(p['lat'] as double, p['lng'] as double)).toList();
  }
}
