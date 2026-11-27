<#
.SYNOPSIS
  Publica en 127.0.0.1 los servicios del namespace "crediticio" con kubectl port-forward, en los mismos puertos
  que Docker Compose (detén antes Compose con "docker compose stop" para no chocar).

.DESCRIPTION
  Cada port-forward corre como un trabajo en segundo plano de esta ventana de PowerShell: al cerrarla, se
  detienen. Para detenerlos antes: .\acceder.ps1 -Detener

.EXAMPLE
  .\acceder.ps1
  .\acceder.ps1 -Detener
#>
[CmdletBinding()]
param([switch] $Detener)

$Namespace = 'crediticio'
$servicios = @(
    @{ svc = 'scoring-api';          local = 8080; remoto = 8080 },
    @{ svc = 'auth-api';             local = 8081; remoto = 8081 },
    @{ svc = 'evaluation-query-api'; local = 8082; remoto = 8082 },
    @{ svc = 'prometheus';           local = 9090; remoto = 9090 },
    @{ svc = 'grafana';              local = 3001; remoto = 3000 },
    @{ svc = 'postgres';             local = 5433; remoto = 5432 }
)

Get-Job -Name 'crediticio-pf-*' -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job
if ($Detener) { Write-Host 'Port-forward detenidos.'; return }

foreach ($s in $servicios) {
    Start-Job -Name "crediticio-pf-$($s.svc)" -ArgumentList $Namespace, $s.svc, $s.local, $s.remoto -ScriptBlock {
        param($ns, $svc, $local, $remoto)
        # Si el pod se reinicia, el port-forward se corta: se vuelve a abrir solo.
        while ($true) {
            kubectl -n $ns port-forward "svc/$svc" "${local}:${remoto}" --address 127.0.0.1
            Start-Sleep -Seconds 3
        }
    } | Out-Null
    Write-Host ("{0,-22} http://127.0.0.1:{1}" -f $s.svc, $s.local)
}
Write-Host ''
Write-Host 'Port-forward activos mientras esta ventana siga abierta. Detener: .\acceder.ps1 -Detener' -ForegroundColor Green
