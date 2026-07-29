param(
  [string]$BaseHref = '/app/'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$pubspec = Get-Content (Join-Path $projectRoot 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*([^\s]+)') {
  throw 'Unable to read the application version from pubspec.yaml.'
}

$releaseVersion = $Matches[1]
Push-Location $projectRoot
try {
  flutter build web --release --base-href $BaseHref --no-pub
  $bootstrap = Join-Path $projectRoot 'build\web\flutter_bootstrap.js'
  $index = Join-Path $projectRoot 'build\web\index.html'
  $source = Get-Content $bootstrap -Raw
  $source = $source.Replace('mainJsPath":"main.dart.js"', ('mainJsPath":"main.dart.js?v={0}"' -f $releaseVersion))
  Set-Content -LiteralPath $bootstrap -Value $source -NoNewline -Encoding utf8
  $indexSource = Get-Content $index -Raw
  $indexSource = $indexSource.Replace('__WEB_RELEASE__', $releaseVersion)
  Set-Content -LiteralPath $index -Value $indexSource -NoNewline -Encoding utf8
} finally {
  Pop-Location
}
