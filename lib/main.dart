import 'package:flutter/material.dart';
import 'package:watbal/display_page.dart';
import 'package:watbal/loading_page.dart';

void main() => runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WatBalApp(),
    ));

class WatBalApp extends StatefulWidget {
  const WatBalApp({super.key});

  @override
  State<WatBalApp> createState() => _WatBalAppState();
}

class _WatBalAppState extends State<WatBalApp> {
  String? _balance;

  @override
  Widget build(BuildContext context) {
    if (_balance == null) {
      return LoadingPage(
        onLoaded: (balance) => setState(() => _balance = balance),
      );
    }
    return DisplayPage(
      balance: _balance!,
      onSessionLost: () => setState(() => _balance = null),
    );
  }
}
