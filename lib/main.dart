import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hearing Test',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.amber,
        scaffoldBackgroundColor: Colors.black26,
      ),
      home: const HearingTestScreen(),
    );
  }
}

class WDRCConstants {
  static const int GAIN_SCALE = 1 << 20;
  static const int GAIN_MAX_INT = (1 << 23) - 1;
  static const int GAIN_MIN_INT = -(1 << 23);
  static const int LUT_SIZE = 1024;
  static const double DBFS_TO_SPL_OFFSET = 100.0;
  static const double MIN_SPL = 40.0;
  static const double MAX_SPL = 100.0;
  static const double MPO_LIMIT = 110.0;
  static const List<int> CENTER_FREQS = [250, 500, 750, 1000, 1500, 2000, 3000, 4000, 6000, 8000];
}

-class BLEConstants {
  static const int TARGET_MTU = 512;           // Request 512 byte MTU
  static const int ENTRIES_PER_PACKET = 120;   // 120 entries * 3 bytes = 360 bytes payload
  static const int FLOW_CONTROL_INTERVAL = 10; // Delay every N packets
  static const int FLOW_CONTROL_DELAY_MS = 1;  // 1ms delay for flow control
}

class WDRCParams {
  final double tk1;
  final double tk2;
  final double cr1;
  final double cr2;
  final double mpo;
  final double atkMs;
  final double relMs;
  final double gsoft;

  WDRCParams({
    required this.tk1,
    required this.tk2,
    required this.cr1,
    required this.cr2,
    required this.mpo,
    required this.atkMs,
    required this.relMs,
    required this.gsoft,
  });
}

-class HearingProfile {
  String name;
  Map<int, double> hlResults;
  Map<int, double> uclResults;
  Map<int, List<int>> gainLUTs;

  HearingProfile({
    required this.name,
    required this.hlResults,
    required this.uclResults,
    required this.gainLUTs,
  });
}

class WDRCFittingEngine {
-  static const double OVERALL_GAIN_BOOST = 50.0;

  static WDRCParams deriveParams({required double hl, required double ucl}) {

    const double softSL = 35.0;
    const double midSL = 45.0;
    const double safetyMargin = 3.0;


    const double lsoftIn = 30.0;  // 35→30 dB
    const double lmidIn = 55.0;   // 60→55 dB
    const double lloudIn = 80.0;  // 85→80 dB

    double lsoftOut = hl + softSL + OVERALL_GAIN_BOOST;
    double lmidOut = min(hl + midSL + OVERALL_GAIN_BOOST, ucl - 5.0);
    double lloudOut = ucl - safetyMargin;

    if (lsoftOut > lmidOut) lsoftOut = lmidOut - 3.0;
    if (lmidOut > lloudOut) lmidOut = lloudOut - 3.0;

    double tk1 = lsoftIn;
    double tk2 = lmidIn;
    double gsoft = lsoftOut - lsoftIn;


    if (gsoft < 15.0) gsoft = 15.0;

    double loutTk1 = tk1 + gsoft;
    double denom1 = max(lmidOut - loutTk1, 0.001);
    double cr1 = (lmidIn - tk1) / denom1;

    double loutTk2 = loutTk1 + (tk2 - tk1) / cr1;
    double denom2 = max(lloudOut - loutTk2, 0.001);
    double cr2 = (lloudIn - tk2) / denom2;

    double mpoVal = min(lloudOut, WDRCConstants.MPO_LIMIT);


    double atkMs, relMs;
    if (hl < 30.0) {
      atkMs = 5.0;   // 10→5
      relMs = 100.0; // 150→100
    } else if (hl < 60.0) {
      atkMs = 3.0;   // 5→3
      relMs = 75.0;  // 100→75
    } else {
      atkMs = 1.0;   // 2→1
      relMs = 50.0;  // 60→50
    }

    return WDRCParams(
      tk1: tk1,
      tk2: tk2,
      cr1: cr1.clamp(1.0, 8.0),
      cr2: cr2.clamp(1.0, 15.0),
      mpo: mpoVal,
      atkMs: atkMs,
      relMs: relMs,
      gsoft: gsoft,
    );
  }

