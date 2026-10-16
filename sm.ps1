function global:sm {
    param(
        [string[]]$Hosts = @('A100-80G', 'PRO6000'),
        [ValidateRange(5, 600)]
        [int]$TimeoutSeconds = 60,
        [switch]$AsObject
    )
    
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = [Console]::OutputEncoding
    $sshPath = (Get-Command ssh -ErrorAction Stop).Source
    $jobs = @()
    try {
        foreach ($machine in $Hosts) {
            $jobs += Start-Job -Name $machine -ArgumentList $sshPath, $machine -ScriptBlock {
                param($sshPath, $machine)
                $ErrorActionPreference = 'Continue'
                [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
                $OutputEncoding = [Console]::OutputEncoding
                $started = Get-Date
                # Run the status script directly to avoid interactive Bash startup overhead.
                $raw = & $sshPath -T -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 $machine 'python3 ~/gpu_status.py' 2>&1
                $code = $LASTEXITCODE
                [pscustomobject]@{
                    HostName = $machine
                    ExitCode = $code
                    Seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
                    Output = ($raw -join [Environment]::NewLine)
                }
            }
        }
        $null = Wait-Job -Job $jobs -Timeout $TimeoutSeconds
        $results = foreach ($job in $jobs) {
            if ($job.State -eq 'Completed') {
                Receive-Job -Job $job
            } else {
                [pscustomobject]@{
                    HostName = $job.Name
                    ExitCode = -1
                    Seconds = $TimeoutSeconds
                    Output = "Query did not complete (state: $($job.State)). Check SSH connectivity/authentication or increase -TimeoutSeconds."
                }
            }
        }
        if ($AsObject) {
            $results
        } else {
            foreach ($result in $results) {
                Write-Host "`n===== $($result.HostName) | exit=$($result.ExitCode) | $($result.Seconds)s =====" -ForegroundColor Cyan
                Write-Host $result.Output
            }
        }
    } finally {
        foreach ($job in $jobs) {
            if ($job.State -in @('Running', 'NotStarted', 'Blocked')) {
                Stop-Job -Job $job -ErrorAction SilentlyContinue
            }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
    
}

