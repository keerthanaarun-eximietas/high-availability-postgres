# PostgreSQL HA - Automated Failover and Recovery Test
# Run from the high-availability-pgs project directory.

$ErrorActionPreference = "Stop"
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$Network = "high-availability-pgs_default"
$Nodes = @("ha-postgres-1", "ha-postgres-2")
$HAProxy = "ha-haproxy"
$Database = "ha_demo"
$DBUser = "ha_app"
$TimeoutSeconds = 120

# Unique messages for this test execution
$BeforeMessage = "before-failover-$([guid]::NewGuid().ToString('N'))"
$AfterMessage  = "after-failover-$([guid]::NewGuid().ToString('N'))"

$script:Failed = $false
$script:StoppedNode = $null

function Write-Result {
    param(
        [string]$Message,
        [bool]$Success
    )

    if ($Success) {
        Write-Host "[PASS] $Message" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $Message" -ForegroundColor Red
        $script:Failed = $true
    }
}

function Test-ContainerRunning {
    param([string]$Name)

    $state = & docker inspect -f '{{.State.Running}}' $Name 2>$null

    return ($LASTEXITCODE -eq 0 -and $state -eq "true")
}

function Test-PrimaryEndpoint {
    param([string]$Node)

    $command = "wget -q -O /dev/null http://${Node}:8008/primary >/dev/null 2>&1; echo `$?"

    $result = & docker run --rm --network $Network busybox sh -c $command

    return ($LASTEXITCODE -eq 0 -and $result.Trim() -eq "0")
}

function Get-PrimaryNode {
    $primaryNodes = @()

    foreach ($node in $Nodes) {
        if (Test-PrimaryEndpoint $node) {
            $primaryNodes += $node
        }
    }

    if ($primaryNodes.Count -ne 1) {
        throw "Expected exactly one primary, found $($primaryNodes.Count)."
    }

    return $primaryNodes[0]
}


function Show-ClusterStatus {
    param([string]$Node)

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " PATRONI CLUSTER STATUS" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan

    if ($Node -eq "ha-postgres-1") {
        $config = "/etc/patroni/patroni1.yml"
    }
    else {
        $config = "/etc/patroni/patroni2.yml"
    }

    & docker exec $Node patronictl -c $config list

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARNING] Could not retrieve Patroni cluster status." -ForegroundColor Yellow
    }

    Write-Host ""
}

function Get-NodeIP {
    param([string]$Node)

    $ip = & docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $Node

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ip)) {
        throw "Could not retrieve IP address for $Node."
    }

    return $ip.Trim()
}


function Test-HAProxyConnection {
    param(
        [string]$ExpectedNode,
        [string]$Password
    )

    $expectedIP = Get-NodeIP $ExpectedNode

    $output = & docker run --rm `
        --network $Network `
        -e "PGPASSWORD=$Password" `
        postgres:17 `
        psql -X -A -t `
        -h ha-haproxy `
        -p 5000 `
        -U $DBUser `
        -d $Database `
        -c "SELECT inet_server_addr()::text || '|' || pg_is_in_recovery()::text;" 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "PostgreSQL connection error: $output" -ForegroundColor Red
        return $false
    }

    $result = ($output | Out-String).Trim()
    $parts = $result -split '\|'

    if ($parts.Count -ne 2) {
        Write-Host "Unexpected query output: $result" -ForegroundColor Red
        return $false
    }

    $actualIP = ($parts[0].Trim() -split '/')[0]
    $recovery = $parts[1].Trim()

    Write-Host "Expected primary IP: $expectedIP"
    Write-Host "Actual server IP:    $actualIP"
    Write-Host "Recovery status:     $recovery"

    return ($actualIP -eq $expectedIP -and $recovery -eq "false")
}


function Invoke-DatabaseQuery {
    param(
        [string]$HostName,
        [int]$Port,
        [string]$Password,
        [string]$Query
    )

    if ([string]::IsNullOrWhiteSpace($Query)) {
        Write-Host "DEBUG: Empty SQL query detected!" -ForegroundColor Red
        Write-Host "HostName: $HostName"
        Write-Host "Port: $Port"
        Write-Host "Query value: '$Query'"
        throw "Invoke-DatabaseQuery received an empty SQL query."
    }

    Write-Host "Executing SQL on ${HostName}:${Port}" -ForegroundColor DarkGray

    $output = & docker run --rm `
        --network $Network `
        -e "PGPASSWORD=$Password" `
        postgres:17 `
        psql -X -A -t -v ON_ERROR_STOP=1 `
        -h $HostName `
        -p $Port `
        -U $DBUser `
        -d $Database `
        -c "$Query" 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Database query failed on ${HostName}:${Port}. $output"
    }

    return ($output | Out-String).Trim()
}