  static double computeStaticGainDb(double envDbfs, WDRCParams params) {
    double x = envDbfs + WDRCConstants.DBFS_TO_SPL_OFFSET;
    x = x.clamp(WDRCConstants.MIN_SPL, WDRCConstants.MAX_SPL);

    if (x <= params.tk1) return params.gsoft;

    if (x <= params.tk2) {
      double lout = (params.tk1 + params.gsoft) + (x - params.tk1) / params.cr1;
      return lout - x;
    }

    double loutTk1 = params.tk1 + params.gsoft;
    double loutTk2 = loutTk1 + (params.tk2 - params.tk1) / params.cr1;
    double lout = loutTk2 + (x - params.tk2) / params.cr2;

    if (lout > params.mpo) lout = params.mpo;
    return lout - x;
  }

  static List<int> generateGainLUT(WDRCParams params) {
    List<int> lut = [];
    for (int i = 0; i < WDRCConstants.LUT_SIZE; i++) {
      double envLin = ((i << 13) + (1 << 12)) / 8388608.0;
      double envDb = 20.0 * log(envLin) / ln10;
      double gainDb = computeStaticGainDb(envDb, params);
      double gainLin = pow(10.0, gainDb / 20.0).toDouble();
      int valFixed = (gainLin * WDRCConstants.GAIN_SCALE).round();
      valFixed = valFixed.clamp(WDRCConstants.GAIN_MIN_INT, WDRCConstants.GAIN_MAX_INT);
      int finalVal = valFixed & 0xFFFFFF;
      lut.add(finalVal);
    }
    return lut;
  }
}

class HearingTestScreen extends StatefulWidget {
  const HearingTestScreen({super.key});

  @override
  State<HearingTestScreen> createState() => _HearingTestScreenState();
}

class _HearingTestScreenState extends State<HearingTestScreen> {
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  BluetoothDevice? device;
  BluetoothCharacteristic? txChar;
  bool isConnected = false;
  String bleStatus = "Searching for AEU...";

  // *** OPTIMIZATION: Track negotiated MTU ***
  int negotiatedMtu = 23;  // Default BLE MTU

  static const String SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef0";
  static const String CHAR_UUID = "abcdef01-1234-5678-1234-56789abcdef0";

  int currentBandIndex = 0;
  double currentDb = 10.0;
  bool isTestRunning = false;
  bool isPlayingTone = false;
  bool isHLPhase = true;

  Map<int, double> hlResults = {};
  Map<int, double> uclResults = {};
  Map<int, WDRCParams> wdrcParams = {};
  Map<int, List<int>> gainLUTs = {};

  bool isSending = false;
  int sendProgress = 0;


  List<HearingProfile?> storedProfiles = [null, null, null];

  @override
  void initState() {
    super.initState();
    _player.openPlayer();
    initBLE();
  }

  @override
  void dispose() {
    _player.closePlayer();
    device?.disconnect();
    super.dispose();
  }

  Future<void> initBLE() async {
    setState(() => bleStatus = "Waiting for Permissions");
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location
    ].request();

    setState(() => bleStatus = "Searching for AEU...");

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

    FlutterBluePlus.scanResults.listen((results) async {
      for (var r in results) {
        if (r.device.platformName.contains("ESP32_HEARING_BLE")) {
          await FlutterBluePlus.stopScan();
          connectToDevice(r.device);
          break;
        }
      }
    });

