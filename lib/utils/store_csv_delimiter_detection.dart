class StoreCsvDelimiterDetection {
  const StoreCsvDelimiterDetection._();

  static String choose({
    required List<String> sampleLines,
    required String fallback,
    required List<String> Function(String line, String delimiter) parseLine,
    required int Function(List<String> fields) scoreHeader,
  }) {
    var bestDelimiter = fallback;
    var bestScore = 0;
    var bestConsistentRows = 0;
    for (final delimiter in [',', ';', '\t']) {
      var delimiterScore = 0;
      for (final line in sampleLines) {
        if (line.trim().isEmpty) continue;
        final score = scoreHeader(parseLine(line, delimiter));
        if (score > delimiterScore) delimiterScore = score;
      }
      final consistentRows = _longestConsistentRowRun(
        sampleLines,
        delimiter,
        parseLine,
      );
      if (delimiterScore > bestScore ||
          (delimiterScore == bestScore &&
              consistentRows > bestConsistentRows)) {
        bestDelimiter = delimiter;
        bestScore = delimiterScore;
        bestConsistentRows = consistentRows;
      }
    }
    return bestDelimiter;
  }

  static int _longestConsistentRowRun(
    List<String> sampleLines,
    String delimiter,
    List<String> Function(String line, String delimiter) parseLine,
  ) {
    var bestRun = 0;
    var currentRun = 0;
    var currentWidth = 0;
    for (final line in sampleLines) {
      if (line.trim().isEmpty) continue;
      final width = parseLine(line, delimiter).length;
      if (width < 2) {
        currentRun = 0;
        currentWidth = 0;
      } else if (width == currentWidth) {
        currentRun++;
      } else {
        currentWidth = width;
        currentRun = 1;
      }
      if (currentRun > bestRun) bestRun = currentRun;
    }
    return bestRun;
  }
}
