function Get-FireNextMigrationPath {
    param($Project, $Database, [string]$Feature)

    $safe = ($Feature -replace '[^A-Za-z0-9]+', '_').Trim('_')
    if (-not $safe) { throw 'Feature name must contain letters or digits.' }
    $path = Get-FireMigrationsPath $Project $Database
    $versions = @(Get-ChildItem -LiteralPath $path -File -Filter 'V*__*.sql' | ForEach-Object {
        if ($_.Name -notmatch '^V([0-9]{5})__[A-Za-z0-9_]+\.sql$') { throw "Invalid migration name '$($_.Name)'." }
        [int]$Matches[1]
    })
    $next = [int](($versions | Measure-Object -Maximum).Maximum + 1)
    if ($next -gt 99999) { throw 'Migration version limit reached.' }
    return Join-Path $path ('V{0:D5}__{1}.sql' -f $next, $safe)
}

function Invoke-FireSqlFile {
    param($Project, $Credentials, [string]$Database, [string]$Path)

    $inContainer = "/tmp/fire_$([Guid]::NewGuid().ToString('N')).sql"
    Invoke-FireNative docker @('cp', $Path, "$($Project.Container):$inContainer") | Out-Null
    try {
        if ($Project.Config.engine -eq 'sqlserver') {
            $sqlcmd = Get-FireSqlcmd $Project.Container
            $args = @('exec', '-e', "SQLCMDPASSWORD=$($Credentials.password)", $Project.Container, $sqlcmd,
                '-S', 'localhost', '-U', 'sa', '-d', $Database, '-b', '-r', '1')
            if ($sqlcmd -like '*tools18*') { $args += '-C' }
            $args += @('-i', $inContainer)
            Invoke-FireNative docker $args | Out-Null
        }
        else {
            Invoke-FireNative docker @('exec', '-e', "PGPASSWORD=$($Credentials.password)", $Project.Container,
                'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', $Database, '-f', $inContainer) | Out-Null
        }
    }
    finally { Invoke-FireNative docker @('exec', $Project.Container, 'rm', '-f', $inContainer) -AllowFailure | Out-Null }
}

function Remove-FireWorkingDatabase {
    param($Project, $Credentials, [string]$Name, $Failure)

    try { Remove-FireDatabase $Project $Credentials $Name }
    catch {
        $message = "Cleanup failed for temporary database '$Name': $($_.Exception.Message) Remove this temporary database with your DB editor before retrying generation."
        if ($Failure) { $message = "$($Failure.Exception.Message) $message" }
        throw $message
    }
}

function New-FireWorkingDatabase {
    param($Project, $Credentials, $Database, $Cache)

    $name = 'fire_verify_' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
    if (Test-FireDatabaseExists $Project $Credentials $name) { throw "Temporary database '$name' already exists. Refusing to replace it." }
    try {
        if (Test-FireCache $Cache) { Restore-FireDatabase $Project $Credentials $name $Cache.Backup }
        else {
            New-FireDatabase $Project $Credentials $name
            $copy = [PSCustomObject]@{ name = $name; migrationOwner = $Database.name }
            Invoke-FireFlyway $Project $Credentials $copy 'migrate' | Out-Null
        }
        return $name
    }
    catch {
        $buildError = $_
        Remove-FireWorkingDatabase $Project $Credentials $name $buildError
        throw $buildError
    }
}

function Test-FireMigrationRecorded {
    param($Project, $Credentials, $Database, [string]$Path)

    $scriptName = (Split-Path -Leaf $Path).Replace("'", "''")
    if ($Project.Config.engine -eq 'sqlserver') {
        $query = "IF OBJECT_ID(N'dbo.flyway_schema_history',N'U') IS NULL SELECT 0 ELSE SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.flyway_schema_history WHERE script=N'$scriptName') THEN 1 ELSE 0 END;"
        $result = Invoke-FireSqlServer $Project.Container $Credentials.password $Database.name $query -User $Credentials.user
    }
    else {
        $history = Invoke-FirePostgres $Project.Container $Credentials.password $Database.name "SELECT to_regclass('public.flyway_schema_history') IS NOT NULL;" -User $Credentials.user
        if ($history.Trim() -ceq 'f') { return $false }
        if ($history.Trim() -cne 't') { throw "Unexpected migration history result for '$($Database.name)'." }
        $query = "SELECT CASE WHEN EXISTS (SELECT 1 FROM public.flyway_schema_history WHERE script='$scriptName') THEN 1 ELSE 0 END;"
        $result = Invoke-FirePostgres $Project.Container $Credentials.password $Database.name $query -User $Credentials.user
    }
    if ($result.Trim() -notin @('0', '1')) { throw "Unexpected migration history result for '$($Database.name)'." }
    return $result.Trim() -eq '1'
}

