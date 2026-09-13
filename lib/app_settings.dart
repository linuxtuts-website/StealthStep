import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const defaultKmGoal = 5.0;
  static const _kmGoalKey = 'daily_km_goal';
  static const _celebratedKey = 'goal_celebrated_date';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  SharedPreferences get _p {
    final p = _prefs;
    if (p == null) {
      throw StateError('AppSettings.init() non chiamato');
    }
    return p;
  }

  double get kmGoal => _p.getDouble(_kmGoalKey) ?? defaultKmGoal;

  Future<void> setKmGoal(double value) => _p.setDouble(_kmGoalKey, value);

  String? get goalCelebratedDate => _p.getString(_celebratedKey);

  Future<void> setGoalCelebratedDate(String date) =>
      _p.setString(_celebratedKey, date);
}
