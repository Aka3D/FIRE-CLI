function Format-FireIdentifier {
    param([string]$Name, [string]$Engine)

    if ($Engine -eq 'sqlserver') { return '[' + $Name.Replace(']', ']]') + ']' }
    return '"' + $Name.Replace('"', '""') + '"'
}

function Get-FireSeedKeyIndexes {
    param($Project, $Table, [object[]]$Columns)

    $names = @($Columns.Name)
    foreach ($key in @($Table.key)) {
        $index = [array]::IndexOf($names, $key)
        if ($index -lt 0 -and $Project.Config.engine -eq 'sqlserver') {
            $index = 0
            while ($index -lt $names.Count -and -not [StringComparer]::OrdinalIgnoreCase.Equals($names[$index], $key)) { $index++ }
        }
        if ($index -lt 0 -or $index -ge $names.Count) { throw "Seed key '$key' is missing in '$($Table.name)'." }
        $index
    }
}

function Get-FireSeedColumns {
    param($Project, $Credentials, [string]$Database, $Table)

    $parts = [string]$Table.name -split '\.', 2
    $schema = $parts[0]
    $name = $parts[1]
    if ($Project.Config.engine -eq 'sqlserver') {
        $query = "SET NOCOUNT ON; SELECT c.name + N'|' + TYPE_NAME(c.system_type_id) + N'|' + CONVERT(varchar(1), c.is_identity) FROM sys.columns c JOIN sys.tables t ON t.object_id=c.object_id JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name=N'$schema' AND t.name=N'$name' AND c.is_computed=0 AND TYPE_NAME(c.system_type_id) NOT IN (N'timestamp',N'rowversion') ORDER BY c.column_id;"
        $output = Invoke-FireSqlServer $Project.Container $Credentials.password $Database $query -User $Credentials.user
    }
    else {
        $query = "SELECT a.attname || '|' || format_type(a.atttypid,a.atttypmod) || '|' || CASE WHEN a.attidentity <> '' THEN '1' ELSE '0' END FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='$schema' AND c.relname='$name' AND c.relkind IN ('r','p') AND a.attnum>0 AND NOT a.attisdropped AND a.attgenerated='' ORDER BY a.attnum;"
        $output = Invoke-FirePostgres $Project.Container $Credentials.password $Database $query -User $Credentials.user
    }
    $columns = @($output -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        if ($_ -notmatch '^[^|]+\|[^|]+\|[01]$') {
            throw "Unsupported reference-column metadata in '$($Table.name)' ($Database). Check column names and types for pipes or line breaks."
        }
        $p = $_ -split '\|', 3
        [PSCustomObject]@{ Name = $p[0]; Type = $p[1].ToLowerInvariant(); Identity = $p[2] -eq '1' }
    })
    if ($columns.Count -eq 0) { throw "Seed table '$($Table.name)' is missing or has no insertable columns in '$Database'." }
    Get-FireSeedKeyIndexes $Project $Table $columns | Out-Null
    return $columns
}

function Get-FireSqlLiteralExpression {
    param($Column)

    $name = Format-FireIdentifier $Column.Name 'sqlserver'
    $value = switch ($Column.Type) {
        { $_ -in @('varchar', 'char', 'text') } { "N'''' + REPLACE(CONVERT(varchar(max), $name), '''', '''''') + N''''"; break }
        { $_ -in @('nvarchar', 'nchar', 'ntext', 'xml', 'sysname') } { "N'N''' + REPLACE(CONVERT(nvarchar(max), $name), N'''', N'''''') + N''''"; break }
        { $_ -in @('tinyint', 'smallint', 'int', 'bigint', 'decimal', 'numeric', 'bit') } { "CONVERT(nvarchar(100), $name)"; break }
        { $_ -in @('money', 'smallmoney') } { "CONVERT(nvarchar(100), $name, 2)"; break }
        { $_ -in @('float', 'real') } { "CONVERT(nvarchar(100), $name, 3)"; break }
        { $_ -in @('binary', 'varbinary', 'image') } { "N'0x' + CONVERT(nvarchar(max), $name, 2)"; break }
        'date' { "N'CONVERT(date,N''' + CONVERT(nvarchar(30), $name, 23) + N''',23)'"; break }
        { $_ -in @('datetime', 'smalldatetime') } { "N'CONVERT($($Column.Type),N''' + CONVERT(nvarchar(30), $name, 121) + N''',121)'"; break }
        { $_ -in @('datetime2', 'time') } { "N'CONVERT($($Column.Type),N''' + CONVERT(nvarchar(40), $name, 126) + N''',126)'"; break }
        'datetimeoffset' { "N'CONVERT(datetimeoffset,N''' + CONVERT(nvarchar(50), $name, 127) + N''',127)'"; break }
        'uniqueidentifier' { "N'N''' + CONVERT(nvarchar(36), $name) + N''''"; break }
        default { throw "Unsupported SQL Server seed type '$($Column.Type)' in '$($Column.Name)'." }
    }
    return "CASE WHEN $name IS NULL THEN N'NULL' ELSE $value END"
}