    Future.delayed(const Duration(seconds: 16), () {
      if (!isConnected && mounted) {
        setState(() => bleStatus = "AEU is not found");
      }
    });
  }

  // *** OPTIMIZED: Connection with MTU negotiation ***
  Future<void> connectToDevice(BluetoothDevice d) async {
    setState(() => bleStatus = "Connecting...");
    try {
      await d.connect(autoConnect: false, timeout: const Duration(seconds: 8));
      device = d;

      // *** OPTIMIZATION: Request high MTU immediately after connection ***
      setState(() => bleStatus = "Negotiating MTU...");
      try {
        negotiatedMtu = await d.requestMtu(BLEConstants.TARGET_MTU);
        print("⚡ MTU negotiated: $negotiatedMtu bytes");
      } catch (e) {
        print("⚠️ MTU negotiation failed, using default: $e");
        negotiatedMtu = 23;
      }

      List<BluetoothService> services = await d.discoverServices();
      for (var s in services) {
        if (s.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase()) {
          for (var c in s.characteristics) {
            if (c.uuid.toString().toLowerCase() == CHAR_UUID.toLowerCase()) {
              txChar = c;
              await c.setNotifyValue(true);
              c.onValueReceived.listen((data) {
                print(" ESP32: ${utf8.decode(data)}");
              });
              setState(() {
                isConnected = true;
                bleStatus = "AEU Connected (MTU: $negotiatedMtu)";
              });
              return;
            }
          }
        }
      }
      setState(() => bleStatus = "Service is not found");
    } catch (e) {
      setState(() => bleStatus = "Connection error");
    }
  }

  Future<void> playTone(double frequency, double dbLevel) async {
    setState(() => isPlayingTone = true);

    int sampleRate = 44100;
    int durationMs = 1000;
    int totalSamples = (sampleRate * durationMs / 1000).toInt();
    double amplitude = (pow(10, dbLevel / 20).toDouble() / 10000).clamp(0.0, 1.0);

    List<int> samples = List.generate(totalSamples, (i) {
      return (sin(2 * pi * frequency * i / sampleRate) * amplitude * 32767).toInt();
    });

    Uint8List buffer = Int16List.fromList(samples).buffer.asUint8List();

    await _player.startPlayer(
      fromDataBuffer: buffer,
      codec: Codec.pcm16,
      sampleRate: sampleRate,
      numChannels: 1,
    );

    await Future.delayed(Duration(milliseconds: durationMs));
    await _player.stopPlayer();

    setState(() => isPlayingTone = false);
  }

  void startTest() {
    if (!isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AEU is not connected')),
      );
      return;
    }

    setState(() {
      isTestRunning = true;
      currentBandIndex = 0;
      hlResults.clear();
      uclResults.clear();
      wdrcParams.clear();
      gainLUTs.clear();
      currentDb = 10.0;
      isHLPhase = true;
    });

    playCurrentFrequency();
  }

  void playCurrentFrequency() async {
    if (currentBandIndex >= WDRCConstants.CENTER_FREQS.length) {
      finishTest();
      return;
    }
    int freq = WDRCConstants.CENTER_FREQS[currentBandIndex];
    await playTone(freq.toDouble(), currentDb);
  }

  void userHeard() {
    if (isPlayingTone) return;
    int freq = WDRCConstants.CENTER_FREQS[currentBandIndex];

    if (isHLPhase) {
      hlResults[freq] = currentDb;
      print(' HL: $freq Hz - ${currentDb} dB');

      setState(() {
        isHLPhase = false;
        currentDb = 80.0;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$freq Hz: HL=${hlResults[freq]?.toInt()} dB → UCL testi'),
          duration: const Duration(seconds: 1),
        ),
      );

      playCurrentFrequency();
    } else {
      currentDb += 5.0;
      if (currentDb > 110.0) {
        uclResults[freq] = 110.0;
        print(' UCL: $freq Hz - Max (110 dB)');
        moveToNextFrequency();
      } else {
        playCurrentFrequency();
      }
    }
  }

  void userDidNotHear() {
    if (isPlayingTone) return;
    int freq = WDRCConstants.CENTER_FREQS[currentBandIndex];

    if (isHLPhase) {
      currentDb += 5.0;
      if (currentDb > 90.0) {
        hlResults[freq] = 90.0;
        print(' HL: $freq Hz - Max (90 dB)');
        setState(() {
          isHLPhase = false;
          currentDb = 90.0;
        });
      }
      playCurrentFrequency();
    } else {
      uclResults[freq] = currentDb;
      print(' UCL: $freq Hz - ${currentDb} dB');
      moveToNextFrequency();
    }
  }

  void moveToNextFrequency() {
    int freq = WDRCConstants.CENTER_FREQS[currentBandIndex];
    print(' $freq Hz: HL=${hlResults[freq]}dB, UCL=${uclResults[freq]}dB');

    setState(() {
      currentBandIndex++;
      isHLPhase = true;
      currentDb = 10.0;
    });

    playCurrentFrequency();
  }

  void finishTest() {
    print('\n=== WDRC FITTING ===');

    for (int i = 0; i < WDRCConstants.CENTER_FREQS.length; i++) {
      int freq = WDRCConstants.CENTER_FREQS[i];
      double hl = hlResults[freq] ?? 25.0;
      double ucl = uclResults[freq] ?? 100.0;

      WDRCParams params = WDRCFittingEngine.deriveParams(hl: hl, ucl: ucl);
      wdrcParams[freq] = params;

      List<int> lut = WDRCFittingEngine.generateGainLUT(params);
      gainLUTs[freq] = lut;

      print('Band $i ($freq Hz): HL=$hl, UCL=$ucl, GSOFT=${params.gsoft.toStringAsFixed(1)}');
    }
    print('====================\n');

    setState(() {
      isTestRunning = false;
    });

    showResultsDialog();
  }

  void showSaveProfileDialog() {
    TextEditingController nameController = TextEditingController();
    int? selectedSlot;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Save Profile'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Profile Name',
                    hintText: 'Enter profile name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('Select Slot:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                ...List.generate(3, (index) {
                  bool hasProfile = storedProfiles[index] != null;
                  return RadioListTile<int>(
                    title: Text(
                      hasProfile
                          ? 'Slot ${index + 1}: ${storedProfiles[index]!.name}'
                          : 'Slot ${index + 1}: Empty',
                      style: TextStyle(
                        color: hasProfile ? Colors.grey : Colors.grey,
                      ),
                    ),
                    subtitle: hasProfile
                        ? Text('Will be overwritten', style: TextStyle(color: Colors.orange[700], fontSize: 12))
                        : null,
                    value: index,
                    groupValue: selectedSlot,
                    onChanged: (value) {
                      setDialogState(() => selectedSlot = value);
                    },
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selectedSlot != null && nameController.text.isNotEmpty
                  ? () {
                setState(() {
                  storedProfiles[selectedSlot!] = HearingProfile(
                    name: nameController.text,
                    hlResults: Map.from(hlResults),
                    uclResults: Map.from(uclResults),
                    gainLUTs: Map.from(gainLUTs),
                  );
                });
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Profile "${nameController.text}" saved to Slot ${selectedSlot! + 1}'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
                  : null,
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void showSelectProfileDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            HearingProfile? profile = storedProfiles[index];
            bool hasProfile = profile != null;

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 5),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: hasProfile ? Colors.grey : Colors.grey[300],
                  child: Text('${index + 1}', style: TextStyle(color: hasProfile ? Colors.white : Colors.grey)),
                ),
                title: Text(
                  hasProfile ? profile.name : 'Empty Slot',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: hasProfile ? Colors.black : Colors.grey,
                  ),
                ),
                trailing: hasProfile
                    ? IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                  onPressed: () {
                    setState(() => storedProfiles[index] = null);
                    Navigator.pop(context);
                    showSelectProfileDialog();
                  },
                )
                    : null,
                onTap: hasProfile
                    ? () {
                  Navigator.pop(context);
                  gainLUTs = Map.from(profile.gainLUTs);
                  sendDataToESP();
                }
                    : null,
              ),
            );
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> sendDataToESP() async {
    if (txChar == null || !isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AEU is not connected')),
      );
      return;
    }

    setState(() {
      isSending = true;
      sendProgress = 0;
    });

    final stopwatch = Stopwatch()..start();

    try {
      print('\n=== HIGH-SPEED WDRC LUT TRANSFER ===');
      print('⚡ MTU: $negotiatedMtu bytes');
      print('⚡ Entries per packet: ${BLEConstants.ENTRIES_PER_PACKET}');

      const int cmdStart = 0x01;
      const int cmdBandData = 0x02;
      const int cmdEnd = 0x03;

      await txChar!.write([cmdStart, 0x00, 0x00, 0x00], withoutResponse: false);
      print('START sent');
      await Future.delayed(const Duration(milliseconds: 100));

      int totalBands = WDRCConstants.CENTER_FREQS.length;
      int packetCount = 0;

      for (int bandIdx = 0; bandIdx < totalBands; bandIdx++) {
        int freq = WDRCConstants.CENTER_FREQS[bandIdx];
        List<int> lut = gainLUTs[freq]!;
        print('Band $bandIdx ($freq Hz)...');

        const int entriesPerPacket = BLEConstants.ENTRIES_PER_PACKET;

        for (int offset = 0; offset < lut.length; offset += entriesPerPacket) {
          int endOffset = min(offset + entriesPerPacket, lut.length);

          List<int> packet = [
            cmdBandData,
            bandIdx,
            (offset >> 8) & 0xFF,
            offset & 0xFF,
          ];

          for (int e = offset; e < endOffset; e++) {
            int val = lut[e];
            packet.add((val >> 16) & 0xFF);
            packet.add((val >> 8) & 0xFF);
            packet.add(val & 0xFF);
          }

          // *** OPTIMIZATION: Write without response for speed ***
          await txChar!.write(packet, withoutResponse: true);
          packetCount++;

          // *** OPTIMIZATION: Minimal flow control - delay every N packets ***
          if (packetCount % BLEConstants.FLOW_CONTROL_INTERVAL == 0) {
            await Future.delayed(Duration(milliseconds: BLEConstants.FLOW_CONTROL_DELAY_MS));
          }
        }

        setState(() {
          sendProgress = ((bandIdx + 1) / totalBands * 100).round();
        });

        print('  Band $bandIdx ✅');
      }

      // *** Small delay before END to ensure all packets are processed ***
      await Future.delayed(const Duration(milliseconds: 50));

      // *** Send END command (with response to ensure completion) ***
      await txChar!.write([cmdEnd, 0x00, 0x00, 0x00], withoutResponse: false);

      stopwatch.stop();
      print('END sent');
      print('⚡ Transfer time: ${stopwatch.elapsedMilliseconds} ms');
      print('⚡ Packets sent: $packetCount');
      print('========================\n');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚡ AEU updated in ${stopwatch.elapsedMilliseconds}ms'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      print(" Error: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => isSending = false);
    }
  }

  void showResultsDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Test Completed'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: Column(
            children: [
              const Text(
                'WDRC Hearing Profile',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: CustomPaint(
                    size: const Size(double.infinity, 200),
                    painter: WDRCAudiogramPainter(hlResults, uclResults),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(width: 20, height: 3, color: Colors.blue),
                  const SizedBox(width: 5),
                  const Text('HL', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 20),
                  Container(width: 20, height: 3, color: Colors.red),
                  const SizedBox(width: 5),
                  const Text('UCL', style: TextStyle(fontSize: 12)),
                ],
              ),
              const SizedBox(height: 15),
              if (isSending)
                Column(
                  children: [
                    LinearProgressIndicator(value: sendProgress / 100),
                    const SizedBox(height: 10),
                    Text('Sending... %$sendProgress'),
                  ],
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        showSaveProfileDialog();
                      },
                      icon: const Icon(Icons.save),
                      label: const Text('Save'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        sendDataToESP();
                      },
                      icon: const Icon(Icons.send),
                      label: const Text('Send AEU'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  bool get hasStoredProfile => storedProfiles.any((p) => p != null);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '  ',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.grey[700],
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 15),
            child: Row(
              children: [
                Icon(
                  isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: isConnected ? Colors.white : Colors.red,
                  size: 28,
                ),
                if (!isConnected)
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: initBLE,
                  ),
              ],
            ),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.grey[700]!, Colors.white],
            stops: const [0.0, 0.3],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blue.withOpacity(0.3),
                      blurRadius: 30,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: Icon(Icons.hearing, size: 100, color: Colors.blue[600]),
              ),
              const SizedBox(height: 20),
              Text(
                bleStatus,
                style: TextStyle(
                  fontSize: 16,
                  color: isConnected ? Colors.green[700] : Colors.red[700],
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '10 Band WDRC',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(height: 40),

              if (isTestRunning) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.grey.withOpacity(0.2),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: isHLPhase ? Colors.blue[100] : Colors.orange[100],
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          isHLPhase ? 'HL Test' : ' UCL Test',
                          style: TextStyle(
                            fontSize: 14,
                            color: isHLPhase ? Colors.blue[800] : Colors.orange[800],
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 15),
                      Text(
                        isPlayingTone ? 'Sound playing' : ' Ready',
                        style: TextStyle(fontSize: 24, color: Colors.blue[900]),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${WDRCConstants.CENTER_FREQS[currentBandIndex]} Hz',
                        style: TextStyle(fontSize: 18, color: Colors.blue[700]),
                      ),
                      Text(
                        '${currentDb.toStringAsFixed(0)} dB',
                        style: TextStyle(fontSize: 16, color: Colors.blue[600]),
                      ),
                      Text(
                        '${currentBandIndex + 1} / ${WDRCConstants.CENTER_FREQS.length}',
                        style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: isPlayingTone ? null : userHeard,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green[700],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: Column(
                        children: [
                          const Icon(Icons.thumb_up, size: 35),
                          const SizedBox(height: 5),
                          Text(
                            isHLPhase ? 'Heard' : 'Comfortable',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 30),
                    ElevatedButton(
                      onPressed: isPlayingTone ? null : userDidNotHear,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red[700],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: Column(
                        children: [
                          const Icon(Icons.thumb_down, size: 35),
                          const SizedBox(height: 5),
                          Text(
                            isHLPhase ? 'Not Heared' : 'Uncomfortable',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ] else ...[
                Column(
                  children: [
                    ElevatedButton(
                      onPressed: isConnected ? startTest : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isConnected ? Colors.blue[600] : Colors.grey,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 30),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.play_arrow, size: 40),
                          SizedBox(width: 10),
                          Text(
                            'Start Test',
                            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    if (hasStoredProfile) ...[
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: isConnected ? showSelectProfileDialog : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isConnected ? Colors.green[400] : Colors.grey,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.send, size: 30),
                            const SizedBox(width: 10),
                            Text(
                              'Send Profile (${storedProfiles.where((p) => p != null).length}/3)',
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Registered Profile is Available',
                        style: TextStyle(color: Colors.green[400], fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class WDRCAudiogramPainter extends CustomPainter {
  final Map<int, double> hlResults;
  final Map<int, double> uclResults;

  WDRCAudiogramPainter(this.hlResults, this.uclResults);

  @override
  void paint(Canvas canvas, Size size) {
    final hlPaint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final uclPaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final hlPointPaint = Paint()
      ..color = Colors.blue[700]!
      ..style = PaintingStyle.fill;

    final uclPointPaint = Paint()
      ..color = Colors.red[400]!
      ..style = PaintingStyle.fill;

    final gridPaint = Paint()
      ..color = Colors.grey[300]!
      ..strokeWidth = 1;

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    const double leftMargin = 30;
    const double rightMargin = 5;
    const double topMargin = 20;
    const double bottomMargin = 35;

    double graphWidth = size.width - leftMargin - rightMargin;
    double graphHeight = size.height - topMargin - bottomMargin;

    for (int db = 0; db <= 100; db += 20) {
      double y = topMargin + (db / 100) * graphHeight;

      canvas.drawLine(
        Offset(leftMargin, y),
        Offset(size.width - rightMargin, y),
        gridPaint,
      );

      textPainter.text = TextSpan(
        text: '$db',
        style: TextStyle(color: Colors.grey[600], fontSize: 9),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(2, y - 5));
    }

    for (int i = 0; i < WDRCConstants.CENTER_FREQS.length; i++) {
      int freq = WDRCConstants.CENTER_FREQS[i];
      double x = leftMargin + (i / (WDRCConstants.CENTER_FREQS.length - 1)) * graphWidth;

      canvas.drawLine(
        Offset(x, topMargin),
        Offset(x, topMargin + graphHeight),
        gridPaint..color = Colors.grey[200]!,
      );

      String freqLabel = freq >= 1000 ? '${freq ~/ 1000}k' : '$freq';
      textPainter.text = TextSpan(
        text: freqLabel,
        style: TextStyle(color: Colors.grey[700], fontSize: 8, fontWeight: FontWeight.w500),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x - textPainter.width / 2, topMargin + graphHeight + 3));
    }

    if (hlResults.isNotEmpty) {
      final hlPath = Path();
      bool first = true;
      int index = 0;

      for (int freq in WDRCConstants.CENTER_FREQS) {
        if (hlResults.containsKey(freq)) {
          double x = leftMargin + (index / (WDRCConstants.CENTER_FREQS.length - 1)) * graphWidth;
          double y = topMargin + (hlResults[freq]! / 100) * graphHeight;

          if (first) {
            hlPath.moveTo(x, y);
            first = false;
          } else {
            hlPath.lineTo(x, y);
          }
          canvas.drawCircle(Offset(x, y), 5, hlPointPaint);

          textPainter.text = TextSpan(
            text: '${hlResults[freq]!.toInt()}',
            style: const TextStyle(color: Colors.blue, fontSize: 8, fontWeight: FontWeight.bold),
          );
          textPainter.layout();
          textPainter.paint(canvas, Offset(x - textPainter.width / 2, y - 14));
        }
        index++;
      }
      canvas.drawPath(hlPath, hlPaint);
    }

    if (uclResults.isNotEmpty) {
      final uclPath = Path();
      bool first = true;
      int index = 0;

      for (int freq in WDRCConstants.CENTER_FREQS) {
        if (uclResults.containsKey(freq)) {
          double x = leftMargin + (index / (WDRCConstants.CENTER_FREQS.length - 1)) * graphWidth;
          double y = topMargin + (uclResults[freq]! / 100) * graphHeight;

          if (first) {
            uclPath.moveTo(x, y);
            first = false;
          } else {
            uclPath.lineTo(x, y);
          }
          canvas.drawCircle(Offset(x, y), 4, uclPointPaint);

-          textPainter.text = TextSpan(
            text: '${uclResults[freq]!.toInt()}',
            style: TextStyle(color: Colors.red[700], fontSize: 8, fontWeight: FontWeight.bold),
          );
          textPainter.layout();
          textPainter.paint(canvas, Offset(x - textPainter.width / 2, y + 7));
        }
        index++;
      }
      canvas.drawPath(uclPath, uclPaint);
    }

    textPainter.text = TextSpan(
      text: 'dB',
      style: TextStyle(color: Colors.grey[700], fontSize: 9, fontWeight: FontWeight.bold),
    );
    textPainter.layout();
    textPainter.paint(canvas, const Offset(2, 2));

    textPainter.text = TextSpan(
      text: 'Hz',
      style: TextStyle(color: Colors.grey[700], fontSize: 9, fontWeight: FontWeight.bold),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(size.width - 15, topMargin + graphHeight + 18));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}