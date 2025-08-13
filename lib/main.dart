import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_chart/fl_chart.dart';

void main() {
  runApp(const TimeTrackerApp());
}

class TimeTrackerApp extends StatelessWidget {
  const TimeTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Time Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const TimeTrackerHomePage(),
    );
  }
}

// Alias für Tests, die noch `MyApp` erwarten
class MyApp extends TimeTrackerApp {
  const MyApp({super.key});
}

class TaskEntry {
  TaskEntry({required this.name});

  final String name;
  Duration accumulatedDuration = Duration.zero;
  DateTime? startedAt;
  bool archivedToday = false;

  bool get isRunning => startedAt != null;

  Duration durationIncludingRunning(DateTime now) {
    if (!isRunning) return accumulatedDuration;
    return accumulatedDuration + now.difference(startedAt!);
  }
}

class TaskSession {
  TaskSession({required this.taskName, required this.start, this.end});

  final String taskName;
  final DateTime start;
  DateTime? end;

  bool get isOpen => end == null;
}

enum ChartRange { day, week, month }

class TimeTrackerHomePage extends StatefulWidget {
  const TimeTrackerHomePage({super.key});

  @override
  State<TimeTrackerHomePage> createState() => _TimeTrackerHomePageState();
}

class _TimeTrackerHomePageState extends State<TimeTrackerHomePage> {
  final List<TaskEntry> _tasks = <TaskEntry>[];
  final List<TaskSession> _sessions = <TaskSession>[];
  final Duration _tickInterval = const Duration(seconds: 1);
  Timer? _ticker;
  DateTime _currentDay = _stripToDate(DateTime.now());
  bool _isFocusMode = false;
  static const MethodChannel _focusChannel = MethodChannel('focus_mode');

  static DateTime _stripToDate(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day);

