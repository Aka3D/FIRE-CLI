function Read-FireSettings {
    $path = Join-Path $Script:FireSourceRoot 'fire.settings.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [PSCustomObject]@{ sounds = $true; animations = $true } }
    $settings = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 20 -NoEnumerate
    if ($settings -isnot [PSCustomObject]) { throw 'fire.settings.json must contain a JSON object.' }
    if (-not $settings.PSObject.Properties['sounds']) { $settings | Add-Member -NotePropertyName sounds -NotePropertyValue $true }
    if ($settings.sounds -isnot [bool]) { throw 'Use true or false for sounds in fire.settings.json.' }
    if (-not $settings.PSObject.Properties['animations']) { $settings | Add-Member -NotePropertyName animations -NotePropertyValue $true }
    if ($settings.animations -isnot [bool]) { throw 'Use true or false for animations in fire.settings.json.' }
    return $settings
}

function Save-FireSettings {
    param($Settings)

    if ($Settings.sounds -isnot [bool]) { throw 'Use true or false for sounds in fire.settings.json.' }
    if ($Settings.animations -isnot [bool]) { throw 'Use true or false for animations in fire.settings.json.' }
    $path = Join-Path $Script:FireSourceRoot 'fire.settings.json'
    $temporary = Join-Path $Script:FireSourceRoot ".fire-settings-$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Settings | ConvertTo-Json -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $path, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Edit-FireSettings {
    $settings = Read-FireSettings
    $choices = @(
        [PSCustomObject]@{ Label = 'Sounds — success and failure cues'; Value = 'sounds' }
        [PSCustomObject]@{ Label = 'Animations — campfire during fire up. Requires at least 15 terminal rows.'; Value = 'animations' }
    )
    $selected = @('sounds', 'animations' | Where-Object { $settings.$_ })
    $enabled = @(Read-FireChoice 'FIRE settings' $choices -MultiSelect -SelectedValues $selected)
    $settings.sounds = 'sounds' -in $enabled
    $settings.animations = 'animations' -in $enabled
    Save-FireSettings $settings
    Write-FireText "FIRE settings saved. Sounds: $(if ($settings.sounds) { 'on' } else { 'off' }). Animations: $(if ($settings.animations) { 'on' } else { 'off' })."
    return $settings
}

function Play-FireSound {
    param([ValidateSet('success', 'failure')][string]$Outcome)

    $path = Join-Path $Script:FireSourceRoot "assets/sounds/$Outcome.wav"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if ($IsWindows) {
        Add-Type -AssemblyName System.Windows.Extensions
        $player = [System.Media.SoundPlayer]::new($path)
        try {
            # Load first so a missing or invalid cue cannot trigger the default system beep.
            $player.Load()
            $player.PlaySync()
        }
        finally { $player.Dispose() }
    }
    else {
        $players = if ($IsMacOS) { @('afplay') } else { @('paplay', 'pw-play', 'aplay') }
        $player = @($players | ForEach-Object { Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue } | Select-Object -First 1)
        if ($player.Count) { & $player[0].Source $path *> $null }
    }
}

function Invoke-FireCommandSound {
    param([ValidateSet('success', 'failure')][string]$Outcome, [bool]$Enabled)

    if (-not $Enabled) { return }
    try { Play-FireSound $Outcome }
    catch { } # Optional audio must not alter command output or its result.
}

# SIG # Begin signature block
# MIIdvgYJKoZIhvcNAQcCoIIdrzCCHasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDp4h1SKyS6SSqR
# 0WReNhrMI9qIqZamajv4Cz60UrjIkKCCF3IwggQ0MIICnKADAgECAhAq44+Z0deO
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
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEICmGXk7vSqgO/uiV
# INNycHKl4LQ8vI7M8Il2B4HSH2vzMA0GCSqGSIb3DQEBAQUABIIBgB7k5MQNvjRR
# xwIb+U9AHbGT61IfFQw4CQZ0xRnZHuGYvt8EgC7yRpEpbiho4j6E5XTUZbQzii8t
# 4HSWhf25ipWRmYqHa78lrK5i8wJmoYqKvvdigHWpCbvOSIQGlip0t0+pN3JQ+5u8
# TI90JoLdmMfvBu+pcYhjsRmUCt0fBQCVHX4FM2tPa0xiRXgsOX4edWgpJ0ObOniS
# R7cNvDZLt06eYYJGFdSWpDhT7GkJY7pJbJo5TnDCooaaXJxBus+DSoAfYuaRxntv
# 6iLkBa0aAGlZWhOCUwSWWt1y1xA6PMlNk4msIHjDcZx203Xw3IeyQdfFxqXwXCoT
# H60ZbVWmwX6h7b9h1Q08gz+OUVR47fMqXuGRmmZNKfMztp9mI7ULCFrP6lyDmFkt
# os0tVuyleDaxa6LcV1E2mszlRqrJQLA9X59GqJC/hGoROBvTb3urxYW6ql00wRel
# Mbgkoz7i99P+RxIpGCAK2PLENxsP856CnwFI6cQKi/yTTqb9F6YsaqGCAyYwggMi
# BgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQK
# Ew5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBU
# aW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MP
# j/mSGDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcB
# MBwGCSqGSIb3DQEJBTEPFw0yNjEwMDExOTU1MjZaMC8GCSqGSIb3DQEJBDEiBCDv
# ZAb/8lpN6l8dns0ER+r7DI2cSEO1Mjv5ld80pEEvazANBgkqhkiG9w0BAQEFAASC
# AgANCPu/6XB9itzS9BRfs6qGwuZyndy2+urOFmRIwstNaA7mIxq4XYII/dGw8jxq
# nMrIvCQqF1S5kQbyytOVLJz3Da3llW+miXLTAEgf87tEs8wdFOJBUUFshG+DPhK0
# NUy78Dw9ffPQSB2m/PoPuTFJIMaCMJpSUCob6sBVIZZisbgTdHZQe+P3kshLSCc/
# 59I3F1Db6m6UtKNW9/f2emQeeYkCPCCIWtiGaqVz0PHhoPVz3kk9/dNmQbzN5oev
# e0qV5nmGsbGRm3vzCibh3FchmpF1Tyc3YUUbDxZl2YQf8Mm3ThI9/LdBO98PhKA0
# BjKZxT/3RH3jPHbp+HyeERhuE8m4Tjh7BlBxQUrJRdXo+mDUD4bar2ypAVQ0/ngd
# mxmFM+GXNXzCAqL6biKA38N0xavIOz/5GUQSivkWZ/M60yilv1JtbhFIz2PbmTWO
# im9qoXVTvcYYDxO/jJef751PH3hhEfaLavHZEsdELphSXpQFsbaQgHeJCJzuyQZy
# iLtfNSqgvoYec+vhyclxdIpM4LIaUUamUsQqRTBOaMl2PC90aCVXkUsLd3l4xI70
# kj9p46kyHXFJziLRpz1W7quM4fkwKjwS2ANn3NjiaC7pEexc/jJy/2eDeSxaw2oQ
# cCMsTkV3+klAhI532dIvAfvXNv4sOvWUU6lFXuCF63J+SA==
# SIG # End signature block
