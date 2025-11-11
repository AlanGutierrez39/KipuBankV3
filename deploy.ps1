# KipuBankV3 Deployment Script para Windows
# Ejecutar con: .\deploy.ps1

# Colores
function Write-ColorOutput($ForegroundColor) {
    $fc = $host.UI.RawUI.ForegroundColor
    $host.UI.RawUI.ForegroundColor = $ForegroundColor
    if ($args) {
        Write-Output $args
    }
    $host.UI.RawUI.ForegroundColor = $fc
}

# Banner
Write-Host ""
Write-ColorOutput Cyan @"
 _  ___             ____             _    
| |/ (_)_ __  _   _| __ )  __ _ _ __| | __
| ' /| | '_ \| | | |  _ \ / _` | '_ \ |/ /
| . \| | |_) | |_| | |_) | (_| | | | |   < 
|_|\_\_| .__/ \__,_|____/ \__,_|_| |_|_|\_\
       |_|     V3 Deployment (Windows)       
"@
Write-Host ""

# Cargar .env
if (-Not (Test-Path ".env")) {
    Write-ColorOutput Red "❌ Error: .env file not found"
    Write-Host "Crea un archivo .env con tu PRIVATE_KEY y ETHERSCAN_API_KEY"
    exit 1
}

# Leer variables del .env
Get-Content .env | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
        $name = $matches[1].Trim()
        $value = $matches[2].Trim()
        Set-Variable -Name $name -Value $value -Scope Script
    }
}

# Verificar PRIVATE_KEY
if ([string]::IsNullOrEmpty($PRIVATE_KEY)) {
    Write-ColorOutput Red "❌ Error: PRIVATE_KEY no encontrada en .env"
    exit 1
}

# Configuración de redes
$networks = @{
    sepolia = @{
        name = "Sepolia Testnet"
        rpc = "https://rpc.sepolia.org"
        factory = "0x7E0987E5b3a30e3f2828572Bb659A548460a3003"
        usdc = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
        weth = "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9"
        bankCap = "1000000000000"
        chainId = "11155111"
    }
    mainnet = @{
        name = "Ethereum Mainnet"
        rpc = "https://eth.llamarpc.com"
        factory = "0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f"
        usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
        bankCap = "10000000000000"
        chainId = "1"
    }
    polygon = @{
        name = "Polygon Mainnet"
        rpc = "https://polygon-rpc.com"
        factory = "0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32"
        usdc = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"
        weth = "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619"
        bankCap = "5000000000000"
        chainId = "137"
    }
}

# Menú
Write-Host "Selecciona la red para deployment:"
Write-Host ""
Write-ColorOutput Green "  1) Sepolia Testnet (⭐ Recomendado para pruebas)"
Write-Host "  2) Ethereum Mainnet"
Write-Host "  3) Polygon Mainnet"
Write-Host ""
$choice = Read-Host "Opción [1-3]"

$selectedNetwork = switch ($choice) {
    "1" { "sepolia" }
    "2" { "mainnet" }
    "3" { "polygon" }
    default {
        Write-ColorOutput Red "❌ Opción inválida"
        exit 1
    }
}

$config = $networks[$selectedNetwork]

# Confirmación para mainnet
if ($selectedNetwork -ne "sepolia") {
    Write-ColorOutput Red "⚠️  ADVERTENCIA: Deployando a $($config.name) (usa fondos reales)"
    $confirm = Read-Host "¿Continuar? (yes/no)"
    if ($confirm -ne "yes") {
        Write-Host "Deployment cancelado"
        exit 0
    }
}

# Mostrar configuración
Write-Host ""
Write-ColorOutput Cyan "======================================"
Write-ColorOutput Cyan "   Deploying KipuBankV3"
Write-ColorOutput Cyan "======================================"
Write-Host ""
Write-ColorOutput Yellow "Network: $($config.name)"
Write-ColorOutput Yellow "RPC: $($config.rpc)"
Write-Host ""
Write-ColorOutput Yellow "Constructor params:"
Write-Host "  Factory:  $($config.factory)"
Write-Host "  USDC:     $($config.usdc)"
Write-Host "  WETH:     $($config.weth)"
Write-Host "  Bank Cap: $($config.bankCap) USD8"
Write-Host ""

# Compilar
Write-ColorOutput Yellow "🔨 Compilando contrato..."
forge build
if ($LASTEXITCODE -ne 0) {
    Write-ColorOutput Red "❌ Compilación falló"
    exit 1
}

# Deployar
Write-Host ""
Write-ColorOutput Yellow "🚀 Deploying..."
Write-Host ""

$deployCmd = "forge create --rpc-url $($config.rpc) --private-key $PRIVATE_KEY --constructor-args $($config.factory) $($config.usdc) $($config.weth) $($config.bankCap) src/KipuBankV3.sol:KipuBankV3"

if (-Not [string]::IsNullOrEmpty($ETHERSCAN_API_KEY)) {
    $deployCmd += " --verify --etherscan-api-key $ETHERSCAN_API_KEY"
}

Invoke-Expression $deployCmd

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-ColorOutput Green "✅ Deployment exitoso!"
    Write-Host ""
    Write-ColorOutput Green "🎉 ¡Deployment completado!"
} else {
    Write-ColorOutput Red "❌ Deployment falló"
    exit 1
}
