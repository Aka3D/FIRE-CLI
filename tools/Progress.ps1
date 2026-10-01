function Format-FireElapsed {
    param([TimeSpan]$Elapsed)

    if ($Elapsed.TotalSeconds -lt 60) {
        return $Elapsed.TotalSeconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + 's'
    }
    if ($Elapsed.TotalHours -lt 1) { return '{0}m {1:00}s' -f [int][Math]::Floor($Elapsed.TotalMinutes), $Elapsed.Seconds }
    return '{0}h {1:00}m {2:00}s' -f [int][Math]::Floor($Elapsed.TotalHours), $Elapsed.Minutes, $Elapsed.Seconds
}

function Get-FireFlameFrame {
    param([double]$Seconds, [int]$Width = 48, [switch]$Color)

    # Two square pixels per cell keep the flame compact and narrower than its logs.
    $pixels = [int[,]]::new(20, 20)
    $palette = @('', '219;62;19', '245;99;23', '255;155;38', '255;203;88', '255;239;166',
        '116;61;35', '164;94;48', '204;139;72', '237;179;105')
    for ($x = 1; $x -lt 19; $x++) {
        foreach ($slope in @(1, -1)) {
            $y = 15 + [int][Math]::Floor($(if ($slope -eq 1) { $x - 1 } else { 18 - $x }) * 3 / 17.0)
            $end = $x -le 2 -or $x -ge 17
            $pixels[$x, $y] = $(if ($end) { 9 } else { 8 })
            $pixels[$x, ($y + 1)] = $(if ($end) { 8 } elseif ($x % 4 -eq 0) { 6 } else { 7 })
        }
    }
    for ($x = 3; $x -lt 17; $x++) {
        $strength = [Math]::Max(0.0, 1.0 - [Math]::Pow([Math]::Abs(($x - 9.5) / 7.5), 1.6))
        $height = [Math]::Max(1.0, 2.0 + 12.0 * $strength + 1.7 * [Math]::Sin($x * 0.75 + $Seconds * 3) +
            0.8 * [Math]::Sin($x * 1.34 - $Seconds * 2))
        for ($y = 0; $y -lt 16; $y++) {
            $rise = 15 - $y
            if ($rise -ge $height) { continue }
            $heat = [Math]::Max(0.0, (0.9 * ($height - $rise) / $height +
                0.08 * [Math]::Sin($x * 0.8 - $rise * 1.1 + $Seconds * 3.5)) * $strength)
            if ($heat -gt 0.04) { $pixels[$x, $y] = [Math]::Min(5, [int][Math]::Ceiling($heat * 5)) }
        }
    }
    $offset = [int][Math]::Floor(($Width - 20) / 2.0)
    for ($row = 0; $row -lt 10; $row++) {
        $line = [Text.StringBuilder]::new()
        $lastForeground = 0
        $lastBackground = 0
        for ($column = 0; $column -lt $Width; $column++) {
            $x = $column - $offset
            $top = 0
            $bottom = 0
            if ($x -ge 0 -and $x -lt 20) {
                $top = $pixels[$x, ($row * 2)]
                $bottom = $pixels[$x, ($row * 2 + 1)]
            }
            $foreground = $(if ($top) { $top } else { $bottom })
            $background = 0
            $glyph = ' '
            if (-not $top -and $bottom) { $glyph = '▄' }
            elseif ($top -and -not $bottom) { $glyph = '▀' }
            elseif ($top -and $bottom) {
                $glyph = '█'
                if ($Color -and $top -ne $bottom) { $glyph = '▀'; $background = $bottom }
            }
            if ($Color) {
                if ($foreground -ne $lastForeground) {
                    [void]$line.Append($(if ($foreground) { "`e[38;2;$($palette[$foreground])m" } else { "`e[39m" }))
                    $lastForeground = $foreground
                }
                if ($background -ne $lastBackground) {
                    [void]$line.Append($(if ($background) { "`e[48;2;$($palette[$background])m" } else { "`e[49m" }))
                    $lastBackground = $background
                }
            }
            [void]$line.Append($glyph)
        }
        if ($Color) { [void]$line.Append($PSStyle.Reset) }
        $line.ToString()
    }
}

