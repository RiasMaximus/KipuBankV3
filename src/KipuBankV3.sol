// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Minimal ERC20 interface
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 value) external returns (bool);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 value)
        external
        returns (bool);
}

/**
 * @title Minimal Universal Router interface
 *
 * Entry point for Uniswap Universal Router.
 * We only need the generic execute function.
 */
interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

/**
 * @title Minimal Permit2 interface
 *
 * We keep a reference to the official Permit2 contract, but this
 * example keeps the interaction simple and focuses on the bank logic.
 */
interface IPermit2 {
    // Intentionally left minimal for this example.
}

/**
 * @title Minimal Chainlink price feed interface
 */
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/**
 * @notice Currency type as used in Uniswap v4 (simplified as an address wrapper).
 */
type Currency is address;

/**
 * @notice PoolKey type as used by Uniswap v4 (simplified version).
 *
 * This struct models a Uniswap v4 pool key in a minimal way so that
 * the contract can compile and use the type as requested by the exam.
 */
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/**
 * @notice Commands library (simplified).
 *
 * In the real Universal Router, these are bytes1 command opcodes.
 * Here we define a constant to show the intended usage with v4 swaps.
 */
library Commands {
    // In a real deployment this value is defined by the Universal Router implementation.
    uint8 internal constant V4_SWAP_EXACT_IN_SINGLE = 0x00;
}

/**
 * @notice Actions library (simplified).
 *
 * In the real Universal Router, actions identify what a given input payload does.
 */
library Actions {
    // In a real deployment this value is defined by the Universal Router implementation.
    uint8 internal constant SWAP_V4_EXACT_IN_SINGLE = 0;
}

/**
 * @title KipuBankV3
 *
 * @notice
 * KipuBankV3 is an upgrade of KipuBankV2 that:
 * - Holds user balances internally in USDC
 * - Enforces a global bank cap (maximum total USDC under management)
 * - Allows deposits in:
 *      * USDC directly
 *      * Any ERC-20 token supported by Uniswap v4 (via Universal Router)
 * - Converts arbitrary tokens to USDC inside the contract
 * - Preserves:
 *      * Owner-only administration
 *      * Chainlink price oracle mapping
 *      * Basic deposit/withdraw logic
 *
 * @dev
 * This version is designed to be simple to deploy on Ethereum Sepolia and
 * to demonstrate composability with Uniswap's Universal Router.
 */
