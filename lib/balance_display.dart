import 'package:flutter/material.dart';

class BalanceDisplay extends StatelessWidget {
  final String balance;

  const BalanceDisplay({super.key, required this.balance});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(
          "Current Balance",
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 16),
        ),
        const SizedBox(height: 8),
        Text(
          balance,
          style: TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.bold,
            color: scheme.primary,
          ),
        ),
      ],
    );
  }
}