function Start-FireBrewing {
    param([bool]$Animations = $true)

    $terminal = Test-FireTerminal
    $cursorVisible = $true
    if ($terminal -and $IsWindows) { $cursorVisible = [Console]::CursorVisible }
    $Script:FireBrewing = [PSCustomObject]@{
        Watch = [Diagnostics.Stopwatch]::StartNew(); Terminal = $terminal; CursorVisible = $cursorVisible
        Rows = $(if ($Animations -and $terminal -and [Console]::WindowHeight -ge 15) { 14 } else { 1 })
        Visible = $false; LastFrame = -125L; LastLog = -15L; LastStatus = ''
        Activity = 'Starting database server'; Migration = ''; Completed = 0L; Total = $null; Result = $null
    }
    Update-FireBrewing
}

function Get-FireBrewingCaption {
    param([double]$Seconds, [int]$Width = 48)

    $dots = ([long][Math]::Floor($Seconds * 2) % 3) + 1
    $label = 'FIRE is warming up'
    # Centre the words; cycling dots occupy a reserved area to their right.
    $caption = (' ' * [Math]::Max(0, [int][Math]::Floor(($Width - $label.Length) / 2.0))) + $label + ('.' * $dots).PadRight(3)
    if ($caption.Length -gt $Width) { $caption = $caption.Substring(0, $Width) }
    return $caption.PadRight($Width)
}

function Set-FireBrewingPhase {
    param([string]$Activity, $Result)

    if (-not $Script:FireBrewing) { return }
    $Script:FireBrewing.Activity = $Activity
    $Script:FireBrewing.Result = $Result
    $Script:FireBrewing.Migration = ''
    $Script:FireBrewing.Completed = 0L
    $Script:FireBrewing.Total = $null
    Update-FireBrewing
}

function Get-FireBrewingStatus {
    param($State, [int]$Width = [int]::MaxValue, [string]$Details = '')

    $elapsed = Format-FireElapsed $State.Watch.Elapsed
    if ($Width -lt 16) { return $elapsed.PadRight($Width).Substring(0, $Width) }
    $timer = $(if ($Width -eq [int]::MaxValue) { $elapsed } else { $elapsed.PadRight(12) })
    $timerSuffix = " | $timer"
    $bodyWidth = $Width - $timerSuffix.Length
    $label = $State.Activity
    if ($State.Migration) {
        $unit = if ($State.Result.Engine -eq 'sqlserver') { 'SQL batches' } else { 'SQL statements' }
        $count = if ($null -ne $State.Total) { "$($State.Completed)/$($State.Total) $unit | $([Math]::Max(0L, $State.Total - $State.Completed)) left" }
            else { "$($State.Completed) $unit done" }
        $details = " | $($State.Migration) | $count"
        if (($label + $details).Length -gt $bodyWidth) {
            $label = "$($State.Result.Lane) $($State.Result.Database)"
            $details = $details.Replace(" $unit", '')
        }
    }
    if (($label + $details).Length -gt $bodyWidth -and $State.Migration) {
        $details = $details.Replace(" | $($State.Migration)", '')
    }
    $room = [Math]::Max(0, $bodyWidth - $details.Length)
    if ($label.Length -gt $room) {
        $label = $(if ($room -ge 3) { $label.Substring(0, $room - 3) + '...' } else { $label.Substring(0, $room) })
    }
    $status = $label + $details
    if ($status.Length -gt $bodyWidth) { $status = $status.Substring($status.Length - $bodyWidth) }
    if ($Width -ne [int]::MaxValue) { $status = $status.PadRight($bodyWidth) }
    return $status + $timerSuffix
}

function Write-FireTimedText {
    param([string]$Text, [TimeSpan]$Elapsed, [string]$Details = '')

    $width = $(if (Test-FireTerminal) { [Math]::Max(1, [Console]::WindowWidth - 1) }
        else { [int]::MaxValue })
    $state = [PSCustomObject]@{ Activity = $Text; Migration = ''; Watch = [PSCustomObject]@{ Elapsed = $Elapsed } }
    Write-FireText (Get-FireBrewingStatus $state $width $Details)
}

