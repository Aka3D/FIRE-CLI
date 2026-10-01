function Get-FireSqlServerConnectionString {
    param([int]$Port, [string]$Database, [string]$Password, [string]$User = 'sa')

    $builder = [Data.Common.DbConnectionStringBuilder]::new()
    $builder['Server'] = "127.0.0.1,$Port"
    $builder['Initial Catalog'] = $Database
    $builder['User ID'] = $User
    $builder['Password'] = $Password
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $true
    $builder['Connect Timeout'] = 60
    return $builder.ConnectionString
}

function Invoke-FireSqlPackage {
    param([string[]]$Arguments)

    $command = Get-Command sqlpackage -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $file = if ($command) { $command.Source }
        else { Join-Path $HOME ".dotnet/tools/$(if ($IsWindows) { 'sqlpackage.exe' } else { 'sqlpackage' })" }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "SqlPackage is missing. Run 'fire install', then retry."
    }
    return Invoke-FireNative $file $Arguments
}

function Backup-FireSqlServer {
    param($Project, $Credentials, [string]$Database, [string]$TargetPath)

    $fileName = "fire_$([Guid]::NewGuid().ToString('N')).bak"
    $inContainer = "/var/opt/mssql/backup/$fileName"
    Invoke-FireNative docker @('exec', $Project.Container, 'mkdir', '-p', '/var/opt/mssql/backup') | Out-Null
    try {
        Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "BACKUP DATABASE [$Database] TO DISK=N'$inContainer' WITH COPY_ONLY, INIT, COMPRESSION, CHECKSUM;" | Out-Null
        Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "RESTORE VERIFYONLY FROM DISK=N'$inContainer' WITH CHECKSUM;" | Out-Null
        Invoke-FireNative docker @('cp', "$($Project.Container):$inContainer", $TargetPath) | Out-Null
    }
    finally { Invoke-FireNative docker @('exec', $Project.Container, 'rm', '-f', $inContainer) -AllowFailure | Out-Null }
}

function Get-FireSqlServerBackupFiles {
    param($Project, $Credentials, [string]$ContainerPath)

    $output = Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "RESTORE FILELISTONLY FROM DISK=N'$ContainerPath';"
    $files = @($output -split '\r?\n' | ForEach-Object {
        $parts = $_ -split '\|'
        if ($parts.Count -ge 3 -and $parts[2] -in @('D', 'L', 'S', 'F')) {
            [PSCustomObject]@{ LogicalName = $parts[0]; Type = $parts[2] }
        }
    })
    if ($files.Count -eq 0) { throw 'Backup has no readable SQL Server data or log files.' }
    if (@($files | Where-Object { $_.Type -notin @('D', 'L') }).Count -gt 0) {
        throw 'Backup contains SQL Server file types FIRE cannot restore safely. Restore it manually.'
    }
    return $files
}

function Get-FireSqlServerRestoreMoves {
    param($Files, [string]$Database)

    $index = 0
    return @($Files | ForEach-Object {
        $logical = $_.LogicalName.Replace("'", "''")
        $extension = if ($_.Type -eq 'L') { 'ldf' } elseif ($index -eq 0) { 'mdf' } else { 'ndf' }
        $target = "/var/opt/mssql/data/${Database}_${index}.${extension}"
        $index++
        "MOVE N'$logical' TO N'$target'"
    })
}

function Test-FireSqlServerBackup {
    param($Project, $Credentials, [string]$Database, [string]$SourcePath)

    $inContainer = "/var/opt/mssql/backup/fire_$([Guid]::NewGuid().ToString('N')).bak"
    Invoke-FireNative docker @('exec', $Project.Container, 'mkdir', '-p', '/var/opt/mssql/backup') | Out-Null
    try {
        Invoke-FireNative docker @('cp', $SourcePath, "$($Project.Container):$inContainer") | Out-Null
        $files = @(Get-FireSqlServerBackupFiles $Project $Credentials $inContainer)
        $moves = Get-FireSqlServerRestoreMoves $files $Database
        Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "RESTORE VERIFYONLY FROM DISK=N'$inContainer' WITH $($moves -join ', ');" | Out-Null
    }
    finally { Invoke-FireNative docker @('exec', $Project.Container, 'rm', '-f', $inContainer) -AllowFailure | Out-Null }
}