function Assert-FireSeedKeysUnique {
    param($Project, $Credentials, [string]$Database, $Table)

    $parts = [string]$Table.name -split '\.', 2
    $qualified = if ($Project.Config.engine -eq 'sqlserver') { "[$($parts[0])].[$($parts[1])]" }
    else { "`"$($parts[0])`".`"$($parts[1])`"" }
    $keys = @($Table.key | ForEach-Object { Format-FireIdentifier $_ $Project.Config.engine })
    $group = $keys -join ', '
    $nulls = @($keys | ForEach-Object { "$_ IS NULL" }) -join ' OR '
    $query = "SELECT CASE WHEN EXISTS (SELECT 1 FROM $qualified GROUP BY $group HAVING COUNT(*) > 1) OR EXISTS (SELECT 1 FROM $qualified WHERE $nulls) THEN 1 ELSE 0 END;"
    $result = if ($Project.Config.engine -eq 'sqlserver') {
        Invoke-FireSqlServer $Project.Container $Credentials.password $Database $query -User $Credentials.user
    }
    else { Invoke-FirePostgres $Project.Container $Credentials.password $Database $query -User $Credentials.user }
    if ($result.Trim() -ne '0') { throw "Reference table '$($Table.name)' needs unique, non-null configured keys." }
}

function Get-FireSeedRows {
    param($Project, $Credentials, [string]$Database, $Table, [object[]]$Columns)

    $keyIndexes = @(Get-FireSeedKeyIndexes $Project $Table $Columns)
    Assert-FireSeedKeysUnique $Project $Credentials $Database $Table
    $parts = [string]$Table.name -split '\.', 2
    if ($Project.Config.engine -eq 'postgresql') {
        $qualified = '"' + $parts[0] + '"."' + $parts[1] + '"'
        $values = @($Columns | ForEach-Object { "quote_nullable(t.$(Format-FireIdentifier $_.Name 'postgresql'))" }) -join ', '
        $output = Invoke-FirePostgres $Project.Container $Credentials.password $Database "SELECT replace(encode(convert_to(json_build_array($values)::text,'UTF8'),'base64'), chr(10), '') FROM $qualified t;" -User $Credentials.user
        $records = @($output -split '\r?\n' | Where-Object { $_ } | ForEach-Object {
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Trim()))
            [PSCustomObject]@{ Values = @(ConvertFrom-Json -InputObject $json) }
        })
    }
    else {
        $qualified = "[$($parts[0])].[$($parts[1])]"
        $expressions = @($Columns | ForEach-Object -Begin { $i = 0 } -Process {
            $result = "$(Get-FireSqlLiteralExpression $_) AS [v$i]"
            $i++
            $result
        }) -join ', '
        $query = @"
SET NOCOUNT ON;
WITH R AS (
    SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS rn,
           CONVERT(varbinary(max), (SELECT $expressions FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS data
    FROM $qualified
), C AS (
    SELECT rn, 1 AS chunk, data FROM R
    UNION ALL
    SELECT rn, chunk+1, data FROM C WHERE DATALENGTH(data) > chunk * 8000
)
SELECT CONVERT(varchar(20),rn) + '|' + CONVERT(varchar(20),chunk) + '|' +
       CONVERT(varchar(max),SUBSTRING(data,((chunk-1)*8000)+1,8000),2)
FROM C ORDER BY rn,chunk OPTION (MAXRECURSION 0);
"@
        $output = Invoke-FireSqlServer $Project.Container $Credentials.password $Database $query -Wide -User $Credentials.user
        $chunks = @($output -split '\r?\n' | Where-Object { $_ -match '^\d+\|\d+\|[0-9A-F]+$' } | ForEach-Object {
            $p = $_ -split '\|', 3
            [PSCustomObject]@{ Row = [long]$p[0]; Chunk = [int]$p[1]; Hex = $p[2] }
        })
        $records = @($chunks | Group-Object Row | Sort-Object { [long]$_.Name } | ForEach-Object {
            $hex = @($_.Group | Sort-Object Chunk | ForEach-Object Hex) -join ''
            $json = [Text.Encoding]::Unicode.GetString([Convert]::FromHexString($hex))
            $object = ConvertFrom-Json -InputObject $json
            [PSCustomObject]@{ Values = @($Columns | ForEach-Object -Begin { $i = 0 } -Process { $value = $object."v$i"; $i++; $value }) }
        })
    }
    $map = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($record in $records) {
        $values = @($record.Values)
        if ($values.Count -ne $Columns.Count) { throw "Unexpected seed row width in '$($Table.name)'." }
        $keyValues = @($keyIndexes | ForEach-Object { $values[$_] })
        if ($keyValues -contains 'NULL') { throw "Seed key contains NULL in '$($Table.name)'." }
        $key = ConvertTo-Json -InputObject $keyValues -Compress -Depth 5
        if ($map.ContainsKey($key)) { throw "Duplicate seed key $key in '$($Table.name)'." }
        $map.Add($key, [PSCustomObject]@{ Key = $keyValues; Values = $values; Hash = Get-FireHash ($values -join "`u{1F}") })
    }
    return ,$map
}

function Get-FirePostgresSeedSequenceScript {
    param($Table, [object[]]$Columns)

    $integerColumns = @($Columns | Where-Object { $_.Type -in @('smallint', 'integer', 'bigint') })
    if (-not $integerColumns.Count) { return '' }
    $qualified = ('"' + ([string]$Table.name).Replace('.', '"."') + '"').Replace("'", "''")
    $names = @($integerColumns | ForEach-Object { "'$($_.Name.Replace("'", "''"))'" }) -join ', '
    return @"
DO `$fire_seed`$
DECLARE
    column_name text;
    sequence_name regclass;
    sequence_step bigint;
    sequence_last bigint;
    sequence_called boolean;
    row_limit bigint;
BEGIN
    FOREACH column_name IN ARRAY ARRAY[$names] LOOP
        sequence_name := pg_get_serial_sequence('$qualified', column_name)::regclass;
        IF sequence_name IS NULL THEN CONTINUE; END IF;
        SELECT seqincrement INTO sequence_step FROM pg_sequence WHERE seqrelid = sequence_name;
        EXECUTE format('SELECT %s(%I) FROM %s', CASE WHEN sequence_step > 0 THEN 'MAX' ELSE 'MIN' END, column_name, '$qualified') INTO row_limit;
        IF row_limit IS NULL THEN CONTINUE; END IF;
        EXECUTE format('SELECT last_value, is_called FROM %s', sequence_name) INTO sequence_last, sequence_called;
        IF (sequence_step > 0 AND row_limit > sequence_last)
           OR (sequence_step < 0 AND row_limit < sequence_last)
           OR (row_limit = sequence_last AND NOT sequence_called) THEN
            PERFORM setval(sequence_name, row_limit, true);
        END IF;
    END LOOP;
END;
`$fire_seed`$;
"@
}

function Get-FireSeedDelta {
    param($Project, $Credentials, [string]$From, [string]$To, $Table)

    $columns = @(Get-FireSeedColumns $Project $Credentials $To $Table)
    $fromColumns = @(Get-FireSeedColumns $Project $Credentials $From $Table)
    if ((@($columns | ForEach-Object { "$($_.Name):$($_.Type):$($_.Identity)" }) -join '|') -cne
        (@($fromColumns | ForEach-Object { "$($_.Name):$($_.Type):$($_.Identity)" }) -join '|')) {
        throw "Seed table '$($Table.name)' has different columns after schema diff. Write a reviewed data migration."
    }
    $before = Get-FireSeedRows $Project $Credentials $From $Table $columns
    $after = Get-FireSeedRows $Project $Credentials $To $Table $columns
    $uniqueKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in @($before.Keys) + @($after.Keys)) { [void]$uniqueKeys.Add($key) }
    $keys = @($uniqueKeys | Sort-Object -CaseSensitive)
    $qualified = if ($Project.Config.engine -eq 'sqlserver') {
        '[' + ([string]$Table.name).Replace('.', '].[') + ']'
    }
    else { '"' + ([string]$Table.name).Replace('.', '"."') + '"' }
    $quote = { param($Name) Format-FireIdentifier $Name $Project.Config.engine }
    $columnList = @($columns | ForEach-Object { & $quote $_.Name }) -join ', '
    $identity = @($columns | Where-Object Identity).Count -gt 0
    $keyNames = @(Get-FireSeedKeyIndexes $Project $Table $columns | ForEach-Object { $columns[$_].Name })
    $updates = @($columns | Where-Object { $_.Name -cnotin $keyNames -and -not $_.Identity })
    $script = [Text.StringBuilder]::new()
    $hasInserts = @($keys | Where-Object { -not $before.ContainsKey($_) -and $after.ContainsKey($_) }).Count -gt 0
    if ($hasInserts -and $identity -and $Project.Config.engine -eq 'sqlserver') { [void]$script.AppendLine("SET IDENTITY_INSERT $qualified ON;") }
    foreach ($key in $keys) {
        $old = if ($before.ContainsKey($key)) { $before[$key] } else { $null }
        $new = if ($after.ContainsKey($key)) { $after[$key] } else { $null }
        if ($old -and $new -and $old.Hash -eq $new.Hash) { continue }
        $keyClause = @($keyNames | ForEach-Object -Begin { $i = 0 } -Process {
            $name = & $quote $_
            $value = if ($old) { $old.Key[$i] } else { $new.Key[$i] }
            $i++
            "$name = $value"
        }) -join ' AND '
        if (-not $new) { [void]$script.AppendLine("DELETE FROM $qualified WHERE $keyClause;"); continue }
        if (-not $old) {
            $override = if ($identity -and $Project.Config.engine -eq 'postgresql') { ' OVERRIDING SYSTEM VALUE' } else { '' }
            [void]$script.AppendLine("INSERT INTO $qualified ($columnList)$override VALUES ($($new.Values -join ', '));")
            continue
        }
        if ($updates.Count -eq 0) { throw "Seed row changed only key or identity columns in '$($Table.name)'." }
        $assignments = @($updates | ForEach-Object {
            $index = [array]::IndexOf(@($columns.Name), $_.Name)
            "$(& $quote $_.Name) = $($new.Values[$index])"
        }) -join ', '
        [void]$script.AppendLine("UPDATE $qualified SET $assignments WHERE $keyClause;")
    }
    if ($hasInserts -and $identity -and $Project.Config.engine -eq 'sqlserver') { [void]$script.AppendLine("SET IDENTITY_INSERT $qualified OFF;") }
    if ($hasInserts -and $Project.Config.engine -eq 'postgresql') {
        $sequences = Get-FirePostgresSeedSequenceScript $Table $columns
        if ($sequences) { [void]$script.AppendLine($sequences) }
    }
    return $script.ToString()
}

function Assert-FireSeedEqual {
    param($Project, $Credentials, [string]$Expected, [string]$Actual, $Database)

    foreach ($table in @($Database.seedTables)) {
        $columns = @(Get-FireSeedColumns $Project $Credentials $Expected $table)
        $left = Get-FireSeedRows $Project $Credentials $Expected $table $columns
        $right = Get-FireSeedRows $Project $Credentials $Actual $table $columns
        if ($left.Count -ne $right.Count) { throw "Seed row count differs in '$($table.name)'." }
        foreach ($key in $left.Keys) {
            if (-not $right.ContainsKey($key) -or $left[$key].Hash -cne $right[$key].Hash) {
                throw "Seed rows differ in '$($table.name)' at key $key."
            }
        }
    }
}

# SIG # Begin signature block
# MIIdvgYJKoZIhvcNAQcCoIIdrzCCHasCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCPX+cE0s8X7PRC
# 5n/bNWn8SRnFBU7RgqZn6qFeF752lqCCF3IwggQ0MIICnKADAgECAhAq44+Z0deO
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
# NwIBCzEOMAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIKNd9nkwsPek6ZRB
# r6fM8tTNG+Uen/0RMjndrOgq0+xmMA0GCSqGSIb3DQEBAQUABIIBgBCNRBmae0/x
# K2xoG9nZKk370jQFsvBm4tYTw4fHaLddcyvsd1z72pMA7pXjoW4qcznHhVihQ08D
# SG5sD5gM7HXLj312o2UubI0xqs7p+r1HI2KsolgwZZACNS58vUjm4xxk2H+5p88r
# MBSp/t9g6RGhUl30Eal63Dlm4I3MO9t8WLH2VzHO8tcXoH87s+zxv7hFc8atQySl
# Q0jfQoQdRvgrWv5iYargkIC8aBBo/5yIVW54ZNJ3NvDgJpToVdqQ/EdgYxJZp+Bb
# 9LyapbGX6LjQW5fmnkmZVxbRfXummZxx3V5C1Ij7gopbY3AdqGM1lwME6x3Tylt9
# wAiEXuhCEUf1uv075+n7AWpLkhlgRpVGrJY3JTZYMv1uE0iQ1o+z/OrU/9LrJcAa
# SUNkh9www7JhJZE3I3DJEqQ18TfVxAoVyhP2zOxGZbcOIjW2yrULEgfo5xkfoYJR
# STQnYXZC1DfVp2YXESxflJBtcxcXx/C4ZjF0PYKpHqsJVdBaa2X3AKGCAyYwggMi
# BgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQK
# Ew5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBU
# aW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP3DNPfkVO28MP
# j/mSGDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJKoZIhvcNAQcB
# MBwGCSqGSIb3DQEJBTEPFw0yNjEwMDExOTU1MjVaMC8GCSqGSIb3DQEJBDEiBCAS
# 0BpX6p+Bg0LNd05E0rRfe2aWT7z4RADN4XSD1xUvzDANBgkqhkiG9w0BAQEFAASC
# AgCtDGkb3BWGZ+WqPxQUAdvNdjiOkWgFdq2WikQ9QWjB44g5tPy5asYj8R+UOAEP
# k0nAIzd48mcpqQu5Jt18cOGWOMdaCald+XLdqrqUarx8DkcR3VcRcHzDOrqOxiI9
# /Ytvcs5/7Ko7dW4ASVwnS7RK1KTh4dhEqQvMbkK5vlUXa3Aj2ihsoYSIWojtYkGH
# pLtpiZn5FLFid7/indX/H6uTu+zOcURTwJtmIf/Zx8Gn3zWIhX0D0Btg4Kjn9cYv
# tZotnsHt/MFvkk8cP5V5TRlq5SBBHQjhMrGH09aIQB9DkQSCJeaGWCeEu1CeTXcH
# KTSxJ8ONA/IfVqm/ChW3nwqsa8ZsGCA4o7gVkyXhLHVK+HDsyvQQvJvfVM6ts0m/
# PcVAR0ddEoOlWqTMXPbCT6sgzzBhUcm+m0/rRZVLt6jOXBUyrzbkL6YutSOrl+Ne
# 0g7vRnvtCes8YpqPVe15iYVjGF5h6nFBQulBHPKCkFtsBmWQZslYkxk21IFcZyxe
# iSOoe0M0vRhdZ8jXLNSZhdcbYfr5RDK/oKhbGEnGnBOCqCob84IjY2KMOGDuluAX
# 9/7M9PdV0wlhHttFxq9SyZ5qcR16pVd4MXNnDZ9+m7qF3OP4CMmiVNU+0nO+AqaO
# RaPRJirc7QLVAdY07Ju09wFPU3Jev6PZXogub6difcvc5Q==
# SIG # End signature block
