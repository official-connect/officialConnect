import 'package:flutter/material.dart';
import 'package:official_connect/Providers/sisdata.dart';
import 'package:official_connect/Screens/login_screen/student_home/unified_screen.dart';
import 'package:official_connect/Widgets/loading_indicator.dart';
import 'package:provider/provider.dart';

class LoadingScreen extends StatefulWidget {
  const LoadingScreen({Key? key}) : super(key: key);

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  @override
  void initState() {
    super.initState();
    _navigateToUnifiedScreen();
  }

  Future<void> _navigateToUnifiedScreen() async {
    await Future.delayed(const Duration(milliseconds: 700), () async {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const Unified()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final sisData = Provider.of<SisData>(context);
    return Scaffold(
      backgroundColor: (sisData.darkMode)
          ? const Color(0xff101114)
          : Colors.white,
      body: const LoadingIndicator(),
    );
  }
}
