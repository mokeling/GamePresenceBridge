$ErrorActionPreference = 'SilentlyContinue'

$root = $PSScriptRoot
$path = Join-Path $root 'presence.txt'

# Force UTF-8 output so Chinese text / emoji are preserved when read by NekoTrak.
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

# NekoTrak may keep the previous value when a command returns truly empty stdout.
# U+2800 BRAILLE PATTERN BLANK is visually blank, but is normally not trimmed as
# ordinary whitespace, so it can overwrite the previous Rich Presence text.
$fallback = [char]0x2800

try {
    if (Test-Path -LiteralPath $path) {
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)

        if ([string]::IsNullOrWhiteSpace($text)) {
            [Console]::Write($fallback)
        } else {
            [Console]::Write($text)
        }
    } else {
        [Console]::Write($fallback)
    }
} catch {
    [Console]::Write($fallback)
}
