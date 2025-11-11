# KipuBankV3 — README

Última actualización: 2025-11-10

Resumen rápido
--------------
KipuBankV3 es un vault que permite a usuarios depositar ETH o cualquier token ERC‑20 que tenga un par directo con USDC en Uniswap V2. Los depósitos (si no son USDC) se intercambian automáticamente a USDC usando el par Uniswap V2 correspondiente y el resultado en USDC se acredita en la cuenta del usuario dentro del vault. El sistema aplica un límite global (bankCap) expresado en USD (con 8 decimales) y mantiene controles administrativos (roles), pausabilidad y protección contra reentrancy.

Hechos importantes
- Balance del usuario: se almacena en USDC (6 decimales) — `s_usdcBalances[user]`.
- Bank cap: valor global en USD con 8 decimales (`s_bankCapUsd8`). Internamente el contrato convierte USDC (6 decimales) → USD8 multiplicando por 100.
- Swap: uso directo de pares Uniswap V2 (no Router). Requiere que exista un par directo `token/USDC`. Para ETH se envuelve a WETH (mediante `IWETH.deposit()`) y luego se hace el swap WETH → USDC.
- Seguridad: AccessControl (ADMIN_ROLE), Pausable y ReentrancyGuard incluidos. `depositETH` y `depositToken` son nonReentrant y `withdraw` respeta CEI.

¿Qué mejoras implementadas y por qué?
-------------------------------------
1. Soporte multi-token con swap automático a USDC
   - Por qué: simplifica la contabilidad (todos los saldos internos están en una única moneda estable) y evita manejar lógica por token.
2. Bank cap en USD (8 decimales)
   - Por qué: permite políticas económicas independientes de la volatilidad del token depositado.
3. Integración con Uniswap V2 pairs
   - Por qué: cumplimiento del requisito "par directo con USDC" (sin rutas multi-hop). Es simple y gas‑eficiente cuando existe el par.
4. Manejo de tokens fee-on-transfer
   - Por qué: algunos tokens reducen la cantidad transferida; calculamos `actualAmountIn = balanceAfter - reserveIn` para soportarlos en muchos casos.
5. Hardening y control administrativo
   - Pausable para emergencias, ReentrancyGuard para mitigar reentrancy, Rescue function para tokens enviados por error, y rol admin mediante AccessControl.
6. Evitar ETH "atascado"
   - Por qué: receive() revierte; obligamos a enviar ETH mediante `depositETH()` que envuelve y procesa el valor.

Instrucciones de despliegue
---------------------------
Requisitos
- Node / npm y Hardhat o Remix para compilar/desplegar.
- Dirección del UniswapV2Factory en la red objetivo.
- Dirección del contrato USDC (token con 6 decimales) en la red objetivo.
- Dirección del WETH de la red objetivo.
- Cuenta de despliegue (recomendado multisig para ADMIN_ROLE en producción).

Constructor
- Firma: `constructor(address _factory, address _usdc, address _weth, uint256 _bankCapUsd8)`
  - `_factory`: Uniswap V2 Factory address.
  - `_usdc`: USDC token contract address (6 decimals).
  - `_weth`: WETH token contract address (para wrapping de ETH).
  - `_bankCapUsd8`: bank cap en USD con 8 decimales. Ejemplo: para $100,000 → `100_000 * 10**8`.

Ejemplo (Remix/Hardhat)
1. Compilar `KipuBankV3_fixed.sol`.
2. Desplegar con los parámetros adecuados:
   - factory = `0x...` (UniswapV2 factory)
   - usdc = `0x...` (USDC token)
   - weth = `0x...` (WETH)
   - bankCapUsd8 = `100_000 * 10**8` (por ejemplo)
3. En el despliegue la cuenta que crea el contrato recibe `ADMIN_ROLE` (usar multisig en producción).

Cómo interactuar (funciones principales)
- depositETH(amountOutMin) payable
  - Envía ETH en `msg.value`. El contrato llama `IWETH.deposit{value: msg.value}()` para obtener WETH y luego intenta swap WETH→USDC por el par WETH/USDC.
  - `amountOutMin` es la cantidad mínima de USDC esperada (en unidades USDC, 6 decimales).
  - Ejemplo en Remix: llamar `depositETH(1000000)` con `Value = 0.5 ETH`; `1000000` = 1 USDC si USDC tiene 6 decimales.

- depositToken(tokenIn, amountIn, amountOutMin)
  - El usuario debe hacer `approve(vaultAddress, amountIn)` previamente.
  - Si `tokenIn == USDC`, el monto se deposita directamente (no swap).
  - Si `tokenIn != USDC`, el vault ejecuta swap en el par `tokenIn/USDC` y acredita al usuario el USDC recibido.
  - `amountOutMin` es el mínimo aceptable de USDC (6 decimales) para proteger contra slippage.