function Show-DatabaseQuery {
    param(
        [string]$HostName,
        [int]$Port,
        [string]$Password,
        [string]$Query,
        [string]$Title
    )

    Write-Host ""
    Write-Host "--------------------------------------------" -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host "--------------------------------------------" -ForegroundColor Cyan

    $output = & docker run --rm `
        --network $Network `
        -e "PGPASSWORD=$Password" `
        postgres:17 `
        psql -X -P pager=off `
        -h $HostName `
        -p $Port `
        -U $DBUser `
        -d $Database `
        -c "$Query" 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host ($output | Out-String) -ForegroundColor Red
        throw "Could not display database query results."
    }

    Write-Host ($output | Out-String)
    Write-Host ""
}


function Show-FailoverTestData {
    param(
        [string]$HostName,
        [int]$Port,
        [string]$Password
    )

    Show-DatabaseQuery `
        -HostName $HostName `
        -Port $Port `
        -Password $Password `
        -Title "Failover Test Table Contents" `
        -Query "SELECT id, message FROM ha_failover_test ORDER BY id;"
}

function Wait-ForPrimaryChange {
    param([string]$OldPrimary)

    Write-Host "Waiting for Patroni to promote the standby..." -ForegroundColor Cyan

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $currentPrimary = Get-PrimaryNode

            if ($currentPrimary -ne $OldPrimary) {
                return $currentPrimary
            }
        }
        catch {
            # No primary may be available briefly during promotion.
        }

        Start-Sleep -Seconds 3
    }

    throw "Automatic promotion did not complete within $TimeoutSeconds seconds."
}

function Wait-ForReplica {
    param([string]$Node)

    Write-Host "Waiting for $Node to rejoin as a replica..." -ForegroundColor Cyan

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {

        $command = "wget -q -O /dev/null http://${Node}:8008/replica >/dev/null 2>&1; echo `$?"

        $result = & docker run --rm --network $Network busybox sh -c $command

        if ($LASTEXITCODE -eq 0 -and $result.Trim() -eq "0") {
            return $true
        }

        Start-Sleep -Seconds 3
    }

    throw "$Node did not rejoin as a replica within $TimeoutSeconds seconds."
}

# --------------------------------------------------
# Start test
# --------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " PostgreSQL HA - Failover and Recovery Test" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Check Docker availability
& docker info *> $null

if ($LASTEXITCODE -ne 0) {
    throw "Docker is not available. Start Docker Desktop first."
}

# Check containers
foreach ($container in @($Nodes + $HAProxy)) {
    if (-not (Test-ContainerRunning $container)) {
        throw "Container $container is not running. Start the HA cluster first."
    }

    Write-Result "$container is running" $true
}

# Read database password securely
$securePassword = Read-Host "Enter the ha_app database password" -AsSecureString
$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)

try {
    $DBPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
}

# Identify current primary
$OldPrimary = Get-PrimaryNode
$Standby = @($Nodes | Where-Object { $_ -ne $OldPrimary })[0]

Write-Host ""
Write-Host "Current primary : $OldPrimary"
Write-Host "Current standby : $Standby"
Write-Host ""

