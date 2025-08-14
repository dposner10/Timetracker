import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PomodoroPage extends StatefulWidget {
  const PomodoroPage({
    super.key,
    required this.onTimeLogged,
    this.initialTaskName,
  });

  final Function(String taskName, Duration duration) onTimeLogged;
  final String? initialTaskName;

  @override
  State<PomodoroPage> createState() => _PomodoroPageState();
}

class _PomodoroPageState extends State<PomodoroPage> with TickerProviderStateMixin {
  Timer? _timer;
  Duration _remainingTime = const Duration(minutes: 25);
  Duration _workDuration = const Duration(minutes: 25);
  Duration _shortBreakDuration = const Duration(minutes: 5);
  Duration _longBreakDuration = const Duration(minutes: 15);
  bool _isRunning = false;
  bool _isBreak = false;
  int _completedPomodoros = 0;
  int _sessionPomodoros = 0;
  String _selectedTask = '';
  final TextEditingController _taskController = TextEditingController();
  late AnimationController _progressController;
  DateTime? _sessionStartTime;
  Duration _currentSessionDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _selectedTask = widget.initialTaskName ?? '';
    _taskController.text = _selectedTask;
    _loadPomodoroState();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _progressController.dispose();
    _taskController.dispose();
    super.dispose();
  }

  void _startTimer() {
    if (_selectedTask.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte wähle eine Aufgabe aus')),
      );
      return;
    }

    setState(() {
      _isRunning = true;
      if (_sessionStartTime == null) {
        _sessionStartTime = DateTime.now();
        _currentSessionDuration = Duration.zero;
      }
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_remainingTime.inSeconds > 0) {
          _remainingTime = Duration(seconds: _remainingTime.inSeconds - 1);
          if (!_isBreak) {
            _currentSessionDuration = Duration(seconds: _currentSessionDuration.inSeconds + 1);
          }
          _progressController.value = 1.0 - (_remainingTime.inSeconds / _getCurrentTotalDuration().inSeconds);
        } else {
          _timer?.cancel();
          _onTimerComplete();
        }
      });
    });
    _savePomodoroState();
  }

  void _pauseTimer() {
    setState(() {
      _isRunning = false;
    });
    _timer?.cancel();
    _savePomodoroState();
  }

  void _resetTimer() {
    _timer?.cancel();
    setState(() {
      _isRunning = false;
      _remainingTime = _isBreak ? _getCurrentBreakDuration() : _workDuration;
      _progressController.value = 0.0;
      if (!_isBreak) {
        // Log the current session time if we were working
        if (_currentSessionDuration > Duration.zero && _selectedTask.isNotEmpty) {
          widget.onTimeLogged(_selectedTask, _currentSessionDuration);
        }
        _sessionStartTime = null;
        _currentSessionDuration = Duration.zero;
      }
    });
    _savePomodoroState();
  }

  void _onTimerComplete() {
    setState(() {
      _isRunning = false;
      _progressController.value = 1.0;
    });

    if (!_isBreak) {
      // Work session completed
      _completedPomodoros++;
      _sessionPomodoros++;
      
      // Log the completed work session
      if (_selectedTask.isNotEmpty) {
        widget.onTimeLogged(_selectedTask, _workDuration);
      }
      
      _sessionStartTime = null;
      _currentSessionDuration = Duration.zero;

      // Show completion message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Pomodoro #$_completedPomodoros abgeschlossen! 🍅'),
          backgroundColor: Colors.green,
        ),
      );

      // Start break
      setState(() {
        _isBreak = true;
        _remainingTime = _getCurrentBreakDuration();
        _progressController.value = 0.0;
      });
    } else {
      // Break completed
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pause beendet! Zeit für die nächste Runde! 💪'),
          backgroundColor: Colors.blue,
        ),
      );

      setState(() {
        _isBreak = false;
        _remainingTime = _workDuration;
        _progressController.value = 0.0;
      });
    }
    _savePomodoroState();
  }

  Duration _getCurrentTotalDuration() {
    return _isBreak ? _getCurrentBreakDuration() : _workDuration;
  }

  Duration _getCurrentBreakDuration() {
    // Long break every 4 pomodoros
    return (_sessionPomodoros % 4 == 0 && _sessionPomodoros > 0) 
        ? _longBreakDuration 
        : _shortBreakDuration;
  }

  String _formatDuration(Duration d) {
    final int minutes = d.inMinutes;
    final int seconds = d.inSeconds.remainder(60);
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _loadPomodoroState() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _completedPomodoros = prefs.getInt('pomodoro_completed') ?? 0;
      _sessionPomodoros = prefs.getInt('pomodoro_session') ?? 0;
      _workDuration = Duration(minutes: prefs.getInt('pomodoro_work_minutes') ?? 25);
      _shortBreakDuration = Duration(minutes: prefs.getInt('pomodoro_short_break_minutes') ?? 5);
      _longBreakDuration = Duration(minutes: prefs.getInt('pomodoro_long_break_minutes') ?? 15);
      
      final bool wasRunning = prefs.getBool('pomodoro_running') ?? false;
      final bool wasBreak = prefs.getBool('pomodoro_is_break') ?? false;
      final int remainingSeconds = prefs.getInt('pomodoro_remaining_seconds') ?? _workDuration.inSeconds;
      final int sessionDurationSeconds = prefs.getInt('pomodoro_session_duration') ?? 0;
      final int sessionStartMs = prefs.getInt('pomodoro_session_start') ?? 0;
      
      _isBreak = wasBreak;
      _remainingTime = Duration(seconds: remainingSeconds);
      _currentSessionDuration = Duration(seconds: sessionDurationSeconds);
      if (sessionStartMs > 0) {
        _sessionStartTime = DateTime.fromMillisecondsSinceEpoch(sessionStartMs);
      }
      
      if (wasRunning) {
        // Resume the timer if it was running
        _startTimer();
      }
      
      _progressController.value = 1.0 - (_remainingTime.inSeconds / _getCurrentTotalDuration().inSeconds);
    });
  }

  Future<void> _savePomodoroState() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pomodoro_completed', _completedPomodoros);
    await prefs.setInt('pomodoro_session', _sessionPomodoros);
    await prefs.setInt('pomodoro_work_minutes', _workDuration.inMinutes);
    await prefs.setInt('pomodoro_short_break_minutes', _shortBreakDuration.inMinutes);
    await prefs.setInt('pomodoro_long_break_minutes', _longBreakDuration.inMinutes);
    await prefs.setBool('pomodoro_running', _isRunning);
    await prefs.setBool('pomodoro_is_break', _isBreak);
    await prefs.setInt('pomodoro_remaining_seconds', _remainingTime.inSeconds);
    await prefs.setInt('pomodoro_session_duration', _currentSessionDuration.inSeconds);
    if (_sessionStartTime != null) {
      await prefs.setInt('pomodoro_session_start', _sessionStartTime!.millisecondsSinceEpoch);
    } else {
      await prefs.remove('pomodoro_session_start');
    }
  }

  void _showSettingsDialog() {
    final TextEditingController workController = TextEditingController(text: _workDuration.inMinutes.toString());
    final TextEditingController shortBreakController = TextEditingController(text: _shortBreakDuration.inMinutes.toString());
    final TextEditingController longBreakController = TextEditingController(text: _longBreakDuration.inMinutes.toString());

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pomodoro Einstellungen'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: workController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Arbeitszeit (Minuten)',
                hintText: '25',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: shortBreakController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Kurze Pause (Minuten)',
                hintText: '5',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: longBreakController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Lange Pause (Minuten)',
                hintText: '15',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              final int work = int.tryParse(workController.text) ?? 25;
              final int shortBreak = int.tryParse(shortBreakController.text) ?? 5;
              final int longBreak = int.tryParse(longBreakController.text) ?? 15;
              
              setState(() {
                _workDuration = Duration(minutes: work);
                _shortBreakDuration = Duration(minutes: shortBreak);
                _longBreakDuration = Duration(minutes: longBreak);
                if (!_isRunning) {
                  _remainingTime = _isBreak ? _getCurrentBreakDuration() : _workDuration;
                  _progressController.value = 0.0;
                }
              });
              _savePomodoroState();
              Navigator.pop(context);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pomodoro Timer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            // Stats Row
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      Text(
                        '$_completedPomodoros',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text('Gesamt'),
                    ],
                  ),
                  Container(width: 1, height: 40, color: Theme.of(context).dividerColor),
                  Column(
                    children: [
                      Text(
                        '$_sessionPomodoros',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: Theme.of(context).colorScheme.secondary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text('Session'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Task Selection
            TextField(
              controller: _taskController,
              decoration: InputDecoration(
                labelText: 'Aufgabe',
                hintText: 'Woran arbeitest du?',
                prefixIcon: const Icon(Icons.work_outline),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _selectedTask = value;
                });
              },
            ),
            const SizedBox(height: 32),

            // Timer Circle
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 300,
                        height: 300,
                        child: CircularProgressIndicator(
                          value: _progressController.value,
                          strokeWidth: 8,
                          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            _isBreak 
                                ? Theme.of(context).colorScheme.secondary
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _formatDuration(_remainingTime),
                            style: Theme.of(context).textTheme.displayLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: (_isBreak 
                                  ? Theme.of(context).colorScheme.secondary
                                  : Theme.of(context).colorScheme.primary).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              _isBreak 
                                  ? (_sessionPomodoros % 4 == 0 && _sessionPomodoros > 0 ? 'Lange Pause' : 'Kurze Pause')
                                  : 'Arbeitszeit',
                              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                color: _isBreak 
                                    ? Theme.of(context).colorScheme.secondary
                                    : Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Control Buttons
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                FilledButton.tonal(
                  onPressed: _resetTimer,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.refresh),
                      SizedBox(width: 8),
                      Text('Reset'),
                    ],
                  ),
                ),
                SizedBox(
                  width: 120,
                  height: 56,
                  child: _isRunning
                      ? FilledButton(
                          onPressed: _pauseTimer,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.orange,
                            foregroundColor: Colors.white,
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.pause),
                              SizedBox(width: 8),
                              Text('Pause'),
                            ],
                          ),
                        )
                      : FilledButton(
                          onPressed: _startTimer,
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.primary,
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.play_arrow),
                              SizedBox(width: 8),
                              Text('Start'),
                            ],
                          ),
                        ),
                ),
                FilledButton.tonal(
                  onPressed: () {
                    setState(() {
                      _sessionPomodoros = 0;
                    });
                    _savePomodoroState();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Session zurückgesetzt')),
                    );
                  },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.replay),
                      SizedBox(width: 8),
                      Text('Session'),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}