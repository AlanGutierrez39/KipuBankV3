// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
/*///////////////////////////////////
            Libraries
///////////////////////////////////*/
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/*//////////////////////////////////////////////////////////////
                            INTERFACES
//////////////////////////////////////////////////////////////*/
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/**
 * @title KipuBankV3
 * @author Alan Gutiérrez
 * @notice Vault that accepts ETH and ERC20 tokens. Tokens that have a direct Uniswap V2 pair with USDC
 *         are swapped to USDC and credited to the user's internal USDC balance.
 * @dev Accounting:
 *      - Internal USDC balances are stored in USDC token units (typically 6 decimals).
 *      - Bank cap is stored in USD with 8 decimals (USD8). Conversion: USDC (6d) -> USD8 = USDC * 10^(8-6) = *100.
 *      - All swaps are executed directly against Uniswap V2 pairs (no router).
 *      - Uses SafeERC20, AccessControl, Pausable, and ReentrancyGuard.
 */
contract KipuBankV3 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STATE
    ////////////////////////////////////////////////////////////////*/

    /// @notice USDC token contract (assumed 6 decimals)
    IERC20 public immutable USDC;

    /// @notice Uniswap V2 factory to fetch pair addresses
    IUniswapV2Factory public immutable FACTORY;

    /// @notice WETH token address (used for wrapping ETH)
    address public immutable WETH;

    /// @notice Internal USDC balances per user (USDC smallest unit, typically 6 decimals)
    mapping(address => uint256) public s_usdcBalances;

    /// @notice Aggregated USD value deposited, expressed with 8 decimals (USD8)
    uint256 public s_totalUsdDeposited8;

    /// @notice Maximum allowed USD value (USD8)
    uint256 public s_bankCapUsd8;

    /// @notice Total USDC tokens stored in vault (USDC units)
    uint256 public s_totalUsdcInVault;

    /// @notice Counter of successful deposit operations
    uint256 public s_depositOps;

    /// @notice Admin role alias (uses DEFAULT_ADMIN_ROLE under the hood)
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a deposit + swap to USDC succeeds and the user's vault is credited.
    /// @param user Depositor address
    /// @param tokenIn Input token address
    /// @param amountIn Input token amount
    /// @param usdcReceived Amount of USDC credited to vault
    event DepositAndSwap(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcReceived);

    /// @notice Emitted when the bank cap is updated.
    /// @param oldCap Previous cap (USD8)
    /// @param newCap New cap (USD8)
    event BankCapUpdated(uint256 oldCap, uint256 newCap);

    /// @notice Emitted on user withdrawal.
    /// @param user Withdrawer address
    /// @param amount Amount of USDC withdrawn
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Emitted when admin rescues ERC20 tokens (emergency).
    /// @param token Token rescued
    /// @param to Recipient
    /// @param amount Amount rescued
    event RescueERC20(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS (NatSpec-like comments)
    ////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a zero or invalid address is provided.
    error KipuBankV3_InvalidAddress();

    /// @notice Thrown when caller attempts to operate with a zero amount.
    error KipuBankV3_ZeroAmount();

    /// @notice Thrown when no Uniswap V2 pair exists for tokenIn <-> USDC.
    error KipuBankV3_PairDoesNotExist();

    /// @notice Thrown when the swap output is less than the caller-provided minimum.
    error KipuBankV3_InsufficientOutputAmount();

    /// @notice Thrown when Uniswap pair has zero reserves.
    error KipuBankV3_InsufficientLiquidity();

    /// @notice Thrown when applying the deposit would exceed the bank cap.
    /// @param newTotal Proposed new total in USD8
    /// @param cap Current bank cap in USD8
    error KipuBankV3_BankCapExceeded(uint256 newTotal, uint256 cap);

    /// @notice Thrown when a non-admin calls an admin-only function.
    /// @param who Caller address
    error KipuBankV3_NotAdmin(address who);

    /// @notice Thrown when withdrawing more than available balance.
    error KipuBankV3_NoBalance();

    /// @notice Thrown when WETH deposit() fails (wrap ETH).
    error KipuBankV3_WETHDepositFailed();

    /// @notice Thrown when a low-level token transfer fails.
    /// @param to Recipient address
    /// @param amount Token amount
    error KipuBankV3_TransferFailed(address to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    ////////////////////////////////////////////////////////////////*/

    /// @notice Restricts function to admin role.
    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert KipuBankV3_NotAdmin(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Construct the vault with required dependencies and initial bank cap.
     * @param _factory Uniswap V2 factory address
     * @param _usdc USDC token address (6 decimals assumed)
     * @param _weth WETH token address (wrapper for native ETH)
     * @param _bankCapUsd8 Initial bank cap denominated in USD with 8 decimals
     */
    constructor(address _factory, address _usdc, address _weth, uint256 _bankCapUsd8) {
        if (_factory == address(0) || _usdc == address(0) || _weth == address(0)) revert KipuBankV3_InvalidAddress();

        FACTORY = IUniswapV2Factory(_factory);
        USDC = IERC20(_usdc);
        WETH = _weth;
        s_bankCapUsd8 = _bankCapUsd8;

        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            RECEIVE/FALLBACKS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Reject naked ETH transfers to avoid locked funds.
     * @dev Users should call depositETH() instead, which properly wraps and swaps ETH->USDC.
     */
    receive() external payable {
        revert("Send ETH via depositETH()");
    }

    /** 
      * @notice Reject all other calls to avoid locked funds.
      */
    fallback() external payable {
        revert("Invalid call");
    }
    
    /*//////////////////////////////////////////////////////////////
                                ADMIN
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Pause deposit and withdrawal functions.
     * @dev Only callable by admin role.
     */
    function pause() external onlyAdmin {
        _pause();
    }

    /**
     * @notice Unpause deposit and withdrawal functions.
     * @dev Only callable by admin role.
     */
    function unpause() external onlyAdmin {
        _unpause();
    }

    /**
     * @notice Update the global bank capacity.
     * @dev Emits BankCapUpdated(old, new) after state change.
     * @param newCapUsd8 New cap expressed in USD with 8 decimals.
     */
    function updateBankCap(uint256 newCapUsd8) external onlyAdmin {
        uint256 old = s_bankCapUsd8;
        s_bankCapUsd8 = newCapUsd8;
        emit BankCapUpdated(old, newCapUsd8);
    }

    /**
     * @notice Rescue ERC20 tokens mistakenly sent to contract (emergency only).
     * @dev Admin-only. Cannot be used to withdraw vault's USDC funds.
     * @param token Token address to rescue
     * @param to Recipient address
     * @param amount Amount to rescue (in token smallest units)
     */
    function rescueERC20(address token, address to, uint256 amount) external onlyAdmin nonReentrant {
        if (token == address(0) || to == address(0)) revert KipuBankV3_InvalidAddress();
        if (amount == 0) revert KipuBankV3_ZeroAmount();

        // Prevent rescuing vault USDC funds (safety)
        if (token == address(USDC)) revert KipuBankV3_InvalidAddress();

        IERC20(token).safeTransfer(to, amount);
        emit RescueERC20(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSITS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit native ETH. ETH is wrapped to WETH via IWETH.deposit() and then swapped to USDC.
     * @dev Caller supplies amountOutMin (USDC units) to protect against slippage. The WETH obtained is transferred
     *      to the appropriate Uniswap V2 pair and swapped; resulting USDC is credited to caller's vault balance.
     * @param amountOutMin Minimum acceptable USDC output after performing the swap (in USDC smallest units, e.g. 6 decimals)
     */
    function depositETH(uint256 amountOutMin) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert KipuBankV3_ZeroAmount();

        // Wrap ETH to WETH — deposit() mints WETH to this contract
        // If deposit reverts, bubble up (no try/catch necessary)
        IWETH(WETH).deposit{value: msg.value}();

        // Swap WETH -> USDC and credit user
        _swapAndCredit(WETH, msg.value, amountOutMin);
    }

    /**
     * @notice Deposit ERC20 token. If tokenIn == USDC, it's credited directly. Otherwise it's swapped to USDC via Uniswap V2.
     * @dev Caller MUST approve this contract for amountIn prior to calling.
     * @param tokenIn Address of token being deposited
     * @param amountIn Amount of tokenIn to deposit (token smallest units)
     * @param amountOutMin Minimum acceptable USDC output after swap (USDC units, e.g. 6 decimals)
     */
    function depositToken(address tokenIn, uint256 amountIn, uint256 amountOutMin)
        external
        nonReentrant
        whenNotPaused
    {
        if (tokenIn == address(0)) revert KipuBankV3_InvalidAddress();
        if (amountIn == 0) revert KipuBankV3_ZeroAmount();

        // Pull tokens from user to vault
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // If USDC, credit directly. Otherwise swap to USDC via Uniswap V2.
        if (tokenIn == address(USDC)) {
            _creditUser(msg.sender, amountIn);
            emit DepositAndSwap(msg.sender, tokenIn, amountIn, amountIn);
            return;
        }

        _swapAndCredit(tokenIn, amountIn, amountOutMin);
    }

    /*//////////////////////////////////////////////////////////////
                                SWAP + CREDIT (INTERNAL)
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Swap tokenIn -> USDC using Uniswap V2 pair and credit the resulting USDC to `msg.sender`.
     * @dev This function is split into helper functions to avoid stack-too-deep errors.
     * @param tokenIn The token to swap from (token already in this contract)
     * @param amountIn Amount of tokenIn to swap (token units)
     * @param amountOutMin Minimum USDC out expected (USDC smallest units)
     */
    function _swapAndCredit(address tokenIn, uint256 amountIn, uint256 amountOutMin) internal {
        address pair = FACTORY.getPair(tokenIn, address(USDC));
        if (pair == address(0)) revert KipuBankV3_PairDoesNotExist();

        // Execute the swap and get USDC received
        uint256 receivedUSDC = _executeSwap(pair, tokenIn, amountIn, amountOutMin);

        // Credit user
        _creditUser(msg.sender, receivedUSDC);

        emit DepositAndSwap(msg.sender, tokenIn, amountIn, receivedUSDC);
    }

    /**
     * @notice Execute the actual Uniswap V2 swap.
     * @dev Separated to avoid stack-too-deep errors in _swapAndCredit.
     * @param pair Uniswap V2 pair address
     * @param tokenIn Input token address
     * @param amountIn Input token amount
     * @param amountOutMin Minimum output amount expected
     * @return receivedUSDC Actual USDC received from the swap
     */
    function _executeSwap(
        address pair,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal returns (uint256 receivedUSDC) {
        // Get reserves and determine token order
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        bool token0IsTokenIn = IUniswapV2Pair(pair).token0() == tokenIn;

        uint256 reserveIn = token0IsTokenIn ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveOut = token0IsTokenIn ? uint256(reserve1) : uint256(reserve0);
        
        if (reserveIn == 0 || reserveOut == 0) revert KipuBankV3_InsufficientLiquidity();

        // Transfer tokenIn to pair
        IERC20(tokenIn).safeTransfer(pair, amountIn);

        // Calculate actual amount received by pair (supports fee-on-transfer)
        uint256 actualAmountIn = IERC20(tokenIn).balanceOf(pair) - reserveIn;
        if (actualAmountIn == 0) revert KipuBankV3_ZeroAmount();

        // Calculate expected output using Uniswap V2 formula
        uint256 amountOutExpected = (actualAmountIn * 997 * reserveOut) / 
                                     ((reserveIn * 1000) + (actualAmountIn * 997));
        
        if (amountOutExpected < amountOutMin) revert KipuBankV3_InsufficientOutputAmount();

        // Snapshot USDC balance
        uint256 usdcBefore = USDC.balanceOf(address(this));

        // Execute swap
        (uint256 amount0Out, uint256 amount1Out) = token0IsTokenIn
            ? (uint256(0), amountOutExpected)
            : (amountOutExpected, uint256(0));
        
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), "");

        // Calculate received USDC
        receivedUSDC = USDC.balanceOf(address(this)) - usdcBefore;
        if (receivedUSDC < amountOutMin) revert KipuBankV3_InsufficientOutputAmount();
    }

    /**
     * @notice Credit user with received USDC and update global accounting, enforcing the bank cap.
     * @dev Converts USDC (6 decimals) to USD8 (multiply by 100) before checking cap.
     * @param user Recipient to credit
     * @param receivedUSDC Amount of USDC obtained from swap (6 decimals)
     */
    function _creditUser(address user, uint256 receivedUSDC) internal {
        // convert 6 -> 8 decimals safely (Solidity 0.8 overflow-checked)
        uint256 receivedUsd8 = receivedUSDC * 100;

        uint256 newTotalUsd8 = s_totalUsdDeposited8 + receivedUsd8;
        if (newTotalUsd8 > s_bankCapUsd8) revert KipuBankV3_BankCapExceeded(newTotalUsd8, s_bankCapUsd8);

        s_usdcBalances[user] += receivedUSDC;
        s_totalUsdcInVault += receivedUSDC;
        s_totalUsdDeposited8 = newTotalUsd8;
        s_depositOps += 1;
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAWALS
    ////////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw USDC from your internal vault balance.
     * @dev State is updated before the external transfer (checks-effects-interactions).
     * @param amountUSDC Amount to withdraw in USDC smallest units (e.g. 6 decimals)
     */
    function withdraw(uint256 amountUSDC) external nonReentrant whenNotPaused {
        if (amountUSDC == 0) revert KipuBankV3_ZeroAmount();
        uint256 bal = s_usdcBalances[msg.sender];
        if (bal < amountUSDC) revert KipuBankV3_NoBalance();

        // Effects
        s_usdcBalances[msg.sender] = bal - amountUSDC;
        s_totalUsdcInVault -= amountUSDC;

        // Interaction using SafeERC20 (handles non-standard tokens)
        USDC.safeTransfer(msg.sender, amountUSDC);

        emit Withdraw(msg.sender, amountUSDC);
    }
}
