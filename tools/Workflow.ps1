function Get-FireCache {
    param($Project, $Database)

    $fingerprint = Get-FireFingerprint $Project $Database
    $folder = Join-Path $Project.LocalRoot "cache/$($Database.name)/$fingerprint"
    $backup = Join-Path $folder $(if ($Project.Config.engine -eq 'sqlserver') { 'database.bak' } else { 'database.dump' })
    return [PSCustomObject]@{ Fingerprint = $fingerprint; Folder = $folder; Backup = $backup; Manifest = Join-Path $folder 'manifest.json' }
}

function Read-FireDatabaseSelection {
    param($Project, [string]$Title)

    $databases = @($Project.Config.databases)
    if ($databases.Count -eq 1) { return $databases }
    $choices = @([PSCustomObject]@{ Label = 'All databases'; Value = $null }) + @(
        $databases | ForEach-Object { [PSCustomObject]@{ Label = $_.name; Value = $_.name } }
    )
    $selection = Read-FireChoice $Title $choices
    if ($null -eq $selection) { return $databases }
    return @($databases | Where-Object { $_.name -eq $selection })
}

function Read-FireBackupSelection {
    param($Project, $Database)

    $folder = Join-Path $Project.LocalRoot 'backups'
    $files = @()
    if (Test-Path -LiteralPath $folder -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $folder -File -Filter '*.bak' |
            Where-Object { $_.Name -match "^(?i:$([regex]::Escape($Database.name)))_(?:before_restore_)?[0-9]{8}T[0-9]{9}Z_[0-9a-f]{8}\.bak$" } |
            Sort-Object LastWriteTime -Descending)
    }
    if (-not $files.Count) { throw "No backups found for '$($Database.name)' in '$folder'." }
    $choices = @($files | ForEach-Object { [PSCustomObject]@{ Label = $_.Name; Value = $_.FullName } })
    return Read-FireChoice "Backup for $($Database.name)" $choices
}

function Test-FireCache {
    param($Cache)

    if (-not (Test-Path -LiteralPath $Cache.Backup -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Cache.Manifest -PathType Leaf)) { return $false }
    try {
        $manifest = Get-Content -Raw -LiteralPath $Cache.Manifest | ConvertFrom-Json
        return $manifest.fingerprint -ceq $Cache.Fingerprint -and
            $manifest.sha256 -ceq (Get-FileHash -LiteralPath $Cache.Backup -Algorithm SHA256).Hash
    }
    catch { return $false }
}

function Backup-FireDatabase {
    param($Project, $Credentials, [string]$Database, [string]$TargetPath)

    if ($Project.Config.engine -eq 'sqlserver') { Backup-FireSqlServer $Project $Credentials $Database $TargetPath }
    else { Backup-FirePostgres $Project $Credentials $Database $TargetPath }
}

function Restore-FireDatabase {
    param($Project, $Credentials, [string]$Database, [string]$SourcePath, [string]$Activity)

    if (Test-FireDatabaseExists $Project $Credentials $Database) { throw "Restore target '$Database' already exists." }
    if ($Project.Config.engine -eq 'sqlserver') { Restore-FireSqlServer $Project $Credentials $Database $SourcePath -Activity $Activity }
    else { Restore-FirePostgres $Project $Credentials $Database $SourcePath -Activity $Activity }
}

function Export-FireBackup {
    param($Project, [string]$DatabaseName)

    if ($Project.Config.engine -ne 'sqlserver') { throw '.bak backup is available only for SQL Server projects.' }
    $database = Get-FireDatabase $Project $DatabaseName
    $container = Get-FireContainerJson $Project.Container
    if (-not $container -or -not $container.State.Running) { throw 'FIRE container is not running. Run fire up.' }
    Assert-FireOwnedContainer $Project $container
    $credentials = Get-FireCredentials $Project
    if (-not (Test-FireDatabaseExists $Project $credentials $database.name)) {
        throw "Database '$($database.name)' is missing. Run fire up."
    }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $target = Join-Path $Project.LocalRoot "backups/$($database.name)_${stamp}_$([Guid]::NewGuid().ToString('N').Substring(0, 8)).bak"
    if (Test-Path -LiteralPath $target) { throw "Backup already exists: '$target'." }
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    try { Backup-FireSqlServer $Project $credentials $database.name $target }
    catch {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        throw
    }
    Write-Host "SQL Server backup created: $target"
}