function Assert-FireCandidateMatches {
    param($Project, $Credentials, $Database, [string]$Candidate, $Cache, [string]$Work)

    $verification = New-FireWorkingDatabase $Project $Credentials $Database $Cache
    $verificationError = $null
    try {
        $copy = [PSCustomObject]@{ name = $verification; migrationOwner = $Database.name }
        Invoke-FireFlyway $Project $Credentials $copy 'migrate' (Split-Path -Parent $Candidate) | Out-Null
        $schemaEqual = if ($Project.Config.engine -eq 'sqlserver') {
            Test-FireSqlServerSchemaEqual $Project $Credentials $Database.name $verification $Work
        }
        else { Test-FirePostgresSchemaEqual $Project $Credentials $Database.name $verification }
        if (-not $schemaEqual) { throw "Candidate schema does not match Main for '$($Database.name)'." }
        Assert-FireSeedEqual $Project $Credentials $Database.name $verification $Database
    }
    catch { $verificationError = $_; throw }
    finally { Remove-FireWorkingDatabase $Project $Credentials $verification $verificationError }
}

function Generate-FireMigration {
    param($Project, [string]$DatabaseName, [string]$Feature)

    $database = Get-FireDatabase $Project $DatabaseName
    Start-FireProject $Project
    $credentials = Get-FireCredentials $Project
    $cache = Get-FireCache $Project $database
    $shadow = Ensure-FireShadow $Project $credentials $database $cache
    $target = Get-FireNextMigrationPath $Project $database $Feature
    if (Test-Path -LiteralPath $target) { throw "Migration already exists: '$target'." }
    $work = New-FireWorkDirectory $Project 'generate'
    $workDatabase = $null
    $success = $false
    $generationError = $null
    try {
        $workDatabase = New-FireWorkingDatabase $Project $credentials $database $cache
        $schema = if ($Project.Config.engine -eq 'sqlserver') {
            if (Test-FireSqlServerSchemaEqual $Project $credentials $database.name $shadow $work) { '' }
            else { Get-FireSqlServerSchemaScript $Project $credentials $database.name $shadow $work }
        }
        else {
            $pgScript = Invoke-FirePgDiff $Project $credentials $shadow $database.name
            if (-not $pgScript.Trim() -and -not (Test-FirePostgresSchemaEqual $Project $credentials $database.name $shadow)) {
                throw 'Unsupported PostgreSQL schema difference. Write a reviewed SQL migration.'
            }
            $pgScript
        }
        if ($schema.Trim()) {
            $schemaPath = Join-Path $work 'schema.sql'
            [IO.File]::WriteAllText($schemaPath, $schema, [Text.UTF8Encoding]::new($false))
            Invoke-FireSqlFile $Project $credentials $workDatabase $schemaPath
        }
        $data = @($database.seedTables | ForEach-Object {
            Get-FireSeedDelta $Project $credentials $workDatabase $database.name $_
        }) -join "`n"
        if (-not $schema.Trim() -and -not $data.Trim()) { throw 'No schema or configured reference-row changes found.' }
        $candidate = Join-Path $work (Split-Path -Leaf $target)
        $content = "-- Generated by FIRE. Review before commit.`n$schema`n$data"
        [IO.File]::WriteAllText($candidate, $content, [Text.UTF8Encoding]::new($false))
        Assert-FireCandidateMatches $Project $credentials $database $candidate $cache $work
        Move-Item -LiteralPath $candidate -Destination $target
        try {
            Invoke-FireFlyway $Project $credentials $database 'migrate' -SkipExecuting | Out-Null
        }
        catch {
            $registrationError = $_
            try { $recorded = Test-FireMigrationRecorded $Project $credentials $database $target }
            catch {
                throw "$($registrationError.Exception.Message) Could not check migration history: $($_.Exception.Message) SQL kept at '$target'. Check migration history before running 'fire up'."
            }
            if ($recorded) {
                throw "$($registrationError.Exception.Message) Migration exists in Main's history. SQL kept at '$target'. Fix the reported Flyway error before running 'fire up'."
            }
            try { Move-Item -LiteralPath $target -Destination $candidate }
            catch {
                throw "$($registrationError.Exception.Message) Could not return migration to '$candidate': $($_.Exception.Message) Review '$target' before running 'fire up'."
            }
            throw $registrationError
        }
        $success = $true
        Write-Host "Migration created and verified: $target"
    }
    catch { $generationError = $_; throw }
    finally {
        $cleaned = $false
        try {
            if ($workDatabase) { Remove-FireWorkingDatabase $Project $credentials $workDatabase $generationError }
            $cleaned = $true
        }
        finally {
            if ($success -and $cleaned) {
                $allowed = [IO.Path]::GetFullPath((Join-Path $Project.LocalRoot 'work')).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                $resolved = [IO.Path]::GetFullPath($work)
                if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected generation cleanup path.' }
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
            else { Write-Warning "Generation debug files: $work" }
        }
    }
}

# SIG # Begin signature block
# MIIdvgYJKoZIhvcNAQcCoIIdrzCCHasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAPZtgxeEEbI45t
# r/d8eWKuBDpipJS/VAZcYbLS3XNUgaCCF3IwggQ0MIICnKADAgECAhAq44+Z0deO
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
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIBg+4EczWAAZeYVv
# IZufN+IKTjB/cK2GQi/bZtyIHuklMA0GCSqGSIb3DQEBAQUABIIBgB9NRBsO1y5b
# q1VFHETRZzQJWvy5O4RuQUdp23y6+tW1DAA9Iws37U734XVRRb9CHEH6twWjbXTF
# OzkPqLts9DRMzRhZh++5H5XyiPNlUsHRrvDLA0dhCXcIxzcenBZJFF/DCNX+7sE2
# eYkGKUtcdUAhcbPNTO7gyJlrJAcJCvJtlta681fPCaHTcQ7XtbiCw6KByAMJPxAM
# ynWcxCkHsK9B60NdLxKotFcwZl/1XBPyWcoKm6ZD8HiVWBZR7VDi5UbXorTKhx4S
# ZE6+lmUU+u5QIjCryZF/YkK9wHaobJ3PeD9W8kwEYCMwNSuwJM9VDzcNXcPBIxXH
# 8Jv7UYOkPbTwgRyE9LUy9tgA8gl3v5BVFPo5oiWbWWhveq1AKAdgoQFEmBAsVhE3
# /lycyIKQ6nCZzk24sv+Y0ZWFETcS+ac4uHzwnzKa2efSo6UC+l9O1qtkjRqJ8f+/
# o3evXHF321FTZHQpy6ZKATqvt2n+muIK7B4Sz15naNFDJfoCP/iMeKGCAyYwggMi
# BgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQK
# Ew5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBU
# aW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MP
# j/mSGDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcB
# MBwGCSqGSIb3DQEJBTEPFw0yNjEwMDExOTU1MjRaMC8GCSqGSIb3DQEJBDEiBCBF
# rNQza+zMudFDF0E8FYK1dDYyNkvrIekflMhORb+L0DANBgkqhkiG9w0BAQEFAASC
# AgBUvUWCmYbA/+cB0EuqNwLhAygHgRlzgHQnhFdfKu5vZbIPCDD+14RjywuaLhdQ
# onO8VaGmqbI/S3nQQObb4+cK8s+UwSILixPhO+1CbKd9LhCD76FRJCFdpTigqyJ1
# sCQMFUK8OOf1OiXJpB5xWwz1Z1w1QjPxHR6k68/k+8QHFZwYS3g6RN08FBMeEMzZ
# Y+r6QOcNBSNfnG+gcsB6D/BygsqsE6MWerTJxHv7xtWVtWRcMEfTnYg4FjZbK3AB
# Tij5+t4uccxZqi1Qt5NoXAMIHcUfiZBSCoEpEJPh3CBjc5l06TdxqX3gPTDfcgEN
# BLE4G1pUmWGBwIwvv/Nc2xx7iMLgL8gBA9aI0t7Qd47vUIETI55xUw2qkeRAzu5v
# OegTLQZ7JWH2h5m/UQg8qGoY2M28B8NYo5j2kNBEiAc3KnAqPYZVK1jWFTWbU9zD
# wE0xx/duxBgJ8imKdauEoX3rM6/Dh4ffYDf1HEBwuruwSND3/N6uAVk+eD/HAnAX
# LuIGdC07984dk3FsNcmzpigZ+bJej1nBtMlIpAG+6eFdGnemLa9OzccOPmAJefzC
# On1iU/XFSqYNCizJeRYoeiioELlyFPicnoTwju2ic5kDpXZZgkLUT5Ll4a7yxTUh
# 7koPZKX2rqU7xYlg3HA7gTHYlfp5XLhABlgeA96h9HxXYw==
# SIG # End signature block