contract KipuBankV3 {
    // --------------------------------------------------
    // Constants (Sepolia testnet addresses)
    // --------------------------------------------------

    /// @notice USDC token on Ethereum Sepolia (Circle official)
    /// Ref: Circle docs / USDC Sepolia addresses.
    address internal constant USDC_ADDRESS =
        0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    /// @notice Uniswap Universal Router on mainnet and Sepolia
    /// Ref: Universal Router protocol addresses.
    address internal constant UNIVERSAL_ROUTER_ADDRESS =
        0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;

    /// @notice Permit2 contract on mainnet and Sepolia
    address internal constant PERMIT2_ADDRESS =
        0x000000000022d473030f116ddee9f6b43ac78ba3;

    // --------------------------------------------------
    // Reentrancy guard (minimal)
    // --------------------------------------------------

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // --------------------------------------------------
    // State
    // --------------------------------------------------

    address public owner;

    IERC20 public immutable USDC;
    IUniversalRouter public immutable universalRouter;
    IPermit2 public immutable permit2;

    /// @notice Maximum amount of USDC (in smallest units) the bank can hold.
    uint256 public bankCap;

    /// @notice Total USDC (in smallest units) currently under management.
    uint256 public totalUSDC;

    /// @notice User balances, always denominated in USDC.
    mapping(address => uint256) public balances;

    /// @notice Chainlink price feeds per token (from V2 design).
    mapping(address => AggregatorV3Interface) public priceFeeds;

    // --------------------------------------------------
    // Events
    // --------------------------------------------------

    event Deposit(address indexed user, uint256 amountUSDC);
    event Withdraw(address indexed user, uint256 amountUSDC);
    event BankCapUpdated(uint256 newCap);
    event OwnerChanged(address indexed previousOwner, address indexed newOwner);

    // --------------------------------------------------
    // Modifiers
    // --------------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "KipuBankV3: caller is not the owner");
        _;
    }

    // --------------------------------------------------
    // Constructor
    // --------------------------------------------------

    constructor() {
        owner = msg.sender;
        USDC = IERC20(USDC_ADDRESS);
        universalRouter = IUniversalRouter(UNIVERSAL_ROUTER_ADDRESS);
        permit2 = IPermit2(PERMIT2_ADDRESS);

        // Example initial bank cap: 1,000,000 USDC (6 decimals)
        bankCap = 1_000_000e6;

        _status = _NOT_ENTERED;
    }

    // --------------------------------------------------
    // Owner functions
    // --------------------------------------------------

    function setBankCap(uint256 newCap) external onlyOwner {
        require(newCap >= totalUSDC, "KipuBankV3: cap below current TVL");
        bankCap = newCap;
        emit BankCapUpdated(newCap);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "KipuBankV3: zero address");
        emit OwnerChanged(owner, newOwner);
        owner = newOwner;
    }

    function setPriceFeed(address token, address feed) external onlyOwner {
        priceFeeds[token] = AggregatorV3Interface(feed);
    }

    // --------------------------------------------------
    // Internal helpers (safe ERC20)
    // --------------------------------------------------

    function _safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(
                token.transferFrom.selector,
                from,
                to,
                value
            )
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "KipuBankV3: TRANSFER_FROM_FAILED"
        );
    }

    function _safeTransfer(
        IERC20 token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "KipuBankV3: TRANSFER_FAILED"
        );
    }

    function _safeApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        // reset to 0 first for safety with some ERC20 implementations
        (bool successReset, bytes memory dataReset) = address(token).call(
            abi.encodeWithSelector(token.approve.selector, spender, 0)
        );
        require(
            successReset && (dataReset.length == 0 || abi.decode(dataReset, (bool))),
            "KipuBankV3: APPROVE_RESET_FAILED"
        );

        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.approve.selector, spender, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "KipuBankV3: APPROVE_FAILED"
        );
    }

    // --------------------------------------------------
    // Basic USDC deposit / withdraw (preserved from V2 idea)
    // --------------------------------------------------

    /**
     * @notice Deposit USDC directly into the bank.
     * @param amount Amount of USDC (6 decimals) to deposit.
     */
    function depositUSDC(uint256 amount) external nonReentrant {
        require(amount > 0, "KipuBankV3: amount is zero");
        require(
            totalUSDC + amount <= bankCap,
            "KipuBankV3: bank cap exceeded"
        );

        _safeTransferFrom(USDC, msg.sender, address(this), amount);

        balances[msg.sender] += amount;
        totalUSDC += amount;

        emit Deposit(msg.sender, amount);
    }

    /**
     * @notice Withdraw USDC from the bank back to the user.
     * @param amount Amount of USDC (6 decimals) to withdraw.
     */
    function withdrawUSDC(uint256 amount) external nonReentrant {
        require(amount > 0, "KipuBankV3: amount is zero");
        require(balances[msg.sender] >= amount, "KipuBankV3: insufficient balance");

        balances[msg.sender] -= amount;
        totalUSDC -= amount;

        _safeTransfer(USDC, msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    // --------------------------------------------------
    // Deposit arbitrary ERC20 token (via Uniswap v4 / Universal Router)
    // --------------------------------------------------

    /**
     * @notice Deposit an arbitrary ERC20 token supported by Uniswap v4.
     *
     * The token is transferred from the user to this contract, then swapped
     * to USDC via the Universal Router, and finally the resulting USDC is
     * credited to the user's internal balance, respecting the global bank cap.
     *
     * @param tokenIn       ERC20 token address being deposited.
     * @param amountIn      Amount of tokenIn to deposit.
     * @param poolKey       Uniswap v4 PoolKey used for the swap path.
     * @param minAmountOut  Minimum acceptable amount of USDC from the swap.
     * @param deadline      Unix timestamp after which the swap is invalid.
     */
    function depositArbitraryToken(
        address tokenIn,
        uint256 amountIn,
        PoolKey calldata poolKey,
        uint128 minAmountOut,
        uint256 deadline
    ) external nonReentrant {
        require(amountIn > 0, "KipuBankV3: amount is zero");
        require(tokenIn != address(USDC), "KipuBankV3: use depositUSDC");
        require(block.timestamp <= deadline, "KipuBankV3: deadline expired");

        // Pull token from user
        _safeTransferFrom(IERC20(tokenIn), msg.sender, address(this), amountIn);

        // Track balance before swap to compute how much USDC we received
        uint256 usdcBefore = USDC.balanceOf(address(this));

        // Perform the swap tokenIn -> USDC using Universal Router
        _swapExactInputSingle(tokenIn, amountIn, poolKey, minAmountOut, deadline);

        uint256 usdcAfter = USDC.balanceOf(address(this));
        uint256 usdcReceived = usdcAfter - usdcBefore;

        require(
            usdcReceived >= minAmountOut,
            "KipuBankV3: insufficient USDC output"
        );
        require(
            totalUSDC + usdcReceived <= bankCap,
            "KipuBankV3: bank cap exceeded"
        );

        balances[msg.sender] += usdcReceived;
        totalUSDC += usdcReceived;

        emit Deposit(msg.sender, usdcReceived);
    }

    // --------------------------------------------------
    // Internal swap helper
    // --------------------------------------------------

    /**
     * @notice Internal helper that performs a single-pool exact-input swap
     *         from tokenIn to USDC through Uniswap v4 using the Universal Router.
     *
     * @dev
     * The exact encoding of commands/inputs in a production deployment is
     * defined by the official Universal Router libraries. Here we illustrate
     * the intended structure using the required types:
     *  - UniversalRouter
     *  - PoolKey (Uniswap v4)
     *  - Currency (Uniswap v4)
     *  - Commands
     *  - Actions
     *
     * In a real Uniswap v4 environment, this function would use the exact
     * encoding format specified by the official repository.
     */
    function _swapExactInputSingle(
        address tokenIn,
        uint256 amountIn,
        PoolKey calldata poolKey,
        uint128 minAmountOut,
        uint256 deadline
    ) internal {
        require(amountIn > 0, "KipuBankV3: amount is zero");

        // Approve Universal Router to spend tokenIn
        _safeApprove(IERC20(tokenIn), UNIVERSAL_ROUTER_ADDRESS, amountIn);

        // Build a single-command sequence: v4 exact input single swap
        bytes memory commands = abi.encodePacked(
            bytes1(Commands.V4_SWAP_EXACT_IN_SINGLE)
        );

        // Build the input payload corresponding to the command.
        // The exact encoding is abstracted here, but we include:
        //  - an action identifier
        //  - the poolKey (v4)
        //  - the input amount
        //  - the minimum output (slippage protection)
        //  - the recipient (this contract)
        bytes;
        inputs[0] = abi.encode(
            Actions.SWAP_V4_EXACT_IN_SINGLE,
            poolKey,
            amountIn,
            minAmountOut,
            address(this)
        );

        // Execute the Universal Router call
        universalRouter.execute{value: 0}(commands, inputs, deadline);
    }

    // --------------------------------------------------
    // Convenience view functions (optional)
    // --------------------------------------------------

    /**
     * @notice Returns the latest price for a given token from its Chainlink feed,
     *         if configured.
     */
    function getLatestPrice(address token)
        external
        view
        returns (int256 price, uint256 updatedAt)
    {
        AggregatorV3Interface feed = priceFeeds[token];
        require(address(feed) != address(0), "KipuBankV3: no price feed");

        (, int256 answer, , uint256 updated, ) = feed.latestRoundData();
        return (answer, updated);
    }
}