function Import-FireBackup {
    param($Project, [string]$DatabaseName, [string]$InputPath)

    if ($Project.Config.engine -ne 'sqlserver') { throw '.bak restore is available only for SQL Server projects.' }
    if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'Choose a backup to restore.' }
    $database = Get-FireDatabase $Project $DatabaseName
    $source = [IO.Path]::GetFullPath($InputPath)
    if ([IO.Path]::GetExtension($source) -ine '.bak' -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "SQL Server backup file is missing or is not .bak: '$source'."
    }
    $container = Get-FireContainerJson $Project.Container
    if (-not $container -or -not $container.State.Running) { throw 'FIRE container is not running. Run fire up.' }
    Assert-FireOwnedContainer $Project $container
    $credentials = Get-FireCredentials $Project
    Test-FireSqlServerBackup $Project $credentials $database.name $source
    $answer = Read-Host "Replace Main database '$($database.name)' in '$($Project.Container)' from '$source'? (y/n)"
    if ($answer -notmatch '^(?i:y|yes)$') { throw [OperationCanceledException]::new('Restore canceled.') }

    $recovery = $null
    if (Test-FireDatabaseExists $Project $credentials $database.name) {
        $folder = Join-Path $Project.LocalRoot 'backups'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
        $recovery = Join-Path $folder "$($database.name)_before_restore_${stamp}_$([Guid]::NewGuid().ToString('N').Substring(0, 8)).bak"
        try { Backup-FireSqlServer $Project $credentials $database.name $recovery }
        catch {
            if (Test-Path -LiteralPath $recovery) { Remove-Item -LiteralPath $recovery -Force }
            throw
        }
    }
    try { Restore-FireSqlServer $Project $credentials $database.name $source -ReplaceExisting }
    catch {
        $failure = $_.Exception.Message
        if ($recovery) {
            try { Restore-FireSqlServer $Project $credentials $database.name $recovery -ReplaceExisting }
            catch { throw "Restore failed: $failure. Recovery also failed: $($_.Exception.Message). Recovery backup: '$recovery'." }
            throw "Restore failed: $failure. Main was recovered from '$recovery'."
        }
        throw
    }
    Write-Host "Main database '$($database.name)' restored from '$source'."
    if ($recovery) { Write-Host "Previous Main backup: $recovery" }
    return $true
}