function Update-FireBrewing {
    $state = $Script:FireBrewing
    if (-not $state -or $state.Watch.ElapsedMilliseconds -lt $state.LastFrame + 125) { return }
    $state.LastFrame = $state.Watch.ElapsedMilliseconds
    $width = $(if ($state.Terminal) { [Math]::Max(1, [Console]::WindowWidth - 1) } else { [int]::MaxValue })
    $status = Get-FireBrewingStatus $state $width
    if (-not $state.Terminal) {
        if ($state.Activity -cne $state.LastStatus -or $state.Watch.Elapsed.TotalSeconds -ge $state.LastLog + 15) {
            Write-FireText "FIRE is warming up. $status"
            $state.LastStatus = $state.Activity
            $state.LastLog = [long][Math]::Floor($state.Watch.Elapsed.TotalSeconds)
        }
        return
    }

    $lines = @($status.PadRight($width))
    if ($state.Rows -eq 14) {
        $flameWidth = [Math]::Min(48, $width)
        $lines = @(Get-FireFlameFrame $state.Watch.Elapsed.TotalSeconds $flameWidth -Color)
        # Pad the flame area, not ANSI escape sequences, to overwrite old cells.
        $lines = @($lines | ForEach-Object { $_ + (' ' * ($width - $flameWidth)) })
        $caption = Get-FireBrewingCaption $state.Watch.Elapsed.TotalSeconds $flameWidth
        $lines += @((' ' * $width), (Format-FireOrange $caption.PadRight($width)), (' ' * $width), $status.PadRight($width))
    }
    $buffer = [Text.StringBuilder]::new()
    if (-not $state.Visible) {
        [void]$buffer.Append("`e[?25l" + ("`n" * ($state.Rows - 1)))
        $state.Visible = $true
    }
    [void]$buffer.Append("`r")
    if ($state.Rows -gt 1) { [void]$buffer.Append("`e[$($state.Rows - 1)A") }
    [void]$buffer.Append($lines -join "`r`n")
    # One write per frame avoids showing a cleared block between redraws.
    [Console]::Write($buffer.ToString())
}

function Stop-FireBrewing {
    $state = $Script:FireBrewing
    if (-not $state) { return }
    try {
        if ($state.Visible) {
            $clear = "`r"
            if ($state.Rows -gt 1) { $clear += "`e[$($state.Rows - 1)A" }
            $clear += "`e[J"
            if ($state.CursorVisible) { $clear += "`e[?25h" }
            [Console]::Write($clear)
        }
    }
    finally { $state.Watch.Stop(); $Script:FireBrewing = $null }
}

function Read-FireMigrationProgress {
    param($State, $Result, [string]$Line)

    if ($Line -match '^DEBUG: Parsing (?<file>V(?<version>[0-9]+)__.*\.sql) \.\.\.$') {
        $State.Parsing = $Matches.version
        $State.Counts[$State.Parsing] = 0L
        Set-FireBrewingPhase "Reading migrations for $($Result.Lane) $($Result.Database)" $Result
    }
    elseif ($State.Parsing -and $Line.StartsWith('DEBUG: Found statement at line ', [StringComparison]::Ordinal)) {
        $State.Counts[$State.Parsing]++
    }
    elseif ($Line -match '^DEBUG: Starting migration of schema .* to version "(?<version>[0-9]+) - .*"') {
        $State.InMigration = $true
        $State.Started = 0L
        $State.Parsing = ''
        $State.CurrentTotal = $(if ($State.Counts.ContainsKey($Matches.version)) { $State.Counts[$Matches.version] } else { $null })
        if ($Script:FireBrewing) {
            Set-FireBrewingPhase "Migrating $($Result.Lane) $($Result.Database)" $Result
            $Script:FireBrewing.Migration = 'V' + $Matches.version
            $Script:FireBrewing.Total = $State.CurrentTotal
        }
    }
    elseif ($State.InMigration -and $Line.StartsWith('DEBUG: Executing SQL:', [StringComparison]::Ordinal)) {
        if ($State.Started -gt 0) {
            $Result.Statements++
            if ($Script:FireBrewing) { $Script:FireBrewing.Completed++ }
        }
        $State.Started++
    }
    elseif ($State.InMigration -and $Line.StartsWith('DEBUG: Successfully completed migration of schema ', [StringComparison]::Ordinal)) {
        $Result.Changed = $true
        if ($State.Started -gt 0) {
            $Result.Statements++
            if ($Script:FireBrewing) { $Script:FireBrewing.Completed++ }
        }
        if ($null -ne $State.CurrentTotal -and $State.CurrentTotal -ne $State.Started) { $Result.CountKnown = $false }
        $State.InMigration = $false
        $State.Migrations++
    }
    elseif ($Line -match '^Successfully applied (?<count>[0-9]+) migration') {
        if ([int]$Matches.count -gt 0) { $Result.Changed = $true }
        if ([int]$Matches.count -gt $State.Migrations) { $Result.CountKnown = $false }
    }
}