function Restore-FireSqlServer {
    param($Project, $Credentials, [string]$Database, [string]$SourcePath, [switch]$ReplaceExisting, [string]$Activity)

    $fileName = "fire_$([Guid]::NewGuid().ToString('N')).bak"
    $inContainer = "/var/opt/mssql/backup/$fileName"
    Invoke-FireNative docker @('exec', $Project.Container, 'mkdir', '-p', '/var/opt/mssql/backup') | Out-Null
    try {
        Invoke-FireNative docker @('cp', $SourcePath, "$($Project.Container):$inContainer") | Out-Null
        $files = @(Get-FireSqlServerBackupFiles $Project $Credentials $inContainer)
        $moves = Get-FireSqlServerRestoreMoves $files $Database
        $existing = Test-FireDatabaseExists $Project $Credentials $Database
        if ($existing -and -not $ReplaceExisting) { throw "Restore target '$Database' already exists." }
        if ($existing) {
            Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" | Out-Null
        }
        try {
            Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "RESTORE DATABASE [$Database] FROM DISK=N'$inContainer' WITH $($moves -join ', '), REPLACE, RECOVERY;" -Activity $Activity | Out-Null
            Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "ALTER DATABASE [$Database] SET MULTI_USER;" | Out-Null
        }
        catch {
            if ($existing) {
                try { Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "ALTER DATABASE [$Database] SET MULTI_USER;" | Out-Null }
                catch { }
            }
            throw
        }
    }
    finally { Invoke-FireNative docker @('exec', $Project.Container, 'rm', '-f', $inContainer) -AllowFailure | Out-Null }
}

function Get-FireSqlServerSchemaScript {
    param($Project, $Credentials, [string]$SourceDatabase, [string]$TargetDatabase, [string]$Work)

    $port = Get-FirePort $Project (Get-FireContainerJson $Project.Container)
    $dacpac = Join-Path $Work 'source.dacpac'
    $script = Join-Path $Work 'schema.sql'
    $source = Get-FireSqlServerConnectionString $port $SourceDatabase $Credentials.password
    $target = Get-FireSqlServerConnectionString $port $TargetDatabase $Credentials.password
    Invoke-FireSqlPackage @('/Action:Extract', "/SourceConnectionString:$source", "/TargetFile:$dacpac",
        '/p:VerifyExtraction=true', '/p:ExtractReferencedServerScopedElements=false', '/p:IgnoreUserLoginMappings=true') | Out-Null
    Invoke-FireSqlPackage @('/Action:Script', "/SourceFile:$dacpac", "/TargetConnectionString:$target", "/OutputPath:$script",
        '/p:IncludeTransactionalScripts=false', '/p:BlockOnPossibleDataLoss=true', '/p:ScriptDatabaseOptions=false',
        '/p:DropObjectsNotInSource=true', '/p:ExcludeObjectTypes=Users;RoleMembership;Permissions') | Out-Null
    $content = [IO.File]::ReadAllText($script)
    $content = [Regex]::Replace($content, '(?m)^\s*:(?:setvar|on error).*(?:\r?\n)?', '')
    $content = $content.Replace('$(__IsSqlCmdEnabled)', 'True')
    $content = [Regex]::Replace($content, '(?im)^\s*USE\s+\[(?:\$\(DatabaseName\)|[^\]]+)\]\s*;\s*$', '-- FIRE uses the current database connection.')
    if ($content -match '(?im)^\s*(?:USE\s+|CREATE\s+DATABASE|DROP\s+DATABASE|ALTER\s+DATABASE)') {
        throw 'SqlPackage generated database-level commands. Write a reviewed migration manually.'
    }
    if ($content.Contains('$(DatabaseName)')) {
        throw 'SqlPackage generated unresolved DatabaseName variables. Write a reviewed migration manually.'
    }
    return $content
}

function Test-FireSqlServerSchemaEqual {
    param($Project, $Credentials, [string]$SourceDatabase, [string]$TargetDatabase, [string]$Work)

    $port = Get-FirePort $Project (Get-FireContainerJson $Project.Container)
    $dacpac = Join-Path $Work 'comparison.dacpac'
    $report = Join-Path $Work 'comparison.xml'
    Invoke-FireSqlPackage @('/Action:Extract', "/SourceConnectionString:$(Get-FireSqlServerConnectionString $port $SourceDatabase $Credentials.password)",
        "/TargetFile:$dacpac", '/p:VerifyExtraction=true', '/p:ExtractReferencedServerScopedElements=false', '/p:IgnoreUserLoginMappings=true') | Out-Null
    Invoke-FireSqlPackage @('/Action:DeployReport', "/SourceFile:$dacpac",
        "/TargetConnectionString:$(Get-FireSqlServerConnectionString $port $TargetDatabase $Credentials.password)",
        "/OutputPath:$report", '/p:DropObjectsNotInSource=true',
        '/p:ExcludeObjectTypes=Users;RoleMembership;Permissions') | Out-Null
    [xml]$xml = Get-Content -Raw -LiteralPath $report
    $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('d', 'http://schemas.microsoft.com/sqlserver/dac/DeployReport/2012/02')
    return @($xml.SelectNodes('/d:DeploymentReport/d:Operations/d:Operation', $ns)).Count -eq 0
}