- withdraw(amountUSDC)
  - Retira `amountUSDC` (en USDC pequeñas unidades) desde la cuenta del usuario. Actualiza estado antes de transferir.

Notas de uso y UX
- Aprobaciones: para depositar tokens ERC‑20 distintos de ETH, el flujo es:
  1. `approve(vault, amount)`,
  2. `depositToken(token, amount, amountOutMin)`.
- Slippage: siempre pasar `amountOutMin` razonable para evitar recibir menos USDC del esperado.
- Pausa: `pause()` y `unpause()` están reservados a `ADMIN_ROLE`.

Decisiones de diseño y trade‑offs
--------------------------------
1. Swap directo sobre pares Uniswap V2 (sin Router)
   - Pros: simplicidad, menor gas cuando el par existe directamente, control preciso de la interacción con la pair.
   - Contras: no soporta rutas multi‑hop; si no existe el par `token/USDC`, el depósito falla. Si se desea soporte multihop hay que integrar UniswapV2Router02 o Router v3.

2. Contabilidad en USDC (6 decimals) y bankCap en USD 8‑decimals
   - Pros: balances internos homogéneos y política económica en USD estable.
   - Contras: ligera complejidad por conversión 6→8 (multiplicar por 100). Asegurar coherencia del bankCap al desplegar.

3. Handling fee‑on‑transfer tokens
   - Pros: intentamos soportar tokens que cobran fees detectando `actualAmountIn`.
   - Contras: algunos tokens con hooks o transfer callbacks pueden crear casos edge; podría requerir controles adicionales o blacklist.

4. WETH wrapping vs Router
   - Implementación actual: usamos `IWETH.deposit()` para wrapear ETH y luego swap en pair.
   - Alternativa: usar UniswapV2Router02.swapExactETHForTokens para simplificar ETH→token. Elegí el método de pair directo para mantener control y cumplir el requisito "par directo con USDC" (evitar usar rutas del router).

5. Seguridad / administración
   - ADMIN_ROLE tiene poder para pausar y rescatar tokens (rescueERC20). Se recomienda usar multisig/timelock para ADMIN_ROLE.
   - Se incluyó `rescueERC20` para recuperar tokens enviados por error (solo admin). Esto es útil pero debe controlarse en producción.

Riesgos conocidos y recomendaciones previas a producción
-------------------------------------------------------
- Tokens maliciosos: acepta solo tokens con par directo USDC y con suficiente liquidez. En producción, habilitar una whitelist administrada por admin.
- Oráculos y precios: este contrato NO usa oráculos de precio (Chainlink). Confía en la liquidez del par Uniswap V2 para determinar el precio de swap. Si necesitas controles basados en precio (por ejemplo límites por usuario en USD), integra Chainlink para conversiones fuera del swap.
- Slippage / front‑running: pasar `amountOutMin` protege frente a slippage; usar slippage razonable evita pérdidas por MEV.
- Overflow / precision: las fórmulas de AMM usan multiplicaciones grandes. Para escenarios con números muy grandes, considerar `mulDiv` para precisión y seguridad.
- Auditoría: auditar el contrato, especialmente la lógica de swap directo sobre pair y el manejo de tokens con callbacks.

Pruebas recomendadas (esenciales)
---------------------------------
- depositToken con token==USDC: approve → depositToken → verificar `s_usdcBalances` y `s_totalUsdDeposited8`.
- depositToken con token != USDC que tenga par con USDC: approve → depositToken → verificar swap y acreditación.
- depositETH: depositETH{value: X}(amountOutMin) con par WETH/USDC activo → verificar balances.
- Bank cap enforcement: intentar depositar de modo que `s_totalUsdDeposited8 + receivedUsd8 > s_bankCapUsd8` → debe revertir y no cambiar estado.
- Reentrancy: intentar ataques reentrantes (usar token malicioso) — deposit functions son nonReentrant.
- Envío directo de ETH: enviar ETH con `transfer` o `send` y comprobar que receive() revierte (evitar fondos atascados).

Ejemplo de parámetros (guía práctica)
-------------------------------------
- Si quieres un bank cap de $200,000:
  - `bankCapUsd8 = 200_000 * 10**8`
  - Si un swap devuelve `500 * 10**6` USDC (500 USDC), el contrato convertirá internamente a USD8: `500 * 10**6 * 100 = 500 * 10**8`.

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