function New-FireBuildResult {
    param([string]$Lane, [string]$Database, [string]$Engine)

    return [PSCustomObject]@{
        Lane = $Lane; Database = $Database; Engine = $Engine; Outcome = 'already current'
        Statements = 0L; CountKnown = $true; Changed = $false; Watch = [Diagnostics.Stopwatch]::new()
    }
}

function Write-FireBuildResult {
    param($Result)

    $unit = if ($Result.Engine -eq 'sqlserver') { 'SQL batches' } else { 'SQL statements' }
    $count = if ($Result.CountKnown) { "$($Result.Statements) $unit" } else { 'SQL count unavailable' }
    Write-FireTimedText "$($Result.Lane) $($Result.Database): $($Result.Outcome)" $Result.Watch.Elapsed " | $count"
}

# SIG # Begin signature block
# MIIdvgYJKoZIhvcNAQcCoIIdrzCCHasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBSs0yX3gjvgS/x
# egb9p7DNdLQxzbrMk7BquWBAbA6MIqCCF3IwggQ0MIICnKADAgECAhAq44+Z0deO
# vUoLyWB3/qUcMA0GCSqGSIb3DQEBCwUAMDIxETAPBgNVBAoMCEZJUkUgQ0xJMR0w
# GwYDVQQDDBRBa2Fyc2hhbiBHbmFuZXN3YXJhbjAeFw0yNjEwMDExOTQwMjRaFw0y
# OTEwMDExOTUwMjNaMDIxETAPBgNVBAoMCEZJUkUgQ0xJMR0wGwYDVQQDDBRBa2Fy
# c2hhbiBHbmFuZXN3YXJhbjCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGB
# AMajm3R68g1AfVGSh7fwCbfRPjrlkdJQI3egCmP5Fp20yw9hRvtmaWR0h+iX1BoI
# sFOfYJ9+LnCK3OdVtEHdn+HkFzm4URHNMbUXlMF5HM8cXhYccuAxw3JR4yy/OH9B
# qd8tBl47/RVe+TjZJaURHhu3V682PT4q5rUZ3FLS0bRUAX2q1iR67GHi4EMaR0EP
# KepuvKdiZ2B3TMUR/poojgsStQ2rRPxv6YGp3yCKz2N44TmP7CtahnrpyNfZVcwk
# IbVHwm2YSH/pTcFJC8k3vki1YMupxg3gibazKwtvB27PZbNIvCK1HPrJK0pDQ2bk
# 54cIgLjdt2WORE63Z6TliIF+MIOARn8Ieg2GtbN7kx41ZADwCaB9+Nk2NSQGcEL9
# c8kzKu0N1leO2Qj67930uUyfSs3TFs29TSpypGxEBMFEB1thT90p9zlwPtEqGyYi
# d7m3NGrJm0aRGK/qih7jVvP/uCRZdjZTB88mS3ysDEgS/MIl3VYNnrFbCtsym4lA
# fQIDAQABo0YwRDAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# HQYDVR0OBBYEFKuiyNwVMOzXprxVCSOyrah6gLjNMA0GCSqGSIb3DQEBCwUAA4IB
# gQArr4jHG3ikrMdbv3XWzfsr55rOXAcelMKY4fsdE9PIczCFPlhetfr07HAUeFQn
# 1v4z0awVOFy8C4BnO/uIWW0qUbFiD5si89Wj0Hh4ytUg5057WJcqwlHcUPb9FEWy
# QspGrxo54fiJn1oi5oLC5fMCess9+XACTBPW2YSHEs4Zwmc8WvtBwleXqoXlsVf4
# EhGyDEE6vXIX9wzApaJC3yG5Xn/7uNwWSdJXvUkzK9zPtP89RBANxr5p/ewK5Crb
# LJIO4PelzJlxPQfvTpiv/Dzzd39gRRY26NgTHRE2Lr7I2CqH+zLtvReE7veK0KFk
# 9BKAlFYZQ9VyA5suBwu4ZQmvCQXhQ1HIsP3Tmk5xKgNFwHwrp5mocjJldEHKxOZ8
# 0SYuPd3p3MfmERggRgY2aArUg8xHCvR83crr7CBijwWMGw4LGTK23vuwSJOE2hsO
# y9t+7zeixXH1X3QUyoYU9E/Xi4zfj7HfqQO266kQ5zxvsUiZBGR3U2eBYkRAiFcQ
# giAwggWNMIIEdaADAgECAhAOmxiO+dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUA
# MGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsT
# EHd3dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQg
# Um9vdCBDQTAeFw0yMjA4MDEwMDAwMDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNV
# BAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdp
# Y2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqcl
# LskhPfKK2FnC4SmnPVirdprNrnsbhA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YF
# PFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKyunWZanMylNEQRBAu34LzB4TmdDttceIt
# DBvuINXJIB1jKS3O7F5OyJP4IWGbNOsFxl7sWxq868nPzaw0QF+xembud8hIqGZX
# V59UWI4MK7dPpzDZVu7Ke13jrclPXuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1
# ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2Tox
# RJozQL8I11pJpMLmqaBn3aQnvKFPObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdp
# ekjw4KISG2aadMreSx7nDmOu5tTvkpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF
# 30sEAMx9HJXDj/chsrIRt7t/8tWMcCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9
# t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQ
# UOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXk
# aS+YHS312amyHeUbAgMBAAGjggE6MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1Ud
# DgQWBBTs1+OC0nFdZEzfLmc/57qYrhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEt
# UYunpyGd823IDzAOBgNVHQ8BAf8EBAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsG
# AQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0
# dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RD
# QS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29t
# L0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAw
# DQYJKoZIhvcNAQEMBQADggEBAHCgv0NcVec4X6CjdBs9thbX979XB72arKGHLOyF
# XqkauyL4hxppVCLtpIh3bb0aFPQTSnovLbc47/T/gLn4offyct4kvFIDyE7QKt76
# LVbP+fT3rDB6mouyXtTP0UNEm0Mh65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8L
# punyNDzs9wPHh6jSTEAZNUZqaVSwuKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2
# CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si
# /xK4VC0nftg62fC2h5b9W9FcrBjDTZ9ztwGpn1eqXijiuZQwgga0MIIEnKADAgEC
# AhANx6xXBf8hmS5AQyIMOkmGMA0GCSqGSIb3DQEBCwUAMGIxCzAJBgNVBAYTAlVT
# MRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5j
# b20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAeFw0yNTA1MDcw
# MDAwMDBaFw0zODAxMTQyMzU5NTlaMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5E
# aWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1l
# U3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQC0eDHTCphBcr48RsAcrHXbo0ZodLRRF51NrY0NlLWZ
# loMsVO1DahGPNRcybEKq+RuwOnPhof6pvF4uGjwjqNjfEvUi6wuim5bap+0lgloM
# 2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHeHYNnQxqXmRinvuNgxVBdJkf77S2uPoCj
# 7GH8BLuxBG5AvftBdsOECS1UkxBvMgEdgkFiDNYiOTx4OtiFcMSkqTtF2hfQz3zQ
# Sku2Ws3IfDReb6e3mmdglTcaarps0wjUjsZvkgFkriK9tUKJm/s80FiocSk1VYLZ
# lDwFt+cVFBURJg6zMUjZa/zbCclF83bRVFLeGkuAhHiGPMvSGmhgaTzVyhYn4p0+
# 8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeSLsJygoLPp66bkDX1ZlAeSpQl92QOMeRx
# ykvq6gbylsXQskBBBnGy3tW/AMOMCZIVNSaz7BX8VtYGqLt9MmeOreGPRdtBx3yG
# OP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL6s36czwzsucuoKs7Yk/ehb//Wx+5kMqI
# MRvUBDx6z1ev+7psNOdgJMoiwOrUG2ZdSoQbU2rMkpLiQ6bGRinZbI4OLu9BMIFm
# 1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFUeEY0qVjPKOWug/G6X5uAiynM7Bu2ayBj
# UwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU729T
# SunkBnx6yuKQVvYv1Ensy04wHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4c
# D08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMIMHcGCCsGAQUF
# BwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEG
# CCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5k
# aWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAgBgNVHSAEGTAX
# MAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQADggIBABfO+xaA
# HP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/T8ObXAZz8OjuhUxjaaFdleMM0lBryPTQ
# M2qEJPe36zwbSI/mS83afsl3YTj+IQhQE7jU/kXjjytJgnn0hvrV6hqWGd3rLAUt
# 6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9rEVKChHyfpzee5kH0F8HABBgr0UdqirZ7
# bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y1IsA0QF8dTXqvcnTmpfeQh35k5zOCPmS
# Nq1UH410ANVko43+Cdmu4y81hjajV/gxdEkMx1NKU4uHQcKfZxAvBAKqMVuqte69
# M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3ty9qIijanrUR3anzEwlvzZiiyfTPjLbnF
# RsjsYg39OlV8cipDoq7+qNNjqFzeGxcytL5TTLL4ZaoBdqbhOhZ3ZRDUphPvSRmM
# Thi0vw9vODRzW6AxnJll38F0cuJG7uEBYTptMSbhdhGQDpOXgpIUsWTjd6xpR6oa
# Qf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud/v4+7RWsWCiKi9EOLLHfMR2ZyJ/+xhCx
# 9yHbxtl5TPau1j/1MIDpMPx0LckTetiSuEtQvLsNz3Qbp7wGWqbIiOWCnb5WqxL3
# /BAPvIXKUjPSxyZsq8WhbaM2tszWkPZPubdcMIIG7TCCBNWgAwIBAgIQCE/cM09+
# RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UE
# ChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQg
# VGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMB4XDTI2MDgwNTAw
# MDAwMFoXDTM3MTEwNDIzNTk1OVowYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRp
# Z2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBU
# aW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz/TjGMPh8CQ6RucZCLv5anHzWJjF/NWJr
# FIhy24fcpKXlgRiky4WAawDfU3YP0BMxt9l3Dm5oCG5Z69AqEN1kgHg2epx+l+lZ
# BcmJCcN0ASURML5uFIS80sZsDwO3BSkUxDjLJhBI+qiZP3aixAC/qEGLjsBNlLol
# 9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZEeoy/0B8Zm+nzKBgSWG52lCO1w+nCg6Xp
# CtklTJXeIg283hw7TmmsZXR+SMbjbrEOvZ3fP2VxIgeR28Y90ZStd3F9VuA5RVyn
# b/whITPAo9b75Zr4Ta6Mj3URm26QZYMn/FnbuTegcoRcFEZ9FOqM5T6MTdtr/n74
# lIT/ug0eeOzmZ6QTFg33otX+bFRsIolvykE1jive4PuESaT8zzVeFWDAMDtozNgL
# ctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZCZVl6pNUOCybMc/kxC6EAmSJY24L0yYK
# D1Nkddsnb/ItVKi/2nXpQNMu1PT5prW83vV8d67WowuUs0HdY4H8AMLGvdL/WHEj
# 3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjdzi0xlp70W+ow63/0++YDEX1M0iwgUHwb
# rJvfpklkZQvw3+kv3vUPItdwroczk9icflf55W1zOEKAcJVAIXpcMCU9AgMBAAGj
# ggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBQUyWOKMC7USvtulPPm40B+
# 9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8E
# BAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGF
# MCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUH
# MAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRH
# NFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBW
# MFSgUqBQhk5odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVk
# RzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkw
# FzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQCNxTph
# Hp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQIENoyKqxrFbJblzCVP/pkXmwXOdrOpWyg
# LzlT12os5ipDCy35RBCg2UMeApEtrfGhz45F4Wt4WGdNdIbRWt3YTYJmpR+b7lr4
# d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfHhHv1mx9EVh71SJelcEN/oORSjXzdjfw1
# iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA02nXD1nYLI7Ijmiv+xLCiYC41DSFYL3G
# hTiy0PxpawPtGRyaBVGzq+UiTfM8pD7KVyF5aQyWP4KhVGUUTnmm/RlYJoW3TiXA
# /+t0YcT2oRVBm3JETjajHug2AL+v5jhtKVnd3D0rbHXEu27o+Q8p4sEWPMqKDB+q
# bceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvKqzpAec9etE14jOQAzLKWdE3w/TCaKtLR
# aRT7LCkRYVnhA2D73FLje1O5b3HR5eHs0NzU/+xX7NbEdcofy0W3Wdwd1XOqtlpg
# /JgwtKfZM5dqO94lbUveOiJBI+xZEbGRsMNbXmMREUTgu+Oca7Y73MPWcslIx2Vh
# kSKSXjDbD6rgg39H5Mh7QfieAIjWagkJNt68Yfim6cjEzVSiLSeZfdkr5dtFPTW6
# jATlWJdYeeDRGCyatf8R1hSjzSvdN8yWQPT9gzGCBaIwggWeAgEBMEYwMjERMA8G
# A1UECgwIRklSRSBDTEkxHTAbBgNVBAMMFEFrYXJzaGFuIEduYW5lc3dhcmFuAhAq
# 44+Z0deOvUoLyWB3/qUcMA0GCWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwx
# CjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGC
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPSRMMdpb2SGGLBu
# gS5ND+u5yGc8OOZLaIw+DvNd7T4cMA0GCSqGSIb3DQEBAQUABIIBgMNRMFtl3vCn
# SyPMpLEqU/y0oN/UFtR9ct62d06SQ4gA/P3BRmzqEY0B3FQJclCx7yMj5DiaumSW
# dMte+PoWB5vggoj67GyAf9iLVZffNDNz29SGB/6jySXSDlW9wLVrWuPCD6hfZimu
# ki48zwuq4QSCUxZlDln1DkogMyCoL/sZacH2VMTwSz7FZ60grMg1T9vcce7Z1vfS
# SrZs18a4ESnXcgRMA9zrg/uBaL3lKfjL5ys8LfDq2snjJfL+zoUGWr3ru8m0iZYC
# sVNMMC5UHRV368dkvt83MAdYKKjr3G5tDOP5kR+JnqQUVfuRg/t1gH88imTxC8BG
# AtLTVb/c6yrgWJHEHYSaqX5QCxwZKTgMO/ub7q7Kx+6sQdTsIT0CpHgiBgwiACqJ
# Zka1A0kA80Uz2bf9Vf8kunZSNhEy6fAXy/OHUvHHSBFMGmiMNTC7JrFg8BjfPyc6
# veZD9otgvscjKDtUcpQ6Z6+lgzOkRxrPPaFZ+xsIL8USSBEeuVE2qaGCAyYwggMi
# BgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQK
# Ew5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBU
# aW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MP
# j/mSGDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcB
# MBwGCSqGSIb3DQEJBTEPFw0yNjEwMDExOTU1MjVaMC8GCSqGSIb3DQEJBDEiBCB1
# zu61aRESMAYL8N06sTuDz4a5ZTlyS73I32NwSaehbTANBgkqhkiG9w0BAQEFAASC
# AgA4AC+BI69xXMSi72+XtKtG+jnKvChETbueXVmkjYvAPI9A6MWYw5VbT1i8tVWx
# pW0Ix4Ec5O0f1TYodevILmL2572MBWQkU4QDVMtORg2YcbcXtpDLfDsniuIXnbvG
# oXWGyujPzAzIt5uJKc6zOx0EoBnDjIy/XstphwDfzQvzmnW/EhCvzALq4RwElh/R
# r2WsZghEaYsuwLlw3F2kwWR6lBUs8bSym2xVSRIBPtWSQo+xIKern5kr9ZL0qZY2
# a2kO032TaTJS2VK/s/SvUcWiybHk1YFVOpGyEevTe8slzPvsxR6VxfMqQ2RciTlm
# AYNxeWxEwgrpIFyrXi810lLeS2irbKzi8w92/48U6fxTG+ZSHJ8IV7hXbiYrsoZh
# rJGvTcQxzou4benOyJoXYrS5NNj2p3B3rxd4hdFYD4PLLXXI41Uu1XX0TMaFDUaE
# +pXwGL78woBnFTkzOmWxK3iKtbftoJvt8PxkzqXvI8ygxqvBhN73txh0LICyVQbT
# kZzulBz0mUCaV1eTJxdyalzAGreQXqqMPR2XS4Q2h+XF8NPlm5YXdpM8/mUkLUaj
# ph0XrhaemNepMcUi2lEyN7/FF2hhZX43LLZ6eLQWA6TD4Agqv9lABi2WG3vQpnCS
# ZuBOIMZyfzGG1SheNEpr/hcBz4+PHMbYt8faX6e8mH+jTg==
# SIG # End signature block
