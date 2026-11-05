class StoreSpreadsheetHeaderDetection {
  const StoreSpreadsheetHeaderDetection._();

  static int? findBestHeaderRow({
    required List<List<String>> rows,
    required int Function(List<String>) score,
    int maxRowsToScan = 20,
  }) {
    final scanLength = rows.length < maxRowsToScan
        ? rows.length
        : maxRowsToScan;
    int? bestIndex;
    var bestScore = -1;
    var bestColumnCount = -1;

    for (var index = 0; index < scanLength; index++) {
      final row = rows[index];
      if (row.every((cell) => cell.trim().isEmpty)) continue;
      final rowScore = score(row);
      final columnCount = row.where((cell) => cell.trim().isNotEmpty).length;
      if (bestIndex == null ||
          rowScore > bestScore ||
          (rowScore == bestScore && columnCount > bestColumnCount)) {
        bestIndex = index;
        bestScore = rowScore;
        bestColumnCount = columnCount;
      }
    }

    return bestIndex;
  }
}
