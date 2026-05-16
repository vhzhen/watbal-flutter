/// One row from the TouchNet transaction-history table.
class Transaction {
  final String dateTime;
  final String type;
  final String terminal;
  final String status;
  final String balance;
  final String units;
  final String amount;

  const Transaction({
    required this.dateTime,
    required this.type,
    required this.terminal,
    required this.status,
    required this.balance,
    required this.units,
    required this.amount,
  });

  /// True when money left the account (amount is negative, e.g. "$-10.00").
  bool get isDebit => amount.contains('-');

  /// "102 : ACCOUNT ADJUSTMENT" -> "ACCOUNT ADJUSTMENT"
  String get label {
    final i = type.indexOf(':');
    return (i >= 0 ? type.substring(i + 1) : type).trim();
  }

  /// "00024 : WEBAPPS" -> "WEBAPPS"
  String get terminalLabel {
    final i = terminal.indexOf(':');
    return (i >= 0 ? terminal.substring(i + 1) : terminal).trim();
  }
}
