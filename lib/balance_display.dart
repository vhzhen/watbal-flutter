import 'package:flutter/material.dart';

class BalanceDisplay extends StatelessWidget {
  final String balance;

  const BalanceDisplay({super.key, required this.balance});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.blueAccent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.blueAccent.withOpacity(0.2)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "FLEX DOLLARS",
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: Colors.blueGrey,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            balance,
            style: const TextStyle(
              fontSize: 52,
              fontWeight: FontWeight.bold,
              color: Colors.blueAccent,
            ),
          ),
        ],
      ),
    );
  }
}