function Save-FireCache {
    param($Project, $Credentials, $Database, $Cache, [string]$SourceDatabase)

    if (Test-FireCache $Cache) { return }
    $work = New-FireWorkDirectory $Project 'cache'
    try {
        $temporary = Join-Path $work (Split-Path -Leaf $Cache.Backup)
        Backup-FireDatabase $Project $Credentials $SourceDatabase $temporary
        $manifest = [PSCustomObject]@{
            fingerprint = $Cache.Fingerprint
            sha256 = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
        }
        [IO.File]::WriteAllText((Join-Path $work 'manifest.json'), ($manifest | ConvertTo-Json) + "`n", [Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Path (Split-Path -Parent $Cache.Folder) -Force | Out-Null
        if (Test-Path -LiteralPath $Cache.Folder) { Remove-Item -LiteralPath $Cache.Folder -Recurse -Force }
        Move-Item -LiteralPath $work -Destination $Cache.Folder
        $work = $null
    }
    finally { if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force } }
}

function Get-FireShadowName {
    param($Project, $Database)
    return 'fire_shadow_' + (Get-FireHash "$($Project.Id):$($Database.name)").Substring(0, 12)
}

function Get-FireDatabaseIdentity {
    param($Project, $Credentials, [string]$Name)

    if ($Project.Config.engine -eq 'sqlserver') {
        return (Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "SELECT CONVERT(varchar(36), database_guid) FROM sys.database_recovery_status WHERE database_id=DB_ID(N'$Name');").Trim()
    }
    return (Invoke-FirePostgres $Project.Container $Credentials.password 'postgres' "SELECT oid FROM pg_database WHERE datname='$Name';").Trim()
}

function Get-FireShadowMarker {
    param($Project, $Database)

    $path = Join-Path $Project.LocalRoot "shadows/$($Database.name).json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

function Save-FireShadowMarker {
    param($Project, $Database, [string]$Identity, [string]$Fingerprint)

    $folder = Join-Path $Project.LocalRoot 'shadows'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $marker = [PSCustomObject]@{ identity = $Identity; fingerprint = $Fingerprint }
    [IO.File]::WriteAllText((Join-Path $folder "$($Database.name).json"), ($marker | ConvertTo-Json) + "`n", [Text.UTF8Encoding]::new($false))
}

function Set-FireShadowReadOnly {
    param($Project, $Credentials, [string]$Name)

    if ($Project.Config.engine -eq 'sqlserver') {
        Invoke-FireSqlServer $Project.Container $Credentials.password 'master' "ALTER DATABASE [$Name] SET READ_ONLY WITH ROLLBACK IMMEDIATE;" | Out-Null
    }
    # pg-schema-diff creates a temporary database from its source connection.
    # PostgreSQL Shadows must permit that validation step.
}

function Ensure-FireShadow {
    param($Project, $Credentials, $Database, $Cache)

    $name = Get-FireShadowName $Project $Database
    $exists = Test-FireDatabaseExists $Project $Credentials $name
    $marker = Get-FireShadowMarker $Project $Database
    if ($exists) {
        $identity = Get-FireDatabaseIdentity $Project $Credentials $name
        if (-not $marker -or $marker.identity -cne $identity) {
            throw "Database '$name' is not a known FIRE Shadow. Refusing to replace it."
        }
        if ($marker.fingerprint -ceq $Cache.Fingerprint -and (Test-FireCache $Cache)) {
            if ($Script:FireBrewing) { $Script:FireBrewing.Result.Outcome = 'already current' }
            return $name
        }
        Remove-FireDatabase $Project $Credentials $name
    }
    $hasCache = Test-FireCache $Cache
    $identity = $null
    try {
        if ($hasCache) {
            if ($Script:FireBrewing) { $Script:FireBrewing.Result.Outcome = 'restored from cache' }
            Set-FireBrewingPhase "Restoring Shadow $($Database.name) from cache backup" $(if ($Script:FireBrewing) { $Script:FireBrewing.Result })
            Restore-FireDatabase $Project $Credentials $name $Cache.Backup -Activity "Restoring Shadow for $($Database.name)"
        }
        else {
            if ($Script:FireBrewing) { $Script:FireBrewing.Result.Outcome = 'created from migrations' }
            Set-FireBrewingPhase "Creating Shadow $($Database.name) from migrations" $(if ($Script:FireBrewing) { $Script:FireBrewing.Result })
            New-FireDatabase $Project $Credentials $name
        }
        $identity = Get-FireDatabaseIdentity $Project $Credentials $name
        # Track ownership while building; an empty fingerprint cannot mark it current.
        Save-FireShadowMarker $Project $Database $identity ''
        if (-not $hasCache) {
            # Replay the schema using the Shadow's own connection.
            $shadowDatabase = [PSCustomObject]@{ name = $name; seedTables = $Database.seedTables }
            $shadowDatabase | Add-Member -NotePropertyName migrationOwner -NotePropertyValue $Database.name
            Invoke-FireFlyway $Project $Credentials $shadowDatabase 'migrate' -Activity "Migrating Shadow for $($Database.name)" | Out-Null
            Set-FireBrewingPhase "Saving cache for $($Database.name)" $(if ($Script:FireBrewing) { $Script:FireBrewing.Result })
            Save-FireCache $Project $Credentials $Database $Cache $name
        }
        Set-FireShadowReadOnly $Project $Credentials $name
        Save-FireShadowMarker $Project $Database $identity $Cache.Fingerprint
        return $name
    }
    catch {
        $failure = $_.Exception.Message
        try {
            if (-not $identity -and (Test-FireDatabaseExists $Project $Credentials $name)) {
                $identity = Get-FireDatabaseIdentity $Project $Credentials $name
                Save-FireShadowMarker $Project $Database $identity ''
            }
            Remove-FireDatabase $Project $Credentials $name
        }
        catch { throw "Shadow '$name' failed: $failure. Cleanup failed: $($_.Exception.Message). Run fire up to retry." }
        throw
    }
}

function Start-FireProject {
    param($Project, [switch]$ShowProgress, [bool]$Animations = $true)

    $mainResults = @{}
    $shadowResults = @{}
    $fresh = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($ShowProgress) { Start-FireBrewing -Animations:$Animations }
        $credentials = Get-FireCredentials $Project -Create
        $container = Start-FireContainer $Project $credentials
        $port = Get-FirePort $Project $container
        foreach ($database in @($Project.Config.databases)) {
            $result = New-FireBuildResult 'Main' $database.name $Project.Config.engine
            $mainResults[$database.name] = $result
            $result.Watch.Start()
            Set-FireBrewingPhase "Preparing Main $($database.name)" $result
            $cache = Get-FireCache $Project $database
            if (-not (Test-FireDatabaseExists $Project $credentials $database.name) -and -not (Test-FireCache $cache)) {
                Set-FireBrewingPhase "Creating Main $($database.name) from migrations" $result
                New-FireDatabase $Project $credentials $database.name
                [void]$fresh.Add($database.name)
                $result.Outcome = 'created from migrations'
            }
            $result.Watch.Stop()
        }
        foreach ($database in @($Project.Config.databases)) {
            $result = $mainResults[$database.name]
            $result.Watch.Start()
            Set-FireBrewingPhase "Preparing Main $($database.name)" $result
            $cache = Get-FireCache $Project $database
            if (-not (Test-FireDatabaseExists $Project $credentials $database.name)) {
                try {
                    Set-FireBrewingPhase "Restoring Main $($database.name) from cache backup" $result
                    Restore-FireDatabase $Project $credentials $database.name $cache.Backup -Activity "Restoring Main $($database.name) from cache"
                    $result.Outcome = 'restored from cache'
                }
                catch {
                    $restoreError = $_
                    try { Remove-FireDatabase $Project $credentials $database.name }
                    catch {
                        throw "$($restoreError.Exception.Message) Cleanup failed for partially restored Main '$($database.name)': $($_.Exception.Message) Remove this partial database with your DB editor before running fire up."
                    }
                    throw $restoreError
                }
            }
            $result.Watch.Stop()
        }
        foreach ($database in @($Project.Config.databases)) {
            $result = $mainResults[$database.name]
            $result.Watch.Start()
            Set-FireBrewingPhase "Migrating Main $($database.name)" $result
            Invoke-FireFlyway $Project $credentials $database 'migrate' -Activity "Migrating Main $($database.name)" | Out-Null
            if ($result.Changed -and $result.Outcome -eq 'already current') { $result.Outcome = 'updated' }
            $result.Watch.Stop()
        }
        foreach ($database in @($Project.Config.databases)) {
            if ($fresh.Contains($database.name)) {
                # Only a freshly replayed Main is a clean migration-built cache source.
                $result = $mainResults[$database.name]
                $result.Watch.Start()
                Set-FireBrewingPhase "Saving cache backup for $($database.name)" $result
                $cache = Get-FireCache $Project $database
                Save-FireCache $Project $credentials $database $cache $database.name
                $result.Watch.Stop()
            }
        }
        foreach ($database in @($Project.Config.databases)) {
            $result = New-FireBuildResult 'Shadow' $database.name $Project.Config.engine
            $shadowResults[$database.name] = $result
            $result.Watch.Start()
            Set-FireBrewingPhase "Preparing Shadow for $($database.name) from cache backup" $result
            $cache = Get-FireCache $Project $database
            $shadow = Ensure-FireShadow $Project $credentials $database $cache
            $result.Watch.Stop()
            if (-not $ShowProgress) { Write-Host "$($database.name): ready | Shadow $shadow" }
        }
    }
    finally {
        $watch.Stop()
        foreach ($result in @($mainResults.Values) + @($shadowResults.Values)) { $result.Watch.Stop() }
        if ($ShowProgress) { Stop-FireBrewing }
    }
    if ($ShowProgress) {
        foreach ($database in @($Project.Config.databases)) {
            Write-FireBuildResult $mainResults[$database.name]
            Write-FireBuildResult $shadowResults[$database.name]
        }
        Write-FireTimedText 'FIRE up completed' $watch.Elapsed
    }
    Write-Host "127.0.0.1:$port"
}

function Show-FireStatus {
    param($Project)

    $container = Get-FireContainerJson $Project.Container
    if (-not $container) { Write-FireText 'FIRE container missing. Run fire up.'; return }
    Assert-FireOwnedContainer $Project $container
    if (-not $container.State.Running) { Write-FireText 'FIRE container stopped. Run fire up.'; return }
    $credentials = Get-FireCredentials $Project
    Write-Host "Container: $($Project.Container)"
    Write-Host "Endpoint: 127.0.0.1:$(Get-FirePort $Project $container)"
    foreach ($database in @($Project.Config.databases)) {
        if (-not (Test-FireDatabaseExists $Project $credentials $database.name)) {
            Write-Host "$($database.name): missing"
            continue
        }
        $version = if ($Project.Config.engine -eq 'sqlserver') {
            $query = "IF OBJECT_ID(N'dbo.flyway_schema_history',N'U') IS NULL SELECT N'none' ELSE SELECT COALESCE(MAX(version),N'none') FROM dbo.flyway_schema_history WHERE success=1;"
            Invoke-FireSqlServer $Project.Container $credentials.password $database.name $query
        }
        else {
            $history = Invoke-FirePostgres $Project.Container $credentials.password $database.name "SELECT to_regclass('public.flyway_schema_history') IS NOT NULL;"
            if ($history.Trim() -eq 't') {
                Invoke-FirePostgres $Project.Container $credentials.password $database.name "SELECT COALESCE(MAX(version),'none') FROM public.flyway_schema_history WHERE success=true;"
            }
            else { 'none' }
        }
        $cache = Get-FireCache $Project $database
        $marker = Get-FireShadowMarker $Project $database
        $cacheReady = Test-FireCache $cache
        $shadowState = 'needs refresh'
        if ($marker -and $marker.fingerprint -ceq $cache.Fingerprint -and $cacheReady) {
            $shadow = Get-FireShadowName $Project $database
            if ((Test-FireDatabaseExists $Project $credentials $shadow) -and
                $marker.identity -ceq (Get-FireDatabaseIdentity $Project $credentials $shadow)) {
                $shadowState = 'current'
            }
        }
        Write-Host "$($database.name): migration $($version.Trim()), cache $(if ($cacheReady) {'ready'} else {'missing'}), Shadow $shadowState"
    }
}

function Show-FireConnection {
    param($Project, [string]$DatabaseName)

    $database = Get-FireDatabase $Project $DatabaseName
    $container = Get-FireContainerJson $Project.Container
    if (-not $container -or -not $container.State.Running) { throw 'FIRE container is not running. Run fire up.' }
    Assert-FireOwnedContainer $Project $container
    $credentials = Get-FireCredentials $Project
    Write-Host "Engine: $($Project.Config.engine)"
    Write-Host "Host: 127.0.0.1"
    Write-Host "Port: $(Get-FirePort $Project $container)"
    Write-Host "Database: $($database.name)"
    Write-Host "User: $($credentials.user)"
    Write-Host "Password: $($credentials.password)"
}

# SIG # Begin signature block
# MIIdvgYJKoZIhvcNAQcCoIIdrzCCHasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDx4byX+i/PI8PD
# EHeBf/h521hRX9BVhUE9Bog7QJLdCKCCF3IwggQ0MIICnKADAgECAhAq44+Z0deO
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
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIG6xtUZMO9JKDivq
# CAPHMc/L+nm51lVZyzF9/xwd6Z6pMA0GCSqGSIb3DQEBAQUABIIBgBBzuP1IcGgn
# ZzmkB2H3NcfkIhVqfTDrixb1F7AlML1ompCvTzfApM8rn2/HzeMrZ0VPyFjCCdHG
# W0bhAD7277povdu4K51etFALxnAgvbxOdhVAXw7mdWbPiZvD9M8tgmtugPT61UJG
# VZ/yFWMEVxFv8tHgir0BfDIlclzO4SAgbLJxaO2Y3Vd6cDeN4s1lV0zrFsU0FGAI
# 8SC4qPKjNYH7OOXhXrLOqETdq7KwPxuSwTl8ks56q8lmyZVDNJcFU1BigCtciXZq
# FAVDNlyNCSTXucNHxrH8+TmI/8uQwGrAQK55cDwTLoOj0OSvz5WNNai8Frrx++cT
# ttwvyVyifWvib30HPcMqn7NOBg+BJAgedrEAhj8epGvRE1El2PaWAlG8p2DXdThF
# 9qSLWWIAkSSQxs8YjtA/xGqwnONZ50meTKzExPRtpDc7Ulo3jj9LNJVFxqAMvHjz
# mOb4+1IDNJ/MeqpL/Es1mGHV/3vfcYBGCb4aTSJzyJ1dxu+8vhL8fqGCAyYwggMi
# BgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQK
# Ew5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBU
# aW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MP
# j/mSGDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcB
# MBwGCSqGSIb3DQEJBTEPFw0yNjEwMDExOTU1MjZaMC8GCSqGSIb3DQEJBDEiBCDm
# zOSMA8zccPFO6jk744rQ81oWwY6FBeGLZ1Wx5Jtn7DANBgkqhkiG9w0BAQEFAASC
# AgAecB9qAZ+sa3fzRYHIxm9LEkcH1WZ5PUcK+50rmRJp5znMUVGDJ4SjJmyGacBu
# /H9vjRZpEVt3x0wF2gryE6AYJWFoGzTx4ln7+eKKV33n5xk26NIEsZ8CYVyTBqr+
# fw/JTQnAQJsXpMsCPCtdlkBHxnt4ZyxU8k+JLj/6dy1rWcXi9OMOCQt58zqGmU7O
# D6gJrxzTDgAqedLvaESBVHhmjaPNQgPVpzWKgV3ogubtmeUd0aNPmzMHehNugxPW
# r9GGzT2STGTsg1icFXnSH/Np+tPsrgEzurDzRLHeHVscF90LiyTyyqqNcZudQS6+
# D1kNIgZirwbN+YQ2j0GPJj9TfwXRPeSMcCbQgeWiSO8TlXZAPFoA6ZOyx7cQJXHd
# WuRyHdXXFj7mo0V07+Q5qXX+qbKGCD/kiiNy1v7Tk9vJjAtDKWD7KzpC5199TOQ1
# 4/doN9DOymIL64xGvBcrgolTTR/uhLigpXph/nQCRSQ/IeQkt9JDheiLFOihBnji
# d1jbNewLtWrNc7fnMgy0KJIFLly+Pw9b5MFoHUyG0w9oFvIAYnT4Fw0RPLm1QX09
# zfIpacWLHiW86FrnREFkhddbPRwEQjaw6UZUxYcWjrlWarOf/yTeRlXlPsMXUpba
# WQ4ZY7x/3JtyuEPve7HugSKGJsOODuKtMrlM3MosOLLbug==
# SIG # End signature block
