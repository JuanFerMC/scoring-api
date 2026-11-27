<#
.SYNOPSIS
  Elimina el entorno de Kubernetes: borra el namespace "crediticio" con todo su contenido, incluida la base de
  datos (PersistentVolumeClaim), los Secret y las claves RSA. No afecta a Docker Compose ni a las imágenes.

.EXAMPLE
  .\eliminar.ps1
  .\eliminar.ps1 -Confirmar
#>
[CmdletBinding()]
param([switch] $Confirmar)

$Namespace = 'crediticio'
$contexto = (kubectl config current-context) 2>$null
Write-Host "Contexto de kubectl: $contexto"
if (-not $Confirmar) {
    $respuesta = Read-Host "Se borrará el namespace '$Namespace' (incluida su base de datos). Escribe 'si' para continuar"
    if ($respuesta -ne 'si') { Write-Host 'Cancelado.'; return }
}
Get-Job -Name 'crediticio-pf-*' -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job
kubectl delete namespace $Namespace --ignore-not-found --wait=true
