import 'package:flutter/material.dart';

class BalanceDisplay extends StatelessWidget {
  final String balance;

  const BalanceDisplay({super.key, required this.balance});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text(
          "Current Balance",
          style: TextStyle(color: Colors.grey, fontSize: 16),
        ),
        const SizedBox(height: 8),
        Text(
          balance,
          style: const TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.bold,
            color: Colors.blueAccent,
          ),
        ),
      ],
    );
  }
}