Write-Result "Exactly one Patroni primary identified" $true
Show-ClusterStatus -Node $OldPrimary

# Verify initial HAProxy routing
if (Test-HAProxyConnection $OldPrimary $DBPassword) {
    Write-Result "HAProxy routes connections to current primary" $true
}
else {
    throw "HAProxy is not routing to the current primary."
}

Write-Host ""
Write-Host "Preparing pre-failover test data..." -ForegroundColor Cyan

$insertBeforeQuery = "INSERT INTO ha_failover_test (message) VALUES ('$BeforeMessage');"

Invoke-DatabaseQuery `
    -HostName "ha-haproxy" `
    -Port 5000 `
    -Password $DBPassword `
    -Query $insertBeforeQuery | Out-Null

Write-Result "Pre-failover record inserted" $true

Show-DatabaseQuery `
    -HostName "ha-haproxy" `
    -Port 5000 `
    -Password $DBPassword `
    -Title "Database Tables" `
    -Query "\dt"

Show-FailoverTestData `
    -HostName "ha-haproxy" `
    -Port 5000 `
    -Password $DBPassword


# --------------------------------------------------
# Simulate primary failure
# --------------------------------------------------

Write-Host ""
Write-Host "Stopping current primary: $OldPrimary" -ForegroundColor Yellow