# SIG # Begin signature block
# MIIdvgYJKoZIhvcNAQcCoIIdrzCCHasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD0l/qgIQBApj/0
# zAoYiekOiu+cFzwOPifotXP5yd0vLqCCF3IwggQ0MIICnKADAgECAhAq44+Z0deO
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
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIKHVSQG/u9Ktiw5E
# xziLL2N1bu2C0YfunayemYON3V+IMA0GCSqGSIb3DQEBAQUABIIBgGOuPdG5jBvg
# OC37WrdWTPLmRchEbzJTnzHmkbqY1SWdcJRwu9C67w5qQeFmBYLA3A/w9xJMcSok
# UYs3GPulKdPdnUcBXXnQttJFOWQbVNnj1BjlCmpfi7TgbXKHgsiOTywqaIoY8mQF
# xg1qYXpMkFYUjMm+RrSH2rsjOa9CWC4Dz/2QNSpVCWr8BEZMxt352JeZW9TQ8z09
# xBwS3sFOEzlN+RjQ9Ev1zRFawndc20NBlQwczWSHVSeVeh/UdELW38Udf68e+ecv
# LPLpKki/SsekA9sX+1g0uVRhTmfPndZZKCH/PjysSUEUD31cf9GatqsRoytTdgjU
# 6NMutswwH4ytwLe6bWyLDynggb6nyhhmM+/0YVHonCQh5OxkHXB4DVfuP74WEwAs
# y7GIXfMB+e/IVjJCcwcJHwHddeNzD9n2k5QRE+bK2y/WnZGqGogBIep8/8kJAmpt
# MBvTInpvJWdATfP4YRbydAr67cFi89d1eNAzbK4/oWlBZLSDWtpgl6GCAyYwggMi
# BgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQK
# Ew5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBU
# aW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MP
# j/mSGDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcB
# MBwGCSqGSIb3DQEJBTEPFw0yNjEwMDExOTU1MjZaMC8GCSqGSIb3DQEJBDEiBCAl
# 4cSdbWCvaMWt048gWlyxvKAtnsP+VRO8oZ6ICazmmDANBgkqhkiG9w0BAQEFAASC
# AgAYl09WU2neGvPoMYrvkrDInHyw1p9btDcs30/y+/xgKitc4tGXYDzqtBk4yXMm
# IKmgZb5tw9gBvzb1eNK3NSVh4SYSOi/TZUQGjlT9F/FKsZnoQa8Ge57JPO8vfkHr
# nlVjz03yVJ5QWRFQk5OzBsorHF5zOWelbtKWJktsv30dDBnIaJP/PSKA7qHMesxI
# sOF9V1MnBU4zVvQXdOpJrH687nn4ucA0RSpxywqJwDQTrkiv/2lksXcndteIDHKa
# CEjKL2cKv92iqf/M3i8S+hZLloz+2EM7QsQ0hhmIwSW30jFmauphpRzi8A+DCojn
# 0genckvB2AZpuYE05W4jV+umXakgw6+BlmKxqW0ldyPnz5SWLNtVFNrzBUNiROdH
# lItP+9qSm8UEcApzUwhsoYDzkTjw6jn0VDqWF0z6jto1gaBMcxaYSzwoEWInXgJQ
# ibwOtT0PAGi2QdH2WJXDNO0s0SaLQc0YkHmdUuBi6ExgfXQerCq+8Q1d03RN91K6
# oG4xzoIHcfuePkxy6WX5cgPXxWunYXHWGl02z5iakAuBrdBPBc+MBt0YsycUWNEB
# KjHJR1YDTs6YKanNcun6eRs4DEl6EluVRlHm50ClygiFZsdXod5dpCpbBeUGx24L
# VONDrcCe4bKdLB6I2ujYsGxWg8STfBrPNhFB93/MUlQQrw==
# SIG # End signature block