  @override
  void initState() {
    super.initState();
    _loadState();
    _ticker = Timer.periodic(_tickInterval, (_) {
      final DateTime now = DateTime.now();
      if (_stripToDate(now).isAfter(_currentDay)) {
        _rollOverToNewDay(now);
      }
      if (mounted) setState(() {});
    });
    _initFocusState();
    _initWorkoutBridge();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _initFocusState() async {
    if (!Platform.isAndroid) return;
    try {
      final bool isPinned =
          await _focusChannel.invokeMethod<bool>('isInLockTaskMode') ?? false;
      if (mounted) setState(() => _isFocusMode = isPinned);
    } catch (_) {
      // ignore
    }
  }

  TaskEntry? get _runningTask =>
      _tasks.where((t) => t.isRunning).cast<TaskEntry?>().firstOrNull;

  void _addTask(String name) {
    if (name.trim().isEmpty) return;
    setState(() {
      _tasks.add(TaskEntry(name: name.trim()));
    });
    _saveState();
  }

  void _startOrSwitchToCategory(String name) {
    // Ensure task exists
    TaskEntry? task;
    try {
      task = _tasks.firstWhere((t) => t.name.toLowerCase() == name.toLowerCase());
    } catch (_) {
      task = null;
    }
    if (task == null) {
      task = TaskEntry(name: name);
      setState(() => _tasks.add(task!));
    }
    if (!task!.isRunning) {
      _startTask(task);
    }
    _saveState();
  }

  void _archiveTaskForToday(TaskEntry task) {
    setState(() {
      if (task.isRunning) {
        _stopTask(task, setStateAlreadyCalled: true);
      }
      task.archivedToday = true;
    });
    _saveState();
  }

  void _archiveAllFinishedForToday() {
    setState(() {
      for (final TaskEntry t in _tasks) {
        if (!t.isRunning && t.accumulatedDuration > Duration.zero) {
          t.archivedToday = true;
        }
      }
    });
    _saveState();
  }

  void _startTask(TaskEntry task) {
    setState(() {
      for (final TaskEntry t in _tasks) {
        if (t.isRunning) {
          _stopTask(t, setStateAlreadyCalled: true);
        }
      }
      task.startedAt = DateTime.now();
      _sessions.add(TaskSession(taskName: task.name, start: task.startedAt!));
    });
  }

  void _stopTask(TaskEntry task, {bool setStateAlreadyCalled = false}) {
    void doStop() {
      final DateTime now = DateTime.now();
      if (task.startedAt != null) {
        task.accumulatedDuration += now.difference(task.startedAt!);
        for (int i = _sessions.length - 1; i >= 0; i--) {
          final TaskSession s = _sessions[i];
          if (s.taskName == task.name && s.end == null) {
            s.end = now;
            break;
          }
        }
        task.startedAt = null;
      }
    }

    if (setStateAlreadyCalled) {
      doStop();
      _saveState();
      return;
    }
    setState(doStop);
    _saveState();
  }

  void _toggleTask(TaskEntry task) {
    if (task.isRunning) {
      _stopTask(task);
    } else {
      _startTask(task);
    }
    _saveState();
  }

  void _clearToday() {
    setState(() {
      for (final TaskEntry t in _tasks) {
        t.startedAt = null;
        t.accumulatedDuration = Duration.zero;
        t.archivedToday = false;
      }
      final DateTime dayStart = _stripToDate(DateTime.now());
      final DateTime dayEnd = dayStart.add(const Duration(days: 1));
      _sessions.removeWhere(
        (TaskSession s) =>
            _overlapDuration(
              s.start,
              s.end ?? DateTime.now(),
              dayStart,
              dayEnd,
            ) >
            Duration.zero,
      );
      _currentDay = _stripToDate(DateTime.now());
    });
    _saveState();
  }

  void _rollOverToNewDay(DateTime now) {
    for (final TaskEntry t in _tasks) {
      if (t.isRunning) {
        t.accumulatedDuration += now.difference(t.startedAt!);
        for (int i = _sessions.length - 1; i >= 0; i--) {
          final TaskSession s = _sessions[i];
          if (s.taskName == t.name && s.end == null) {
            s.end = now;
            break;
          }
        }
        t.startedAt = null;
      }
      t.accumulatedDuration = Duration.zero;
      t.archivedToday = false;
    }
    _currentDay = _stripToDate(now);
    _saveState();
  }

  String _formatDuration(Duration d) {
    final int hours = d.inHours;
    final int minutes = d.inMinutes.remainder(60);
    final int seconds = d.inSeconds.remainder(60);
    String two(int n) => n.toString().padLeft(2, '0');
    if (hours > 0) {
      return '${two(hours)}:${two(minutes)}:${two(seconds)} h';
    }
    return '${two(minutes)}:${two(seconds)} min';
  }

  String _formatDate(DateTime d) {
    final List<String> months = <String>[
      '01',
      '02',
      '03',
      '04',
      '05',
      '06',
      '07',
      '08',
      '09',
      '10',
      '11',
      '12',
    ];
    return '${d.day.toString().padLeft(2, '0')}.${months[d.month - 1]}.${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final List<TaskEntry> sortedTasks = List<TaskEntry>.from(_tasks)..sort(
      (a, b) => b
          .durationIncludingRunning(now)
          .compareTo(a.durationIncludingRunning(now)),
    );

    final Duration totalToday = sortedTasks.fold<Duration>(
      Duration.zero,
      (prev, t) => prev + t.durationIncludingRunning(now),
    );

    return PopScope(
      canPop: !_isFocusMode,
      child: Scaffold(
      appBar: AppBar(
          title: const Text('Time Tracker'),
          actions: <Widget>[
            IconButton(
              tooltip: 'Statistiken',
              icon: const Icon(Icons.show_chart_outlined),
              onPressed: _openStatistics,
            ),
            IconButton(
              tooltip:
                  _isFocusMode ? 'Fokusmodus beenden' : 'Fokusmodus starten',
              icon: Icon(_isFocusMode ? Icons.lock_open : Icons.lock_outline),
              onPressed: _toggleFocusMode,
            ),
            IconButton(
              tooltip: 'Diagramm',
              icon: const Icon(Icons.pie_chart_outline_rounded),
              onPressed: _openChart,
            ),
            IconButton(
              tooltip: 'Heute zurücksetzen',
              icon: const Icon(Icons.restore),
              onPressed:
                  _tasks.isEmpty
                      ? null
                      : () async {
                        final bool? confirmed = await showDialog<bool>(
                          context: context,
                          builder: (BuildContext context) {
                            return AlertDialog(
                              title: const Text('Heute zurücksetzen?'),
                              content: const Text(
                                'Alle heutigen Zeiten werden auf 00:00 gesetzt.',
                              ),
                              actions: <Widget>[
                                TextButton(
                                  onPressed:
                                      () => Navigator.of(context).pop(false),
                                  child: const Text('Abbrechen'),
                                ),
                                FilledButton(
                                  onPressed:
                                      () => Navigator.of(context).pop(true),
                                  child: const Text('Zurücksetzen'),
                                ),
                              ],
                            );
                          },
                        );
                        if (confirmed == true) _clearToday();
                      },
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.today, size: 18),
                        const SizedBox(width: 8),
                        Text(_formatDate(_currentDay)),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Row(
                    children: <Widget>[
                      const Icon(Icons.timer_outlined, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        _formatDuration(totalToday),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _QuickCategoryBar(
              runningTaskName: _runningTask?.name,
              onSelect: _startOrSwitchToCategory,
            ),
          ),
            Expanded(
              child:
                  _tasks.isEmpty
                      ? _EmptyState(onAdd: _showAddTaskDialog)
                      : ListView.separated(
                        itemCount: sortedTasks.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (BuildContext context, int index) {
                          final TaskEntry task = sortedTasks[index];
                          final Duration displayDuration = task
                              .durationIncludingRunning(now);
                          final bool isRunning = task.isRunning;
                          if (task.archivedToday) {
                            return const SizedBox.shrink();
                          }
                      return Dismissible(
                        key: ValueKey<String>('task_${task.name}_${task.hashCode}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.red.withValues(alpha: 0.12),
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: const Icon(Icons.delete_outline, color: Colors.red),
                        ),
                        onDismissed: (_) {
                          setState(() {
                            if (task.isRunning) {
                              _stopTask(task, setStateAlreadyCalled: true);
                            }
                            _tasks.remove(task);
                          });
                          _saveState();
                        },
                        child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  isRunning
                                      ? Theme.of(
                                        context,
                                      ).colorScheme.primaryContainer
                                      : Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                              child: Icon(
                                isRunning ? Icons.play_arrow : Icons.pause,
                                color:
                                    Theme.of(
                                      context,
                                    ).colorScheme.onPrimaryContainer,
                              ),
                            ),
                            title: Text(task.name),
                            subtitle: Text(_formatDuration(displayDuration)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                IconButton(
                                  tooltip: isRunning ? 'Stopp' : 'Start',
                                  icon: Icon(
                                    isRunning ? Icons.stop : Icons.play_arrow,
                                  ),
                                  onPressed: () => _toggleTask(task),
                                ),
                                IconButton(
                                  tooltip: 'Session abschließen',
                                  icon: const Icon(Icons.check_circle_outline),
                                  onPressed: () => _archiveTaskForToday(task),
                                ),
                              ],
                            ),
                          ),
                      );
                        },
                      ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _showAddTaskDialog,
                        icon: const Icon(Icons.add),
                        label: const Text('Aufgabe hinzufügen'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonalIcon(
                      onPressed:
                          _runningTask == null
                              ? null
                              : () => _stopTask(_runningTask!),
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Stopp'),
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

  Future<void> _showAddTaskDialog() async {
    final TextEditingController controller = TextEditingController();
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Neue Aufgabe'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => Navigator.of(context).pop(true),
            decoration: const InputDecoration(
              labelText: 'Name der Aufgabe',
              hintText: 'z.B. E-Mails, Coding, Meetings',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Hinzufügen'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      _addTask(controller.text);
    }
  }

  void _openChart() {
    final DateTime now = DateTime.now();
    ChartRange selected = ChartRange.day;
    List<_DonutSlice> slices = _buildSlicesForRange(selected, now);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (BuildContext context) {
        return SafeArea(
          top: false,
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setModalState) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          const Icon(Icons.pie_chart_outline_rounded),
                          const SizedBox(width: 8),
                          Text(
                            'Verteilung',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const Spacer(),
                          Flexible(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SegmentedButton<ChartRange>(
                                segments: const <ButtonSegment<ChartRange>>[
                                  ButtonSegment<ChartRange>(
                                    value: ChartRange.day,
                                    label: Text('Tag'),
                                  ),
                                  ButtonSegment<ChartRange>(
                                    value: ChartRange.week,
                                    label: Text('Woche'),
                                  ),
                                  ButtonSegment<ChartRange>(
                                    value: ChartRange.month,
                                    label: Text('Monat'),
                                  ),
                                ],
                                selected: <ChartRange>{selected},
                                onSelectionChanged: (Set<ChartRange> v) {
                                  selected = v.first;
                                  slices = _buildSlicesForRange(
                                    selected,
                                    DateTime.now(),
                                  );
                                  setModalState(() {});
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (slices.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          child: Center(
                            child: Text(
                              'Keine Daten',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                        )
                      else
                        LayoutBuilder(
                          builder: (
                            BuildContext context,
                            BoxConstraints constraints,
                          ) {
                            final double maxWidth = constraints.maxWidth;
                            final double chartSize = math.min(maxWidth, 280);
                            final double availableHeight =
                                MediaQuery.of(context).size.height * 0.5;
                            final double size = math.min(
                              chartSize,
                              availableHeight,
                            );
                            final Duration total = slices.fold<Duration>(
                              Duration.zero,
                              (prev, s) => prev + s.value,
                            );
                          return Column(
                              children: <Widget>[
                                Center(
                                  child: SizedBox(
                                    width: size,
                                    height: size,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: <Widget>[
                                        CustomPaint(
                                          size: Size(size, size),
                                          painter: _DonutChartPainter(
                                            slices: slices,
                                            backgroundColor:
                                                Theme.of(context)
                                                    .colorScheme
                                                    .surfaceContainerHighest,
                                          ),
                                        ),
                                        Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: <Widget>[
                                            Text(
                                              _formatDuration(total),
                                              style:
                                                  Theme.of(
                                                    context,
                                                  ).textTheme.titleLarge,
                                            ),
                                            Text(
                                              'gesamt',
                                              style:
                                                  Theme.of(
                                                    context,
                                                  ).textTheme.labelMedium,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                              _DonutLegend(
                                  slices: slices,
                                  formatDuration: _formatDuration,
                                ),
                              const SizedBox(height: 8),
                              if (selected == ChartRange.day)
                                TextButton.icon(
                                  onPressed: () => _archiveAllFinishedForToday(),
                                  icon: const Icon(Icons.check_circle_outline),
                                  label: const Text('Heute abgeschlossene Sessions ausblenden'),
                                ),
                              ],
                            );
                          },
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _openStatistics() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StatisticsPage(
          sessions: _sessions,
          colorForTask: _colorForTask,
        ),
      ),
    );
  }

  Future<void> _loadState() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? tasksJson = prefs.getString('tasks');
    final String? sessionsJson = prefs.getString('sessions');
    final String? runningTaskName = prefs.getString('runningTask');
    final int? runningStartedAtMs = prefs.getInt('runningStartedAt');
    final int? currentDayMs = prefs.getInt('currentDay');

    if (currentDayMs != null) {
      _currentDay = _stripToDate(DateTime.fromMillisecondsSinceEpoch(currentDayMs));
    }

    if (tasksJson != null && tasksJson.isNotEmpty) {
      final List<dynamic> list = jsonDecode(tasksJson) as List<dynamic>;
      _tasks.clear();
      for (final dynamic item in list) {
        final Map<String, dynamic> m = Map<String, dynamic>.from(item as Map);
        final TaskEntry t = TaskEntry(name: m['name'] as String);
        t.accumulatedDuration = Duration(milliseconds: (m['accMs'] as int?) ?? 0);
        t.archivedToday = (m['archivedToday'] as bool?) ?? false;
        _tasks.add(t);
      }
    }

    if (sessionsJson != null && sessionsJson.isNotEmpty) {
      final List<dynamic> list = jsonDecode(sessionsJson) as List<dynamic>;
      _sessions.clear();
      for (final dynamic item in list) {
        final Map<String, dynamic> m = Map<String, dynamic>.from(item as Map);
        _sessions.add(
          TaskSession(
            taskName: m['task'] as String,
            start: DateTime.fromMillisecondsSinceEpoch(m['start'] as int),
            end: m['end'] == null ? null : DateTime.fromMillisecondsSinceEpoch(m['end'] as int),
          ),
        );
      }
    }

    if (runningTaskName != null && runningStartedAtMs != null) {
      TaskEntry? existing;
      try {
        existing = _tasks.firstWhere((t) => t.name == runningTaskName);
      } catch (_) {
        existing = null;
      }
      if (existing == null) {
        existing = TaskEntry(name: runningTaskName);
        _tasks.add(existing);
      }
      final DateTime restoredStart = DateTime.fromMillisecondsSinceEpoch(runningStartedAtMs);
      existing.startedAt = restoredStart;
      // Ensure an open session exists for the running task so stats include ongoing time
      final bool hasOpenSession = _sessions.any((s) => s.taskName == runningTaskName && s.end == null);
      if (!hasOpenSession) {
        _sessions.add(TaskSession(taskName: runningTaskName, start: restoredStart));
      }
    }

    if (mounted) setState(() {});
  }

  Future<void> _saveState() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<Map<String, dynamic>> tasksList = _tasks
        .map((t) => <String, dynamic>{
              'name': t.name,
              'accMs': t.accumulatedDuration.inMilliseconds,
              'archivedToday': t.archivedToday,
            })
        .toList();
    await prefs.setString('tasks', jsonEncode(tasksList));

    final List<Map<String, dynamic>> sessionsList = _sessions
        .map((s) => <String, dynamic>{
              'task': s.taskName,
              'start': s.start.millisecondsSinceEpoch,
              'end': s.end?.millisecondsSinceEpoch,
            })
        .toList();
    await prefs.setString('sessions', jsonEncode(sessionsList));

    final TaskEntry? running = _runningTask;
    if (running != null && running.startedAt != null) {
      await prefs.setString('runningTask', running.name);
      await prefs.setInt('runningStartedAt', running.startedAt!.millisecondsSinceEpoch);
    } else {
      await prefs.remove('runningTask');
      await prefs.remove('runningStartedAt');
    }

    await prefs.setInt('currentDay', _currentDay.millisecondsSinceEpoch);
  }

  Future<void> _initWorkoutBridge() async {
    const MethodChannel ttBridge = MethodChannel('tt_bridge');
    try {
      // Ask Android to register receiver (no-op on iOS)
      await ttBridge.invokeMethod('registerReceiver');
    } catch (_) {}

    // Pull pending payloads saved by the BroadcastReceiver (Android side)
    // Reuse SharedPreferences namespace used by receiver
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    // Receiver speichert unter flutter.tt_bridge_pending als JSON-Array-String
    final String? arrJson = prefs.getString('tt_bridge_pending');
    final Set<String> pending = arrJson == null
        ? <String>{}
        : (jsonDecode(arrJson) as List<dynamic>).cast<String>().toSet();
    if (pending.isEmpty) return;
    for (final String payload in pending) {
      _ingestExternalWorkoutPayload(payload);
    }
    await prefs.remove('tt_bridge_pending');
  }

  void _ingestExternalWorkoutPayload(String payloadJson) {
    try {
      final Map<String, dynamic> m = jsonDecode(payloadJson) as Map<String, dynamic>;
      if ((m['eventType'] as String?) != 'workout_completed') return;
      // Always map to category "Sport"
      final String name = 'Sport';
      final int startMs = m['start'] as int; // epoch ms
      final int endMs = m['end'] as int;
      final DateTime start = DateTime.fromMillisecondsSinceEpoch(startMs);
      final DateTime end = DateTime.fromMillisecondsSinceEpoch(endMs);
      if (!end.isAfter(start)) return;
      setState(() {
        _sessions.add(TaskSession(taskName: name, start: start, end: end));
        // Also reflect into today's task list so it appears on the home screen
        final DateTime dayStart = _stripToDate(DateTime.now());
        final DateTime dayEnd = dayStart.add(const Duration(days: 1));
        final Duration overlap = _overlapDuration(start, end, dayStart, dayEnd);
        if (overlap > Duration.zero) {
          TaskEntry? task;
          try {
            task = _tasks.firstWhere((t) => t.name.toLowerCase() == name.toLowerCase());
          } catch (_) {
            task = null;
          }
          task ??= TaskEntry(name: name);
          if (!_tasks.contains(task)) {
            _tasks.add(task);
          }
          // Ensure not marked archived today
          task.archivedToday = false;
          // Add duration (do not start running)
          task.accumulatedDuration = task.accumulatedDuration + overlap;
        }
      });
      _saveState();
    } catch (_) {
      // ignore malformed payload
    }
  }

  Future<void> _toggleFocusMode() async {
    if (!Platform.isAndroid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Fokusmodus wird derzeit nur auf Android unterstützt.',
            ),
          ),
        );
      }
      return;
    }

    try {
      if (_isFocusMode) {
        await _focusChannel.invokeMethod('stopLockTask');
        if (mounted) setState(() => _isFocusMode = false);
      } else {
        await _focusChannel.invokeMethod('startLockTask');
        if (mounted) setState(() => _isFocusMode = true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Fokusmodus aktiviert. Zum Beenden: Zurück gedrückt halten und Entsperren wählen.',
              ),
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fokusmodus fehlgeschlagen: ${e.code}')),
        );
      }
    }
  }

  

  Color _colorForTask(String name) {
    const List<Color> palette = <Color>[
      Color(0xFF1E88E5), // blue
      Color(0xFFD81B60), // pink
      Color(0xFF43A047), // green
      Color(0xFFFB8C00), // orange
      Color(0xFF8E24AA), // purple
      Color(0xFFF4511E), // deep orange
      Color(0xFF00897B), // teal
      Color(0xFF3949AB), // indigo
      Color(0xFF7CB342), // light green
      Color(0xFF00ACC1), // cyan
    ];
    final int index = name.hashCode.abs() % palette.length;
    return palette[index];
  }

  Map<String, Color> _assignColorsForLabels(List<String> labels) {
    // Ensure unique colors within the given set of labels using a fixed palette
    const List<Color> palette = <Color>[
      Color(0xFF1E88E5), // blue
      Color(0xFFD81B60), // pink
      Color(0xFF43A047), // green
      Color(0xFFFB8C00), // orange
      Color(0xFF8E24AA), // purple
      Color(0xFFF4511E), // deep orange
      Color(0xFF00897B), // teal
      Color(0xFF3949AB), // indigo
      Color(0xFF7CB342), // light green
      Color(0xFF00ACC1), // cyan
    ];

    final List<String> sorted = List<String>.from(labels)..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final Map<String, Color> mapping = <String, Color>{};
    final Set<int> used = <int>{};

    int overflowIndex = 0;
    for (final String label in sorted) {
      final int base = label.hashCode.abs() % palette.length;
      int idx = base;
      int attempts = 0;
      while (used.contains(idx) && attempts < palette.length) {
        attempts += 1;
        idx = (base + attempts) % palette.length;
      }
      if (!used.contains(idx)) {
        mapping[label] = palette[idx];
        used.add(idx);
      } else {
        // Palette exhausted; generate distinct HSV-based colors deterministically
        final double hue = (overflowIndex * 37) % 360.0;
        overflowIndex += 1;
        mapping[label] = HSVColor.fromAHSV(1, hue, 0.6, 0.9).toColor();
      }
    }
    return mapping;
  }

  Duration _overlapDuration(
    DateTime aStart,
    DateTime aEnd,
    DateTime bStart,
    DateTime bEnd,
  ) {
    final DateTime start = aStart.isAfter(bStart) ? aStart : bStart;
    final DateTime end = aEnd.isBefore(bEnd) ? aEnd : bEnd;
    if (end.isAfter(start)) return end.difference(start);
    return Duration.zero;
  }

  List<_DonutSlice> _buildSlicesForRange(ChartRange range, DateTime now) {
    DateTime start;
    switch (range) {
      case ChartRange.day:
        start = _stripToDate(now);
        break;
      case ChartRange.week:
        final int daysFromMonday = (now.weekday - DateTime.monday);
        start = _stripToDate(now.subtract(Duration(days: daysFromMonday)));
        break;
      case ChartRange.month:
        start = DateTime(now.year, now.month, 1);
        break;
    }

    if (range == ChartRange.day) {
    final List<_DonutSlice> list = <_DonutSlice>[];
      for (final TaskEntry t in _tasks) {
        final Duration value = t.durationIncludingRunning(now);
        if (value > Duration.zero) {
          list.add(
            _DonutSlice(
              label: t.name,
            value: value,
            color: Colors.transparent,
            ),
          );
        }
      }
      // Assign unique colors for the current set
      final Map<String, Color> cmap = _assignColorsForLabels(list.map((e) => e.label).toList());
      for (final _DonutSlice s in list) {
        s.color = cmap[s.label] ?? _colorForTask(s.label);
      }
      list.sort((a, b) => b.value.compareTo(a.value));
      return list;
    }

    final Map<String, Duration> totals = <String, Duration>{};
    final DateTime end = now;
    for (final TaskSession s in _sessions) {
      final DateTime sessionEnd = s.end ?? now;
      final Duration d = _overlapDuration(s.start, sessionEnd, start, end);
      if (d > Duration.zero) {
        totals[s.taskName] = (totals[s.taskName] ?? Duration.zero) + d;
      }
    }

    final List<_DonutSlice> list = totals.entries
        .map((e) => _DonutSlice(label: e.key, value: e.value, color: Colors.transparent))
        .toList();
    final Map<String, Color> cmap = _assignColorsForLabels(list.map((e) => e.label).toList());
    for (final _DonutSlice s in list) {
      s.color = cmap[s.label] ?? _colorForTask(s.label);
    }
    list.sort((a, b) => b.value.compareTo(a.value));
    return list;
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.timer_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            const Text(
              'Noch keine Aufgaben für heute',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Füge eine Aufgabe hinzu und starte den Timer. Die Liste sortiert sich automatisch nach der längsten Zeit.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Aufgabe hinzufügen'),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickCategoryBar extends StatelessWidget {
  const _QuickCategoryBar({
    required this.runningTaskName,
    required this.onSelect,
  });

  final String? runningTaskName;
  final void Function(String) onSelect;

  static const List<String> categories = <String>[
    'Sport', 'Lesen', 'Arbeiten', 'Lernen'
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: categories.map((String c) {
        final bool isActive = runningTaskName != null && runningTaskName!.toLowerCase() == c.toLowerCase();
        return ChoiceChip(
          label: Text(c),
          selected: isActive,
          onSelected: (_) => onSelect(c),
        );
      }).toList(),
    );
  }
}

extension _IterableFirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final Iterator<T> iterator = this.iterator;
    if (iterator.moveNext()) return iterator.current;
    return null;
  }
}

class _DonutSlice {
  _DonutSlice({required this.label, required this.value, required this.color});

  final String label;
  final Duration value;
  Color color;
}

class _DonutChartPainter extends CustomPainter {
  _DonutChartPainter({required this.slices, required this.backgroundColor});

  final List<_DonutSlice> slices;
  final Color backgroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    final double thickness = size.shortestSide * 0.18;
    final double radius = size.shortestSide / 2 - thickness / 2;
    final Offset center = Offset(size.width / 2, size.height / 2);
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    final Paint backgroundPaint =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness
          ..color = backgroundColor;

    // Draw background ring
    canvas.drawArc(rect, 0, 2 * math.pi, false, backgroundPaint);

    final Duration total = slices.fold<Duration>(
      Duration.zero,
      (p, s) => p + s.value,
    );
    if (total <= Duration.zero) return;

    double startAngle = -math.pi / 2; // start at top
    for (final _DonutSlice s in slices) {
      final double sweep =
          (s.value.inMilliseconds / total.inMilliseconds) * 2 * math.pi;
      final Paint segmentPaint =
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = thickness
            ..strokeCap = StrokeCap.butt
            ..color = s.color;
      canvas.drawArc(rect, startAngle, sweep, false, segmentPaint);
      startAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutChartPainter oldDelegate) {
    if (oldDelegate.slices.length != slices.length) return true;
    for (int i = 0; i < slices.length; i++) {
      if (oldDelegate.slices[i].label != slices[i].label) return true;
      if (oldDelegate.slices[i].value != slices[i].value) return true;
      if (oldDelegate.slices[i].color != slices[i].color) return true;
    }
    return false;
  }
}

class _DonutLegend extends StatelessWidget {
  const _DonutLegend({required this.slices, required this.formatDuration});

  final List<_DonutSlice> slices;
  final String Function(Duration) formatDuration;

  @override
  Widget build(BuildContext context) {
    final Duration total = slices.fold<Duration>(
      Duration.zero,
      (p, s) => p + s.value,
    );
    return Column(
      children:
          slices.map((s) {
            final double percent =
                total.inMilliseconds == 0
                    ? 0
                    : (s.value.inMilliseconds / total.inMilliseconds) * 100;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: s.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      s.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${percent.toStringAsFixed(1)}% · ${formatDuration(s.value)}',
                  ),
                ],
              ),
            );
          }).toList(),
    );
  }
}

class StatisticsPage extends StatefulWidget {
  const StatisticsPage({
    super.key,
    required this.sessions,
    required this.colorForTask,
  });

  final List<TaskSession> sessions;
  final Color Function(String) colorForTask;

  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

enum StatsRange { days7, days30 }

class _StatisticsPageState extends State<StatisticsPage> {
  StatsRange _range = StatsRange.days7;

  DateTime get _now => DateTime.now();
  DateTime _strip(DateTime d) => DateTime(d.year, d.month, d.day);

  String _formatDuration(Duration d) {
    final int hours = d.inHours;
    final int minutes = d.inMinutes.remainder(60);
    final int seconds = d.inSeconds.remainder(60);
    String two(int n) => n.toString().padLeft(2, '0');
    if (hours > 0) {
      return '${two(hours)}:${two(minutes)}:${two(seconds)} h';
    }
    return '${two(minutes)}:${two(seconds)} min';
  }

  @override
  Widget build(BuildContext context) {
    final DateTime end = _strip(_now).add(const Duration(days: 1));
    final int length = _range == StatsRange.days7 ? 7 : 30;
    final DateTime start = _strip(end.subtract(Duration(days: length)));

    final Map<String, List<Duration>> series = _buildDailySeries(start, end, length);
    final List<MapEntry<String, int>> totals = series.entries
        .map((e) => MapEntry<String, int>(e.key, e.value.fold<int>(0, (p, d) => p + d.inMinutes)))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final List<String> top = totals.take(5).map((e) => e.key).toList();

    final List<Duration> dailyTotals = _buildDailyTotals(series, length);
    final bool hasAnyData = dailyTotals.any((d) => d > Duration.zero) || top.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Statistiken'),
        actions: <Widget>[
          SegmentedButton<StatsRange>(
            segments: const <ButtonSegment<StatsRange>>[
              ButtonSegment<StatsRange>(value: StatsRange.days7, label: Text('7T')),
              ButtonSegment<StatsRange>(value: StatsRange.days30, label: Text('30T')),
            ],
            selected: <StatsRange>{_range},
            onSelectionChanged: (Set<StatsRange> v) => setState(() => _range = v.first),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: hasAnyData
                  ? LineChart(_buildLineChartData(series, top, start, length, dailyTotals))
                  : Center(child: Text('Keine Daten im ausgewählten Zeitraum', style: Theme.of(context).textTheme.bodyLarge)),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text('Gesamt'),
                  ],
                ),
                ...top.map((task) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: widget.colorForTask(task),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(task),
                  ],
                );
              }).toList(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Map<String, List<Duration>> _buildDailySeries(DateTime start, DateTime end, int length) {
    final Map<String, List<Duration>> perTaskPerDay = <String, List<Duration>>{};
    for (final TaskSession s in widget.sessions) {
      final DateTime sEnd = s.end ?? _now;
      DateTime curStart = s.start.isBefore(start) ? start : s.start;
      DateTime curEnd = sEnd.isAfter(end) ? end : sEnd;
      if (!curEnd.isAfter(curStart)) continue;

      DateTime dayCursor = _strip(curStart);
      while (dayCursor.isBefore(_strip(curEnd))) {
        final DateTime dayStart = dayCursor;
        final DateTime dayEnd = dayStart.add(const Duration(days: 1));
        final DateTime segStart = curStart.isAfter(dayStart) ? curStart : dayStart;
        final DateTime segEnd = curEnd.isBefore(dayEnd) ? curEnd : dayEnd;
        if (segEnd.isAfter(segStart)) {
          final int dayIndex = dayEnd.difference(start).inDays - 1;
          perTaskPerDay.putIfAbsent(s.taskName, () => List<Duration>.filled(length, Duration.zero));
          final List<Duration> arr = perTaskPerDay[s.taskName]!;
          final Duration add = segEnd.difference(segStart);
          if (dayIndex >= 0 && dayIndex < arr.length) {
            arr[dayIndex] = arr[dayIndex] + add;
          }
        }
        dayCursor = dayCursor.add(const Duration(days: 1));
      }
    }
    return perTaskPerDay;
  }

  List<Duration> _buildDailyTotals(Map<String, List<Duration>> series, int length) {
    final List<Duration> totals = List<Duration>.filled(length, Duration.zero);
    for (final List<Duration> values in series.values) {
      for (int i = 0; i < length; i++) {
        totals[i] = totals[i] + (i < values.length ? values[i] : Duration.zero);
      }
    }
    return totals;
  }

  LineChartData _buildLineChartData(
    Map<String, List<Duration>> series,
    List<String> top,
    DateTime start,
    int length,
    List<Duration> dailyTotals,
  ) {
    final List<FlSpot> xTicks = <FlSpot>[];
    for (int i = 0; i < length; i++) {
      xTicks.add(FlSpot(i.toDouble(), 0));
    }

    final List<LineChartBarData> lines = <LineChartBarData>[];
    // Total line first (secondary color)
    final List<FlSpot> totalSpots = <FlSpot>[];
    for (int i = 0; i < dailyTotals.length; i++) {
      totalSpots.add(FlSpot(i.toDouble(), dailyTotals[i].inMinutes.toDouble()));
    }
    lines.add(
      LineChartBarData(
        spots: totalSpots,
        isCurved: true,
        color: Theme.of(context).colorScheme.secondary,
        barWidth: 3,
        dashArray: [6, 4],
        dotData: const FlDotData(show: false),
      ),
    );

    for (final String task in top) {
      final List<Duration> values = series[task] ?? List<Duration>.filled(length, Duration.zero);
      final List<FlSpot> spots = <FlSpot>[];
      for (int i = 0; i < values.length; i++) {
        spots.add(FlSpot(i.toDouble(), values[i].inMinutes.toDouble()));
      }
      lines.add(
        LineChartBarData(
          spots: spots,
          isCurved: true,
          color: widget.colorForTask(task),
          barWidth: 3,
          dotData: const FlDotData(show: false),
        ),
      );
    }

    return LineChartData(
      lineBarsData: lines,
      gridData: const FlGridData(show: true),
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: (length / 6).ceilToDouble(),
            getTitlesWidget: (double value, TitleMeta meta) {
              final int idx = value.toInt();
              if (idx < 0 || idx >= length) return const SizedBox.shrink();
              final DateTime d = start.add(Duration(days: idx + 1));
              return SideTitleWidget(
                axisSide: meta.axisSide,
                child: Text('$d.day.$d.month'),
              );
            },
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40,
            interval: 60,
            getTitlesWidget: (double value, TitleMeta meta) {
              return SideTitleWidget(
                axisSide: meta.axisSide,
                child: Text('${value.toInt()}m'),
              );
            },
          ),
        ),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(
        show: true,
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      minY: 0,
    );
  }
}