try {
    & docker stop $OldPrimary

    if ($LASTEXITCODE -ne 0) {
        throw "Could not stop $OldPrimary."
    }

    $script:StoppedNode = $OldPrimary

    Write-Result "Primary failure simulated" $true

    # Wait for automatic promotion
    $NewPrimary = Wait-ForPrimaryChange $OldPrimary

    Write-Host "New primary: $NewPrimary" -ForegroundColor Cyan

    Write-Result "Patroni automatically promoted $NewPrimary" $true

    # Verify HAProxy routes to promoted primary
    $routingVerified = $false
    $deadline = (Get-Date).AddSeconds(60)

    while ((Get-Date) -lt $deadline) {
        try {
            if (Test-HAProxyConnection $NewPrimary $DBPassword) {
                $routingVerified = $true
                break
            }
        }
        catch {
            # Allow time for HAProxy health checks to update.
        }

        Start-Sleep -Seconds 3
    }

    if (-not $routingVerified) {
        throw "HAProxy did not route to the promoted primary."
    }

    Write-Result "HAProxy rerouted connections to $NewPrimary" $true
    Show-ClusterStatus -Node $NewPrimary

    # --------------------------------------------------
    # Verify data after failover
    # --------------------------------------------------

    Write-Host ""
    Write-Host "Verifying data after failover..." -ForegroundColor Cyan

    # Verify pre-failover record survived
    $beforeCount = Invoke-DatabaseQuery `
        -HostName "ha-haproxy" `
        -Port 5000 `
        -Password $DBPassword `
        -Query "SELECT COUNT(*) FROM ha_failover_test WHERE message = '$BeforeMessage';"

    Write-Host "Pre-failover record count: $beforeCount"

    if ($beforeCount -ne "1") {
        throw "Pre-failover record is missing after promotion."
    }

    Write-Result "Pre-failover record survived failover" $true

    # Insert a new record after promotion
    $insertAfterQuery = "INSERT INTO ha_failover_test (message) VALUES ('$AfterMessage');"

    Invoke-DatabaseQuery `
        -HostName "ha-haproxy" `
        -Port 5000 `
        -Password $DBPassword `
        -Query $insertAfterQuery | Out-Null

    Write-Result "New record inserted after failover" $true
    Show-FailoverTestData `
        -HostName "ha-haproxy" `
        -Port 5000 `
        -Password $DBPassword
}
finally {
    # Always attempt to restore the stopped node.
    if ($script:StoppedNode) {
        Write-Host ""
        Write-Host "Restarting failed node: $script:StoppedNode" -ForegroundColor Yellow

        & docker start $script:StoppedNode

        if ($LASTEXITCODE -ne 0) {
            Write-Host "[FAIL] Could not restart $script:StoppedNode" -ForegroundColor Red
            Write-Host "Please restart it manually using: docker start $script:StoppedNode"
            $script:Failed = $true
        }
        else {
            Write-Result "Failed node restarted" $true
        }
    }
}

# --------------------------------------------------
# Verify recovery
# --------------------------------------------------

if ($script:StoppedNode -and (Test-ContainerRunning $script:StoppedNode)) {
    try {
        Wait-ForReplica $script:StoppedNode | Out-Null

        Write-Result "$script:StoppedNode rejoined as a replica" $true

        Show-ClusterStatus -Node $NewPrimary

        Show-FailoverTestData `
            -HostName $script:StoppedNode `
            -Port 5432 `
            -Password $DBPassword

        # --------------------------------------------------
        # Verify replicated data on recovered replica
        # --------------------------------------------------


        Write-Host ""
        Write-Host "Verifying data on recovered replica..." -ForegroundColor Cyan
        # Wait until both records are visible on the recovered replica
        $dataReplicated = $false
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

        while ((Get-Date) -lt $deadline) {
        try {
        $replicaCount = Invoke-DatabaseQuery `
            -HostName $script:StoppedNode `
            -Port 5432 `
            -Password $DBPassword `
            -Query "SELECT COUNT(*) FROM ha_failover_test WHERE message IN ('$BeforeMessage', '$AfterMessage');"
        if ($replicaCount -eq "2") {
        $dataReplicated = $true
        break
        }
        }
        catch {
        # Retry while the recovered replica catches up.
        }

        Start-Sleep -Seconds 3
        }

        if (-not $dataReplicated) {
        throw "Both test records did not replicate within $TimeoutSeconds seconds."
        }

        Write-Result "Both records replicated to recovered replica" $true
        # Verify that the recovered node is actually in recovery mode
        $recoveryStatus = Invoke-DatabaseQuery `
            -HostName $script:StoppedNode `
            -Port 5432 `
            -Password $DBPassword `
            -Query "SELECT pg_is_in_recovery()::text;"

        if ($recoveryStatus -ne "true") {
        throw "Recovered node is not operating as a replica."
        }

        Write-Result "Recovered node confirmed as a PostgreSQL replica" $true

        Show-ClusterStatus -Node $NewPrimary

        Show-FailoverTestData `
            -HostName "ha-haproxy" `
            -Port 5000 `
            -Password $DBPassword

        # Confirm HAProxy still routes to the new primary
        $currentPrimary = Get-PrimaryNode

        if ($currentPrimary -ne $NewPrimary) {
            throw "Unexpected primary after recovery: $currentPrimary"
        }

        Write-Result "Original promoted primary remains the leader" $true

        if (Test-HAProxyConnection $NewPrimary $DBPassword) {
            Write-Result "HAProxy still routes to the correct primary" $true
        }
        else {
            throw "HAProxy routing verification failed after recovery."
        }

        # Display final Patroni state
        Write-Host ""
        Write-Host "Final Patroni cluster state:" -ForegroundColor Cyan

        & docker exec $NewPrimary patronictl `
            -c "/etc/patroni/$($(if ($NewPrimary -eq 'ha-postgres-1') {'patroni1'} else {'patroni2'})).yml" list
    }
    catch {
        Write-Host "[FAIL] Recovery verification: $_" -ForegroundColor Red
        $script:Failed = $true
    }
}
else {
    Write-Host "[FAIL] The stopped node is not running. Recovery could not be verified." -ForegroundColor Red
    $script:Failed = $true
}

# --------------------------------------------------
# Final result
# --------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan

if ($script:Failed) {
    Write-Host " RESULT: TEST FAILED" -ForegroundColor Red
}
else {
    Write-Host " RESULT: ALL TESTS PASSED" -ForegroundColor Green
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$DBPassword = $null